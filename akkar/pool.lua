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

And nothing here knows how long a resource stays good, either, which is why
`max_lifetime` and `idle_timeout` exist: see `Pool:reap_idle`.
]]

local condition = require "cqueues.condition"
local execution = require "akkar.execution"
local time      = require "akkar.time"

local Pool = {}
Pool.__index = Pool

-- Both overridable, both disabled by passing `false` or `0`.
--
-- These are the numbers HikariCP settled on after a decade of the same
-- failures, and the reasoning carries: every connection has a third party
-- that may kill it -- a failover, a load balancer's idle reap, a
-- `pg_terminate_backend` -- and the pool should recycle first rather than find
-- out by handing a corpse to a request. Keep `max_lifetime` under whatever
-- reaps connections in front of the database.
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
-- @param options   `max_lifetime` and `idle_timeout`, in seconds, each
--                  disabled by `false` or `0`; and `now`, the clock the
--                  ages are measured against
function Pool.new(open, size, reusable, options)
  options = options or {}
  return setmetatable({
    open = open,
    size = size,
    reusable = reusable,
    idle = {},
    live = 0,

    -- AGE IS READ FROM ITS OWN CLOCK, and only age is. A deadline and a
    -- `waited` sample are measurements of the running scheduler and have to
    -- come from the same monotonic clock the scheduler uses; how old a socket
    -- is, is a fact about a timer somewhere else, and a spec that wants to
    -- prove a thirty-minute connection gets retired cannot wait thirty
    -- minutes to do it.
    now = options.now or time.monotime,
    max_lifetime = setting(options.max_lifetime, MAX_LIFETIME),
    idle_timeout = setting(options.idle_timeout, IDLE_TIMEOUT),
    retired = 0,
    -- Slots taken by a coroutine that is still inside `open`. Weak keys: an
    -- abandoned coroutine is unreferenced by anything else, so a collection
    -- takes its reservation with it. See `Pool:reap`.
    opening = setmetatable({}, { __mode = "k" }),
    reaped = 0,
    waits = 0, waited = 0, waited_max = 0,

    -- A QUEUE, NOT A CROWD. `queue` holds tickets oldest-first and `qhead` is
    -- the oldest one still worth waking; see `Pool:_head`.
    --
    -- One `condition` per ticket rather than one for the pool, which is only
    -- affordable because a cqueues condition is a VIRTUAL pollable: measured,
    -- 200 of them cost zero file descriptors, and `pollfd()` returns the
    -- condition object rather than a number. `spec/substrate_spec.lua` states
    -- the constraint this had to clear -- "a pool of thirty waiters must not
    -- cost sixty descriptors" -- and it clears it with nothing to spare
    -- because there is nothing to spend.
    queue = {},
    qhead = 1,
  }, Pool)
end

--- The oldest ticket still worth waking, dropping any that cannot take a
--- resource any more.
---
--- A ticket is spent when its holder left (`done`) or when the deadline it
--- recorded on arrival has passed. THE DEADLINE IS WHY THIS IS POSSIBLE AT
--- ALL: an abandoned coroutine is suspended rather than dead, so
--- `coroutine.status` cannot distinguish it -- the same problem `Pool:reap`
--- solves with a weak table. Here the answer is cheaper, because a waiter
--- knows when it will stop caring and can say so when it queues.
function Pool:_head()
  local q = self.queue
  while self.qhead <= #q do
    local ticket = q[self.qhead]
    if ticket and not ticket.done
       and not (ticket.expires and ticket.expires <= time.monotime()) then
      return ticket
    end
    -- WOKEN ON THE WAY OUT, and `spec/pool_abandoned_wait_spec.lua` is why.
    --
    -- Dropping an expired ticket silently leaves its holder parked for ever.
    -- If that coroutine is genuinely abandoned nobody notices; but if it is
    -- merely LATE -- past its deadline and still resumable -- it is owed the
    -- refusal that names what happened, and the old broadcast gave it that by
    -- accident, because it woke everybody including the condemned.
    --
    -- The spec caught this the first time the queue ran: "the abandoned
    -- waiter was not refused at all", `nil` where an error message belongs.
    -- A signal costs nothing when there is nobody to resume.
    if ticket then ticket.cond:signal() end
    q[self.qhead] = false      -- drop the reference, keep the sequence
    self.qhead = self.qhead + 1
  end
  -- Drained. Reset rather than let the array grow for the life of the pool.
  if self.qhead > 1 then self.queue, self.qhead = {}, 1 end
  return nil
end

--- Wakes the oldest waiter, if there is one.
function Pool:_wake()
  local ticket = self:_head()
  if ticket then ticket.cond:signal(1) end
end

--- Wakes the next in line, but only if there is something for them to take.
---
--- Waking one waiter per resource is the whole discipline, and it has two
--- edges. A caller that LEAVES the queue -- with a connection, or empty
--- handed -- must pass the turn on, or the queue stalls until the next `put`.
--- And a wakeup with nothing behind it costs a scheduler round trip and
--- teaches the waiter nothing, which is what the old broadcast did N times
--- over.
---
--- Capacity counts as something to take: `reap` frees reservations rather
--- than resources, and a waiter woken by it has no `idle` entry waiting --
--- it has permission to open one.
function Pool:_wake_next()
  if #self.idle > 0 or self.live + self:reserved() < self.size then
    self:_wake()
  end
end

--- Joins the queue, at the back.
function Pool:_enqueue()
  local left = execution.remaining()
  local ticket = {
    cond = condition.new(),
    expires = left and (time.monotime() + left) or nil,
  }
  self.queue[#self.queue + 1] = ticket
  return ticket
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
    -- One wakeup, not a broadcast: the woken caller wakes the next as it
    -- leaves, so `freed` slots reach `freed` waiters in a chain rather than
    -- in a stampede that then contends over the same first slot.
    self:_wake_next()
  end
  return freed
end

--- Whether a resource sitting in `idle` is too old to hand out.
---
--- Two ages, because they answer different questions. `created_at` bounds how
--- long a connection may exist at all, which is what a failover or a rolling
--- restart needs; `idle_since` bounds how long it may sit unused, which is
--- what a load balancer's idle reap needs. A resource that is merely BUSY has
--- no `idle_since` -- a long transaction is not a stale socket -- so only the
--- lifetime bound applies to it, and it is only ever consulted here, on the
--- way back out of the idle set.
local function expired(self, resource, now)
  if self.max_lifetime and resource.created_at
     and now - resource.created_at > self.max_lifetime then
    return true
  end
  return self.idle_timeout ~= nil and resource.idle_since ~= nil
     and now - resource.idle_since > self.idle_timeout
end

--- Closes the idle resources that have aged out, and frees their slots.
---
--- THE POOL HANDS A CONNECTION OUT OF `idle` WITHOUT VALIDATING IT, and the
--- `reusable` predicate only runs on the return leg. So after a Postgres
--- restart, a failover, or a load balancer reaping idle connections behind the
--- pool's back, up to `size` corpses get dealt out, one failed request each --
--- and the pool reports nothing wrong the whole time, because as far as it can
--- see it is holding `size` perfectly good connections.
---
--- The fix is deliberately NOT a `select 1` on every acquire. That is a round
--- trip on the hottest path in the framework, and it still races: the
--- connection can die between the probe and the query. Age is free and catches
--- the whole class, because every third party that kills connections from the
--- outside does it on a timer.
---
--- Called from `get`, before the idle set is read, so a retired connection is
--- never the one handed back. Public because a supervisor draining a pool that
--- has gone quiet has no `get` to hang this off.
function Pool:reap_idle()
  if #self.idle == 0 then return 0 end
  if not (self.max_lifetime or self.idle_timeout) then return 0 end

  local now, kept, retired = self.now(), {}, 0
  for _, resource in ipairs(self.idle) do
    if expired(self, resource, now) then
      -- `pooled` STAYS SET, and `discarded` joins it. Both are what `put`
      -- reads to refuse a second release, and this resource is now closed:
      -- a late `put` that got through would decrement `live` for a slot this
      -- loop has already given back, which is the arithmetic that drove
      -- `live` negative before.
      resource.discarded = true
      resource.pool = nil
      pcall(function() resource:close() end)
      self.live = self.live - 1
      retired = retired + 1
    else
      kept[#kept + 1] = resource        -- order preserved: `idle` is LIFO
    end
  end
  self.idle = kept
  self.retired = self.retired + retired

  -- Reaping frees CAPACITY, not a resource -- `live` went down, the idle set
  -- did not grow -- and that is exactly the state `_wake_next` counts as
  -- something to take: a woken waiter has permission to open one.
  if retired > 0 then self:_wake_next() end
  return retired
end

--- Refuses a caller whose execution is already over.
---
--- THE HOLE F2 LEFT, and it cost an outage on the study box before anyone saw
--- it. Removing the per-request controller made an abandoned handler wake
--- instead of staying inert, and what was supposed to protect the next
--- request is the budget -- `db.lua` and `redis.lua` both refuse a query when
--- `execution.remaining()` has gone negative.
---
--- That covers the QUERY and not the ACQUISITION. A handler parked in
--- `waiters:wait()` below when its deadline fires is not inside a query yet.
--- It woke after the 503 had gone out, was handed the next free slot, and
--- nothing ever returned it: the request's release ran at the 503, when the
--- handler held nothing to release.
---
--- Measured, pool of 2, four fast clients and one slow, 120 s:
---
---     with the hole    224.7 ok/s, then 0.0 ok/s from t=10s, for ever
---     without it      3195.4 ok/s, flat to the end
---
--- and afterwards, with no load running at all, `live=2 idle=0` and every
--- probe answering 503. A permanent outage, not a slowdown.
---
--- Self-reinforcing, which is why it arrives as a cliff: each leaked slot
--- lengthens the wait, and a longer wait abandons more handlers inside it.
--- With slack it never starts -- a pool of 10 ran 935,510 requests with a
--- `waited_max` of 16 ms and leaked nothing.
---
--- nil means NO budget, which is jobs, workers and `app:test`, and must read
--- as "no limit" rather than "already over" -- the same trap `with_deadline`
--- documents about `timeout = 0`.
local function abandoned()
  local left = execution.remaining()
  return left ~= nil and left <= 0
end

function Pool:get()
  local ticket

  -- Leaving the queue is its own step because there are four ways out of the
  -- loop below -- got one, opened one, deadline, raise -- and a ticket left
  -- behind blocks everybody behind it until its deadline expires.
  local function leave()
    if ticket then ticket.done = true; ticket = nil end
  end

  while true do
    if abandoned() then
      leave()
      -- Hand the turn on rather than swallowing it: another waiter may still
      -- have time, and this one is leaving.
      self:_wake()
      error("pool: the request deadline passed while waiting for a slot", 0)
    end

    -- BEFORE THE IDLE SET IS READ, never after. A connection that has aged
    -- out must not be the one this turn of the loop hands back, and the slot
    -- it frees is capacity this same caller can immediately open into.
    self:reap_idle()

    -- FIRST IN LINE, OR NOBODY IS. This one line is the fix.
    --
    -- `table.remove(self.idle)` used to run unconditionally, and that is how
    -- a pool with a condition on it still starved: `put` appended to `idle`
    -- and broadcast, but a coroutine that is ALREADY RUNNING -- a request
    -- just read off a socket -- reaches this line before any woken waiter is
    -- resumed, and takes the connection it was signalled about. The queue was
    -- decoration; the resource went to whoever the scheduler ran next.
    --
    -- Measured on the box, twelve waiters and one token over 400 rounds:
    -- **ten of the twelve were never served at all**, in both controller
    -- shapes, with a worst gap of the entire run. Serving the oldest first
    -- gave every waiter 16 or 17 of the 400.
    --
    -- In the server, on `/users/42` at 100 connections, p99 fell from 5.42 s
    -- to 17 ms -- 320x -- and throughput went UP, 7165 to 7409 req/s. The
    -- barging was not buying the throughput it cost the tail. It also
    -- explains a shape that had been read backwards: p50 RISES when this is
    -- fixed, 5.9 to 13.3 ms, because the good median was the starved tail.
    --
    -- Opening is deliberately NOT gated this way, below. Taking from `idle`
    -- takes something a parked caller is owed; opening creates capacity that
    -- did not exist, and serialising that behind the queue would make a cold
    -- pool establish its connections one at a time.
    local head = self:_head()
    if head == nil or head == ticket then
      local resource = table.remove(self.idle)
      if resource then
        leave()
        self:_wake_next()
        resource.pool = self
        resource.pooled = nil
        -- It is out of the idle set, so it is not accruing idle age any more.
        -- Only `created_at` still bounds it, which is what keeps a long
        -- transaction from being mistaken for a stale socket.
        resource.idle_since = nil
        return resource
      end
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
        leave()
        self:_wake()
        error(resource_or_err, 0)
      end

      self.live = self.live + 1
      resource_or_err.pool = self
      resource_or_err.pooled = nil
      -- Stamped where the resource comes into existence, and nowhere else:
      -- `max_lifetime` is measured from the connect, not from the last time
      -- somebody borrowed it, or a busy pool would keep a socket for ever by
      -- refreshing its own clock.
      resource_or_err.created_at = self.now()

      -- AND CHECKED AGAIN HERE, WHICH IS THE HOLE THE FIRST FIX MISSED.
      --
      -- `open` YIELDS: it connects a socket, and on Postgres it authenticates
      -- and sets `statement_timeout` besides. The deadline lands in there, and
      -- the guard at the top of the loop cannot have seen it -- the budget was
      -- still positive when this iteration began.
      --
      -- Measured on the study box after the wait-path guard shipped: the pool
      -- still went to zero, and every leaked resource was tagged
      -- `budget=-0.0035 @ pool.lua in akkar.pool.get`, handed out with the
      -- budget ALREADY NEGATIVE, from this branch. The entry check caught
      -- nothing at all -- `budget_over=0` across 21,691 acquisitions -- while
      -- 26 refusals fired on the wait path. Right guard, wrong frame.
      --
      -- It is easy to reach precisely because an abandoned query discards its
      -- connection, so `open` runs constantly under exactly the load that
      -- abandons handlers.
      --
      -- `put` rather than `close`: the connection is fresh and perfectly good,
      -- and parking it signals a waiter who may still have time. Throwing it
      -- away would make a contended pool reconnect on every abandonment.
      if abandoned() then
        leave()
        self:put(resource_or_err)
        error("pool: the request deadline passed while the connection opened", 0)
      end

      leave()
      -- Opening consumed a slot, but there may still be more, and whoever is
      -- next in line has been waiting longer than the caller that just
      -- opened one.
      self:_wake_next()
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
      -- Joined here rather than on entry, so the uncontended path -- a
      -- resource sitting in `idle` -- allocates no ticket and no condition.
      if not ticket then ticket = self:_enqueue() end
      local started = time.monotime()
      ticket.cond:wait()
      local waited = time.monotime() - started
      -- Checked HERE as well as at the top of the loop, because this is the
      -- moment that matters: the deadline may have passed during the wait,
      -- and the next turn of the loop would take a slot for a caller that can
      -- no longer give it back.
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
    resource.idle_since = self.now()
    self.idle[#self.idle + 1] = resource
  else
    resource.discarded = true
    pcall(function() resource:close() end)
    self.live = self.live - 1
  end

  -- Wake the OLDEST waiter, and only that one.
  --
  -- This used to be a broadcast, for a reason that was real: a request whose
  -- deadline fires while parked in `get()` is never resumed but stays
  -- registered on the condition, so `signal(1)` could hand the wakeup to a
  -- coroutine that would never take it while a live waiter slept beside an
  -- idle connection. Measured then: a request waited its full ten-second
  -- budget and returned 503 with `idle=1` in the pool.
  --
  -- Waking everybody did fix that, and caused the tail this file now carries
  -- a queue to avoid -- every waiter woke, and the connection went to
  -- whichever the scheduler resumed first, or to a barging arrival before
  -- any of them ran.
  --
  -- The queue answers the original problem directly instead: `_head` drops a
  -- ticket whose recorded deadline has passed, so a wakeup is never spent on
  -- a coroutine that cannot use it. AND THE RESOURCE IS STILL PUT IN `idle`
  -- FIRST, deliberately -- it is never handed to a waiter and held there. If
  -- a wakeup is somehow lost anyway, the connection is sitting where the next
  -- caller will find it, so the worst case is latency rather than a resource
  -- stranded on a coroutine nobody will resume.
  self:_wake()
end

function Pool:close()
  for _, resource in ipairs(self.idle) do
    resource.pooled = nil
    pcall(function() resource:close() end)
  end
  self.idle, self.live = {}, 0
  self.opening = setmetatable({}, { __mode = "k" })
  -- Anyone parked is woken so they re-check and leave, rather than waiting
  -- out a deadline against a pool that is gone.
  for i = self.qhead, #self.queue do
    local ticket = self.queue[i]
    if ticket then ticket.cond:signal() end
  end
  self.queue, self.qhead = {}, 1
end

--- `live` is resources that EXIST; `reserved` is slots held by an open still
--- in flight. Two numbers because a pool reporting one total cannot say
--- whether it is busy or stuck.
function Pool:stats()
  return {
    size = self.size, live = self.live, idle = #self.idle,
    reserved = self:reserved(), reaped = self.reaped,
    -- Connections closed for age rather than for a verdict: a number that
    -- rises steadily is the pool doing its job, and one that jumps is
    -- something in front of the database reaping faster than `max_lifetime`.
    retired = self.retired,
    -- How often a request had to queue for a connection, and for how long.
    waits = self.waits, waited = self.waited, waited_max = self.waited_max,
  }
end

return Pool
