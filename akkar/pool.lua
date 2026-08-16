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
local time      = require "akkar.time"

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
    -- Slots taken by a coroutine that is still inside `open`. Weak keys: an
    -- abandoned coroutine is unreferenced by anything else, so a collection
    -- takes its reservation with it. See `Pool:reap`.
    opening = setmetatable({}, { __mode = "k" }),
    reaped = 0,
    waits = 0, waited = 0, waited_max = 0,
    waiters = condition.new(),
  }, Pool)
end

--- How many slots are held by opens still in flight.
function Pool:reserved()
  local n = 0
  for _ in pairs(self.opening) do n = n + 1 end
  return n
end

--- Recovers slots reserved by coroutines nobody will ever resume.
---
--- An abandoned coroutine is SUSPENDED, not dead, so `coroutine.status` says
--- nothing useful about it. What distinguishes it is that nothing references
--- it any more -- the deadline dropped it -- so it is exactly what a
--- collection removes, and the weak table is what turns that into an answer.
---
--- Called on demand, when the pool looks full, rather than left to whenever
--- the collector happens to run. That distinction is not theoretical here:
--- this project has already measured a case where descriptors came back only
--- with the collector, which tied a hard operating-system limit to the pace of
--- the garbage collector.
function Pool:reap()
  local before = self:reserved()
  if before == 0 then return 0 end

  -- TWICE, and the number is measured rather than defensive. An abandoned
  -- handler is held by its `cqueues` controller, and the controller has a
  -- finalizer: the first collection runs that finalizer, which is what
  -- finally drops the coroutine, and only the second collects it. Counted
  -- directly -- one collection left the weak entry in place, two removed it.
  collectgarbage()
  collectgarbage()

  local freed = before - self:reserved()
  if freed > 0 then
    self.reaped = self.reaped + freed
    self.waiters:signal()
  end
  return freed
end

function Pool:get()
  while true do
    local resource = table.remove(self.idle)
    if resource then
      resource.pool = self
      resource.pooled = nil
      return resource
    end

    -- THE SLOT IS RESERVED, NOT SPENT, WHILE `open` RUNS.
    --
    -- `open` yields: it connects a socket, and on Postgres it authenticates
    -- and sets `statement_timeout` besides. A deadline landing anywhere in
    -- there abandons the coroutine, and `live` was already incremented -- so
    -- the slot was gone for the life of the process. The recovery below the
    -- old `pcall` only ever covered an error that was RAISED, and an
    -- abandoned coroutine raises nothing; it simply never comes back.
    --
    -- Counting reservations separately means a slot in that state is
    -- recoverable rather than lost, and `live` goes back to meaning what it
    -- says: resources that exist.
    if self.live + self:reserved() < self.size then
      local co = coroutine.running()
      if co then self.opening[co] = true end

      local ok, resource_or_err = pcall(self.open)

      -- Not reached if the coroutine was abandoned inside `open`, which is
      -- precisely the state `reap` exists to find.
      if co then self.opening[co] = nil end

      if not ok then
        -- A pool that leaks a slot per failed connection wedges permanently
        -- once the backend has been down for a moment.
        self.waiters:signal(1)
        error(resource_or_err, 0)
      end

      self.live = self.live + 1
      resource_or_err.pool = self
      resource_or_err.pooled = nil
      return resource_or_err
    end

    -- Full. If part of that is a reservation nobody will ever come back for,
    -- this is where it is found -- before parking, not after a timeout.
    if self:reap() == 0 then
      -- Exhausted for real.  `condition:wait` yields to the controller; it
      -- does not spin and it does not block the loop.
      --
      -- TIMED, because this is the number that decides pool size and akkar
      -- could not answer it. The study measured a p99 of 191 ms at 100
      -- connections against a pool of ten and could only infer that ninety
      -- requests were queuing; how long each actually waited was invisible.
      -- A p99 made of queue is a different problem from a p99 made of work,
      -- and they are indistinguishable from the outside.
      local started = time.monotime()
      self.waiters:wait()
      local waited = time.monotime() - started
      self.waits = self.waits + 1
      self.waited = self.waited + waited
      if waited > self.waited_max then self.waited_max = waited end
    end
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
  -- `pooled` covers a resource that went back to the idle set. `discarded`
  -- covers one the predicate REJECTED -- and it had to be added, because the
  -- guard used to cover only the first case while the second decremented
  -- `live` every single time it was called.
  --
  -- Returning a broken resource twice therefore drove `live` NEGATIVE, and a
  -- negative `live` is worse than a wrong number: capacity is
  -- `live + reserved < size`, so the pool then opens more connections than it
  -- was allowed. Found by `spec/properties_spec.lua` on its first run, at
  -- seed 7919 step 61, which is a schedule nobody would have written by hand.
  if resource.pooled or resource.discarded then return end

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
    resource.discarded = true
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
  self.opening = setmetatable({}, { __mode = "k" })
end

--- `live` is resources that EXIST; `reserved` is slots held by an open still
--- in flight. Two numbers because a pool reporting one total cannot say
--- whether it is busy or stuck.
function Pool:stats()
  return {
    size = self.size, live = self.live, idle = #self.idle,
    reserved = self:reserved(), reaped = self.reaped,
    -- How often a request had to queue for a connection, and for how long.
    waits = self.waits, waited = self.waited, waited_max = self.waited_max,
  }
end

return Pool
