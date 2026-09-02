--[[
akkar.breaker — stop dialling a dependency that is down.

## The gap this closes

akkar already has two of the three resilience patterns every mature client
carries. The deadline is a number the whole execution reads
(`akkar/execution.lua`), so an outbound call with 200 ms of budget left gets
200 ms and not the client's ten-second default -- which is better than a
per-call timeout, because the budget PROPAGATES. `akkar.limit.concurrent` is
a bulkhead in all but name. `akkar/http.lua` retries what is safe to retry.

What none of those do is notice that a dependency has been hard-down for the
last thirty seconds and stop paying for the discovery. A deadline stops one
slow call from eating one budget; it does not stop the next thousand requests
from each dialling the dead service, each waiting its bounded share, each
holding a connection slot and a coroutine while it does. That is the failure
a circuit breaker exists for, and `grep -ri breaker akkar/` found nothing.

## Three states, two policies

    closed      calls run; failures are counted
    open        calls are REFUSED without running, until `cooldown` passes
    half-open   `half_open_max` probes may run; all succeed -> closed,
                any one fails -> open again, cooldown re-armed

The policy is what turns a run of failures into a trip:

    consecutive   `threshold` failures in a row (a success resets the run)
    sampling      failures / calls >= `threshold` over the last `window`
                  seconds, once at least `minimum` calls have been seen

Both are cockatiel's (`ConsecutiveBreaker`, `SamplingBreaker`), chosen for
the same reason cockatiel offers both: a consecutive count is the right rule
for a dependency that is either up or down, and a ratio is the right rule for
one that is degraded, where a healthy call slips in between the failures and
would reset a consecutive count for ever.

## What counts as a failure, and why that is configurable

The house convention (`docs/why/adapters.md`) is that an adapter returns
`nil, reason`; it does not raise. So the default here is that `fn` FAILED when
it raised OR when its first result is nil. That is the right default for a
transport -- `http:get` answers `nil, "connection refused"` -- and the wrong
one for a lookup, where `nil, "not found"` is the dependency working
correctly, and a run of legitimate misses would open the breaker on a
service that is fine. So `is_failure` is a function of the results, and a
caller whose `nil` means "no such row" replaces it.

## Time is read, never waited on

Every instant is `akkar.time.monotime()`, and nothing here sleeps. The
cooldown is a number compared against the clock when the next call arrives,
so `spec/breaker_spec.lua` proves every transition with a manual clock and no
real seconds pass. That is the same discipline the deadline follows, and it
is what makes "opens after N, allows exactly M probes after T" a statement a
test can make exactly rather than approximately.

## A probe that never reports does not wedge the breaker

A probe is a call that was let through in the half-open state. If the
coroutine running it is abandoned -- the execution's deadline fired while it
was waiting on the socket -- its verdict never arrives, and a breaker that
waited for it would refuse for ever. So the half-open budget is issued again
after another `cooldown` with no verdict. That is a decision about the
outside world (something was still slow enough to hit the deadline), not a
guess about the probe.
]]

local time = require "akkar.time"

local M = {}

--- The reason a refused call returns. Exported so a caller compares against
--- the constant rather than the spelling.
M.OPEN = "breaker open"

local Breaker = {}
Breaker.__index = Breaker

-- Numeric form of the state, for the gauge `akkar.metrics` renders: an
-- operator's alert is `akkar_breaker_state > 0`, and a string cannot be
-- compared in a rule.
local STATE_CODE = { closed = 0, half_open = 1, open = 2 }
M.STATE_CODE = STATE_CODE

local DEFAULTS = {
  cooldown      = 30,   -- seconds open before probing
  half_open_max = 1,    -- probes issued per half-open period
  minimum       = 10,   -- sampling: calls in the window before the ratio counts
  buckets       = 10,   -- sampling: fixed slices the window is measured in
}

local function default_is_failure(first) return first == nil end

--- Builds a breaker. See the header for the two policies.
---
--- `threshold` is required: a whole number of consecutive failures when
--- `window` is absent, a ratio in (0, 1] when `window` (seconds) is given.
function M.new(options)
  options = options or {}
  local threshold = options.threshold
  if type(threshold) ~= "number" or threshold <= 0 then
    error("akkar.breaker: threshold must be a positive number, got "
          .. tostring(threshold), 2)
  end
  local window = options.window
  if window ~= nil then
    if type(window) ~= "number" or window <= 0 then
      error("akkar.breaker: window must be a positive number of seconds", 2)
    end
    if threshold > 1 then
      error("akkar.breaker: with a window, threshold is a failure ratio in (0, 1]", 2)
    end
  elseif threshold ~= math.floor(threshold) then
    error("akkar.breaker: without a window, threshold is a whole number of "
          .. "consecutive failures", 2)
  end
  local cooldown = options.cooldown or DEFAULTS.cooldown
  if type(cooldown) ~= "number" or cooldown <= 0 then
    error("akkar.breaker: cooldown must be a positive number of seconds", 2)
  end
  local half_open_max = options.half_open_max or DEFAULTS.half_open_max
  if type(half_open_max) ~= "number" or half_open_max < 1 then
    error("akkar.breaker: half_open_max must be at least 1", 2)
  end
  if options.is_failure ~= nil and type(options.is_failure) ~= "function" then
    error("akkar.breaker: is_failure must be a function", 2)
  end

  local self = setmetatable({
    threshold     = threshold,
    window        = window,
    minimum       = options.minimum or DEFAULTS.minimum,
    cooldown      = cooldown,
    half_open_max = half_open_max,
    is_failure    = options.is_failure or default_is_failure,
    on_change     = options.on_change,

    state         = "closed",
    since         = time.monotime(),  -- when the current state began
    streak        = 0,                -- consecutive failures (consecutive policy)
    probes        = 0,                -- probes issued this half-open period
    probe_wins    = 0,                -- probes that came back a success

    -- Counters read by `stats()`; monotonic, never reset.
    calls = 0, successes = 0, failures = 0, refused = 0, trips = 0,
  }, Breaker)

  if window then
    -- A ring of fixed slices rather than a list of timestamps: memory is
    -- bounded by `buckets` whatever the call rate, and `prune` is a loop over
    -- ten entries rather than over every call of the last minute.
    local n = options.buckets or DEFAULTS.buckets
    self.slice = window / n
    self.ring = {}
    for i = 1, n do self.ring[i] = { index = -1, calls = 0, failures = 0 } end
  end
  return self
end

--- True for a value `M.new` returned. `akkar.http` uses it to tell a breaker
--- it should share from a configuration it should build one per origin from.
function M.is(value)
  return getmetatable(value) == Breaker
end

local function move(self, to)
  local from = self.state
  if from == to then return end
  self.state = to
  self.since = time.monotime()
  if to == "open" then self.trips = self.trips + 1 end
  if to ~= "closed" then self.streak = 0 end
  self.probes, self.probe_wins = 0, 0
  if to == "closed" and self.ring then
    for _, slot in ipairs(self.ring) do
      slot.index, slot.calls, slot.failures = -1, 0, 0
    end
  end
  -- An observer must not be able to take the breaker down with it; the same
  -- rule `akkar.metrics` applies to a gauge source.
  if self.on_change then pcall(self.on_change, self, from, to) end
end

-- Applies the transitions time alone causes. Called at the top of every
-- entry point, so state is always current when it is read and nothing has to
-- run on a timer.
local function settle(self)
  local now = time.monotime()
  if self.state == "open" then
    if now - self.since >= self.cooldown then move(self, "half_open") end
  elseif self.state == "half_open" then
    -- Every probe was issued and none came back: see the header. A fresh
    -- budget, and `since` moves so this fires once per cooldown, not per call.
    if self.probes >= self.half_open_max and now - self.since >= self.cooldown then
      self.since, self.probes, self.probe_wins = now, 0, 0
    end
  end
end

--- The ring slot for `now`, cleared if it last held an older slice.
local function slot_for(self, now)
  local index = math.floor(now / self.slice)
  local slot = self.ring[index % #self.ring + 1]
  if slot.index ~= index then
    slot.index, slot.calls, slot.failures = index, 0, 0
  end
  return slot, index
end

--- Failures and calls over the last `window` seconds.
local function sample(self, now)
  local _, current = slot_for(self, now)
  local oldest = current - #self.ring + 1
  local calls, failures = 0, 0
  for _, slot in ipairs(self.ring) do
    if slot.index >= oldest then
      calls, failures = calls + slot.calls, failures + slot.failures
    end
  end
  return calls, failures
end

--- Whether a call may run now. Claims a probe when half-open.
---
--- Returns true, or nil and `M.OPEN`. Every path through here is a table
--- read and a comparison; a refused call costs no I/O and none of the
--- execution's budget, which is the whole point of refusing.
function Breaker:allow()
  settle(self)
  if self.state == "closed" then return true end
  if self.state == "half_open" and self.probes < self.half_open_max then
    self.probes = self.probes + 1
    return true
  end
  self.refused = self.refused + 1
  return nil, M.OPEN
end

local function record(self, failed)
  local now = time.monotime()
  self.calls = self.calls + 1
  if failed then self.failures = self.failures + 1
  else self.successes = self.successes + 1 end
  if self.ring then
    local slot = slot_for(self, now)
    slot.calls = slot.calls + 1
    if failed then slot.failures = slot.failures + 1 end
  end
end

--- Reports that a call let through by `allow` succeeded.
function Breaker:success()
  settle(self)
  record(self, false)
  if self.state == "half_open" then
    self.probe_wins = self.probe_wins + 1
    -- Closes when every probe has come back good, not on the first one:
    -- `half_open_max` above 1 asks for more than one sample precisely so
    -- that one lucky call does not reopen the floodgates.
    if self.probe_wins >= self.half_open_max then move(self, "closed") end
  else
    self.streak = 0
  end
end

--- Reports that a call let through by `allow` failed.
function Breaker:failure()
  settle(self)
  record(self, true)
  if self.state == "half_open" then
    move(self, "open")
    return
  end
  if self.state ~= "closed" then return end
  if self.ring then
    local calls, failures = sample(self, time.monotime())
    if calls >= self.minimum and failures / calls >= self.threshold then
      move(self, "open")
    end
  else
    self.streak = self.streak + 1
    if self.streak >= self.threshold then move(self, "open") end
  end
end

--- Runs `fn(...)` under the breaker.
---
--- Returns everything `fn` returned, or `nil, "breaker open"` without calling
--- it. A raise inside `fn` is counted as a failure and re-raised: the breaker
--- observes errors, it does not swallow them, because a caller who wanted
--- `nil, reason` would have written `fn` to return one.
function Breaker:call(fn, ...)
  local ok, why = self:allow()
  if not ok then return nil, why end
  local results = table.pack(pcall(fn, ...))
  if not results[1] then
    self:failure()
    error(results[2], 0)
  end
  if self.is_failure(table.unpack(results, 2, results.n)) then
    self:failure()
  else
    self:success()
  end
  return table.unpack(results, 2, results.n)
end

--- Holds the breaker open until `reset` -- cockatiel's `isolate()`. For a
--- dependency an operator knows is down, or is about to take down.
function Breaker:trip()
  settle(self)
  move(self, "open")
  -- A tripped breaker is meant to stay tripped, so it must not drift into
  -- half-open when the cooldown passes. Pushed far enough forward that no
  -- cooldown can elapse.
  self.since = math.huge
end

--- Closes the breaker and forgets the failures behind the trip.
function Breaker:reset()
  move(self, "closed")
  self.streak = 0
end

--- The current state, after applying any transition time has caused.
function Breaker:current()
  settle(self)
  return self.state
end

--- What the breaker has seen, in the shape `akkar.metrics` reads at render
--- time. `state` is numeric (`M.STATE_CODE`), `trips` counts every entry
--- into `open`, `refused` counts calls that never ran.
function Breaker:stats()
  settle(self)
  return {
    state     = STATE_CODE[self.state],
    trips     = self.trips,
    refused   = self.refused,
    calls     = self.calls,
    failures  = self.failures,
    successes = self.successes,
  }
end

M.Breaker = Breaker

return M
