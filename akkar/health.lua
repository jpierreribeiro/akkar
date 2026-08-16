--[[
akkar.health — liveness and readiness, and the distinction is the whole point.

## The two questions are not the same question

    live()    is this process running its event loop?
    ready()   should this process be sent traffic right now?

Conflating them is not a style preference, it is an outage. `akkar/init.lua`
already records the reasoning, at the comment above the capability metatable
that acquires on first read:

    "A route that never queries still took a connection out of the pool, so
     health checks competed with real work for slots.  Worse, with the
     database down every route failed -- including the ones that do not touch
     it -- which defeated the whole point of `check_capabilities = false`,
     whose reason to exist is coming up degraded and still answering
     `/health/live`."

That comment is about eager capability acquisition; the same sentence is the
whole design of this file. An orchestrator restarts a container whose LIVENESS
probe fails, and it takes a container whose READINESS probe fails out of the
load balancer. So a liveness probe that opens a database connection means:
one slow database -> every instance fails liveness at the same moment ->
every instance is killed at the same moment. A degradation that would have
served cached reads and static routes becomes a cluster with nothing running
in it, and the restarts add load to the database that caused it.

**So `live()` touches nothing.** Not the pool, not the database, not the
cache, not the network. It is enforced here rather than documented: the checks
table is only ever read by `ready()`, and `spec/health_spec.lua` proves it by
passing a check that sets a flag and asserting the flag is still false after
`live()`.

## What liveness can honestly report

Very little, and that is correct. A process whose event loop has stopped
turning cannot answer the probe at all -- the connection hangs and the probe
times out, which is the signal. So there is no observation `live()` can make
from the inside that its own successful return has not already made. It
reports uptime, because that is true and because a restart loop is visible as
an uptime that keeps resetting.

Anything cleverer would be a check pretending to be a proof.

## Readiness, and the cost of asking

A readiness probe runs on a schedule -- typically every second, per instance.
Without a cache, twenty instances probing once a second is twenty queries a
second that no user asked for, and under load those compete with real traffic
for exactly the pool slots the comment above is about. So results are cached,
failures included: a dependency that is down must not be hammered by the
probes reporting that it is down.

Each check gets its own timeout, because the failure mode of a readiness check
is not usually "returned false", it is "did not return". Nothing here is a
response: `live()` and `ready()` return a table. akkar handlers return values
and never mutate a response, and health is not an exception to that.

## Using it

    local health = require "akkar.health"

    local probe = health.new {
      checks = {
        db    = function() return req_db:one "select 1" ~= nil end,
        redis = function() return cache:ping() end,
      },
      timeout = 2,      -- per check, seconds
      cache   = 5,      -- seconds a result is reused
    }

    app:get("/health/live",  function() return probe:live()  end)
    app:get("/health/ready", function()
      local result = probe:ready()
      if result.status == "fail" then error(akkar.unavailable(result)) end
      return result
    end)

A check returns `true` to pass, or `false`/`nil` plus a reason string to fail.
A check that raises fails with the error message rather than taking the probe
down with it -- a readiness endpoint that 500s tells the orchestrator nothing
about which dependency is unhappy.
]]

local cqueues = require "cqueues"
local time    = require "akkar.time"

local M = {}

local OPTIONS = { checks = true, timeout = true, cache = true }

local DEFAULT_TIMEOUT = 2      -- seconds, per check
local DEFAULT_CACHE   = 5      -- seconds a readiness result is reused

local Health = {}
Health.__index = Health

--- Calls one check and normalises whatever it returned.
---
--- The protocol is deliberately the one Lua already uses for failure:
--- `true` passes, `false`/`nil` plus a reason fails, and a raised error is a
--- failure carrying its own message.  Only the first line of the message is
--- kept, because a traceback in a JSON field is unreadable in the one place
--- this gets read: an orchestrator event or a terminal at 3am.
local function call(fn)
  local ok, first, second = pcall(fn)
  if not ok then
    return false, tostring(first):match "^[^\n]*"
  end
  if first then
    return true, nil
  end
  local reason = type(second) == "string" and second
                 or (type(first) == "string" and first or nil)
  return false, reason
end

--- Runs one check under its own deadline.
---
--- HONEST LIMIT, the same one `with_deadline` in init.lua states: this is
--- cooperative.  A check that yields on I/O -- which is every check that
--- talks to a dependency -- is interrupted on time.  A check that burns CPU
--- without yielding is not interrupted by anything, here or anywhere else in
--- this runtime, and the blocking watchdog is what reports that instead.
---
--- Real monotonic time, not `akkar.time`.  A manual clock moves budgets and
--- timestamps and explicitly does NOT move the event loop (see the docstring
--- of `akkar/time.lua`), so measuring this budget against a clock that only
--- advances when told would spin here for ever waiting on a poll that is
--- waiting on real milliseconds.
local function with_timeout(fn, seconds)
  if not seconds or seconds <= 0 then
    local ok, reason = call(fn)
    return ok, reason, false
  end

  local cq = cqueues.new()
  local done, ok, reason = false, nil, nil
  cq:wrap(function()
    ok, reason = call(fn)
    done = true
  end)

  -- Step before polling: `wrap` only queues the coroutine, so a check that
  -- never yields has not run yet and polling first would wait on a descriptor
  -- for work that is already ready.  Copied from `with_deadline`, which found
  -- this the same way.
  cq:step(0)

  local deadline = cqueues.monotime() + seconds
  while not done do
    local remaining = deadline - cqueues.monotime()
    if remaining <= 0 then break end
    if cqueues.running() then
      -- Inside the server's controller: yield to it, never `loop`, or this
      -- probe blocks every request in the process while it waits.
      cqueues.poll(cq, remaining)
      cq:step(0)
    else
      -- Outside any controller -- a CLI, a test, a boot-time check.  There is
      -- nothing to yield to, so blocking here is the only thing available and
      -- costs nobody anything.
      cq:step(remaining)
    end
  end

  if not done then
    -- The controller is dropped, never reused: the check is still running
    -- inside it, and handing that to the next probe is the same class of bug
    -- as a pooled connection with a transaction still open.
    --
    -- It holds two file descriptors until the collector runs (init.lua
    -- measured exactly 2.00 per controller).  That is affordable only because
    -- of the cache below: a timing-out check costs one controller per cache
    -- period, not one per probe.  With `cache = 0` and a probe every second,
    -- it is one every second, which is a real cost and is stated rather than
    -- discovered.
    return false, ("timed out after %gs"):format(seconds), true
  end
  return ok, reason, false
end

--- A fresh copy of a stored result.
---
--- DEFECT THIS FIXES, found by its own test.  The first version cached the
--- very table it had just returned to the caller, so a handler decorating the
--- result -- `result.detail = ...`, or setting `status` before turning it
--- into a 503 -- wrote into the cache.  Every probe for the next five seconds
--- then read back the handler's edit as if a check had produced it, and the
--- endpoint reported a state no check had ever observed.
---
--- Two levels deep, which is all there is: the envelope and one entry per
--- check.
local function snapshot(entry, cached, uptime)
  local checks = {}
  for name, result in pairs(entry.checks) do
    checks[name] = {
      status = result.status, reason = result.reason,
      took_ms = result.took_ms, timed_out = result.timed_out,
    }
  end
  return { status = entry.status, checks = checks, cached = cached,
           uptime = uptime }
end

--- A probe.  `checks` is only ever read by `ready()`; see the header.
function M.new(options)
  options = options or {}
  for key in pairs(options) do
    if not OPTIONS[key] then
      error("akkar.health: unknown option '" .. tostring(key) ..
            "'; use checks, timeout or cache", 2)
    end
  end

  local checks = options.checks or {}
  for name, fn in pairs(checks) do
    if type(fn) ~= "function" then
      error(("akkar.health: check '%s' is a %s, not a function")
            :format(tostring(name), type(fn)), 2)
    end
  end

  return setmetatable({
    checks  = checks,
    timeout = options.timeout or DEFAULT_TIMEOUT,
    ttl     = options.cache == nil and DEFAULT_CACHE or options.cache,
    started = time.monotime(),
    cached  = nil,          -- { status = ..., checks = ..., at = monotime }
  }, Health)
end

--- Is this process running its event loop?
---
--- Touches nothing.  Reads no check, opens no connection, and answers from
--- two numbers this object has held since it was constructed.  The proof that
--- it stays that way is a test, not this comment.
---
--- Uptime comes from `akkar.time`, so a manual clock moves it -- this one IS
--- a budget rather than an event-loop wait, and a test that has to sleep to
--- assert on uptime is a test nobody keeps.
function Health:live()
  return {
    status  = "pass",
    checks  = {},           -- empty BY CONSTRUCTION, not because none passed
    uptime  = time.monotime() - self.started,
  }
end

--- Should this process be sent traffic?
---
--- Every check runs, even after one has failed.  Stopping at the first
--- failure would report the alphabetically-first broken dependency and stay
--- silent about the other two, and the whole value of this endpoint during an
--- incident is knowing which of them are unhappy.
---
--- `options.fresh = true` bypasses the cache, for a human asking now.
function Health:ready(options)
  options = options or {}

  local now = time.monotime()
  if not options.fresh and self.cached and self.ttl > 0
     and (now - self.cached.at) < self.ttl then
    return snapshot(self.cached, true, now - self.started)
  end

  local names = {}
  for name in pairs(self.checks) do names[#names + 1] = name end
  table.sort(names)          -- stable output; a probe read by a human diffs

  local results, status = {}, "pass"
  for _, name in ipairs(names) do
    local began = cqueues.monotime()
    local ok, reason, timed_out = with_timeout(self.checks[name], self.timeout)
    local entry = {
      status  = ok and "pass" or "fail",
      took_ms = math.floor((cqueues.monotime() - began) * 1000 + 0.5),
    }
    if reason then entry.reason = reason end
    if timed_out then entry.timed_out = true end
    results[name] = entry
    if not ok then status = "fail" end
  end

  local current = { status = status, checks = results, at = now }

  -- FAILURES ARE CACHED TOO.  Caching only the successes means a dependency
  -- that is down gets probed on every single request to /health/ready, from
  -- every instance -- which is load added to the thing that is already
  -- failing, by the endpoint reporting that it is failing.
  if self.ttl > 0 then self.cached = current end

  -- A copy on the miss path as well as the hit path, so what the caller holds
  -- is never the table the cache holds.
  return snapshot(current, false, now - self.started)
end

--- Throws the cache away.  For a process that has just finished starting up,
--- or a test that has just repaired the thing a check was failing on.
function Health:invalidate()
  self.cached = nil
  return self
end

M.Health = Health
M.DEFAULT_TIMEOUT = DEFAULT_TIMEOUT
M.DEFAULT_CACHE = DEFAULT_CACHE
return M
