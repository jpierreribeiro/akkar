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

local cqueues   = require "cqueues"
local condition = require "cqueues.condition"
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

-- ============================================================== the lifetime
-- Acquiring capabilities, and releasing them exactly once.
--
-- THE RECORD IS A TABLE THE CALLER ALREADY HAS. Allocation on this path is
-- measured, and a scope object costs 152 bytes against 169 of headroom under
-- the ceiling -- so there is no scope object. The HTTP layer passes the
-- `input` table its server already built; a worker will pass the job's.
--
-- THE CARRIER IS WHATEVER THE HANDLER SEES. In HTTP that is `req`, which is
-- why `req.db` keeps working: it is still `req`, with a metatable that knows
-- how to fetch a capability the first time it is read.

--- The framework's own logger, replaced when an application configures one.
---
--- A MUTABLE MODULE LOCAL, and it has to be, because `App:run { log = ... }`
--- can change it after this module has loaded. The trap it replaces: while
--- this default lived in `init.lua` as a local, moving the acquisition here
--- would have captured whatever it was at load time, so a service that
--- configured a logger would still get akkar's own voice in `req.log` --
--- silently, and only when no `log` capability was passed.
local default_log

--- Sets the logger an execution falls back to. Called from `App:run`.
function M.default_log(logger)
  default_log = logger
end

--- Fetches one capability for an execution, caching it on the carrier.
---
--- Returns nil for anything outside the closed set, so the caller's metatable
--- can handle its own transport-specific fields first and delegate the rest
--- here. This module never learns what a header is.
function M.acquire(carrier, record, key)
  if not M.CAPABILITIES[key] then return nil end

  local provided = record.capabilities and record.capabilities[key]
  local value

  if key == "log" then
    -- `log` is the one capability with a default, because diagnostics that
    -- need configuring before they appear are diagnostics nobody sees. Bound
    -- to the execution's id, so `log:info(...)` correlates for free.
    value = (provided or default_log):with { request_id = carrier.id }
  elseif provided == nil then
    value = M.guard("req." .. key,
                    "req." .. key .. " is not configured; pass " ..
                    key .. " = ... to app:run{}")
  elseif type(provided) == "function"
      or (getmetatable(provided) or {}).__call then
    value = provided()
    if type(value) == "table" and type(value.release) == "function" then
      -- LAZILY, and that is the whole reason this is a field rather than a
      -- constructor argument. An execution that acquires nothing releasable
      -- -- which is every `/ping` -- never allocates this table.
      local list = record.released
      if not list then list = {} record.released = list end
      list[#list + 1] = value
    end
  else
    value = provided
  end

  rawset(carrier, key, value)     -- acquired once per execution, not per read
  return value
end

--- Installs the carrier's metatable. One call so the HTTP layer does not have
--- to know the shape of what it is installing.
function M.attach(carrier, mt)
  return setmetatable(carrier, mt)
end

--- Releases everything this execution acquired. Idempotent.
---
--- Releasing is the framework's job, not the handler's, and it happens on
--- every exit -- normal return, thrown response, handler error, deadline --
--- because a connection that leaks on the error path leaks exactly when load
--- is highest.
---
--- The list is cleared before anything runs, so a second call is a no-op
--- rather than a double release. That is new: `handle` called `release_all`
--- from exactly one place, so it could not happen. A worker loop can.
function M.release(record)
  local list = record.released
  if not list then return end
  record.released = nil
  for i = 1, #list do
    local resource = list[i]
    pcall(resource.release, resource)
  end
end

--- The deferred release, for a response whose body has not been produced yet.
---
--- COMPOSES, NEVER OVERWRITES, and the cost of getting that wrong is on
--- record: writing `release` onto a handler's own returned table meant a
--- handler returning a hoisted or memoised response had request A's closure
--- overwritten by request B -- A's connection never released, B's released
--- twice, and the second release found the pool already cleared and CLOSED a
--- connection sitting idle in it. One leaked slot, one poisoned entry, one
--- 500 to an innocent request, per occurrence.
---
--- `previous` is whatever `akkar/limit.lua`, `etag.lua`, `csrf.lua`,
--- `auth.lua` or `compress.lua` already deferred.
function M.deferred(record, previous)
  return function()
    if previous then pcall(previous) end
    M.release(record)
  end
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
-- Conditions are recycled where controllers used to be. A condition costs 93
-- bytes and NO descriptor, which is the whole difference: the controller pool
-- traded allocation against a hard operating-system limit, and this one only
-- trades allocation.
local condition_pool = {}
local CONDITION_POOL_LIMIT = 64

local controller_pool = {}

-- RECYCLING IS ON, AND IT IS UNDER SUSPICION. Both halves matter, so both are
-- written here rather than one being left for somebody to discover.
--
-- The suite segfaults intermittently, and every recorded crash lands on one
-- instruction: `table_LLRB_FIND`, walking a pollset's file-descriptor tree.
-- Recycling pollsets is the thing akkar does that most cqueues users do not.
-- A controlled experiment, alternating, all 1,699 tests in every run:
--
--     pool on  (64)   3 crashes / 6 runs
--     pool off (0)    0 crashes / 6 runs
--
-- Then the cost of turning it off was measured, isolated to this one commit
-- on the study box, five alternating repetitions:
--
--     pool on      19,409 req/s   p99 6.19 ms
--     pool off     18,078 req/s   p99 8.48 ms      -6.9%, and a 37% worse tail
--
-- So the trade is a permanent 6.9% of throughput and a much worse tail against
-- a one-sided Fisher exact p of about 0.09. THAT IS NOT ENOUGH EVIDENCE FOR
-- THAT PRICE. The default was flipped to 0 and flipped back when the number
-- came in, which is the benchmark doing its job.
--
-- The crash is also not new -- it predates every change made this week. A
-- pre-existing bug does not become urgent enough to buy at 6.9% just because
-- somebody finally looked at it.
--
-- WHAT WOULD SETTLE IT: more repetitions of the same experiment. If pool-off
-- stays at zero over twenty runs, the price is worth paying and this comment
-- should say so. Better still, the actual cqueues defect -- two targeted
-- reproducers failed to reproduce it outside the suite, so the mechanism is
-- inferred, not understood. `docs/substrate/SEGFAULT.md` has the full account.
--
-- WHAT IS NOT AN OPTION: removing the controller altogether. It would cost
-- nothing and fix this outright, and it breaks a guarantee the README sells --
-- `spec/akkar_spec.lua` has a handler calling `cqueues.sleep(2)` against a
-- 0.15 s budget that must answer 503. `sleep` goes through no akkar adapter,
-- so only a controller can cut it off.
--
-- RETIRED WITH THE CONTROLLER ITSELF. `AKKAR_CONTROLLER_POOL` selected how
-- many nested controllers to recycle; there are no nested controllers now, so
-- it selects nothing. Kept as a no-op read rather than deleted outright so an
-- environment that still sets it does not look like it is doing something.
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

  -- NO CONTROLLER. The deadline is a number, and cqueues already knows how
  -- to wait on one.
  --
  -- This used to allocate a nested `cqueues.new()` per request -- pooled, but
  -- still one per in-flight request -- purely to arbitrate a deadline. It cost
  -- 25 us of akkar's 34.7 us of overhead, about 592 bytes a request, and
  -- **exactly 2.00 file descriptors** on epoll (3.00 on kqueue), confirmed at
  -- three limits: 126 controllers at ulimit 256, 510 at 1024, 2046 at 4096.
  --
  -- `cqueues.poll` takes a bare number in its argument list AS A DEADLINE.
  -- The manual is explicit -- "A number value is interpreted as a simple
  -- timeout, not a file descriptor" -- and `object_getinfo` in cqueues.c has
  -- an `/* optimize simple timeout */` branch that never touches the
  -- descriptor path. The deadline lands in a `struct timer` EMBEDDED in
  -- `struct thread`, on an LLRB tree, and is handed straight to epoll_wait's
  -- own timeout. No malloc, no descriptor, no userdata.
  --
  -- So this was paying for a whole nested epoll instance to duplicate a
  -- red-black tree node the loop we are already inside keeps for free.
  --
  -- MEASURED, `bench/study/deadline-without-controller.lua`, same three
  -- outcomes from both:
  --
  --     a controller per request   fds 8 -> 30 over 200 calls   2,216 B/call
  --     a bare number in poll      fds 6 ->  6                  1,624 B/call
  --
  -- The descriptor growth is not reduced but ABSENT, which matters more than
  -- the bytes: a Lua number is not a GC object, so there is nothing for the
  -- collector to be late about. The failure this runtime hit under load --
  -- 97,912 of 706,563 requests answered `Too many open files`, because dead
  -- controllers outran the collector -- becomes categorically impossible
  -- rather than bounded.
  --
  -- WHAT THIS GIVES UP, and it is the reason it took this long. The nested
  -- controller made an abandoned handler INERT: nothing stepped it, so it
  -- never woke. On the controller we are already in, it wakes.
  --
  -- What replaces inertness is the budget itself. A handler abandoned by its
  -- deadline carries a NEGATIVE remaining budget -- `M.begin` set the deadline
  -- inside the handler's own coroutine and `M.finish` never ran, because the
  -- handler never resumed -- so every capability that asks how long it has
  -- left is told it is over and refuses. `akkar/db.lua` and `akkar/redis.lua`
  -- both do, and `log` and `clock` hold nothing poolable.
  --
  -- `spec/abandoned_defence_spec.lua` is the file that argues this, and
  -- `spec/abandoned_spec.lua` checks the protocol half against real servers.
  -- THE CONDITION IS RECYCLED, and unlike the controller it replaced, that
  -- carries no descriptor risk: a condition holds none. Removing the
  -- controller cost 95 bytes a request in exchange for two descriptors, and
  -- this is how the 95 come back -- a condition is 93 bytes, measured.
  --
  -- Safe to reuse because it is returned only after the wait has ended, so it
  -- has no waiter left; and it is dropped rather than pooled if anything is
  -- still waiting on it, which is the same rule the controller pool used.
  local cq = assert(cqueues.running(),
    "akkar: with_deadline needs a controller; call it from inside one")
  local finished = table.remove(condition_pool) or condition.new()
  local winner, result

  cq:wrap(function()
    -- The budget starts inside the coroutine that will do the work, because
    -- it is keyed by that coroutine. Every capability the handler touches can
    -- now read how long it has -- and, once the deadline passes, that it has
    -- none.
    M.begin(seconds)
    local ok, res = pcall(fn)
    if winner == nil then              -- first arbitrating event wins
      winner = ok and "COMPLETION" or "ERROR"
      result = res
    end
    finished:signal()
  end)

  -- NOT DEAD, despite looking it. `deadline` is read at the bottom of this
  -- function, where an error raised after the budget passed is reclassified
  -- as a TIMEOUT rather than reported as a 500. Removing it on a reading that
  -- it was unused turned `spec/execution_spec.lua`'s "raises what the work
  -- raised" red inside a minute.
  local deadline = time.monotime() + seconds

  -- A bare number IS the deadline. `finished` is signalled by the handler, so
  -- whichever comes first ends the wait.
  cqueues.poll(finished, seconds)

  -- Back to the pool ONLY IF THE HANDLER FINISHED, which `winner ~= nil`
  -- says: the handler sets it and signals immediately after, without
  -- yielding in between, so by the time this line runs the signal has landed
  -- and nothing will ever signal this condition again.
  --
  -- An abandoned handler is still inside `pcall(fn)` and WILL signal when it
  -- eventually returns. Recycling that condition would wake the next request
  -- early, and `poll` returning with its own `winner` still nil means it
  -- would be reported as a TIMEOUT -- a fast request told it was too slow.
  -- cqueues offers no `has_waiters`, so this is the test that is available
  -- and it happens to be the exact one required.
  if winner ~= nil and #condition_pool < CONDITION_POOL_LIMIT then
    condition_pool[#condition_pool + 1] = finished
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
