--[[
Tests driven through the in-process client.

No socket, no port, no server, no Postgres — but travelling exactly the same
middleware, validation and dispatch chain a real request does, because
`handle` is shared between both paths.

That is what injecting `req.db` buys: the test hands over a fake database.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local v     = akkar.v

-- A fake database.  Not a library mock: a table with four methods, because
-- the adapter surface is deliberately small.
local function fake_db(rows)
  local db = {}
  function db:one(sql)
    if sql:match "count" then return { n = #rows } end
    return rows[1]
  end
  function db:many() return rows end
  function db:exec() return true end
  function db:transaction(fn) return fn(self) end
  return function() return db end
end

describe("in-process test client", function()

  it("answers rung 0 with no database at all", function()
    local app = akkar.new()
    app:get("/", function() return { hello = "world" } end)

    local res = app:test():get "/"
    assert.equal(200, res.status)
    assert.equal("world", res.body.hello)
  end)

  it("validates before the handler is reached", function()
    local app = akkar.new()
    local called = false
    app:post("/users", { body = { name = "string" } }, function()
      called = true
      return { ok = true }
    end)

    local res = app:test():post("/users", { body = { email = "x@y.z" } })
    assert.equal(422, res.status)
    assert.equal("required", res.body.fields["body.name"])
    assert.is_false(called)          -- the handler never ran
  end)

  it("coerces query values and applies defaults", function()
    local app = akkar.new()
    app:get("/x", {
      query = { limit = v.integer { optional = true, min = 1, max = 100, default = 20 } },
    }, function(req) return { limit = req.query.limit } end)

    local c = app:test()
    assert.equal(20,  c:get("/x").body.limit)              -- default
    assert.equal(5,   c:get("/x?limit=5").body.limit)      -- string -> number
    assert.equal(422, c:get("/x?limit=0").status)          -- below the minimum
  end)

  it("turns a response thrown from a deep layer into a status", function()
    local app = akkar.new()
    local function service() error(akkar.not_found "does not exist") end
    app:get("/y", function() return service() end)

    local res = app:test():get "/y"
    assert.equal(404, res.status)
    assert.equal("does not exist", res.body.error)
  end)

  it("turns a real error into a 500 without leaking details", function()
    local app = akkar.new()
    app:get("/boom", function() error "password=hunter2 in the traceback" end)

    local res = app:test():get "/boom"
    assert.equal(500, res.status)
    assert.equal("internal server error", res.body.error)
    assert.is_nil(res.body.detail)
    assert.is_nil(res.body.traceback)
  end)

  it("lets middleware see every status, including early failures", function()
    local app = akkar.new()
    local seen = {}
    app:use(function(req, next)
      local res = next(req)
      seen[#seen + 1] = res.status
      return res
    end)
    app:get("/ok", function() return { a = 1 } end)
    app:post("/v", { body = { name = "string" } }, function() return { a = 1 } end)

    local c = app:test()
    c:get "/ok"
    c:post("/v", { body = {} })
    c:get "/no-such-route"

    assert.same({ 200, 422, 404 }, seen)
  end)

  it("runs against a fake database, with no Postgres", function()
    local app = akkar.new()
    app:get("/users", function(req) return { users = req.db:many() } end)

    local rows = { { id = 1, name = "ada" }, { id = 2, name = "alan" } }
    local res = app:test({ db = fake_db(rows) }):get "/users"
    assert.equal(200, res.status)
    assert.equal(2, #res.body.users)
    assert.equal("ada", res.body.users[1].name)
  end)

  it("keeps a sub-app testable on its own, unaware of its prefix", function()
    local health = akkar.new()
    health:get("/live", function() return { status = "live" } end)

    -- standalone
    assert.equal("live", health:test():get("/live").body.status)

    -- and mounted
    local app = akkar.new()
    app:mount("/health", health)
    assert.equal("live", app:test():get("/health/live").body.status)
  end)

  it("explains a missing req.user in the log and returns 500", function()
    local app = akkar.new()
    app:get("/me", function(req) return { n = req.user.name } end)
    assert.equal(500, app:test():get("/me").status)
  end)

  it("rejects a duplicate route at startup, not at request time", function()
    local app = akkar.new()
    app:get("/dup", function() return {} end)
    local ok, err = pcall(function()
      app:get("/dup", function() return {} end)
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "duplicate route")
  end)

  it("gives a clear error when a handler returns an invalid value", function()
    local app = akkar.new()
    app:get("/s", function() return "a string" end)
    assert.equal(500, app:test():get("/s").status)
  end)

  it("turns nil into 204 with no body", function()
    local app = akkar.new()
    app:delete("/z", function() return nil end)
    local res = app:test():delete "/z"
    assert.equal(204, res.status)
    assert.is_nil(res.body)
  end)
end)

describe("the capability boundary", function()

  it("guards every unconfigured capability, not just db", function()
    local app = akkar.new()
    app:get("/db",    function(req) return { x = req.db.anything } end)
    app:get("/cache", function(req) return { x = req.cache.anything } end)
    app:get("/log",   function(req) return { x = req.log.anything } end)
    app:get("/clock", function(req) return { x = req.clock.anything } end)

    local c = app:test()
    for _, path in ipairs { "/db", "/cache", "/log", "/clock" } do
      assert.equal(500, c:get(path).status)
    end
  end)

  it("injects a capability given as a plain value", function()
    local app = akkar.new()
    app:get("/now", function(req) return { now = req.clock.now() } end)

    local res = app:test({ clock = { now = function() return 1755000000 end } }):get "/now"
    assert.equal(200, res.status)
    assert.equal(1755000000, res.body.now)
  end)

  it("calls a capability given as a function once per request", function()
    local app = akkar.new()
    app:get("/n", function(req) return { n = req.db.n } end)

    local calls = 0
    local factory = function() calls = calls + 1 return { n = calls } end
    local c = app:test { db = factory }

    assert.equal(1, c:get("/n").body.n)
    assert.equal(2, c:get("/n").body.n)
    assert.equal(2, calls)          -- one acquisition per request, not shared
  end)

  -- The closed set is what stops `req` from decaying into a service locator.
  it("rejects an unknown option and suggests the nearest one", function()
    local app = akkar.new()

    local ok, err = pcall(function() app:test { timout = 5 } end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "unknown app:test{} option 'timout'")
    assert.is_truthy(tostring(err):match "did you mean 'timeout'")
  end)

  it("refuses an application concern as a capability", function()
    local app = akkar.new()

    -- A mailer is the application's business, not infrastructure the framework
    -- knows how to guard and fake.  Handlers close over it instead.
    local ok, err = pcall(function() app:test { mailer = {} } end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "unknown app:test{} option 'mailer'")
  end)
end)

describe("request deadline", function()
  local cqueues = require "cqueues"

  -- The deadline needs a controller to yield to, so these run inside one.
  local function in_controller(fn)
    local cq = cqueues.new()
    local result, failure
    cq:wrap(function()
      local ok, res = pcall(fn)
      if ok then result = res else failure = res end
    end)
    assert(cq:loop(10))
    if failure then error(failure, 0) end
    return result
  end

  it("stops a handler that overruns its budget", function()
    local app = akkar.new()
    app:get("/slow", function() cqueues.sleep(2) return { done = true } end)

    local res = in_controller(function()
      return app:test():get("/slow", { timeout = 0.15 })
    end)
    assert.equal(503, res.status)
    assert.equal("request deadline exceeded", res.body.error)
  end)

  it("lets a handler inside its budget through untouched", function()
    local app = akkar.new()
    app:get("/quick", function() cqueues.sleep(0.02) return { done = true } end)

    local res = in_controller(function()
      return app:test():get("/quick", { timeout = 1.0 })
    end)
    assert.equal(200, res.status)
    assert.is_true(res.body.done)
  end)

  -- SM-WAIT arbitration: the winner is decided by the first arbitrating event
  -- and a late one never overturns it.  Reporting a finished handler as a
  -- timeout would discard work that actually happened.
  it("never reports a completed handler as a timeout", function()
    local app = akkar.new()
    app:get("/edge", function() cqueues.sleep(0.05) return { done = true } end)

    for _ = 1, 25 do
      local res = in_controller(function()
        return app:test():get("/edge", { timeout = 0.055 })
      end)
      -- Either outcome is legal at the boundary.  What is illegal is a 503
      -- carrying a body the handler produced, or a 200 with no body.
      if res.status == 200 then
        assert.is_true(res.body.done)
      else
        assert.equal(503, res.status)
        assert.equal("request deadline exceeded", res.body.error)
      end
    end
  end)

  it("does not convert a handler error into a timeout", function()
    local app = akkar.new()
    app:get("/boom", function() error "handler exploded" end)

    local res = in_controller(function()
      return app:test():get("/boom", { timeout = 1.0 })
    end)
    assert.equal(500, res.status)
  end)

  it("one slow request does not stall another", function()
    local app = akkar.new()
    app:get("/slow", function() cqueues.sleep(0.30) return { which = "slow" } end)
    app:get("/fast", function() return { which = "fast" } end)

    local order = {}
    local cq = cqueues.new()
    cq:wrap(function()
      app:test():get("/slow", { timeout = 5 })
      order[#order + 1] = "slow"
    end)
    cq:wrap(function()
      cqueues.sleep(0.05)
      app:test():get("/fast", { timeout = 5 })
      order[#order + 1] = "fast"
    end)
    assert(cq:loop(10))

    assert.same({ "fast", "slow" }, order)
  end)
end)
