--[[
akkar.pool — the failures that do not heal.

Every case here was reproduced against the pool before it was fixed, and every
one of them ends the same way: the pool does not fall over, it stops, and stays
stopped until the process is restarted. That is what makes them worth a spec of
their own -- a crash gets noticed.

The clock is injected where a case is about time, so nothing here sleeps.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local Pool    = require "akkar.pool"
local cqueues = require "cqueues"

-- A pool over trivial resources, with a clock the test drives.
local function fake_pool(size, options)
  options = options or {}
  local clock = { t = 1000 }
  options.now = function() return clock.t end
  local opened, closed = 0, 0
  local pool = Pool.new(function()
    opened = opened + 1
    local r = { id = opened }
    function r:close() closed = closed + 1 end
    return r
  end, size, options.reusable, options)
  return pool, clock, function() return opened, closed end
end

describe("returning a resource somebody else is now holding", function()
  it("is refused, because a boolean the acquire path clears cannot see it", function()
    -- `put` checked `resource.pooled` and `get` cleared it, so
    -- `put -> get(by another coroutine) -> put` filed the connection in `idle`
    -- while the second holder was still using it -- and the next `get` handed
    -- the same socket to a third. Verified before the fix: `live=1 idle=1`
    -- with the idle entry being the object the second caller held.
    local pool = fake_pool(2)
    local shared

    local first = coroutine.create(function()
      shared = pool:get()
      pool:put(shared)                    -- release path one
      coroutine.yield()
      pool:put(shared)                    -- release path two, much later
    end)
    local second = coroutine.create(function()
      local mine = pool:get()             -- takes the very same object
      coroutine.yield()
      pool:put(mine)
    end)

    coroutine.resume(first)
    coroutine.resume(second)
    coroutine.resume(first)               -- the stale second release

    assert.equal(0, pool:stats().idle,
                 "a connection in use was filed as idle")
    assert.equal(1, pool:stats().live)

    coroutine.resume(second)              -- the holder's own release still works
    assert.equal(1, pool:stats().idle)
  end)

  it("still allows a release on somebody's behalf", function()
    -- Draining a request's capabilities from a supervising coroutine is a real
    -- pattern, and it is not the bug above: nobody has released this checkout.
    local pool = fake_pool(2)
    local held = pool:get()
    local helper = coroutine.create(function() pool:put(held) end)
    coroutine.resume(helper)
    assert.equal(1, pool:stats().idle)
  end)
end)

describe("a slot whose open never returned", function()
  it("is reclaimed, so the pool heals when the backend comes back", function()
    -- `live` is taken before `open` runs -- it has to be, or two coroutines
    -- both see room and blow the cap -- and the decrement only runs if `open`
    -- returns. A blackholed backend (firewall change, failed failover, a NAT
    -- table that forgot the flow) parks the coroutine inside `open` forever
    -- and the request's deadline abandons it there.
    --
    -- Measured before the fix: after `pool_size` such requests the pool held
    -- `live == size`, `idle == 0` and zero connections, and every later `get`
    -- parked for its whole deadline. The database coming back healed nothing.
    local blackholed = true
    local clock = { t = 1000 }
    local opened = 0
    local pool = Pool.new(function()
      if blackholed then coroutine.yield() end            -- never returns
      opened = opened + 1
      local r = { id = opened }
      function r:close() end
      return r
    end, 2, nil, { now = function() return clock.t end, open_timeout = 5 })

    for _ = 1, 2 do
      local abandoned = coroutine.create(function() pool:get() end)
      coroutine.resume(abandoned)                          -- parks inside open()
    end
    assert.equal(2, pool:stats().live, "the slots were taken")
    assert.equal(0, pool:stats().idle, "holding no connections at all")

    blackholed = false                                     -- the backend is back
    clock.t = clock.t + 6                                  -- past open_timeout

    local conn = pool:get()
    assert.is_table(conn, "the pool never recovered")
    assert.equal(1, opened)
  end)

  it("does not double-count a slow open that returns after being written off", function()
    local clock = { t = 1000 }
    local late
    local pool = Pool.new(function()
      clock.t = clock.t + 10                               -- open took too long
      late = { close = function() end }
      return late
    end, 1, nil, { now = function() return clock.t end, open_timeout = 5 })

    local conn = pool:get()
    assert.equal(late, conn)
    assert.equal(1, pool:stats().live)
  end)
end)

describe("waiting for a free resource", function()
  it("gives up rather than parking forever", function()
    -- With a leaked slot and nothing ever released, an unbounded park means
    -- every request sleeps here until its own deadline fires while the pool
    -- reports nothing wrong.
    local pool = Pool.new(function() return { close = function() end } end, 1, nil,
                          { wait_timeout = 0.05 })
    local held = pool:get()
    local err
    local cq = cqueues.new()
    cq:wrap(function()
      local ok, why = pcall(function() return pool:get() end)
      if not ok then err = why end
    end)

    assert(cq:loop(3))
    assert.is_truthy(err, "the waiter never came back")
    assert.is_truthy(tostring(err):match "timed out")
    assert.is_truthy(held)
  end)
end)

describe("a closed pool", function()
  it("is not resurrected by a late release", function()
    -- Without a closed flag, a release arriving after `close()` filed a
    -- connection into the idle set of a pool that had already reported itself
    -- drained. Measured: `size=2 but handed out 3 live connections`.
    local pool, _, counts = fake_pool(2)
    local held = pool:get()
    pool:close()
    pool:put(held)

    assert.equal(0, pool:stats().idle)
    assert.equal(0, pool:stats().live)
    local _, closed = counts()
    assert.equal(1, closed, "the late release leaked its connection")
    assert.is_false(pcall(function() return pool:get() end))
  end)

  it("wakes the coroutines waiting on it", function()
    -- `close()` never signalled, so a saturated pool left a coroutine parked
    -- on a condition nothing would ever signal again: a graceful drain could
    -- not finish, and the process hung on the way out.
    local pool = Pool.new(function() return { close = function() end } end, 1, nil,
                          { wait_timeout = false })
    local held = pool:get()
    local woke = false

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function() return pool:get() end)
      woke = true
    end)
    cq:wrap(function()
      cqueues.sleep(0.02)
      pool:close()
    end)

    assert(cq:loop(2), "the drain never finished")
    assert.is_true(woke, "the waiter is still parked")
    assert.is_truthy(held)
  end)
end)

describe("releasing an unfit resource twice", function()
  it("decrements the slot once, not once per call", function()
    -- `pooled` was marked only on the keep branch, so every release of an
    -- unfit connection took another slot off `live`. Measured: `live = -3`,
    -- and the pool then handed out 5 connections at once against `size = 2`.
    local pool = fake_pool(2, { reusable = function(r) return not r.broken end })
    local conn = pool:get()
    conn.broken = true
    pool:put(conn)
    pool:put(conn)
    pool:put(conn)

    assert.equal(0, pool:stats().live)

    local out = 0
    local co = coroutine.create(function()
      while true do pool:get(); out = out + 1 end
    end)
    coroutine.resume(co)
    assert.equal(2, out, "the pool exceeded its own cap")
  end)
end)

describe("what the adapters ask the pool for", function()
  it("hands the pool the application's numbers", function()
    -- The reasons live in `akkar.pool`; only the numbers belong here. A
    -- `connect_timeout` also tells the pool how long an `open` may plausibly
    -- take, which is what makes a slot lost to a blackholed backend
    -- distinguishable from one that is merely being used.
    local factory = require("akkar.db").connect {
      database = "x", pool_size = 3,
      connect_timeout = 2, max_lifetime = 60, idle_timeout = 30,
      pool_wait_timeout = 4,
    }
    assert.equal(4, factory.pool.wait_timeout)
    assert.equal(4, factory.pool.open_timeout)
    assert.equal(60, factory.pool.max_lifetime)
    assert.equal(30, factory.pool.idle_timeout)
  end)

  it("leaves the pool's own defaults in place when nothing is configured", function()
    local factory = require("akkar.redis").connect { pool_size = 2 }
    assert.is_truthy(factory.pool.max_lifetime)
    assert.is_truthy(factory.pool.wait_timeout)
  end)
end)

describe("recycling idle connections", function()
  it("retires one that has outlived max_lifetime instead of handing it out", function()
    -- A connection is handed out of `idle` with no validation, so after a
    -- Postgres restart, a failover or a load balancer's idle reap the pool
    -- deals out up to `pool_size` corpses, one failed request each. Age is the
    -- cheap half of the answer -- no round trip on the acquire path -- because
    -- everything that kills connections from the outside does it on a timer.
    local pool, clock, counts = fake_pool(2, { max_lifetime = 100 })
    local first = pool:get()
    pool:put(first)

    clock.t = clock.t + 101
    local second = pool:get()

    assert.is_not.equal(first, second, "a connection past max_lifetime was reused")
    local opened, closed = counts()
    assert.equal(2, opened)
    assert.equal(1, closed, "the retired connection was not closed")
    assert.equal(1, pool:stats().live)
  end)

  it("retires one that has sat idle past idle_timeout", function()
    local pool, clock = fake_pool(2, { max_lifetime = false, idle_timeout = 60 })
    local first = pool:get()
    pool:put(first)

    clock.t = clock.t + 61
    assert.is_not.equal(first, pool:get())
  end)

  it("keeps a connection that is merely in use, however long for", function()
    -- The age that matters on the way out of `idle` is idle age; a long
    -- transaction is not a stale socket.
    local pool, clock = fake_pool(2, { max_lifetime = false, idle_timeout = 60 })
    local held = pool:get()
    clock.t = clock.t + 600
    pool:put(held)
    assert.equal(held, pool:get())
  end)
end)
