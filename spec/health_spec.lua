--[[
Liveness and readiness.

The property this file exists to pin is a NEGATIVE one: liveness must not
reach a dependency. It is a negative property, so it cannot be observed by
looking at what `live()` returns -- a probe that quietly opened a connection
and threw the result away would return exactly the same table. It is observed
by giving the probe a check that records having been called, and asserting the
recording never happened.

Everything else here is ordinary: the protocol a check speaks, the timeout,
and the cache that stops a probe every second becoming a query every second.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local health  = require "akkar.health"
local time    = require "akkar.time"
local cqueues = require "cqueues"

describe("liveness does not touch dependencies", function()
  it("never calls a check", function()
    -- The check sets a flag instead of returning one, so what is asserted is
    -- that it was not RUN -- not that its answer was ignored.  A liveness
    -- probe that ran the check and discarded the result would still have
    -- taken the pool slot, which is the whole failure.
    local touched = false
    local probe = health.new {
      checks = {
        db = function() touched = true; return true end,
      },
    }

    local result = probe:live()

    assert.is_false(touched,
      "live() ran a check that touches a dependency; one slow database now " ..
      "fails liveness on every instance at once and the orchestrator kills " ..
      "the whole deployment")
    assert.equal("pass", result.status)
  end)

  it("reports no checks at all, rather than checks that passed", function()
    local probe = health.new { checks = { db = function() return true end } }
    assert.same({}, probe:live().checks)
  end)

  it("still answers when every check would fail", function()
    -- The moment this matters: the database is down.  Readiness must say so,
    -- so the instance leaves the load balancer.  Liveness must NOT, or the
    -- instance is restarted -- and a restart cannot fix somebody else's
    -- database, it only adds a reconnect storm to it.
    local probe = health.new {
      checks = { db = function() error "connection refused" end },
    }
    assert.equal("pass", probe:live().status)
    assert.equal("fail", probe:ready().status)
  end)

  it("runs the check on ready(), so the flag test above proves something", function()
    -- Without this, the assertion in the first test would also pass against a
    -- module that never called any check at all.
    local touched = false
    local probe = health.new { checks = { db = function() touched = true; return true end } }
    probe:ready()
    assert.is_true(touched)
  end)
end)

describe("liveness uptime", function()
  it("moves with the clock and needs no sleep to prove it", function()
    local clock = time.manual { monotime = 100 }
    local restore = time.set(clock)
    local probe = health.new {}
    assert.equal(0, probe:live().uptime)
    clock:advance(42)
    assert.equal(42, probe:live().uptime)
    restore()
  end)
end)

describe("the check protocol", function()
  local function ready_with(checks)
    return health.new { checks = checks, cache = 0 }:ready()
  end

  it("passes on true", function()
    assert.equal("pass", ready_with { db = function() return true end }.checks.db.status)
  end)

  it("fails on false with a reason", function()
    local result = ready_with { db = function() return false, "too many clients" end }
    assert.equal("fail", result.checks.db.status)
    assert.equal("too many clients", result.checks.db.reason)
    assert.equal("fail", result.status)
  end)

  it("fails on nil plus a reason", function()
    local result = ready_with { db = function() return nil, "no route to host" end }
    assert.equal("fail", result.checks.db.status)
    assert.equal("no route to host", result.checks.db.reason)
  end)

  it("turns a raised error into a failed check, not a failed probe", function()
    -- A readiness endpoint that 500s tells the orchestrator that the instance
    -- is unready and nothing about which dependency is unhappy, which is the
    -- one fact anyone reads it for.
    local result = ready_with { db = function() error("connection refused", 0) end }
    assert.equal("fail", result.checks.db.status)
    assert.is_truthy(result.checks.db.reason:find("connection refused", 1, true))
  end)

  it("keeps only the first line of an error, not the traceback", function()
    local result = ready_with { db = function() error("boom\nstack\nmore", 0) end }
    assert.equal("boom", result.checks.db.reason)
  end)

  it("runs every check even after one has failed", function()
    -- Short-circuiting reports the alphabetically first broken dependency and
    -- stays silent about the rest, and during an incident the rest is the
    -- question being asked.
    local ran = {}
    local result = ready_with {
      a = function() ran.a = true; return false, "down" end,
      b = function() ran.b = true; return false, "also down" end,
      c = function() ran.c = true; return true end,
    }
    assert.same({ a = true, b = true, c = true }, ran)
    assert.equal("fail", result.checks.a.status)
    assert.equal("fail", result.checks.b.status)
    assert.equal("pass", result.checks.c.status)
  end)

  it("passes with no checks configured", function()
    assert.equal("pass", health.new{}:ready().status)
  end)
end)

describe("per-check timeout", function()
  it("fails a check that does not return, and says so", function()
    -- The usual failure of a dependency check is not "returned false", it is
    -- "did not return".  Without a per-check deadline the probe itself hangs,
    -- and a probe that hangs is read by the orchestrator as a timeout with no
    -- information in it.
    local probe = health.new {
      checks = { slow = function() cqueues.sleep(5); return true end },
      timeout = 0.05,
      cache = 0,
    }
    local began = cqueues.monotime()
    local result = probe:ready()
    local elapsed = cqueues.monotime() - began

    assert.equal("fail", result.checks.slow.status)
    assert.is_true(result.checks.slow.timed_out)
    assert.is_truthy(result.checks.slow.reason:find("timed out", 1, true))
    assert.is_true(elapsed < 1,
      ("the probe waited %.2fs for a check with a 0.05s timeout"):format(elapsed))
  end)

  it("does not fail a check that returns inside its budget", function()
    local probe = health.new {
      checks = { quick = function() cqueues.sleep(0.01); return true end },
      timeout = 1,
      cache = 0,
    }
    local result = probe:ready()
    assert.equal("pass", result.checks.quick.status)
    assert.is_nil(result.checks.quick.timed_out)
  end)

  it("times out one check without failing the others", function()
    local probe = health.new {
      checks = {
        slow = function() cqueues.sleep(5); return true end,
        fast = function() return true end,
      },
      timeout = 0.05,
      cache = 0,
    }
    local result = probe:ready()
    assert.equal("fail", result.checks.slow.status)
    assert.equal("pass", result.checks.fast.status)
  end)
end)

describe("the readiness cache", function()
  it("does not turn a probe every second into a query every second", function()
    local calls = 0
    local probe = health.new {
      checks = { db = function() calls = calls + 1; return true end },
      cache = 5,
    }
    for _ = 1, 10 do probe:ready() end
    assert.equal(1, calls,
      "ten probes ran the check " .. calls .. " times; under twenty " ..
      "instances that is twenty queries a second nobody asked for")
  end)

  it("says when an answer came from the cache", function()
    local probe = health.new { checks = { db = function() return true end }, cache = 5 }
    assert.is_false(probe:ready().cached)
    assert.is_true(probe:ready().cached)
  end)

  it("expires, proved with a manual clock rather than a sleep", function()
    local clock = time.manual { monotime = 0 }
    local restore = time.set(clock)

    local calls = 0
    local probe = health.new {
      checks = { db = function() calls = calls + 1; return true end },
      cache = 5,
    }
    probe:ready()
    clock:advance(4.9)
    probe:ready()
    assert.equal(1, calls)
    clock:advance(0.2)          -- 5.1s in total, past the ttl
    probe:ready()
    assert.equal(2, calls)

    restore()
  end)

  it("caches failures too", function()
    -- Caching only the successes means a dependency that is down is probed on
    -- every request to /health/ready -- load added to the failing thing, by
    -- the endpoint reporting that it is failing.
    local calls = 0
    local probe = health.new {
      checks = { db = function() calls = calls + 1; return false, "down" end },
      cache = 5,
    }
    probe:ready(); probe:ready(); probe:ready()
    assert.equal(1, calls)
  end)

  it("bypasses the cache when asked, and when invalidated", function()
    local calls = 0
    local probe = health.new {
      checks = { db = function() calls = calls + 1; return true end },
      cache = 60,
    }
    probe:ready()
    probe:ready { fresh = true }
    assert.equal(2, calls)
    probe:invalidate()
    probe:ready()
    assert.equal(3, calls)
  end)

  it("does not let a caller writing into the result poison the next read", function()
    local probe = health.new { checks = { db = function() return true end }, cache = 60 }
    local first = probe:ready()
    first.status = "fail"                 -- a handler decorating the envelope
    assert.equal("pass", probe:ready().status)
  end)

  it("cache = 0 asks every time", function()
    local calls = 0
    local probe = health.new {
      checks = { db = function() calls = calls + 1; return true end },
      cache = 0,
    }
    probe:ready(); probe:ready()
    assert.equal(2, calls)
  end)
end)

describe("construction refuses what it cannot honour", function()
  it("names an unknown option", function()
    local ok, err = pcall(health.new, { timout = 1 })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("timout", 1, true))
  end)

  it("refuses a check that is not a function", function()
    local ok, err = pcall(health.new, { checks = { db = "select 1" } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("db", 1, true))
  end)
end)

describe("health returns a value, and never writes a response", function()
  it("is a plain table a handler can return", function()
    -- akkar handlers return; they do not mutate a response.  Health is not an
    -- exception, so the whole module is testable without a server -- and the
    -- result serialises, which is the only thing an endpoint needs of it.
    local probe = health.new {
      checks = { db = function() return true end },
      cache = 0,
    }
    local app = akkar.new()
    app:get("/health/live",  function() return probe:live() end)
    app:get("/health/ready", function() return probe:ready() end)

    local client = app:test()
    local live = client:get "/health/live"
    assert.equal(200, live.status)
    assert.equal("pass", live.body.status)

    local ready = client:get "/health/ready"
    assert.equal(200, ready.status)
    assert.equal("pass", ready.body.status)
    assert.equal("pass", ready.body.checks.db.status)
  end)

  it("lets the caller decide the status code, because the module does not", function()
    local probe = health.new {
      checks = { db = function() return false, "down" end },
      cache = 0,
    }
    local app = akkar.new()
    app:get("/health/ready", function()
      local result = probe:ready()
      -- `akkar.unavailable` wraps its argument in `{ error = ... }`; the
      -- checks table is the body here, not an error message inside one.
      if result.status == "fail" then error(akkar.response(503, result)) end
      return result
    end)

    local res = app:test():get "/health/ready"
    assert.equal(503, res.status)
    assert.equal("fail", res.body.checks.db.status)
  end)
end)
