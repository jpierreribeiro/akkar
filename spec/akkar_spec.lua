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

describe("HTTP conformance", function()
  local function app_with_routes()
    local app = akkar.new()
    app:get("/users",      function() return { list = true } end)
    app:post("/users",     function() return akkar.created { made = true } end)
    app:get("/users/:id",  function(req) return { id = req.params.id } end)
    return app
  end

  it("answers 405 with Allow when the path exists but the method does not", function()
    local res = app_with_routes():test():delete "/users"
    assert.equal(405, res.status)
    assert.equal("GET, POST", res.headers.allow)
    assert.same({ "GET", "POST" }, res.body.allowed)
  end)

  it("still answers 404 when the path itself is unknown", function()
    local res = app_with_routes():test():get "/nothing"
    assert.equal(404, res.status)
  end)

  it("serves HEAD from the GET handler", function()
    local res = app_with_routes():test():head "/users"
    assert.equal(200, res.status)
    -- No HEAD route was ever declared; the GET handler answered it.
  end)

  it("answers OPTIONS from the routing table, with no handler written", function()
    local res = app_with_routes():test():options "/users"
    assert.equal(204, res.status)
    assert.equal("GET, HEAD, OPTIONS, POST", res.headers.allow)
  end)

  it("treats a trailing slash as the same resource", function()
    local c = app_with_routes():test()
    assert.equal(200, c:get("/users").status)
    assert.equal(200, c:get("/users/").status)
    assert.equal(200, c:get("/users/2/").status)
  end)

  it("keeps the root path as /", function()
    local app = akkar.new()
    app:get("/", function() return { root = true } end)
    assert.equal(200, app:test():get("/").status)
  end)

  it("percent-decodes route parameters, as query strings already were", function()
    local app = akkar.new()
    app:get("/echo/:value", function(req) return { value = req.params.value } end)

    local c = app:test()
    assert.equal("a b",  c:get("/echo/a%20b").body.value)
    assert.equal("1",    c:get("/echo/%31").body.value)
    assert.equal("ç",    c:get("/echo/%C3%A7").body.value)
  end)

  it("hands handlers a plain lowercase header table from either path", function()
    local app = akkar.new()
    app:get("/h", function(req)
      return { auth = req.headers.authorization, ct = req.headers["content-type"] }
    end)

    -- Mixed case in, lowercase out -- no req.headers:get fallback needed.
    local res = app:test():get("/h", {
      headers = { Authorization = "Bearer x", ["Content-Type"] = "application/json" },
    })
    assert.equal("Bearer x", res.body.auth)
    assert.equal("application/json", res.body.ct)
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

  it("rejects an unknown route option instead of ignoring it", function()
    local app = akkar.new()
    local ok, err = pcall(function()
      app:post("/x", { bdy = { name = "string" } }, function() return {} end)
    end)
    assert.is_false(ok)
    -- Ignoring this would leave a route accepting anything while looking
    -- validated, which is worse than a loud failure at startup.
    assert.is_truthy(tostring(err):match "unknown POST /x option 'bdy'")
    assert.is_truthy(tostring(err):match "did you mean 'body'")
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

describe("connection pool", function()
  local cqueues = require "cqueues"
  local db_adapter = require "akkar.db"

  -- A pool over fake connections: the pool logic is what is under test, not
  -- Postgres.  `docs/substrate/RESULT.md` covers the real driver.
  local function fake_pool(size, on_open)
    local opened = 0
    local function open()
      opened = opened + 1
      if on_open then on_open(opened) end
      local conn = { id = opened, pg = true }
      function conn:close() self.pg = nil end
      function conn:release() if self.pool then self.pool:put(self) else self:close() end end
      return conn
    end
    local pool = db_adapter.Pool.new(open, size)
    return pool, function() return opened end
  end

  it("reuses a connection instead of opening a second one", function()
    local pool, opened = fake_pool(4)
    local a = pool:get()
    a:release()
    local b = pool:get()
    b:release()
    assert.equal(1, opened())
    assert.equal(a, b)
  end)

  it("opens up to the cap and no further", function()
    local pool, opened = fake_pool(3)
    local held = {}
    for i = 1, 3 do held[i] = pool:get() end
    assert.equal(3, opened())
    assert.equal(3, pool:stats().live)
    for _, c in ipairs(held) do c:release() end
    assert.equal(3, pool:stats().idle)
  end)

  -- This is where pool code is usually wrong.
  it("yields rather than blocking when exhausted, and resumes on release", function()
    local pool = fake_pool(1)
    local order = {}

    local cq = cqueues.new()
    cq:wrap(function()
      local conn = pool:get()
      order[#order + 1] = "first acquired"
      cqueues.sleep(0.10)              -- holds the only connection
      order[#order + 1] = "first releasing"
      conn:release()
    end)
    cq:wrap(function()
      cqueues.sleep(0.02)              -- arrives while the pool is empty
      order[#order + 1] = "second waiting"
      local conn = pool:get()
      order[#order + 1] = "second acquired"
      conn:release()
    end)
    -- Proof the wait did not block the loop: an unrelated coroutine runs
    -- while the second one is parked.
    cq:wrap(function()
      cqueues.sleep(0.05)
      order[#order + 1] = "unrelated ran"
    end)

    assert(cq:loop(5))
    assert.same({
      "first acquired", "second waiting", "unrelated ran",
      "first releasing", "second acquired",
    }, order)
  end)

  it("does not leak a slot when opening fails", function()
    local attempts = 0
    local pool = db_adapter.Pool.new(function()
      attempts = attempts + 1
      error("connection refused", 0)
    end, 2)

    for _ = 1, 5 do
      local ok = pcall(function() return pool:get() end)
      assert.is_false(ok)
    end
    assert.equal(5, attempts)               -- kept trying, never wedged
    assert.equal(0, pool:stats().live)      -- and never leaked a slot
  end)

  it("discards a connection left inside a transaction", function()
    local pool, opened = fake_pool(2)
    local conn = pool:get()
    conn.in_transaction = true              -- rollback failed
    conn:release()

    assert.equal(0, pool:stats().idle)      -- not put back
    assert.equal(0, pool:stats().live)      -- slot returned
    pool:get()
    assert.equal(2, opened())               -- a fresh one was opened
  end)

  it("releases the connection even when the handler raises", function()
    local pool = fake_pool(1)
    local app = akkar.new()
    app:get("/boom", function() error "handler exploded" end)
    app:get("/ok", function() return { ok = true } end)

    local factory = setmetatable({}, { __call = function() return pool:get() end })
    local c = app:test { db = factory }

    assert.equal(500, c:get("/boom").status)
    assert.equal(0, pool:stats().live - #pool.idle)   -- nothing still checked out
    assert.equal(200, c:get("/ok").status)            -- pool of 1 still usable
  end)

  it("pool_size = 0 opts out and opens per request", function()
    local factory = db_adapter.connect { pool_size = 0, database = "x" }
    assert.equal("function", type(factory))           -- no pool attached
  end)
end)

describe("graceful shutdown", function()
  local cqueues = require "cqueues"

  -- App:stop drives a state machine; these exercise it without a socket by
  -- standing in a fake server.  The socket path is covered by hand against a
  -- real server, since that is where lua-http behaviour actually lives.
  local function stoppable(in_flight)
    local app = akkar.new()
    app.state, app.in_flight, app.closers = "RUNNING", in_flight or 0, {}
    app.server = { pause = function() end, close = function() end }
    return app
  end

  it("runs the sequence to STOPPED when nothing is in flight", function()
    local app = stoppable(0)
    assert.equal("STOPPED", app:stop(1))
  end)

  it("is idempotent -- a second stop is not a second teardown", function()
    local app = stoppable(0)
    local closed = 0
    app.closers = { function() closed = closed + 1 end }
    app:stop(1)
    app:stop(1)
    assert.equal(1, closed)
  end)

  it("closes pools during CLOSING, after the drain, never before", function()
    local app = stoppable(1)
    local order = {}
    app.closers = { function() order[#order + 1] = "pool closed" end }

    local cq = cqueues.new()
    cq:wrap(function()
      cqueues.sleep(0.10)
      order[#order + 1] = "request finished"
      app.in_flight = 0
    end)
    cq:wrap(function() app:stop(1) end)
    assert(cq:loop(5))

    assert.same({ "request finished", "pool closed" }, order)
    assert.equal("STOPPED", app.state)
  end)

  -- The rule that matters more than the diagram.
  it("waits past the grace period rather than forcing a request to end", function()
    local app = stoppable(1)
    local finished = false

    local cq = cqueues.new()
    cq:wrap(function()
      cqueues.sleep(0.40)          -- far longer than the grace below
      finished = true
      app.in_flight = 0
    end)

    local took
    cq:wrap(function()
      local t = cqueues.monotime()
      app:stop(0.05)               -- grace expires almost immediately
      took = cqueues.monotime() - t
    end)
    assert(cq:loop(5))

    assert.is_true(finished)       -- the request was never truncated
    assert.is_true(took > 0.3)     -- stop kept waiting, it did not force
    assert.equal("STOPPED", app.state)
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

describe("OpenAPI generation", function()
  local openapi = require "akkar.openapi"
  local v = akkar.v

  local function sample()
    local app = akkar.new()
    app:get("/users", {
      query = { limit = v.integer { optional = true, min = 1, max = 100, default = 20 } },
    }, function() return {} end)
    app:post("/users", {
      body = { name = v.string { min = 1, max = 100 }, email = "string?" },
      response = { id = "integer", name = "string" },
    }, function() return {} end)
    app:get("/users/:id", { params = { id = v.integer { min = 1 } } }, function() return {} end)
    app:delete("/raw/:key", function() return nil end)   -- no schema at all

    local health = akkar.new()
    health:get("/live", function() return {} end)
    app:mount("/health", health)
    return app
  end

  it("turns :id into an OpenAPI path template", function()
    local doc = openapi.document(sample())
    assert.is_truthy(doc.paths["/users/{id}"])
    assert.is_nil(doc.paths["/users/:id"])
  end)

  it("reuses the validation schema rather than asking for it twice", function()
    local doc = openapi.document(sample())
    local body = doc.paths["/users"].post.requestBody
      .content["application/json"].schema

    assert.equal("object", body.type)
    assert.equal("string", body.properties.name.type)
    assert.equal(1,   body.properties.name.minLength)
    assert.equal(100, body.properties.name.maxLength)
    assert.same({ "name" }, body.required)          -- email was optional
  end)

  it("carries query constraints and defaults across", function()
    local doc = openapi.document(sample())
    local params = doc.paths["/users"].get.parameters
    assert.equal("limit", params[1].name)
    assert.equal("query", params[1]["in"])
    assert.is_false(params[1].required)
    assert.equal(1,   params[1].schema.minimum)
    assert.equal(100, params[1].schema.maximum)
    assert.equal(20,  params[1].schema.default)
  end)

  it("declares a path parameter even when the route has no schema", function()
    local doc = openapi.document(sample())
    local params = doc.paths["/raw/{key}"].delete.parameters
    assert.equal("key", params[1].name)
    assert.is_true(params[1].required)
  end)

  it("documents a mounted sub-app at the prefix it answers on", function()
    local doc = openapi.document(sample())
    assert.is_truthy(doc.paths["/health/live"])
    assert.is_truthy(doc.paths["/health/live"].get)
  end)

  it("documents the statuses akkar produces on its own", function()
    local doc = openapi.document(sample())
    assert.is_truthy(doc.paths["/users"].post.responses["422"])   -- has a schema
    assert.is_truthy(doc.paths["/users"].post.responses["500"])
    assert.is_nil(doc.paths["/health/live"].get.responses["422"]) -- has none
  end)

  it("describes the response body when one is declared", function()
    local doc = openapi.document(sample())
    local schema = doc.paths["/users"].post.responses["200"]
      .content["application/json"].schema
    assert.equal("integer", schema.properties.id.type)
  end)

  it("serves the document over HTTP with no handler written", function()
    local app = sample()
    openapi.serve(app, "/openapi.json", { title = "Test API", version = "1.2.3" })

    local res = app:test():get "/openapi.json"
    assert.equal(200, res.status)
    assert.equal("3.1.0", res.body.openapi)
    assert.equal("Test API", res.body.info.title)
    assert.equal("1.2.3", res.body.info.version)
    assert.is_truthy(res.body.paths["/users/{id}"])
  end)
end)

describe("request bodies beyond JSON", function()
  it("accepts form-urlencoded, because an HTML form cannot send JSON", function()
    local app = akkar.new()
    app:post("/f", { body = { name = "string" } }, function(req)
      return { name = req.body.name }
    end)

    local res = app:test():post("/f", {
      body = { name = "ada" },
      headers = { ["content-type"] = "application/x-www-form-urlencoded" },
    })
    assert.equal(200, res.status)
  end)

  it("tolerates a charset parameter on the content type", function()
    local app = akkar.new()
    app:post("/j", { body = { name = "string" } }, function(req)
      return { name = req.body.name }
    end)
    local res = app:test():post("/j", {
      body = { name = "ada" },
      headers = { ["content-type"] = "application/json; charset=utf-8" },
    })
    assert.equal(200, res.status)
  end)
end)

describe("CORS", function()
  it("advertises the router's real Allow list on a preflight", function()
    local app = akkar.new()
    app:use(akkar.cors { origin = "https://example.com" })
    app:get("/users",  function() return {} end)
    app:post("/users", function() return {} end)

    local res = app:test():options "/users"
    -- The browser is told what the router accepts, not a hardcoded guess.
    assert.equal(res.headers.allow, res.headers["access-control-allow-methods"])
    assert.equal("https://example.com", res.headers["access-control-allow-origin"])
    assert.is_truthy(res.headers["access-control-max-age"])
  end)

  it("adds the origin header to ordinary responses too", function()
    local app = akkar.new()
    app:use(akkar.cors())
    app:get("/x", function() return { ok = true } end)

    local res = app:test():get "/x"
    assert.equal(200, res.status)
    assert.equal("*", res.headers["access-control-allow-origin"])
  end)
end)

describe("JSON null handling", function()
  -- cjson represents null with a sentinel userdata, not nil.  Left alone it
  -- leaks into user code; these pin that it does not.
  local app_with_optional = function()
    local app = akkar.new()
    app:post("/u", {
      body = { name = "string", email = "string?" },
    }, function(req) return { name = req.body.name, email = req.body.email } end)
    return app
  end

  it("treats an explicit null on an optional field as absent", function()
    local app = app_with_optional()
    -- A client sending {"email": null} used to get 422 "expected string".
    local res = app:test():post("/u", { body = { name = "ada", email = akkar.null } })
    assert.equal(200, res.status)
    assert.equal("ada", res.body.name)
    assert.is_nil(res.body.email)
  end)

  it("rejects a scalar body instead of failing inside validation", function()
    local app = app_with_optional()
    local res = app:test():post("/u", { body = 42 })
    assert.equal(400, res.status)
    assert.is_truthy(res.body.error:match "JSON object")
  end)

  it("treats a null body as no body at all", function()
    local app = app_with_optional()
    -- Used to reach the validator as userdata and become a 500.
    local res = app:test():post("/u", { body = akkar.null })
    assert.equal(422, res.status)
    assert.equal("required", res.body.fields["body.name"])
  end)
end)
