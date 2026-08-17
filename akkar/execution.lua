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

-- ============================================================ the budget
-- The deadline as a NUMBER the whole execution can read, rather than as a
-- scheduler that watches it.
--
-- A wall-clock budget is one instant: `now + seconds`. Everything downstream
-- needs the same one, and the reason is a defect that is in the tree today --
-- `akkar/http.lua` opens every outbound call with its own `timeout = 10`, so a
-- request with 200 ms left calls the service below it with ten seconds. That
-- is the cascading-failure pattern the SRE book names, built in by default,
-- and no amount of care at the call site fixes it because the call site does
-- not know the budget.
--
-- KEYED BY THE RUNNING COROUTINE, WEAKLY, and that is not a new idea here:
-- `akkar/http.lua` already keys its connect timeout the same way, and its
-- comment gives the reasoning -- "the calling coroutine is an exact key. Weak,
-- because an abandoned coroutine must not keep an entry alive."
--
-- What this buys over the alternatives, all of which were considered:
--
--   * a field on the capability     -- `http.connect` returns ONE shared client
--                                      for the whole app, so a deadline on it
--                                      would be one request's budget applied to
--                                      every other request. That is the exact
--                                      aliasing defect this project has fixed
--                                      three times already.
--   * an argument threaded through -- every adapter signature changes, and a
--                                      third-party adapter that does not know
--                                      about it silently loses its deadline.
--   * a wrapper object per request  -- an allocation per request, and the
--                                      ceiling has refused smaller ones.
--
-- This costs one hash insert per execution that HAS a budget, and nothing at
-- all for one that does not.
local deadlines = setmetatable({}, { __mode = "k" })

--- Starts a budget for the running coroutine. `seconds` nil or <= 0 means no
--- budget, and clears any inherited one rather than leaving it to be found.
function M.begin(seconds)
  local co = coroutine.running()
  if not co then return end
  if seconds and seconds > 0 then
    deadlines[co] = time.monotime() + seconds
  else
    deadlines[co] = nil
  end
end

--- Ends the budget for the running coroutine.
---
--- The weak table would drop it eventually, but "eventually" is the pace of
--- the collector, and this project has already tied one operating-system limit
--- to that pace by accident. Cleared explicitly.
function M.finish()
  local co = coroutine.running()
  if co then deadlines[co] = nil end
end

--- The instant this execution must be done by, or nil when it has no budget.
function M.deadline()
  local co = coroutine.running()
  return co and deadlines[co] or nil
end

--- Seconds left, or nil when there is no budget. Negative when it has passed,
--- which a caller must treat as "already too late" rather than as "no limit" --
--- passing a negative number to an I/O call is how you get a hang.
function M.remaining()
  local at = M.deadline()
  if not at then return nil end
  return at - time.monotime()
end

--- `want` seconds, or whatever the execution has left, whichever is smaller.
---
--- The one function a capability should call. Returns nil only when there is
--- no budget anywhere, which means "your own default applies".
function M.bounded(want)
  local left = M.remaining()
  if not left then return want end
  if not want then return left end
  return (left < want) and left or want
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
    -- THE BUDGET IS PUBLISHED EVEN HERE, and the reason is `app:test`.
    --
    -- Without a controller there is nothing to arbitrate with, so this branch
    -- cannot abandon a handler -- but capabilities can still honour the
    -- number, and `app:test { timeout = 4 }` runs entirely down this path. A
    -- deadline that a test cannot see but production can is a trap: it makes
    -- the tested behaviour and the shipped behaviour different in exactly the
    -- dimension the test was written to check.
    --
    -- `seconds` nil or <= 0 clears rather than inherits.
    M.begin(seconds)
    return "COMPLETION", fn()
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
    -- The budget starts inside the coroutine that will do the work, because
    -- it is keyed by that coroutine. Every capability the handler touches can
    -- now read how long it has.
    M.begin(seconds)
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

  -- A FAILURE AFTER THE BUDGET PASSED IS THE DEADLINE, NOT AN ERROR.
  --
  -- Two arbiters now race for the same instant. The controller above expires
  -- at the deadline; so does the socket timeout each capability sets from the
  -- same budget. Whichever fires first, the request is over for the same
  -- reason -- but when the socket wins, the handler RAISES, and without this
  -- the client is told 500 for what is plainly a timeout.
  --
  -- Caught by `spec/abandoned_spec.lua`, which asserted 503 and got 500 the
  -- moment the database started honouring the budget. A deadline is not a
  -- server error, and reporting it as one sends whoever reads the log looking
  -- for a bug that is not there.
  --
  -- Completion is still never overturned: a handler that finished at 4.99 s
  -- against a 5 s budget has completed, and this branch is only reached when
  -- it failed.
  if winner == "ERROR" and time.monotime() >= deadline then
    winner = "TIMEOUT"
  end

  if winner == "ERROR" then error(result, 0) end
  return winner, result
end

return M
