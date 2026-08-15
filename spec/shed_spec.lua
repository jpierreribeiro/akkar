--[[
akkar.limit.shed — the middleware that could never fire.

`M.shed` compares the app's in-flight count against a fraction of its
concurrency ceiling, and it read that ceiling from `app.max_concurrent`.
Nothing ever wrote `app.max_concurrent`: `App:run` computed the number into a
LOCAL and handed it to lua-http, so the field the shedder read was always nil,
the capacity was always nil, and the branch that sheds could not be reached.

An installed shedder that never sheds is worse than no shedder, because the
system is configured to survive a load it will in fact accept in full. It fails
exactly once, under exactly the load it was there for.

Two changes are pinned here. The ceiling is now published on the app, and a
shedder given nothing to measure against is refused at construction instead of
degrading into a middleware that returns `next(req)` forever.

No Redis: this limiter talks to no store. It reads two numbers off the app.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

--- The two fields `shed` reads, and nothing else, so the test states exactly
--- what the contract between the app and the shedder is.
local function app_at(in_flight, ceiling)
  return { in_flight = in_flight, max_concurrent = ceiling }
end

local function capturing()
  local lines = {}
  return akkar.log.new {
    level = "warn",
    format = "text",
    sink = function(line) lines[#lines + 1] = line end,
  }, lines
end

describe("the load shedder", function()
  it("refuses to be installed where it could never shed", function()
    -- Loud at boot, the way a duplicate route and an unknown run{} option
    -- already are.
    local ok, err = pcall(akkar.limit.shed, { ceiling = 0.8 })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("can never shed", 1, true),
      "the message must say what is wrong, not merely that something is: " ..
      tostring(err))
  end)

  it("accepts an app, because the app is what it measures", function()
    assert.has_no.errors(function()
      akkar.limit.shed { app = app_at(0, 100) }
    end)
    assert.has_no.errors(function()
      akkar.limit.shed { capacity = 100 }
    end)
  end)

  it("sheds once the in-flight count passes the ceiling", function()
    local app = akkar.new()
    app:use(akkar.limit.shed { app = app_at(81, 100) })   -- 81 > 0.8 * 100
    app:get("/report", function() return { ok = true } end)

    local res = app:test({}):get "/report"
    assert.equal(429, res.status)
    assert.equal("1", res.headers["retry-after"],
      "a 429 without Retry-After produces a client that hammers")
  end)

  it("serves while there is headroom", function()
    local app = akkar.new()
    app:use(akkar.limit.shed { app = app_at(79, 100) })   -- 79 < 0.8 * 100
    app:get("/report", function() return { ok = true } end)

    assert.equal(200, app:test({}):get("/report").status)
  end)

  it("never sheds work the application declared critical", function()
    -- The whole point of shedding by priority: the payment goes through while
    -- the report waits.
    local app = akkar.new()
    app:use(akkar.limit.shed {
      app = app_at(99, 100),
      critical = function(req) return req.path:match "^/payments" ~= nil end,
    })
    app:get("/payments/1", function() return { charged = true } end)
    app:get("/report", function() return { ok = true } end)

    local client = app:test {}
    assert.equal(200, client:get("/payments/1").status)
    assert.equal(429, client:get("/report").status)
  end)

  it("says so once when the platform gave it no ceiling to measure", function()
    -- `/proc/self/limits` is Linux only. On anything else the derived ceiling
    -- is nil, and a shedder that silently passes everything through is the
    -- defect this file exists for -- so it passes through and SAYS so.
    local log, lines = capturing()
    local app = akkar.new()
    app:use(akkar.limit.shed { app = { in_flight = 500 } })   -- no ceiling
    app:get("/report", function() return { ok = true } end)

    local client = app:test { log = log }
    assert.equal(200, client:get("/report").status)
    assert.equal(200, client:get("/report").status)

    local warnings = 0
    for _, line in ipairs(lines) do
      if line:find("no capacity", 1, true) then warnings = warnings + 1 end
    end
    assert.equal(1, warnings,
      "once, not per request -- per request would bury the log under the load")
  end)
end)
