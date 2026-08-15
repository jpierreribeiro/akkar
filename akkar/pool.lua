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
      return resource_or_err
    end

    -- Exhausted.  `condition:wait` yields to the controller; it does not spin
    -- and it does not block the loop.
    self.waiters:wait()
  end
end

function Pool:put(resource)
  resource.pool = nil
  local keep = true
  if self.reusable then
    local ok, verdict = pcall(self.reusable, resource)
    keep = ok and verdict
  end

  if keep then
    self.idle[#self.idle + 1] = resource
  else
    pcall(function() resource:close() end)
    self.live = self.live - 1
  end
  self.waiters:signal(1)
end

function Pool:close()
  for _, resource in ipairs(self.idle) do
    pcall(function() resource:close() end)
  end
  self.idle, self.live = {}, 0
end

function Pool:stats()
  return { size = self.size, live = self.live, idle = #self.idle }
end

return Pool
