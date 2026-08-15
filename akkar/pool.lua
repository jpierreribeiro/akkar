--[[
akkar.pool — a bounded resource pool.

Two things decide whether pool code is right, because this is where pool code
is usually wrong:

  1. When the pool is exhausted it YIELDS the coroutine instead of blocking.
     Blocking here would stall every other request in the process, which is
     the exact failure the whole async design exists to avoid.
  2. A resource is returned even when the handler raised.  Same discipline as
     a closure-scoped transaction: the release is not the caller's to
     remember.

Nothing here knows what it is pooling.  Whether a returned resource is fit for
reuse is the adapter's judgement, passed in as `reusable`, because "still
inside a transaction" means something to Postgres and nothing to Redis.
]]

local condition = require "cqueues.condition"

local Pool = {}
Pool.__index = Pool

--- Creates a pool.
-- @param open      function returning a fresh resource, or raising
-- @param size      maximum live resources
-- @param reusable  optional predicate; a resource it rejects is closed
--                  instead of returned to the idle set
function Pool.new(open, size, reusable)
  return setmetatable({
    open = open,
    size = size,
    reusable = reusable,
    idle = {},
    live = 0,
    waiters = condition.new(),
  }, Pool)
end

function Pool:get()
  while true do
    local resource = table.remove(self.idle)
    if resource then
      resource.pool = self
      resource.pooled = nil
      return resource
    end

    if self.live < self.size then
      self.live = self.live + 1
      local ok, resource_or_err = pcall(self.open)
      if not ok then
        -- Give the slot back.  A pool that leaks a slot per failed connection
        -- wedges permanently once the backend has been down for a moment.
        self.live = self.live - 1
        self.waiters:signal(1)
        error(resource_or_err, 0)
      end
      resource_or_err.pool = self
      resource_or_err.pooled = nil
      return resource_or_err
    end

    -- Exhausted.  `condition:wait` yields to the controller; it does not spin
    -- and it does not block the loop.
    self.waiters:wait()
  end
end

function Pool:put(resource)
  -- Returning the same resource twice used to put it in `idle` twice, and
  -- then two callers of `get()` received THE SAME OBJECT -- two requests
  -- sharing one connection, which is the worst outcome this file can produce.
  -- Verified: `put` twice gave `live=1 idle=2`, and two `get()` calls returned
  -- the same table.
  --
  -- It is reachable whenever a release runs on two paths, and one such path
  -- shipped in the streaming code.
  if resource.pooled then return end

  resource.pool = nil
  local keep = true
  if self.reusable then
    local ok, verdict = pcall(self.reusable, resource)
    keep = ok and verdict
  end

  if keep then
    resource.pooled = true
    self.idle[#self.idle + 1] = resource
  else
    pcall(function() resource:close() end)
    self.live = self.live - 1
  end

  -- Wake EVERY waiter, not one.
  --
  -- A request whose deadline fires while it is parked in `get()` is never
  -- resumed, but it stays registered on the condition -- so `signal(1)` can
  -- hand the wakeup to a coroutine that will never take it, and the live
  -- waiter sleeps on beside an idle connection. Measured: a request waited
  -- its full ten-second budget and returned 503 with `idle=1` in the pool.
  --
  -- One wakeup is lost per abandoned waiter, so timeouts under saturation
  -- produce more timeouts -- exactly when a pool matters most. Waking all of
  -- them costs a few needless loop iterations, which the loop already handles
  -- because it re-checks and re-waits.
  self.waiters:signal()
end

function Pool:close()
  for _, resource in ipairs(self.idle) do
    resource.pooled = nil
    pcall(function() resource:close() end)
  end
  self.idle, self.live = {}, 0
end

function Pool:stats()
  return { size = self.size, live = self.live, idle = #self.idle }
end

return Pool
