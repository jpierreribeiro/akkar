--[[
akkar.breaker — every transition, on a clock that only moves when told.

The deadline bounds what ONE call to a dead dependency costs. Nothing in the
tree stopped the next thousand calls from each paying it, and that is the one
resilience pattern `docs/BACKLOG.md` and the plan both name as absent. What is
pinned here is each edge of the state machine, exactly -- "after N failures",
"exactly M probes", "closed after T seconds" -- which is only possible because
`akkar.time` is a manual clock in every test below and no real second passes.

The last group proves the point of the module rather than its mechanics: an
HTTP client with a breaker stops DIALLING, counted at the connection, not at
the call.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local breaker = require "akkar.breaker"
local time    = require "akkar.time"
local metrics = require "akkar.metrics"

describe("akkar.breaker", function()
  local clock, restore

  before_each(function()
    clock = time.manual { monotime = 1000 }
    restore = time.set(clock)
  end)
  after_each(function() restore() end)

  --- A dependency whose verdict the test chooses per call, and which counts
  --- how many times it was actually invoked -- the number a refusal must not
  --- move.
  local function dependency()
    local dep = { calls = 0, answer = "ok" }
    function dep.call()
      dep.calls = dep.calls + 1
      if dep.answer == "raise" then error("boom", 0) end
      if dep.answer == "fail" then return nil, "connection refused" end
      return dep.answer
    end
    return dep
  end

  local function fail_n(b, dep, n)
    dep.answer = "fail"
    for _ = 1, n do b:call(dep.call) end
  end

  describe("the consecutive policy", function()
    it("opens after `threshold` failures and refuses without calling", function()
      local b = breaker.new { threshold = 3, cooldown = 30 }
      local dep = dependency()

      fail_n(b, dep, 2)
      assert.equal("closed", b:current(), "two failures must not trip a threshold of three")
      fail_n(b, dep, 1)
      assert.equal("open", b:current())
      assert.equal(3, dep.calls)

      local res, why = b:call(dep.call)
      assert.is_nil(res)
      assert.equal("breaker open", why)
      assert.equal(breaker.OPEN, why)
      assert.equal(3, dep.calls, "an open breaker called the dependency")
    end)

    it("resets the run on a success, so failures must be consecutive", function()
      local b = breaker.new { threshold = 3 }
      local dep = dependency()
      fail_n(b, dep, 2)
      dep.answer = "ok"
      assert.equal("ok", b:call(dep.call))
      fail_n(b, dep, 2)
      assert.equal("closed", b:current(), "a success in the middle did not reset the run")
      fail_n(b, dep, 1)
      assert.equal("open", b:current())
    end)

    it("counts a raise as a failure and re-raises it", function()
      local b = breaker.new { threshold = 2 }
      local dep = dependency()
      dep.answer = "raise"
      assert.has_error(function() b:call(dep.call) end, "boom")
      assert.has_error(function() b:call(dep.call) end, "boom")
      assert.equal("open", b:current())
      -- Refused, not raised: the breaker's own answer is the house convention.
      assert.has_no.errors(function()
        local res, why = b:call(dep.call)
        assert.is_nil(res)
        assert.equal(breaker.OPEN, why)
      end)
    end)

    it("returns everything the call returned", function()
      local b = breaker.new { threshold = 1 }
      local a, c, d = b:call(function() return 1, nil, 3 end)
      assert.same({ 1, nil, 3 }, { a, c, d })
      assert.equal("closed", b:current())
    end)
  end)

  describe("the cooldown and the half-open probes", function()
    it("stays open until `cooldown` seconds have passed on the clock", function()
      local b = breaker.new { threshold = 1, cooldown = 30 }
      local dep = dependency()
      fail_n(b, dep, 1)

      clock:advance(29)
      assert.equal("open", b:current())
      assert.is_nil(b:call(dep.call))
      assert.equal(1, dep.calls)

      clock:advance(1)
      assert.equal("half_open", b:current())
    end)

    it("allows exactly `half_open_max` probes, then refuses again", function()
      local b = breaker.new { threshold = 1, cooldown = 10, half_open_max = 2 }
      local dep = dependency()
      fail_n(b, dep, 1)
      clock:advance(10)

      -- Probes are claimed at `allow` and reported later, so two callers can
      -- both be let through before either has an answer.
      assert.is_true(b:allow())
      assert.is_true(b:allow())
      local ok, why = b:allow()
      assert.is_nil(ok)
      assert.equal(breaker.OPEN, why)
      assert.equal("half_open", b:current())
    end)

    it("closes on a probe success", function()
      local b = breaker.new { threshold = 1, cooldown = 10 }
      local dep = dependency()
      fail_n(b, dep, 1)
      clock:advance(10)

      dep.answer = "ok"
      assert.equal("ok", b:call(dep.call))
      assert.equal("closed", b:current())
      assert.equal("ok", b:call(dep.call))
      assert.equal(3, dep.calls)
    end)

    it("needs every probe to succeed when more than one is issued", function()
      local b = breaker.new { threshold = 1, cooldown = 10, half_open_max = 2 }
      local dep = dependency()
      fail_n(b, dep, 1)
      clock:advance(10)
      dep.answer = "ok"
      b:call(dep.call)
      assert.equal("half_open", b:current(), "one good probe of two closed the breaker")
      b:call(dep.call)
      assert.equal("closed", b:current())
    end)

    it("re-opens on a probe failure and re-arms the cooldown", function()
      local b = breaker.new { threshold = 1, cooldown = 10 }
      local dep = dependency()
      fail_n(b, dep, 1)
      clock:advance(10)

      fail_n(b, dep, 1)                     -- the probe fails
      assert.equal("open", b:current())
      assert.equal(2, b:stats().trips)
      clock:advance(9)
      assert.equal("open", b:current(), "the cooldown was not re-armed")
      clock:advance(1)
      assert.equal("half_open", b:current())
    end)

    it("issues the probes again after a cooldown with no verdict", function()
      -- The probe's coroutine was abandoned at the deadline, so nobody
      -- reports. Without this the breaker refuses for ever.
      local b = breaker.new { threshold = 1, cooldown = 10 }
      local dep = dependency()
      fail_n(b, dep, 1)
      clock:advance(10)
      assert.is_true(b:allow())             -- claimed, never reported
      assert.is_nil(b:allow())
      clock:advance(10)
      assert.is_true(b:allow(), "an abandoned probe wedged the breaker")
    end)
  end)

  describe("the sampling policy", function()
    it("trips on the failure ratio, not on the count", function()
      local b = breaker.new { threshold = 0.5, window = 60, minimum = 10 }
      local dep = dependency()

      -- Twenty failures below the ratio: 20 of 50 is 40 %. A consecutive
      -- policy with any threshold under twenty would have tripped by now.
      for _ = 1, 30 do dep.answer = "ok"; b:call(dep.call) end
      fail_n(b, dep, 20)
      assert.equal("closed", b:current(), "tripped on a count, not on the ratio")

      -- Ten more failures make it 30 of 60: half. Trips.
      fail_n(b, dep, 10)
      assert.equal("open", b:current())
    end)

    it("does not judge a ratio over fewer than `minimum` calls", function()
      local b = breaker.new { threshold = 0.5, window = 60, minimum = 10 }
      local dep = dependency()
      fail_n(b, dep, 9)                     -- 100 % of nine
      assert.equal("closed", b:current())
      fail_n(b, dep, 1)                     -- 100 % of ten
      assert.equal("open", b:current())
    end)

    it("forgets failures older than the window", function()
      local b = breaker.new { threshold = 0.5, window = 60, minimum = 4 }
      local dep = dependency()
      fail_n(b, dep, 3)
      clock:advance(61)                     -- all three fall out of the window
      dep.answer = "ok"
      b:call(dep.call); b:call(dep.call); b:call(dep.call)
      fail_n(b, dep, 1)                     -- 1 of 4 in the window
      assert.equal("closed", b:current(), "failures outside the window were counted")
    end)

    it("interleaved failures a consecutive breaker would never see", function()
      local b = breaker.new { threshold = 0.5, window = 60, minimum = 10 }
      local dep = dependency()
      for _ = 1, 10 do
        dep.answer = "fail"; b:call(dep.call)
        dep.answer = "ok";   b:call(dep.call)
      end
      assert.equal("open", b:current())
    end)
  end)

  describe("what counts as a failure", function()
    it("is `nil, reason` by default, the adapter convention", function()
      local b = breaker.new { threshold = 1 }
      b:call(function() return nil, "not found" end)
      assert.equal("open", b:current())
    end)

    it("is whatever `is_failure` says", function()
      -- A lookup answering `nil, "not found"` is the dependency WORKING.
      local b = breaker.new {
        threshold = 1,
        is_failure = function(first, why)
          return first == nil and why ~= "not found"
        end,
      }
      b:call(function() return nil, "not found" end)
      assert.equal("closed", b:current())
      b:call(function() return nil, "connection refused" end)
      assert.equal("open", b:current())
    end)
  end)

  describe("operator controls and observation", function()
    it("trip() holds it open past the cooldown; reset() closes it", function()
      local b = breaker.new { threshold = 1, cooldown = 10 }
      b:trip()
      clock:advance(1000)
      assert.equal("open", b:current())
      b:reset()
      assert.equal("closed", b:current())
    end)

    it("reports a transition to on_change and survives it raising", function()
      local seen = {}
      local b = breaker.new {
        threshold = 1, cooldown = 10,
        on_change = function(_, from, to)
          seen[#seen + 1] = from .. ">" .. to
          error "observer bug"
        end,
      }
      b:call(function() return nil, "x" end)
      clock:advance(10)
      b:call(function() return true end)
      assert.same({ "closed>open", "open>half_open", "half_open>closed" }, seen)
    end)

    it("publishes state and trips through akkar.metrics, read at render", function()
      local registry = metrics.new()
      local b = registry:breaker("payments", breaker.new { threshold = 1, cooldown = 10 })
      local dep = dependency()

      local text = registry:render()
      assert.is_truthy(text:find('akkar_breaker_state{breaker="payments"} 0', 1, true))
      assert.is_truthy(text:find('akkar_breaker_trips_total{breaker="payments"} 0', 1, true))

      fail_n(b, dep, 1)
      b:call(dep.call)                      -- refused
      text = registry:render()
      assert.is_truthy(text:find('akkar_breaker_state{breaker="payments"} 2', 1, true), text)
      assert.is_truthy(text:find('akkar_breaker_trips_total{breaker="payments"} 1', 1, true))
      assert.is_truthy(text:find('akkar_breaker_refused_total{breaker="payments"} 1', 1, true))
      assert.is_truthy(text:find('akkar_breaker_calls_total{breaker="payments"} 1', 1, true))
      assert.is_truthy(text:find('akkar_breaker_failures_total{breaker="payments"} 1', 1, true))

      -- The registry READS at scrape time: nothing was pushed when the
      -- cooldown passed, and the state is still current.
      clock:advance(10)
      assert.is_truthy(registry:render():find('akkar_breaker_state{breaker="payments"} 1', 1, true))
    end)

    it("rejects a threshold that does not fit the policy", function()
      assert.has_error(function() breaker.new {} end)
      assert.has_error(function() breaker.new { threshold = 2.5 } end)
      assert.has_error(function() breaker.new { threshold = 5, window = 60 } end)
      assert.has_error(function() breaker.new { threshold = 1, cooldown = 0 } end)
    end)
  end)
end)

describe("akkar.http with a breaker", function()
  local cqueues = require "cqueues"
  local http = require "akkar.http"
  local clock, restore

  before_each(function()
    clock = time.manual { monotime = 1000 }
    restore = time.set(clock)
  end)
  after_each(function() restore() end)

  local function inside(fn)
    local err
    local cq = cqueues.new()
    cq:wrap(function()
      local ok, why = pcall(fn)
      if not ok then err = why end
    end)
    assert(cq:loop(20))
    if err then error(err, 0) end
  end

  --- Counts DIALS, not calls: `acquire` is where a connection is opened or
  --- taken from the pool, so it is the number a refusal must leave alone.
  local function counting(client)
    local dials = 0
    local original = client.acquire
    client.acquire = function(self, ...)
      dials = dials + 1
      return original(self, ...)
    end
    return function() return dials end
  end

  -- Port 9 has nothing on it, so every dial fails at connect.
  local DEAD = "http://127.0.0.1:9/never"

  it("stops dialling a dependency that is hard-down", function()
    inside(function()
      local client = http.connect { timeout = 1, breaker = { threshold = 2, cooldown = 30 } }()
      local dials = counting(client)

      local res, why = client:get(DEAD)
      assert.is_nil(res); assert.not_equal(breaker.OPEN, why)
      client:get(DEAD)
      assert.equal(2, dials())

      for _ = 1, 5 do
        res, why = client:get(DEAD)
        assert.is_nil(res)
        assert.equal(breaker.OPEN, why)
      end
      assert.equal(2, dials(), "an open breaker still dialled the dead host")

      local stats = client:stats().breakers["http://127.0.0.1:9"]
      assert.equal(2, stats.state)
      assert.equal(5, stats.refused)
    end)
  end)

  it("dials once as a probe after the cooldown, then refuses again", function()
    inside(function()
      local client = http.connect { timeout = 1, breaker = { threshold = 1, cooldown = 30 } }()
      local dials = counting(client)
      client:get(DEAD)
      assert.equal(1, dials())

      clock:advance(30)
      local _, why = client:get(DEAD)       -- the probe, which fails
      assert.equal(2, dials())
      assert.not_equal(breaker.OPEN, why)
      _, why = client:get(DEAD)
      assert.equal(breaker.OPEN, why)
      assert.equal(2, dials())
    end)
  end)

  it("does not back off or retry a refusal, so the budget is untouched", function()
    inside(function()
      local client = http.connect {
        timeout = 1, retries = 3, retry_backoff = 1,
        breaker = { threshold = 1, cooldown = 300 },
      }()
      local dials = counting(client)
      client:get(DEAD)                      -- one dial trips it (retries refused)
      assert.equal(1, dials())

      local before = clock.monotime()
      local _, why = client:get(DEAD)
      assert.equal(breaker.OPEN, why)
      assert.equal(1, dials())
      -- Under a manual clock a backoff would ADVANCE it; none did.
      assert.equal(before, clock.monotime(), "a refused call slept its backoff")
    end)
  end)

  it("keeps one origin's breaker away from another's", function()
    inside(function()
      local client = http.connect { timeout = 1, breaker = { threshold = 1, cooldown = 30 } }()
      local dials = counting(client)
      client:get(DEAD)
      local _, why = client:get "http://127.0.0.1:10/other"
      assert.not_equal(breaker.OPEN, why, "a dead host tripped its neighbour's breaker")
      assert.equal(2, dials())
    end)
  end)

  it("shares one breaker across origins when given an instance", function()
    inside(function()
      local shared = breaker.new { threshold = 1, cooldown = 30 }
      local client = http.connect { timeout = 1, breaker = shared }()
      local dials = counting(client)
      client:get(DEAD)
      local _, why = client:get "http://127.0.0.1:10/other"
      assert.equal(breaker.OPEN, why)
      assert.equal(1, dials())
      assert.equal("open", shared:current())
      assert.equal(2, client:stats().breakers["*"].state)
    end)
  end)
end)
