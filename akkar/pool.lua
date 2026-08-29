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

Every number below is a bound on how long something may go wrong for.  A pool
without them does not fail; it stops, and stays stopped until a restart.
]]

local cqueues   = require "cqueues"
local condition = require "cqueues.condition"

local Pool = {}
Pool.__index = Pool

-- Defaults, all overridable, all disabled by passing `false`.
--
-- `max_lifetime` and `idle_timeout` are the numbers HikariCP settled on after
-- a decade of the same failures, and the reasoning carries: every connection
-- has a third party that may kill it -- a failover, a load balancer's idle
-- reap, a `pg_terminate_backend` -- and the pool should recycle first rather
-- than find out by handing a corpse to a request.  Keep `max_lifetime` under
-- whatever reaps connections in front of the database.
local WAIT_TIMEOUT = 10     -- how long `get` may park before it gives up
local OPEN_TIMEOUT = 15     -- an `open` outstanding longer than this is presumed abandoned
local MAX_LIFETIME = 1800   -- retire a connection this old on its way out of `idle`
local IDLE_TIMEOUT = 600    -- retire one that has sat unused this long

local function setting(value, default)
  if value == nil then return default end
  if value == false or value == 0 then return nil end
  return value
end

--- Creates a pool.
-- @param open      function returning a fresh resource, or raising
-- @param size      maximum live resources
-- @param reusable  optional predicate; a resource it rejects is closed
--                  instead of returned to the idle set
-- @param options   wait_timeout, open_timeout, max_lifetime, idle_timeout,
--                  each in seconds and each disabled by `false`
function Pool.new(open, size, reusable, options)
  options = options or {}
  return setmetatable({
    open = open,
    size = size,
    reusable = reusable,
    idle = {},
    live = 0,
    opening = {},               -- opens in flight, so an abandoned one is visible
    checkouts = 0,              -- monotonic; the generation half of ownership
    waiters = condition.new(),
    now = options.now or cqueues.monotime,
    wait_timeout = setting(options.wait_timeout, WAIT_TIMEOUT),
    open_timeout = setting(options.open_timeout, OPEN_TIMEOUT),
    max_lifetime = setting(options.max_lifetime, MAX_LIFETIME),
    idle_timeout = setting(options.idle_timeout, IDLE_TIMEOUT),
  }, Pool)
end

-- ================================================================= ownership
-- A boolean the acquire path clears cannot say who is holding the resource.
--
-- `put` used to check `resource.pooled`, and `get` cleared it -- so
-- `put -> get(by another coroutine) -> put` put the connection into `idle`
-- while somebody else was actively using it, which is verbatim the outcome the
-- boolean was added to eliminate. Verified: after that sequence the pool held
-- `live=1 idle=1` with the idle entry being the object the second caller was
-- still holding, and the next `get` handed the same socket to a third.
--
-- The resource cannot answer this on its own: both holders reference the same
-- table, so anything written on it is the LATEST holder's state. What can
-- answer it is the checkout generation each holder saw -- recorded per
-- coroutine, weakly, so a finished request's entry goes away with it. A
-- coroutine may return only the checkout it took, which makes a second release
-- from a stale holder a no-op instead of a double hand-out.
--
-- A put from a coroutine that never acquired the resource is still allowed:
-- releasing on someone's behalf is a real pattern (shutdown, a supervisor
-- draining a request's capabilities), and it is caught by the idle check
-- instead.
local function generations(resource)
  local held = rawget(resource, "held_by")
  if not held then
    held = setmetatable({}, { __mode = "k" })
    resource.held_by = held
  end
  return held
end

function Pool:checkout(resource)
  self.checkouts = self.checkouts + 1
  resource.pool = self
  resource.checkout = self.checkouts
  resource.idle_since = nil
  generations(resource)[coroutine.running()] = self.checkouts
  return resource
end

-- ================================================================== recycling
-- A connection is handed out of `idle` without being validated, and validation
-- happens only on the return leg. So after a Postgres restart, a failover or a
-- load balancer's idle reap, up to `pool_size` dead connections get handed out,
-- one failed request each.
--
-- The fix is not a `select 1` on every acquire: that is a round trip on the
-- hottest path in the framework, and it still races -- the connection can die
-- between the probe and the query. Age is free and catches the whole class,
-- because every third party that kills connections does it on a timer.
local function expired(self, resource, now)
  if self.max_lifetime and resource.created_at
     and now - resource.created_at > self.max_lifetime then
    return true
  end
  return self.idle_timeout ~= nil and resource.idle_since ~= nil
     and now - resource.idle_since > self.idle_timeout
end

function Pool:reap_idle()
  if not (self.max_lifetime or self.idle_timeout) or #self.idle == 0 then return end
  local now, kept = self.now(), {}
  for _, resource in ipairs(self.idle) do
    if expired(self, resource, now) then
      resource.checkout = nil
      pcall(function() resource:close() end)
      self.live = self.live - 1
    else
      kept[#kept + 1] = resource        -- order preserved: `idle` is LIFO
    end
  end
  self.idle = kept
end

-- The slot is taken BEFORE `open` runs, because two coroutines opening at once
-- would otherwise both see room and blow the cap. That is correct, and it is
-- why an `open` that never returns takes the slot with it: no adapter can set
-- a connect timeout that covers every case, and a blackholed backend -- a
-- firewall change, a failed failover, a NAT table that forgot the flow -- parks
-- the coroutine inside `open` forever. The request's deadline then abandons the
-- coroutine, so the line that gives the slot back never runs.
--
-- Measured before this existed: after `pool_size` such requests the pool held
-- `live == size`, `idle == 0` and zero actual connections, `get` parked every
-- later request for its whole deadline, and the database coming back healed
-- nothing. Only a restart did.
--
-- The existing guard covered `open` RAISING, which is the easy shape. This
-- covers `open` being abandoned, which is the likelier one.
function Pool:reclaim_abandoned_opens()
  if not self.open_timeout then return end
  local cutoff = self.now() - self.open_timeout
  for pending in pairs(self.opening) do
    if pending.started <= cutoff then
      self.opening[pending] = nil
      pending.reclaimed = true          -- so a late return does not decrement twice
      self.live = self.live - 1
    end
  end
end

-- Takes a slot, opens, and hands back the resource -- or nil when the slot it
-- took was written off as abandoned while `open` was still running, which
-- tells `get` to go round the loop again rather than park.
function Pool:open_one()
  self.live = self.live + 1
  local pending = { started = self.now() }
  self.opening[pending] = true

  local ok, resource = pcall(self.open)
  self.opening[pending] = nil

  if not ok then
    -- Give the slot back.  A pool that leaks a slot per failed connection
    -- wedges permanently once the backend has been down for a moment.
    if not pending.reclaimed then self.live = self.live - 1 end
    self.waiters:signal()
    error(resource, 0)
  end

  -- `open` came back after its slot had been written off. Rare -- an abandoned
  -- coroutine does not resume -- but a merely slow one does, and its
  -- connection must be neither counted twice nor leaked.
  if pending.reclaimed then
    if self.live >= self.size or self.closed then
      pcall(function() resource:close() end)
      self.waiters:signal()
      return nil
    end
    self.live = self.live + 1
  end

  resource.created_at = self.now()
  return resource
end

-- ======================================================================= get
function Pool:get()
  local deadline = self.wait_timeout and (self.now() + self.wait_timeout)

  while true do
    if self.closed then
      error("pool: the pool is closed", 0)
    end

    self:reclaim_abandoned_opens()
    self:reap_idle()

    local resource = table.remove(self.idle)
    if resource then
      return self:checkout(resource)
    end

    if self.live < self.size then
      local opened = self:open_one()
      if opened then return self:checkout(opened) end

    -- Exhausted.  `condition:wait` yields to the controller; it does not spin
    -- and it does not block the loop.
    --
    -- Bounded, because an unbounded park is how a leaked slot becomes an
    -- outage: with `live == size` and nothing ever released, every request
    -- sleeps here until its own deadline fires and the pool reports nothing
    -- wrong. Waking up is also what gives `reclaim_abandoned_opens` a chance
    -- to run again, so the pool can heal while requests are still arriving.
    elseif deadline then
      local remaining = deadline - self.now()
      if remaining <= 0 then
        error(("pool: timed out after %gs waiting for a free resource "
            .. "(size=%d, live=%d, idle=%d)")
            :format(self.wait_timeout, self.size, self.live, #self.idle), 0)
      end
      self.waiters:wait(math.min(remaining, self.open_timeout or remaining))
    else
      self.waiters:wait()
    end
  end
end

-- ======================================================================= put
function Pool:put(resource)
  local mine = rawget(resource, "held_by")
  mine = mine and mine[coroutine.running()]

  if mine then
    -- This coroutine did hold it, but only the checkout it took is its to
    -- return.  Anything else is a stale release: either the resource is
    -- already idle (a second release on another path -- one such path shipped
    -- in the streaming code) or somebody else has it now.
    if mine ~= resource.checkout then return end
  elseif resource.checkout == nil then
    return                              -- already idle; nobody is holding it
  end

  resource.pool = nil
  -- Cleared on BOTH branches below, not just the keep one.  Marking it only
  -- when the resource was pooled meant a double release of an UNFIT connection
  -- decremented `live` once per call: measured `live = -3`, and the pool then
  -- handed out 5 connections at once against `size = 2`.
  resource.checkout = nil

  -- A pool that has been closed is closed.  Without this flag a late release
  -- put a connection back into the idle set of a pool that had already
  -- reported itself drained, and the pool then exceeded its own cap:
  -- measured `size=2 but handed out 3 live connections`.
  if self.closed then
    pcall(function() resource:close() end)
    return
  end

  local keep = true
  if self.reusable then
    local ok, verdict = pcall(self.reusable, resource)
    keep = ok and verdict
  end

  if keep then
    resource.idle_since = self.now()
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
  -- Set before anything else: a resource released while this runs must be
  -- closed, not filed away in the idle set of a pool that is going away.
  self.closed = true
  for _, resource in ipairs(self.idle) do
    resource.checkout = nil
    pcall(function() resource:close() end)
  end
  self.idle, self.live = {}, 0

  -- And wake everyone waiting for a connection that is never coming. A
  -- saturated pool otherwise leaves a coroutine parked on a condition nothing
  -- will ever signal again, so a graceful drain cannot finish at all -- the
  -- process hangs on the way out, which is exactly when nobody is watching.
  self.waiters:signal()
end

function Pool:stats()
  return { size = self.size, live = self.live, idle = #self.idle }
end

return Pool
