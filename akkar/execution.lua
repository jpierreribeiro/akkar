--[[
Execution: what an akkar execution is, with no HTTP in it.

akkar stopped being a web framework and became a runtime for services -- the
rockspec says so, the README says so, `docs/RUNTIME-1.0.md` sustains it with
measurement. The code did not say so. Every piece of the execution machinery --
identity, deadline, lazily acquired capabilities, guaranteed release -- lived as
local state inside ONE function, `handle(app, input)` in `akkar/init.lua`,
reachable only by an HTTP request.

The consequence was measured rather than argued: `app:task` receives
`{ name, stopping, app }` and nothing else. No `db`, no `cache`, no `log`, and
no way to reach them through `app` either, because `app:run`'s config is never
kept on `self`. Whoever writes a worker closes over their own connection,
outside the closed capability set that is half the point of the framework.

TWO LIFETIMES, AND KEEPING THEM APART IS THE WHOLE DESIGN:

    service lifetime      lives with the process      stopping, supervisor,
                                                      the root logger
    invocation lifetime   lives with one unit of      id, deadline,
                          work                        capabilities, cleanup

A task may be eternal. AN EXECUTION INSIDE IT MAY NOT. This distinction exists
because the obvious move -- "give capabilities to `app:task`" -- would hold a
database connection open for the whole life of a task, which can be months.

WHAT THIS MODULE IS NOT: it is not a per-request object. Allocation on this
path is measured, and a scope object costs 152 bytes against 169 of headroom
under the ceiling; a closure costs 80 per upvalue, so "make the scope a
closure" costs MORE, not less. So the record is a table the caller already
allocates, the carrier is the request itself, and the only thing this module
adds is behaviour hoisted into a metatable built once at load.

Internal in this phase. Nothing here is exported on the `akkar` table, and the
HTTP layer keeps its own metatable which handles `ip`, `trace` and `user` and
then delegates here. This module never learns what a header is.
]]

local cqueues = require "cqueues"
local time    = require "akkar.time"

local M = {}

-- ============================================================== capabilities

-- A capability is infrastructure the framework knows how to inject, guard and
-- fake.  Anything belonging to the application -- a mailer, a payment gateway,
-- a recommendation service -- does not qualify and must be closed over by the
-- handler instead.  Without an admission rule this table grows forever, and
-- every entry becomes permanent: moving `req.db` to `ctx.db` later would force
-- an edit to every handler ever written, which is exactly what the complexity
-- ladder forbids.
M.CAPABILITIES = { db = true, cache = true, log = true, clock = true,
                   http = true }

-- ==================================================================== guards
-- Invariant: reading something that was never configured gives a useful
-- message, not "attempt to index a nil value".
-- A guard is immutable and its identity carries no meaning, so one per name
-- is built once and shared.  Every request was allocating a table, a
-- metatable and three closures to represent the same nothing.
--
-- `__newindex` is what makes sharing safe: without it, `req.user.id = 1` on
-- an unauthenticated request would silently write into an object every other
-- request also holds.  With it, that line says what is actually wrong.
local guards = {}

function M.guard(name, hint)
  local existing = guards[name]
  if existing then return existing end

  local fail = function() error(hint, 2) end
  local g = setmetatable({}, {
    __index = fail,
    __call = fail,
    __newindex = fail,
    __tostring = function() return "<" .. name .. " missing>" end,
  })
  guards[name] = g
  return g
end

-- ================================================================ identity

-- A counter behind a per-process prefix, not a random draw per execution.
-- Within a process a counter cannot collide at all, which is strictly better
-- than hoping two 48-bit draws differ; across processes the prefix separates
-- them.
local ID_PREFIX = string.format("%08x", math.random(0, 0xffffffff))
local id_counter = 0

--- The next execution id. Callers that accept a caller-supplied id -- the HTTP
--- layer honours `x-request-id` -- decide that themselves and only fall back
--- here, because "trust a header" is a transport question.
function M.id()
  id_counter = id_counter + 1
  return ID_PREFIX .. string.format("%06x", id_counter & 0xffffff)
end

-- ================================================================== deadline
-- Wall-clock budget for one execution.
--
-- Arbitration follows one rule, learned the expensive way on an earlier
-- project: THE WINNER IS DECIDED BY THE FIRST ARBITRATING EVENT AND A LATE
-- EVENT NEVER OVERTURNS IT.  A handler that finishes at 4.99 s against a 5 s
-- deadline has completed; reporting that as a timeout would discard work that
-- actually happened, which is how this goes wrong silently.
--
-- A nested controller is stepped through `cqueues.poll`, never `loop`, because
-- calling loop() from inside the server's controller would block every other
-- request -- exactly the failure this is meant to prevent.
--
-- HONEST LIMIT: this is cooperative.  It can only fire while the handler is
-- yielding on I/O.  A handler burning CPU in a tight loop is not interrupted
-- by the deadline; that is what the watchdog reports instead.
local controller_pool = {}

-- The pool size, overridable at load for one reason: it is the prime suspect
-- in `docs/substrate/SEGFAULT.md`. Four crashes, all at the same instruction --
-- `table_LLRB_FIND` walking a pollset's file-descriptor tree -- and recycling
-- pollsets is the thing akkar does that most cqueues users do not.
--
-- `AKKAR_CONTROLLER_POOL=0` turns recycling off: every execution gets a fresh
-- controller and none is ever reused. If the crashes stop, the pool is
-- implicated; if they continue, it is not, and that is worth as much.
--
-- Read once, at load, so nothing checks an environment variable per request.
-- This goes away with the pool itself when F2 lands.
local POOL_LIMIT = tonumber(os.getenv "AKKAR_CONTROLLER_POOL") or 64

--- Runs `fn` under a wall-clock budget. Returns the outcome and the result:
--- `"COMPLETION"`, or `"TIMEOUT"`, and raises on `"ERROR"`.
---
--- Does NOT release anything. See `M.attempt` and `M.run`.
function M.with_deadline(seconds, fn)
  if not seconds or seconds <= 0 or not cqueues.running() then
    return "COMPLETION", fn()          -- no budget, or no controller to yield to
  end

  -- Controllers are pooled, and speed is only one of three reasons.
  --
  -- Three separate investigations landed on this object.  A fresh
  -- `cqueues.new()` per request cost 25 us of akkar's 34.7 us total overhead;
  -- it contributed to the 2,814 bytes of garbage a trivial request produced;
  -- and each controller holds **exactly 2.00 file descriptors** on epoll,
  -- confirmed at three different limits:
  --
  --     ulimit -n 256   ->  126 controllers   (2.03 each)
  --     ulimit -n 1024  ->  510 controllers   (2.01 each)
  --     ulimit -n 4096  -> 2046 controllers   (2.00 each)
  --
  -- and THREE on kqueue, which the platform matrix found on macOS.
  --
  -- Those descriptors came back only when the collector ran, which quietly
  -- tied a hard operating-system limit to the pace of the garbage collector.
  -- Nothing declared that, and no profile would have shown it.
  local cq = table.remove(controller_pool) or cqueues.new()
  local winner, result

  cq:wrap(function()
    local ok, res = pcall(fn)
    if winner == nil then              -- first arbitrating event wins
      winner = ok and "COMPLETION" or "ERROR"
      result = res
    end
  end)

  -- Step before polling.  `wrap` only queues the coroutine, so the handler has
  -- not started yet; polling first made every synchronous request wait on a
  -- descriptor for work that was already ready to run.
  cq:step(0)

  local deadline = time.monotime() + seconds
  while winner == nil do
    local remaining = deadline - time.monotime()
    if remaining <= 0 then break end
    cqueues.poll(cq, remaining)        -- yields to the outer controller
    cq:step(0)
  end

  -- Only an empty controller goes back.  A handler abandoned by the deadline
  -- is still running inside its controller, and reusing that would hand the
  -- next request someone else's unfinished work -- the same class of bug as a
  -- pooled database connection with a transaction still open.
  if cq:empty() and #controller_pool < POOL_LIMIT then
    controller_pool[#controller_pool + 1] = cq
  end

  if winner == nil then winner = "TIMEOUT" end
  if winner == "ERROR" then error(result, 0) end
  return winner, result
end

return M
