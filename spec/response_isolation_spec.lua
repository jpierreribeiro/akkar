--[[
One request must not be able to write on another one's response.

A handler is allowed to return a module-level constant. Nothing forbids it,
the "handlers return a value" thesis makes it look free, and it is the obvious
thing to write for /health:

    local UP = akkar.ok { status = "up" }
    app:get("/health", function() return UP end)

The framework then wrote `x-request-id` into that table on every request, and
so did every middleware decorating the response on the way out. The table is
shared, so the writes stayed on it forever. Reproduced with a real server and
separate TCP connections: after alice logged in, an anonymous probe received
`set-cookie: session=TOKEN-FOR-alice`.

Commit d1e5d45 fixed this class for `release` and left `headers`, which the
framework writes on EVERY request rather than on streamed ones.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

--- A middleware that decorates the response on the way out, which is what
--- session, CORS and cache-header middleware all are.
local function cookie_for_logged_in()
  return function(req, next)
    local res = next(req)
    local who = req.headers["x-login"]
    if who then
      res.headers = res.headers or {}
      res.headers["set-cookie"] = "session=TOKEN-FOR-" .. who
    end
    return res
  end
end

describe("a handler that returns a hoisted response", function()
  it("does not leak one client's set-cookie to the next", function()
    local UP = akkar.ok { status = "up" }
    local app = akkar.new()
    app:use(cookie_for_logged_in())
    app:get("/health", function() return UP end)

    local client = app:test()
    local alice = client:get("/health", { headers = { ["x-login"] = "alice" } })
    local anonymous = client:get "/health"

    assert.equal("session=TOKEN-FOR-alice", alice.headers["set-cookie"])
    assert.is_nil(anonymous.headers["set-cookie"])
  end)

  it("is never written to at all", function()
    -- The framework's own writes are the ones that happen on every request,
    -- so this is the assertion that holds even with no middleware installed.
    local UP = akkar.ok { status = "up" }
    local app = akkar.new()
    app:get("/health", function() return UP end)

    app:test():get "/health"
    assert.is_nil(UP.headers)
  end)

  it("gives each response its own headers table", function()
    -- Two responses held by one caller used to BE the same table, so the
    -- second request rewrote the first one's correlation id -- which is the
    -- same defect wearing the other consequence.
    local UP = akkar.ok { status = "up" }
    local app = akkar.new()
    app:get("/health", function() return UP end)

    local client = app:test()
    local first  = client:get "/health"
    local second = client:get "/health"

    assert.are_not.equal(first.headers, second.headers)
    assert.are_not.equal(first.headers["x-request-id"], second.headers["x-request-id"])
  end)

  it("holds for a middleware's own short-circuit too", function()
    -- An auth middleware that answers from a constant is the same
    -- optimisation, one layer up.
    local DENIED = akkar.unauthorized "no token"
    local app = akkar.new()
    app:use(function(req, next)
      if not req.headers["authorization"] then return DENIED end
      return next(req)
    end)
    app:get("/x", function() return { ok = true } end)

    local client = app:test()
    local first  = client:get "/x"
    local second = client:get "/x"

    assert.equal(401, first.status)
    assert.is_nil(DENIED.headers)
    assert.are_not.equal(first.headers["x-request-id"], second.headers["x-request-id"])
  end)

  it("holds for a route-scoped `before` middleware too", function()
    local UP = akkar.ok { status = "up" }
    local app = akkar.new()
    app:get("/health", { before = { cookie_for_logged_in() } },
            function() return UP end)

    local client = app:test()
    client:get("/health", { headers = { ["x-login"] = "alice" } })
    assert.is_nil(client:get("/health").headers["set-cookie"])
  end)

  it("holds for a response the app's on_error handler hoisted", function()
    local OOPS = akkar.response(500, { error = "internal server error" })
    local app = akkar.new()
    app:on_error(function() return OOPS end)
    app:get("/boom", function() error "nope" end)

    local client = app:test()
    local first  = client:get "/boom"
    local second = client:get "/boom"

    assert.equal(500, first.status)
    assert.is_nil(OOPS.headers)
    assert.are_not.equal(first.headers["x-request-id"], second.headers["x-request-id"])
  end)

  it("still lets middleware decorate the response it was given", function()
    -- The fix must not turn "middleware may add a header" into "middleware
    -- writes into a copy nobody sends".
    local UP = akkar.ok { status = "up" }
    local app = akkar.new()
    app:use(akkar.cors { origin = "https://example.test" })
    app:get("/health", function() return UP end)

    local res = app:test():get "/health"
    assert.equal("https://example.test", res.headers["access-control-allow-origin"])
    assert.equal("up", res.body.status)
    assert.is_nil(UP.headers)
  end)

  it("carries a hoisted response's own headers through", function()
    local CACHED = akkar.response(200, { ok = true }, { ["cache-control"] = "max-age=60" })
    local app = akkar.new()
    app:get("/x", function() return CACHED end)

    local res = app:test():get "/x"
    assert.equal("max-age=60", res.headers["cache-control"])
    assert.is_string(res.headers["x-request-id"])
    -- and the constant still says exactly what it said before the request
    assert.equal("max-age=60", CACHED.headers["cache-control"])
    assert.is_nil(CACHED.headers["x-request-id"])
  end)
end)

describe("middleware that forgets to return", function()
  -- `app:use(function(req, next) next(req) end)` -- the handler ran, its
  -- answer was discarded, and the client got an empty 204. Every signal an
  -- operator has said the request was fine.
  it("is a 500 naming the file and line, not a silent 204", function()
    local app = akkar.new()
    app:use(function(req, next) next(req) end)
    app:get("/x", function() return { ok = true } end)

    local res = app:test():get "/x"
    assert.equal(500, res.status)
    assert.equal("internal server error", res.body.error)
  end)

  it("says which middleware, through on_error", function()
    local seen
    local app = akkar.new()
    app:on_error(function(err) seen = tostring(err) end)
    app:use(function(req, next) next(req) end)
    app:get("/x", function() return { ok = true } end)

    app:test():get "/x"
    assert.is_truthy(seen:find("called next() and returned nothing", 1, true))
    assert.is_truthy(seen:find("response_isolation_spec.lua:", 1, true))
  end)

  it("catches a route-scoped `before` that forgets too", function()
    local app = akkar.new()
    app:get("/x", { before = { function(req, next) next(req) end } },
            function() return { ok = true } end)

    assert.equal(500, app:test():get("/x").status)
  end)

  it("still allows a middleware that answers 204 on purpose", function()
    -- Returning nothing WITHOUT calling next is a middleware deciding the
    -- answer, which is a different thing and stays legal.
    local app = akkar.new()
    app:use(function() return nil end)
    app:get("/x", function() return { ok = true } end)

    assert.equal(204, app:test():get("/x").status)
  end)
end)
