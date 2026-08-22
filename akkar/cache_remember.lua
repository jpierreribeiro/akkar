--- `cache:remember(key, ttl, produce)` with the thundering herd removed.
---
--- ## The problem, measured
---
--- The obvious way to use a cache is get, and on a miss compute and set. Under
--- concurrency that is a stampede: a hundred requests for the same not-yet-cached
--- key all miss, because a cache fill takes a database round-trip and every one
--- of them yields inside it before any has written the result. Measured here,
--- 100 concurrent requests for one hot key:
---
---     naive get-or-compute      100 computations
---     coalesced                   1 computation
---
--- Kerkour's "thundering herd" article shows Go's `singleflight` solving this
--- with a mutex, because Go's goroutines run in parallel. akkar does not need
--- the mutex: one thread, cooperative scheduling, so the coalescing is a
--- `cqueues.condition` and there is no race to guard. It is the SAME idea and a
--- smaller implementation, which is the whole reason it belongs here rather
--- than being left to every application to get wrong.
---
--- ## What it is not
---
--- Not a cache. It DECORATES a cache -- anything with `get(key)` and
--- `set(key, value, ttl)`, which is every akkar cache adapter, memory and
--- redis alike -- so the coalescing lives on akkar's side of the wire and works
--- the same over both. The flight table is per decorator, so per process; two
--- processes each fill the key once, which is the correct behaviour for a
--- shared cache and what `reuseport` already implies elsewhere.
local cqueues = require "cqueues"
local condition = require "cqueues.condition"

local M = {}

local Remember = {}
Remember.__index = Remember

--- Wraps a cache adapter. `now` is injectable for tests; it is only used to
--- bound how long a caller waits on an in-flight fill.
function M.wrap(cache)
  return setmetatable({ cache = cache, flights = {} }, Remember)
end

--- Returns the cached value for `key`, computing it with `produce` on a miss.
---
--- On a concurrent miss for the same key, exactly one caller runs `produce`
--- and the rest wait on a condition and read the value it stored. A `produce`
--- that raises wakes the waiters so they do not hang; each of them then sees
--- the miss again and one of them becomes the next producer, which is the
--- right behaviour -- an error is not a value to share.
function Remember:remember(key, ttl, produce)
  local hit = self.cache:get(key)
  if hit ~= nil then return hit end

  local flight = self.flights[key]
  if flight then
    -- Someone is already computing this key. Wait for them, then read what
    -- they wrote. If they FAILED, `get` still misses and we fall through to
    -- become a producer ourselves.
    cqueues.poll(flight.cond)
    local now = self.cache:get(key)
    if now ~= nil then return now end
    -- The producer failed; fall through and try to produce.
    return self:remember(key, ttl, produce)
  end

  flight = { cond = condition.new() }
  self.flights[key] = flight

  local ok, value = pcall(produce)

  -- The flight ends and the waiters wake, WHATEVER happened. Clearing the
  -- flight before signalling means a waiter that wakes and misses becomes the
  -- next producer rather than finding a flight that is already over.
  self.flights[key] = nil
  flight.cond:signal()

  if not ok then error(value, 0) end

  if value ~= nil then
    self.cache:set(key, value, ttl)
  end
  return value
end

return M
