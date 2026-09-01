--[[
`max_qps` and `latency_ms` on the in-memory adapters.

## What they are for

A capacity diagram says "1,500 requests per second, 8 ms of service time" and
until now the adapter a test ran against knew neither number. So an application
could be tested against a dependency that is always instantly available, and
against nothing else -- which is the one condition production never provides.

These two knobs put the diagram's numbers into the adapter, and the reason that
closes a loop rather than merely adding a feature is that THE SAME NUMBERS
CONFIGURE A SIMULATION AND A REAL RUN. A prediction and a measurement can then
disagree, and the disagreement is the interesting part: a model that presents
itself as truth teaches less than one that admits it is approximate.

## The constraint that makes it usable

They are honoured by advancing `akkar.time`, not by waiting on a wall clock.
Under `akkar.time.manual` a modelled second passes instantly, so a test of a
saturated store is deterministic and finishes now; under the real clock the
same configuration costs real seconds, which is what a load test wants. One
setting, two behaviours, and the difference is which clock is installed.

`:hang` deliberately does NOT work that way -- it sleeps on the real clock
whatever is installed, because its job is to stage a coroutine abandoned
mid-command and that needs a genuine yield. The two are in the same modules and
they pull in opposite directions on purpose; `spec/cache_fault_parity_spec.lua`
holds the other end.

## The drift guard

The model is written out twice, once per adapter, because neither module should
have to require the other to be honest about its own timing. Every case here
that can be asked of both adapters IS asked of both, from one table of numbers,
so a change to one that is not made to the other fails here.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local time    = require "akkar.time"
local cache   = require "akkar.cache.memory"
local db      = require "akkar.db.memory"

-- The diagram's numbers, and every case below reads them from here rather than
-- writing its own. `docs/labs/DALIVIM-INTEGRATION.md` uses exactly these.
local DIAGRAM = { max_qps = 1500, latency_ms = 8 }

--- One adapter of each kind, configured identically and driven identically.
---
--- `issue` is what "one round trip" means for that adapter, so a case can say
--- "fifty round trips" once and have it mean the right thing on both.
local function adapters(options)
  return {
    {
      name = "akkar.cache.memory",
      make = function()
        return cache.new(options)
      end,
      issue = function(store, i) return store:get("k" .. i) end,
    },
    {
      name = "akkar.db.memory",
      make = function()
        local fake = db.new(options)
        fake:on("select", { { id = 1 } })
        return fake
      end,
      issue = function(store, i) return store:many("select " .. i) end,
    },
  }
end

--- Installs a manual clock, runs `fn`, and puts the previous clock back
--- however `fn` ends. Returns how much time the CLOCK thinks passed and how
--- much the wall clock says really did.
---
--- Both numbers, always, because the whole claim is about the gap between
--- them.
local function under_manual_clock(fn)
  local clock   = time.manual { now = 1755000000, monotime = 0 }
  local restore = time.set(clock)
  local wall    = os.clock()

  local ok, err = pcall(fn, clock)
  local virtual = clock.monotime()
  restore()

  if not ok then error(err, 0) end
  return virtual, os.clock() - wall
end

describe("latency_ms", function()
  for _, adapter in ipairs(adapters { latency_ms = DIAGRAM.latency_ms }) do
    it("costs the configured service time per round trip, on " .. adapter.name,
      function()
        local virtual, real = under_manual_clock(function()
          local store = adapter.make()
          for i = 1, 50 do adapter.issue(store, i) end
        end)

        -- 50 round trips at 8 ms.
        assert.is_true(math.abs(virtual - 0.4) < 1e-9,
          ("50 trips at 8 ms moved the clock %.6fs, not 0.4"):format(virtual))
        -- And nothing waited for any of it.
        assert.is_true(real < 0.4,
          ("0.4s of modelled latency cost %.3fs of CPU"):format(real))
      end)
  end

  it("moves the clock the adapter itself reads, so a TTL expires with it",
    function()
      -- Not a separate mechanism bolted on beside the cache's own clock: the
      -- default `now` IS `akkar.time.now`, so modelled latency ages the
      -- entries. A store slow enough matters precisely because things expire
      -- while you wait for it.
      under_manual_clock(function()
        local store = cache.new { latency_ms = 500 }
        store:set("session", "alice", 1)
        assert.equal("alice", store:get "session")   -- 0.5s in
        assert.is_nil(store:get "session")           -- 1.5s in: gone
      end)
    end)

  it("is not charged twice for one command", function()
    -- `cache:get` and `cache:command("GET", ...)` are the same round trip
    -- reached two ways, and the dispatcher underneath them must be charged by
    -- exactly one of the two.
    local virtual = under_manual_clock(function()
      local store = cache.new { latency_ms = 100 }
      store:command("GET", "k")
    end)
    assert.is_true(math.abs(virtual - 0.1) < 1e-9,
      ("one GET cost %.3fs of a 0.1s service time"):format(virtual))
  end)

  it("charges a script once, however many commands it runs", function()
    -- EVAL is one round trip on a real server. Charging per `redis.call`
    -- would model a Redis nobody has, and would make `akkar.limit` -- whose
    -- whole decision is one script -- look twenty times slower than it is.
    local virtual = under_manual_clock(function()
      local store = cache.new { latency_ms = 100 }
      store:eval([[
        for i = 1, 20 do redis.call('INCR', KEYS[1]) end
        return redis.call('GET', KEYS[1])
      ]], 1, "n")
    end)
    assert.is_true(math.abs(virtual - 0.1) < 1e-9,
      ("a 21-command script cost %.3fs of a 0.1s round trip"):format(virtual))
  end)
end)

describe("max_qps", function()
  for _, adapter in ipairs(adapters { max_qps = 1000 }) do
    it("serves at the configured rate and no faster, on " .. adapter.name,
      function()
        local virtual = under_manual_clock(function()
          local store = adapter.make()
          for i = 1, 1000 do adapter.issue(store, i) end
        end)

        -- A queue with a fixed service rate: the first trip is free because
        -- the server is idle, and the thousandth cannot finish before
        -- 999/1000 of a second.
        assert.is_true(math.abs(virtual - 0.999) < 1e-6,
          ("1000 trips at 1000/s took %.6fs, not 0.999"):format(virtual))
      end)
  end

  it("does not charge a caller for capacity nobody was using", function()
    -- An arrival into an idle store waits for nothing. Without this the model
    -- would be a fixed delay wearing a throughput's name.
    local virtual = under_manual_clock(function(clock)
      local store = cache.new { max_qps = 10 }
      store:get "first"
      clock:advance(60)             -- an idle minute
      store:get "second"
    end)
    assert.is_true(math.abs(virtual - 60) < 1e-9,
      ("an idle store charged %.6fs beyond the minute"):format(virtual - 60))
  end)

  it("is one queue with latency_ms and not a second delay added to it", function()
    -- THE ARITHMETIC THIS CASE EXISTS TO PIN, because the obvious reading of
    -- two knobs is that they add up, and adding them would invent a store
    -- slower than either number describes.
    --
    -- One server. A command occupies it for `latency_ms` and the rate says
    -- how often a new one may start, so whichever is the tighter constraint
    -- is the one a caller feels.

    -- Service-bound: 50 ms of work cannot be issued 100 times a second.
    -- 10 trips at 50 ms is 0.5s, and the 100/s never binds.
    local service_bound = under_manual_clock(function()
      local store = cache.new { max_qps = 100, latency_ms = 50 }
      for i = 1, 10 do store:get("k" .. i) end
    end)
    assert.is_true(math.abs(service_bound - 0.5) < 1e-9,
      ("a service-bound store took %.6fs, not 0.5 -- the rate was added on " ..
       "top of the service time"):format(service_bound))

    -- Rate-bound: the same store at 20/s. The first trip pays its 10 ms of
    -- service, and each one after it waits for its 50 ms slot.
    local rate_bound = under_manual_clock(function()
      local store = cache.new { max_qps = 20, latency_ms = 10 }
      for i = 1, 10 do store:get("k" .. i) end
    end)
    assert.is_true(math.abs(rate_bound - 0.46) < 1e-9,
      ("a rate-bound store took %.6fs, not 0.46"):format(rate_bound))
  end)
end)

describe("the latency is observed without anything sleeping", function()
  -- THE CLAIM THIS FEATURE STANDS OR FALLS ON, and elapsed time cannot prove
  -- it: a machine fast enough makes any wall-clock assertion pass. What
  -- distinguishes a modelled wait from a real one is whether the SCHEDULER
  -- ever got control, so the proof is event ordering -- the same shape
  -- `spec/akkar_spec.lua` uses for the pool and `spec/work_spec.lua` for
  -- cooperative yielding.
  --
  -- A real sleep yields, so an unrelated coroutine runs in the middle of the
  -- slow one. A modelled one does not, so the slow coroutine finishes first
  -- and the ordering says so.

  local function ordering(store, trips)
    local order = {}
    local cq = cqueues.new()
    cq:wrap(function()
      order[#order + 1] = "slow started"
      for i = 1, trips do store:get("k" .. i) end
      order[#order + 1] = "slow finished"
    end)
    cq:wrap(function()
      cqueues.sleep(0)                    -- runnable on the very next tick
      order[#order + 1] = "unrelated ran"
    end)
    assert(cq:loop(30))
    return order
  end

  it("never yields to the scheduler, under a manual clock", function()
    local order
    local virtual, real = under_manual_clock(function()
      order = ordering(cache.new { latency_ms = 200 }, 50)
    end)

    assert.same({ "slow started", "slow finished", "unrelated ran" }, order)

    -- Ten modelled seconds passed.
    assert.is_true(math.abs(virtual - 10) < 1e-9,
      ("the clock moved %.6fs, not 10"):format(virtual))
    -- And the process spent none of them.
    assert.is_true(real < 1,
      ("ten modelled seconds cost %.3fs of CPU"):format(real))
  end)

  it("does yield when the clock is the real one, which is what makes the " ..
     "assertion above mean something", function()
    -- The control. Without it, `{ started, finished, unrelated }` could be
    -- the ordering this harness always produces, and the case above would be
    -- asserting nothing. Deliberately small: 5 trips at 10 ms is 0.05s.
    local order = ordering(cache.new { latency_ms = 10 }, 5)

    assert.same({ "slow started", "unrelated ran", "slow finished" }, order)
  end)
end)

describe("an adapter nobody configured", function()
  for _, adapter in ipairs(adapters(nil)) do
    it("costs nothing at all, on " .. adapter.name, function()
      local virtual = under_manual_clock(function()
        local store = adapter.make()
        for i = 1, 200 do adapter.issue(store, i) end
      end)
      assert.equal(0, virtual,
        "an unconfigured adapter moved the clock, so every existing spec is " ..
        "now paying for a feature it did not ask for")
    end)
  end
end)

describe("a capacity that cannot be met", function()
  for _, adapter in ipairs { { name = "akkar.cache.memory", new = cache.new },
                             { name = "akkar.db.memory",    new = db.new } } do
    it("refuses a max_qps of zero rather than dividing by it, on " .. adapter.name,
      function()
        local ok, err = pcall(adapter.new, { max_qps = 0 })
        assert.is_false(ok)
        assert.is_truthy(tostring(err):match "max_qps must be a number greater than zero")
        -- And it says what to write instead, because "capacity zero" is a
        -- real thing somebody means: a store nothing can reach is `:drop()`.
        assert.is_truthy(tostring(err):match ":drop%(%)")
      end)

    it("refuses a negative latency_ms, on " .. adapter.name, function()
      local ok, err = pcall(adapter.new, { latency_ms = -1 })
      assert.is_false(ok)
      assert.is_truthy(tostring(err):match "latency_ms must be a number of milliseconds")
    end)
  end
end)

describe("through the framework, which is the point of it", function()
  it("gives a handler the dependency the diagram described", function()
    -- `app:test` with the diagram's own numbers, and no Postgres or Redis
    -- anywhere. This is the shape a generated exercise runs in.
    local app = akkar.new()
    app:get("/order/:id", function(req)
      local hit = req.cache:get("order:" .. req.params.id)
      if hit then return { id = hit, cached = true } end
      local row = req.db:one "select id from orders where id = $1"
      req.cache:set("order:" .. req.params.id, row.id, 60)
      return { id = row.id, cached = false }
    end)

    local virtual = under_manual_clock(function()
      local client = app:test {
        cache = cache.factory(DIAGRAM),
        db    = db.factory(DIAGRAM, function(fake)
          fake:on("select id from orders", { { id = 7 } })
        end),
      }

      local first = client:get "/order/7"
      assert.equal(200, first.status)
      assert.is_false(first.body.cached)

      local second = client:get "/order/7"
      assert.is_true(second.body.cached)
    end)

    -- Four round trips: a cache miss, a query, a cache write, a cache hit.
    -- At 8 ms each, and the queueing at 1500/s is negligible beside it.
    assert.is_true(virtual > 0.03 and virtual < 0.04,
      ("the request cost %.4fs of modelled dependency time; four round " ..
       "trips at 8 ms should be ~0.032"):format(virtual))
  end)

  it("keeps the old factory shape working", function()
    -- `db.factory(function(fake) ... end)` predates the options table and is
    -- used across the suite. A table is options, a function is the programmer,
    -- and both together is both.
    local by_function = db.factory(function(fake) fake:on("select", { { id = 1 } }) end)
    assert.equal(1, by_function():one("select 1").id)
    assert.is_nil(by_function().max_qps)

    local by_table = db.factory { latency_ms = 5 }
    assert.equal(5, by_table().latency_ms)
  end)
end)
