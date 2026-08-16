--[[
akkar.session — the properties a cookie session has and a JWT does not.

Four of these exist specifically because they are the arguments for this
design over a self-contained token, so they are the ones that must not rot:
a session can be revoked server-side; a forged cookie costs an HMAC and not a
store lookup; the id rotates on privilege change; and the cookie is not
readable by JavaScript.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local session = require "akkar.session"
local cache   = require "akkar.cache.memory"
local crypto  = require "akkar.crypto"

local SECRET = crypto.token(32)

local function manager(options)
  options = options or {}
  options.secret = options.secret or SECRET
  return session.new(options)
end

--- Pulls the cookie value back out of a Set-Cookie header, as a browser would.
local function cookie_value(set_cookie)
  return set_cookie:match "^[^=]+=([^;]*)"
end

describe("akkar.session", function()
  it("refuses a secret too short to be one", function()
    -- A signing key somebody typed is a signing key somebody guesses.
    local ok, why = pcall(session.new, { secret = "hunter2" })
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("32 bytes", 1, true))

    assert.is_false((pcall(session.new, {})))
  end)

  it("round-trips data across two requests", function()
    local c = cache.new()
    local m = manager()

    local first = m:open(c, nil)
    first:set("user_id", 42)
    local set_cookie = first:commit()
    assert.is_string(set_cookie)

    local second = m:open(c, m.name .. "=" .. cookie_value(set_cookie))
    assert.equal(42, second:get "user_id")
  end)

  it("keeps the session on the SERVER, so it can be revoked", function()
    -- The property a self-contained token cannot have, and the reason this
    -- module exists. After `destroy`, the same cookie must stop working --
    -- which is what "log out" means and what a JWT cannot do before expiry.
    local c = cache.new()
    local m = manager()

    local s = m:open(c, nil)
    s:set("user_id", 7)
    local jar = m.name .. "=" .. cookie_value(s:commit())

    assert.equal(7, m:open(c, jar):get "user_id")

    local live = m:open(c, jar)
    live:destroy()
    live:commit()

    local after = m:open(c, jar)
    assert.is_nil(after:get "user_id",
      "the session survived being destroyed, so it cannot be revoked")
  end)

  it("rejects a tampered cookie without touching the store", function()
    -- Cheapness is the point: a forged cookie must cost an HMAC, not a round
    -- trip to Redis, or an attacker with a script has a denial of service.
    local reads = 0
    local c = cache.new()
    local counting = setmetatable({
      get = function(self, k) reads = reads + 1 return c:get(k) end,
      set = function(self, ...) return c:set(...) end,
      del = function(self, ...) return c:del(...) end,
    }, {})

    local m = manager()
    local s = m:open(counting, nil)
    s:set("user_id", 1)
    local value = cookie_value(s:commit())

    reads = 0
    -- Same id, signature from a different key.
    local id = value:match "^([^.]+)%."
    local forged = id .. "." .. crypto.to_hex(crypto.hmac("another key", id))
    local opened = m:open(counting, m.name .. "=" .. forged)

    assert.is_nil(opened:get "user_id")
    assert.equal(0, reads, "a forged cookie caused a store lookup")
  end)

  it("gives an unknown cookie a fresh id rather than adopting it", function()
    -- Session fixation: adopting an attacker-chosen id for an empty session
    -- lets them pick the id, wait for the victim to log in, and hold it.
    local c = cache.new()
    local m = manager()
    local chosen = "attacker-chosen-id"
    local forged = chosen .. "." .. crypto.to_hex(crypto.hmac(SECRET, chosen))

    local s = m:open(c, m.name .. "=" .. forged)
    -- The signature is valid -- the attacker may have obtained one -- but the
    -- store has never heard of it, so it must not become the session.
    s:set("user_id", 5)
    s:commit()
    assert.are_not.equal(chosen, s.id,
      "an unknown id was adopted, which is session fixation")
  end)

  it("rotates the id on regenerate and forgets the old one", function()
    local c = cache.new()
    local m = manager()

    local s = m:open(c, nil)
    s:set("user_id", 9)
    local before = m.name .. "=" .. cookie_value(s:commit())
    local old_id = s.id

    local live = m:open(c, before)
    live:regenerate()
    local after = m.name .. "=" .. cookie_value(live:commit())

    assert.are_not.equal(old_id, live.id)
    -- The data followed the user...
    assert.equal(9, m:open(c, after):get "user_id")
    -- ...and the old id is dead, or rotation bought nothing.
    assert.is_nil(m:open(c, before):get "user_id",
      "the pre-rotation cookie still works")
  end)

  it("does not rewrite the cookie when nothing changed", function()
    -- Rewriting on every response resets the expiry on every poll, and a
    -- session that never expires while a tab is open outlives a stolen laptop.
    local c = cache.new()
    local m = manager()

    local s = m:open(c, nil)
    s:set("user_id", 1)
    local jar = m.name .. "=" .. cookie_value(s:commit())

    local untouched = m:open(c, jar)
    assert.equal(1, untouched:get "user_id")
    assert.is_nil(untouched:commit(), "the cookie was rewritten for a read")
  end)

  it("sets HttpOnly, Secure and SameSite by default", function()
    -- An option nobody sets is the option everybody gets. A session cookie
    -- readable by JavaScript is one XSS away from being stolen.
    local c = cache.new()
    local s = manager():open(c, nil)
    s:set("x", 1)
    local header = s:commit()

    assert.is_truthy(header:find("HttpOnly", 1, true))
    assert.is_truthy(header:find("Secure", 1, true))
    assert.is_truthy(header:find("SameSite=Lax", 1, true))
    assert.is_truthy(header:find("Path=/", 1, true))
  end)

  it("expires the cookie in the browser when the session is destroyed", function()
    local c = cache.new()
    local m = manager()
    local s = m:open(c, nil)
    s:set("x", 1)
    local jar = m.name .. "=" .. cookie_value(s:commit())

    local live = m:open(c, jar)
    live:destroy()
    local header = live:commit()
    assert.is_truthy(header:find("Max-Age=0", 1, true),
      "the browser was not told to drop the cookie")
  end)

  it("survives undecodable state instead of locking the user out", function()
    -- Raising here would make one corrupt key a user who can neither log in
    -- nor log out, because every request dies before reaching a handler.
    local c = cache.new()
    local m = manager()
    local s = m:open(c, nil)
    s:set("x", 1)
    local jar = m.name .. "=" .. cookie_value(s:commit())

    c:set("session:" .. s.id, "{not json", 60)
    local after = m:open(c, jar)
    assert.is_nil(after:get "x")
    assert.is_table(after:all())
  end)

  describe("cookie parsing", function()
    it("handles the shapes a browser actually sends", function()
      local jar = session.parse_cookies "a=1; b=two; empty=; spaced = 3"
      assert.equal("1", jar.a)
      assert.equal("two", jar.b)
      assert.equal("", jar.empty)
      assert.is_nil(session.parse_cookies(nil).anything)
    end)
  end)
end)
