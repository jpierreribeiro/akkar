--[[
akkar.csrf — the two properties that make it worth having, and the one that
makes it survivable.

**It refuses a forged cookie-authenticated write.** That is the point.

**It does not apply to a bearer token or an API key.** That is what keeps it
from breaking every script on the day it is switched on, and it is not a
convenience: an attacker's page cannot make a victim's `curl` add a header, so
there is no ambient credential to ride on and nothing for a token to buy.

**A planted cookie does not help the attacker.** This is the test that
separates this from double-submit as it is usually shipped. Cookies are not
origin-scoped, so anybody who controls a subdomain can set one on the parent
domain -- and then a plain "does the cookie equal the header" check passes,
because the attacker chose both values. The HMAC binding is what closes it, and
the test below plants an attacker's own valid token into a victim's session and
requires a 403.

The refusals are real responses. `akkar/auth.lua` records what happens
otherwise: a bare `{ status = 401, ... }` looks exactly like a response, is not
one, and becomes a **200 whose body is the word "401"** -- so an integration
testing `if res.status == 200` treats a refused request as an accepted one.
Every assertion here checks the status.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local csrf    = require "akkar.csrf"
local session = require "akkar.session"
local crypto  = require "akkar.crypto"

local SECRET = crypto.token(32)

--- An app with one safe route and two unsafe ones.
local function app_with(options)
  options = options or {}
  options.secret = options.secret or SECRET

  local writes = 0
  local app = akkar.new()
  app:use(csrf.new(options))
  app:get("/page", function(req) return { token = req.csrf_token } end)
  app:post("/write", function() writes = writes + 1; return { written = true } end)
  app:put("/write", function() writes = writes + 1; return { written = true } end)
  return app, function() return writes end
end

local function cookie_header(parts)
  local out = {}
  for name, value in pairs(parts) do out[#out + 1] = name .. "=" .. value end
  return table.concat(out, "; ")
end

--- The value of a Set-Cookie header, as a browser would keep it.
local function value_of(set_cookie)
  return set_cookie and set_cookie:match "^[^=]+=([^;]*)"
end

-- =========================================================================

describe("issuing a token", function()
  it("sets a csrf cookie on a safe request", function()
    local app = app_with()
    local res = app:test():get "/page"

    assert.equal(200, res.status)
    local set_cookie = res.headers["set-cookie"]
    assert.is_string(set_cookie)
    assert.is_truthy(set_cookie:find("akkar_csrf=", 1, true))
  end)

  it("does NOT mark it HttpOnly, and that is the mechanism", function()
    -- The page's own script has to read this value and echo it in a header;
    -- that is the whole reason a forged cross-site request cannot produce it.
    -- The token grants nothing by itself, so it is not a credential to hide.
    local app = app_with()
    local set_cookie = app:test():get("/page").headers["set-cookie"]

    assert.is_nil(set_cookie:find("HttpOnly", 1, true),
                  "the csrf cookie must be readable by the page")
    -- The session cookie, by contrast, is not, and `akkar.session` defaults it
    -- that way for the reason it documents at length.
    assert.is_truthy(session.cookie_header("s", "v", {}):find("HttpOnly", 1, true))
  end)

  it("marks it SameSite=Strict and Secure", function()
    local set_cookie = app_with():test():get("/page").headers["set-cookie"]
    assert.is_truthy(set_cookie:find("SameSite=Strict", 1, true))
    assert.is_truthy(set_cookie:find("Secure", 1, true))
  end)

  it("hands the handler the token, for a form to render", function()
    local res = app_with():test():get "/page"
    assert.is_string(res.body.token)
    assert.equal(value_of(res.headers["set-cookie"]), res.body.token)
  end)

  it("does not reissue when the caller already holds a valid one", function()
    -- Rewriting the cookie on every response resets its expiry on every poll,
    -- which is the same objection `akkar.session:commit` makes.
    local app = app_with()
    local client = app:test()

    local first = client:get "/page"
    local token = value_of(first.headers["set-cookie"])

    local second = client:get("/page", {
      headers = { cookie = cookie_header { akkar_csrf = token } } })
    assert.is_nil(second.headers["set-cookie"])
    assert.equal(token, second.body.token)
  end)
end)

-- =========================================================================

describe("refusing a forged write", function()
  it("refuses a cookie-authenticated POST with no token at all", function()
    local app, writes = app_with()
    local res = app:test():post("/write", {
      headers = { cookie = cookie_header { akkar_session = "victim" } },
      body = { amount = 100 },
    })

    -- A REAL 403, checked as a status rather than as a body that says "403".
    assert.equal(403, res.status)
    assert.is_truthy(res.body.error:find("csrf", 1, true))
    -- And the handler never ran, which is the property that matters: a
    -- refusal that arrives after the transfer is not a refusal.
    assert.equal(0, writes())
  end)

  it("refuses when the header does not match the cookie", function()
    local app, writes = app_with()
    local mine = csrf.issue(SECRET, "victim")
    local other = csrf.issue(SECRET, "victim")

    local res = app:test():post("/write", {
      headers = {
        cookie = cookie_header { akkar_session = "victim", akkar_csrf = mine },
        ["x-csrf-token"] = other,
      },
      body = {},
    })
    assert.equal(403, res.status)
    assert.equal(0, writes())
  end)

  it("refuses a token that was not minted here", function()
    local app = app_with()
    local invented = crypto.token(16) .. "." .. crypto.token(32)

    local res = app:test():post("/write", {
      headers = {
        cookie = cookie_header { akkar_session = "victim",
                                 akkar_csrf = invented },
        ["x-csrf-token"] = invented,
      },
      body = {},
    })
    assert.equal(403, res.status)
  end)

  it("refuses a token altered by a single character", function()
    local app = app_with()
    local token = csrf.issue(SECRET, "victim")
    local flipped = token:sub(1, -2) ..
                    (token:sub(-1) == "a" and "b" or "a")

    local res = app:test():post("/write", {
      headers = {
        cookie = cookie_header { akkar_session = "victim",
                                 akkar_csrf = flipped },
        ["x-csrf-token"] = flipped,
      },
      body = {},
    })
    assert.equal(403, res.status)
  end)

  it("THE PLANTED COOKIE: a token minted for the attacker's own session", function()
    -- This is the test that separates a signed double-submit from the version
    -- almost everybody ships.
    --
    -- Cookies are not origin-scoped. An attacker who controls any subdomain --
    -- or who can inject a Set-Cookie through a proxy, or has an XSS on a
    -- sibling host -- can plant a cookie on the parent domain. They then visit
    -- the site themselves, which anybody may do, collect a perfectly valid
    -- CSRF token, plant it as the victim's cookie and send the matching
    -- header.
    --
    -- Cookie equals header. A plain double-submit check passes and the
    -- transfer happens.
    local app, writes = app_with()
    local client = app:test()
    local attacker_token = csrf.issue(SECRET, "attacker-session")

    local res = client:post("/write", {
      headers = {
        cookie = cookie_header { akkar_session = "victim-session",
                                 akkar_csrf = attacker_token },
        ["x-csrf-token"] = attacker_token,
      },
      body = { amount = 100 },
    })

    assert.equal(403, res.status,
                 "a token minted for another session was accepted")
    assert.equal(0, writes())

    -- And the same token is genuinely valid -- for the session it was minted
    -- for. Without this half, the test above would also pass if `issue` were
    -- simply broken.
    local legitimate = client:post("/write", {
      headers = {
        cookie = cookie_header { akkar_session = "attacker-session",
                                 akkar_csrf = attacker_token },
        ["x-csrf-token"] = attacker_token,
      },
      body = {},
    })
    assert.equal(200, legitimate.status)
    assert.equal(1, writes())
  end)

  it("stops honouring a token after the session id rotates", function()
    -- `akkar.session:regenerate()` issues a new id on login, which changes the
    -- binding. A token minted for the anonymous visitor must not be honoured
    -- for the logged-in user, and that is what makes the refusal correct
    -- rather than inconvenient.
    local app = app_with()
    local before_login = csrf.issue(SECRET, "anonymous-session")

    local res = app:test():post("/write", {
      headers = {
        cookie = cookie_header { akkar_session = "rotated-session",
                                 akkar_csrf = before_login },
        ["x-csrf-token"] = before_login,
      },
      body = {},
    })
    assert.equal(403, res.status)
    assert.is_truthy(res.body.hint:find("rotates", 1, true))
  end)
end)

-- =========================================================================

describe("allowing what should be allowed", function()
  it("accepts a matching, correctly bound token", function()
    local app, writes = app_with()
    local token = csrf.issue(SECRET, "victim")

    local res = app:test():post("/write", {
      headers = {
        cookie = cookie_header { akkar_session = "victim", akkar_csrf = token },
        ["x-csrf-token"] = token,
      },
      body = {},
    })
    assert.equal(200, res.status)
    assert.equal(1, writes())
  end)

  it("accepts the token from a form field, for a page with no script", function()
    local app = app_with()
    local token = csrf.issue(SECRET, "victim")

    local res = app:test():post("/write", {
      headers = { cookie = cookie_header { akkar_session = "victim",
                                           akkar_csrf = token } },
      body = { _csrf = token, amount = 100 },
    })
    assert.equal(200, res.status)
  end)

  it("leaves safe methods alone", function()
    -- OPTIONS is in the exempt set because a CORS preflight is sent by the
    -- browser before the real request and cannot carry a token; refusing it
    -- would break the very request the preflight was clearing.
    local client = app_with():test()
    for _, call in ipairs { "get", "head", "options" } do
      local res = client[call](client, "/page", {
        headers = { cookie = cookie_header { akkar_session = "victim" } } })
      assert.is_true(res.status < 400,
                     call .. " was refused: " .. tostring(res.status))
    end
  end)
end)

describe("the requests it must NOT apply to", function()
  it("exempts a bearer request, because breaking every script buys nothing",
    function()
      -- `evil.example` cannot make a victim's client attach an Authorization
      -- header. There is no ambient credential to forge with, so a CSRF token
      -- protects nothing here and demanding one breaks every integration.
      local app, writes = app_with()
      local res = app:test():post("/write", {
        headers = { authorization = "Bearer abc123",
                    cookie = cookie_header { akkar_session = "victim" } },
        body = {},
      })
      assert.equal(200, res.status)
      assert.equal(1, writes())
    end)

  it("exempts an api-key request", function()
    local app = app_with()
    local res = app:test():post("/write", {
      headers = { ["x-api-key"] = "ak_abc",
                  cookie = cookie_header { akkar_session = "victim" } },
      body = {},
    })
    assert.equal(200, res.status)
  end)

  it("exempts a request with no session cookie at all", function()
    -- A public signup or contact form is not authenticated by anything, so a
    -- forged one borrows no privilege. Refusing it would be refusing an
    -- anonymous POST for want of a token it was never given.
    local app = app_with()
    local res = app:test():post("/write", { body = {} })
    assert.equal(200, res.status)
  end)

  it("lets an application replace the test entirely", function()
    local app = app_with { applies = function(req)
      return req.headers["x-force-csrf"] == "yes"
    end }

    -- Exempted despite looking exactly like a cookie-authenticated write.
    local open = app:test():post("/write", {
      headers = { cookie = cookie_header { akkar_session = "victim" } },
      body = {},
    })
    assert.equal(200, open.status)

    -- And protected despite carrying a bearer token, because the application
    -- said so. A predicate returning false must not fall back to the built-in
    -- test -- an `and`/`or` chain gets that wrong and re-protects a route
    -- somebody carefully exempted.
    local closed = app:test():post("/write", {
      headers = { ["x-force-csrf"] = "yes", authorization = "Bearer abc" },
      body = {},
    })
    assert.equal(403, closed.status)
  end)
end)

-- =========================================================================

describe("what it does to the response", function()
  it("NEVER writes onto the table the handler returned", function()
    -- `akkar.etag`, `akkar.limit` and `akkar.auth` were each fixed for exactly
    -- this. A handler may return a hoisted or memoised table -- a constant
    -- 404, a cached payload -- and writing a header onto it means one table is
    -- shared by every request that reaches that handler. A stray
    -- `x-request-id` was merely confusing; a stray `Set-Cookie` is one user's
    -- token handed to another.
    --
    -- akkar now normalises at every hop, so a middleware receives a fresh
    -- response rather than the handler's own table and this is currently
    -- belt-and-braces. It is asserted anyway: the invariant is "this module
    -- does not mutate what it was given", and that must not quietly become
    -- "the framework happened to hand it a copy".
    local HOISTED = { cached = true }

    local app = akkar.new()
    app:use(csrf.new { secret = SECRET })
    app:get("/hoisted", function() return HOISTED end)

    local client = app:test()
    local first = client:get "/hoisted"
    local second = client:get "/hoisted"

    assert.is_truthy(first.headers["set-cookie"])
    assert.is_nil(HOISTED.headers, "the handler's table was mutated")
    assert.is_nil(HOISTED.__response, "the handler's table was mutated")
    assert.is_nil(HOISTED.status, "the handler's table was mutated")
    assert.is_true(second.body.cached)
  end)

  it("keeps the status the handler chose", function()
    -- The copy that carries the cookie has to be a RESPONSE. `akkar.auth`
    -- records the debugging session this cost: copying fields off a bare table
    -- produced three nils carrying a cookie, and akkar normalised THAT into a
    -- 200 whose body was the copy, so the body and the header both vanished.
    local app = akkar.new()
    app:use(csrf.new { secret = SECRET })
    app:get("/made", function() return akkar.response(201, { id = 7 }) end)

    local res = app:test():get "/made"
    assert.equal(201, res.status)
    assert.equal(7, res.body.id)
    assert.is_truthy(res.headers["set-cookie"])
  end)

  it("does not clobber a Set-Cookie somebody else already wrote", function()
    -- akkar sends exactly one Set-Cookie per response: response headers are a
    -- table keyed by name and the server writes each key once. `akkar.auth`
    -- owns that slot whenever a session commits, so this file yields rather
    -- than overwriting -- losing a session cookie to gain a csrf cookie would
    -- be a straight downgrade.
    local app = akkar.new()
    app:use(csrf.new { secret = SECRET })
    app:get("/login", function()
      return akkar.response(200, { ok = true },
                            { ["set-cookie"] = "akkar_session=abc; Path=/" })
    end)

    local res = app:test():get "/login"
    assert.equal("akkar_session=abc; Path=/", res.headers["set-cookie"])
  end)

  it("issues no cookie on an unsafe response, so it never contends", function()
    local app = app_with()
    local token = csrf.issue(SECRET, "victim")
    local res = app:test():post("/write", {
      headers = { cookie = cookie_header { akkar_session = "victim",
                                           akkar_csrf = token },
                  ["x-csrf-token"] = token },
      body = {},
    })
    assert.equal(200, res.status)
    assert.is_nil(res.headers["set-cookie"])
  end)
end)

describe("the secret", function()
  it("refuses one too short to be a signing key", function()
    -- The same refusal and the same reasoning as `akkar.session`: a guessable
    -- key here lets an attacker mint a token bound to the victim's session,
    -- which is the one thing the binding exists to prevent.
    local ok, why = pcall(csrf.new, { secret = "hunter2" })
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("32 bytes", 1, true))

    assert.is_false((pcall(csrf.new, {})))
  end)

  it("mints a different token every time", function()
    assert.not_equal(csrf.issue(SECRET, "s"), csrf.issue(SECRET, "s"))
    assert.is_true(csrf.valid(SECRET, csrf.issue(SECRET, "s"), "s"))
    assert.is_false(csrf.valid(SECRET, csrf.issue(SECRET, "s"), "other"))
    assert.is_false(csrf.valid(crypto.token(32), csrf.issue(SECRET, "s"), "s"))
  end)

  it("survives a token that is not a token", function()
    for _, junk in ipairs { "", ".", "a.b", "no-dot", "ZZ.ZZ" } do
      assert.is_false(csrf.valid(SECRET, junk, "s"))
    end
    assert.is_false(csrf.valid(SECRET, nil, "s"))
    assert.is_false(csrf.valid(SECRET, 7, "s"))
  end)
end)
