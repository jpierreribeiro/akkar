--[[
`app:on_error` — seeing why a 500 happened.

Three places produce a 500: a handler that raised, middleware that raised, and
a response that did not match its own schema. Each assembled the body itself
and dropped the cause on the floor. Middleware saw the 500 come back through
the chain, which is correct and deliberate, but nothing could see WHY — so
Sentry, an internal error code and RFC 7807 output had nowhere to attach.

The tests that matter are not the happy path. They are the two rules that stop
this hook becoming a way to break the server: a handler that returns nonsense,
and a handler that raises.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

describe("app:on_error", function()
  it("sees the error a handler raised, and the request", function()
    local seen = {}
    local app = akkar.new()
    app:on_error(function(err, req)
      seen.err, seen.path, seen.id = tostring(err), req.path, req.id
      return akkar.response(500, { instance = req.id })
    end)
    app:get("/boom", function() error "the cursor died" end)

    local res = app:test():get "/boom"
    assert.equal(500, res.status)
    assert.is_truthy(seen.err:find("the cursor died", 1, true))
    assert.equal("/boom", seen.path)
    assert.equal(seen.id, res.body.instance)
  end)

  it("sees an error raised by middleware", function()
    local seen
    local app = akkar.new()
    app:on_error(function(err) seen = tostring(err); return akkar.response(500, { seen = true }) end)
    app:use(function() error "middleware exploded" end)
    app:get("/", function() return {} end)

    assert.equal(500, app:test():get("/").status)
    assert.is_truthy(seen:find("middleware exploded", 1, true))
  end)

  it("sees a response that did not match its own schema", function()
    -- This one produced a 500 from a third place entirely, and the cause
    -- never left the function that found it.
    local seen
    local app = akkar.new()
    app:on_error(function(err) seen = tostring(err); return akkar.response(500, {}) end)
    app:get("/wrong", { response = { id = "integer" } },
      function() return { id = "not a number" } end)

    assert.equal(500, app:test():get("/wrong").status)
    assert.is_truthy(seen:find("does not match its schema", 1, true))
    assert.is_truthy(seen:find("id", 1, true))
  end)

  it("can answer with any status, not only 500", function()
    -- A team that maps a known exception to 409 should be able to.
    local app = akkar.new()
    app:on_error(function() return akkar.conflict "already settled" end)
    app:get("/", function() error "duplicate" end)

    local res = app:test():get "/"
    assert.equal(409, res.status)
    assert.equal("already settled", res.body.error)
  end)
end)

describe("what stops on_error breaking the server", function()
  it("falls back to the default 500 when the handler itself raises", function()
    -- A bug in the error handler must not crash the server through the exact
    -- path that exists to stop that happening.
    local app = akkar.new()
    app:on_error(function() error "the error handler is broken too" end)
    app:get("/", function() error "original" end)

    local res = app:test():get "/"
    assert.equal(500, res.status)
    assert.equal("internal server error", res.body.error)
  end)

  it("falls back when the handler returns something that is not a response", function()
    for _, nonsense in ipairs { "a string", 42, true } do
      local app = akkar.new()
      app:on_error(function() return nonsense end)
      app:get("/", function() error "original" end)

      local res = app:test():get "/"
      assert.equal(500, res.status)
      assert.equal("internal server error", res.body.error)
    end
  end)

  it("leaves the default bare when nothing is registered", function()
    -- A Lua error carries file paths, line numbers and sometimes SQL. The
    -- detail belongs in the log beside the request id, not in the response.
    local app = akkar.new()
    app:get("/", function() error "select * from secrets where id = 1" end)

    local res = app:test():get "/"
    assert.same({ error = "internal server error" }, res.body)
  end)

  it("does not intercept a response thrown on purpose", function()
    -- Response-as-error is not an error. A 404 raised from a deep layer must
    -- still be a 404, not something the error handler gets to rewrite.
    local seen = false
    local app = akkar.new()
    app:on_error(function() seen = true; return akkar.response(500, {}) end)
    app:get("/", function() error(akkar.not_found "no such thing") end)

    local res = app:test():get "/"
    assert.equal(404, res.status)
    assert.is_false(seen, "the error handler was called for a deliberate response")
  end)

  it("refuses anything that is not a function", function()
    local ok, err = pcall(function() akkar.new():on_error "not a function" end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "needs a function")
  end)
end)

describe("an error handler that declines", function()
  it("gets the default 500, not an empty 204", function()
    -- `normalize` turns nil into 204 everywhere else, which is right there
    -- and would be the worst possible answer here: an empty success for a
    -- request that failed.
    local app = akkar.new()
    app:on_error(function(err)
      if tostring(err):find("known", 1, true) then
        return akkar.conflict "known problem"
      end
      -- anything else: not mine
    end)

    app:get("/known", function() error "a known thing" end)
    app:get("/unknown", function() error "something else" end)

    local client = app:test()
    assert.equal(409, client:get("/known").status)

    local res = client:get "/unknown"
    assert.equal(500, res.status)
    assert.equal("internal server error", res.body.error)
  end)
end)
