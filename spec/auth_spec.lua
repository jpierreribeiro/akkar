--[[
akkar.auth — authentication through the real request path.

Not the functions in isolation: an app with the middleware installed, driven
through `app:test`, because what has to hold is what a caller observes. The
two assertions that matter most are that an unauthenticated request never
reaches a handler, and that a `Set-Cookie` is never written onto a table a
handler returned -- the aliasing defect `akkar/init.lua` documents, where the
stray header used to be a request id and here would be somebody's session.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local cache   = require "akkar.cache.memory"
local crypto  = require "akkar.crypto"

local SECRET = crypto.token(32)

describe("akkar.auth", function()
  describe("API keys", function()
    it("stores a hash and never the key", function()
      local key, hash = auth.generate_key "sk"
      assert.is_truthy(key:match "^sk_%x+$")
      assert.are_not.equal(key, hash)
      assert.is_true(auth.compare_key(key, hash))
      assert.is_false(auth.compare_key(key .. "x", hash))
      assert.is_false(auth.compare_key("", hash))
    end)

    it("carries a prefix a secret scanner can find", function()
      -- A key that looks like any other hex string is a key nobody can detect
      -- in a public repository.
      local key = auth.generate_key "myapp"
      assert.is_truthy(key:find("myapp_", 1, true))
    end)

    it("refuses non-strings rather than raising", function()
      assert.is_false(auth.compare_key(nil, "abc"))
      assert.is_false(auth.compare_key("abc", nil))
    end)
  end)

  describe("header extraction", function()
    local function req_with(headers) return { headers = headers } end

    it("accepts any casing of the bearer scheme", function()
      -- RFC 7235 says the scheme is case-insensitive and clients send all
      -- three. Rejecting them is a support ticket, not security.
      for _, scheme in ipairs { "Bearer", "bearer", "BEARER" } do
        assert.equal("abc123",
          auth.bearer(req_with { authorization = scheme .. " abc123" }))
      end
    end)

    it("ignores an Authorization header that is not bearer", function()
      assert.is_nil(auth.bearer(req_with { authorization = "Basic dXNlcjpwdw==" }))
      assert.is_nil(auth.bearer(req_with {}))
      assert.is_nil(auth.bearer(req_with { authorization = "Bearer" }))
    end)

    it("finds an api key in either place clients put it", function()
      assert.equal("k1", auth.api_key(req_with { ["x-api-key"] = "k1" }))
      assert.equal("k2", auth.api_key(req_with { authorization = "ApiKey k2" }))
      assert.is_nil(auth.api_key(req_with { authorization = "Bearer t" }))
    end)
  end)

  describe("middleware", function()
    local function app_with(options, handler)
      local app = akkar.new()
      app:use(auth.middleware(options))
      app:get("/me", handler or function(req)
        return { who = req.auth and req.auth.user_id or "nobody",
                 scheme = req.auth_scheme }
      end)
      return app
    end

    it("refuses an unauthenticated request BEFORE the handler runs", function()
      local reached = false
      local app = app_with({ bearer = function() return nil end },
                           function() reached = true return { ok = true } end)

      local res = app:test { cache = cache.factory() }:get "/me"
      assert.equal(401, res.status)
      assert.is_false(reached, "the handler ran for an unauthenticated request")
      -- The client is told what to send, which is why so many integrations
      -- otherwise guess.
      assert.is_truthy(res.headers["www-authenticate"])
    end)

    it("lets a valid bearer token through", function()
      local app = app_with { bearer = function(_, token)
        if token == "good" then return { user_id = 7 } end
      end }

      local client = app:test { cache = cache.factory() }
      assert.equal(401, client:get("/me", { headers = { authorization = "Bearer bad" } }).status)

      local ok = client:get("/me", { headers = { authorization = "Bearer good" } })
      assert.equal(200, ok.status)
      assert.equal(7, ok.body.who)
      assert.equal("bearer", ok.body.scheme)
    end)

    it("lets a valid api key through", function()
      local key, hash = auth.generate_key "sk"
      local app = app_with { keys = function(_, presented)
        if auth.compare_key(presented, hash) then return { user_id = 3 } end
      end }

      local client = app:test { cache = cache.factory() }
      assert.equal(401, client:get("/me", { headers = { ["x-api-key"] = "wrong" } }).status)
      assert.equal(3, client:get("/me", { headers = { ["x-api-key"] = key } }).body.who)
    end)

    it("lets an anonymous request through when it is optional", function()
      local app = app_with { optional = true, bearer = function() return nil end }
      local res = app:test { cache = cache.factory() }:get "/me"
      assert.equal(200, res.status)
      assert.equal("nobody", res.body.who)
    end)

    it("prefers the first scheme that produces a principal", function()
      -- A request carrying both is ambiguous, and picking deterministically
      -- beats merging.
      local app = app_with {
        bearer = function() return { user_id = "from-bearer" } end,
        keys   = function() return { user_id = "from-key" } end,
      }
      local res = app:test { cache = cache.factory() }:get("/me", {
        headers = { authorization = "Bearer t", ["x-api-key"] = "k" },
      })
      assert.equal("from-bearer", res.body.who)
    end)
  end)

  describe("sessions through the middleware", function()
    local function login_app()
      local manager = session.new { secret = SECRET, secure = false }
      local app = akkar.new()
      app:use(auth.middleware { sessions = manager, optional = true })
      app:post("/login", function(req)
        auth.login(req, 42)
        return { ok = true }
      end)
      app:get("/me", function(req)
        return { who = req.auth and req.auth.user_id or "nobody" }
      end)
      app:post("/logout", function(req)
        auth.logout(req)
        return { ok = true }
      end)
      return app, manager
    end

    it("logs in, stays logged in, and logs out", function()
      local app = login_app()
      -- ONE cache across requests, since the session lives there.
      local shared = cache.new()
      local client = app:test { cache = function() return shared end }

      assert.equal("nobody", client:get("/me").body.who)

      local login = client:post("/login", { body = {} })
      local set_cookie = login.headers["set-cookie"]
      assert.is_string(set_cookie, "logging in did not set a cookie")
      local jar = set_cookie:match "^([^;]+)"

      assert.equal(42, client:get("/me", { headers = { cookie = jar } }).body.who)

      client:post("/logout", { body = {}, headers = { cookie = jar } })
      assert.equal("nobody",
        client:get("/me", { headers = { cookie = jar } }).body.who,
        "the session survived logout, so it cannot be revoked")
    end)

    it("NEVER writes Set-Cookie onto the table a handler returned", function()
      -- The aliasing defect `akkar/init.lua` documents. A handler may return a
      -- hoisted or memoised table -- a constant, a cached payload -- and then
      -- one table is shared by every request that reaches it. As a request id
      -- that was confusing; as a Set-Cookie it is one user's session handed to
      -- another.
      local SHARED = { ok = true }          -- hoisted on purpose
      local manager = session.new { secret = SECRET, secure = false }
      local app = akkar.new()
      app:use(auth.middleware { sessions = manager, optional = true })
      app:post("/login", function(req)
        auth.login(req, 99)
        return SHARED
      end)

      local shared_cache = cache.new()
      local client = app:test { cache = function() return shared_cache end }
      local res = client:post("/login", { body = {} })

      assert.is_string(res.headers["set-cookie"])
      assert.is_nil(SHARED.headers,
        "the middleware wrote headers onto the handler's own table")
    end)

    it("rotates the session id on login", function()
      -- Session fixation. An attacker who planted a cookie before the login
      -- knows the id afterwards unless it changes at exactly this moment.
      local manager = session.new { secret = SECRET, secure = false }
      local app = akkar.new()
      local before_id, after_id
      app:use(auth.middleware { sessions = manager, optional = true })
      app:post("/login", function(req)
        before_id = req.session.id
        auth.login(req, 1)
        after_id = req.session.id
        return { ok = true }
      end)

      local shared = cache.new()
      app:test { cache = function() return shared end }:post("/login", { body = {} })
      assert.are_not.equal(before_id, after_id, "the session id was not rotated")
    end)

    it("does not set a cookie on a request that changed nothing", function()
      local app = login_app()
      local shared = cache.new()
      local res = app:test { cache = function() return shared end }:get "/me"
      assert.is_nil(res.headers and res.headers["set-cookie"],
        "a read reset the session expiry")
    end)
  end)
end)
