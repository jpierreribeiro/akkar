--[[
akkar.session — server-side sessions behind a signed, opaque cookie.

## The decision, stated first because it is the whole design

**A session is an id in a cookie and state on the server. It is not a JWT.**

A signed token that carries its own claims cannot be revoked before it
expires, and revocation is the thing a session most needs: log out, change
password, ban an account, rotate after privilege escalation. Every workaround
for that — a deny-list, a short expiry with a refresh token — reintroduces the
server-side lookup the token was supposed to remove, and now there are two
mechanisms instead of one.

The other half is that a token in a browser has to live somewhere.
`localStorage` is readable by any script on the page, so one XSS is every
session; a cookie with `HttpOnly` is not. The browser has done this correctly
since 1994 and akkar is not going to improve on it.

So: an opaque random id, a signed cookie, and the state in `req.cache` — which
already has two implementations, one of which needs nothing installed.

JWT is not banned outright and it is not here. Its honest use is a
short-lived assertion issued by somebody else that you VERIFY, and if that
arrives it belongs in a module with `verify` and no `issue`, so that nobody
reaches for it to keep a user logged in.

## What the cookie carries, and why it is signed at all

The value is `<id>.<hmac>`. The id is 32 random bytes and means nothing by
itself; the signature is not there to hide it — there is nothing in it to hide
— but to stop the server doing a store lookup for every forged string an
attacker sends. A garbage cookie is rejected by an HMAC comparison instead of
a round trip to Redis, which is the difference between a nuisance and a
denial of service.

The comparison is `akkar.crypto.equal`, in constant time, for the reason that
module documents at length.

## Rotation on privilege change

`:regenerate()` issues a new id and moves the data. It exists because of
session fixation: an attacker who can set a cookie before you log in
otherwise knows your session id afterwards. Call it on login. The docstring
says so and `akkar.auth` does it for you.
]]

local crypto = require "akkar.crypto"

local M = {}

local Session = {}
Session.__index = Session

local DEFAULTS = {
  cookie   = "akkar_session",
  ttl      = 14 * 24 * 60 * 60,     -- two weeks
  prefix   = "session:",
  path     = "/",
  same_site = "Lax",
  http_only = true,
  secure    = true,
}

-- ================================================================== the store

local Store = {}
Store.__index = Store

--- Wraps a cache capability so a session's state has one place to live.
---
--- `cache` rather than `db` on purpose: a session is expiring key/value data,
--- which is what a cache IS, and putting it in Postgres makes every request
--- that touches a session a database round trip. The cost of the choice is
--- that a cache flush logs everybody out, which is annoying and not dangerous;
--- the cost of the other choice is paid on every single request.
function Store.new(cache, options)
  return setmetatable({
    cache  = cache,
    prefix = options.prefix or DEFAULTS.prefix,
    ttl    = options.ttl or DEFAULTS.ttl,
  }, Store)
end

function Store:key(id) return self.prefix .. id end

function Store:load(id)
  local raw = self.cache:get(self:key(id))
  if not raw then return nil end
  local ok, data = pcall(require("akkar.json").decode, raw)
  if not ok or type(data) ~= "table" then
    -- Undecodable session state is treated as no session. The alternative --
    -- raising -- turns one corrupt key into a user who cannot log in and
    -- cannot log out either, because every request dies before reaching a
    -- handler.
    return nil
  end
  return data
end

function Store:save(id, data)
  return self.cache:set(self:key(id), require("akkar.json").encode(data), self.ttl)
end

function Store:destroy(id)
  return self.cache:del(self:key(id))
end

-- ================================================================ the cookie

local function sign(secret, id)
  return id .. "." .. crypto.to_hex(crypto.hmac(secret, id))
end

--- Splits a cookie value and checks its signature in constant time.
local function unsign(secret, value)
  if type(value) ~= "string" then return nil end
  local id, signature = value:match "^([^.]+)%.(%x+)$"
  if not id then return nil end
  if not crypto.equal(crypto.to_hex(crypto.hmac(secret, id)), signature) then
    return nil
  end
  return id
end

--- Parses a `Cookie:` header into a table. Absent header, empty table.
function M.parse_cookies(header)
  local out = {}
  if type(header) ~= "string" then return out end
  for pair in header:gmatch "[^;]+" do
    local name, value = pair:match "^%s*([^=]+)=(.*)$"
    if name then out[name] = value end
  end
  return out
end

--- Renders a `Set-Cookie` value.
---
--- `HttpOnly` and `SameSite` default ON, and `Secure` defaults ON. A session
--- cookie readable by JavaScript is one XSS away from being stolen, and the
--- defaults are where that is decided -- an option nobody sets is the option
--- everybody gets.
function M.cookie_header(name, value, options)
  options = options or {}
  local parts = { ("%s=%s"):format(name, value) }
  parts[#parts + 1] = "Path=" .. (options.path or DEFAULTS.path)
  if options.max_age then parts[#parts + 1] = "Max-Age=" .. math.floor(options.max_age) end
  if options.domain then parts[#parts + 1] = "Domain=" .. options.domain end
  if options.http_only ~= false then parts[#parts + 1] = "HttpOnly" end
  if options.secure ~= false then parts[#parts + 1] = "Secure" end
  parts[#parts + 1] = "SameSite=" .. (options.same_site or DEFAULTS.same_site)
  return table.concat(parts, "; ")
end

-- =============================================================== the session

function Session:get(key) return self.data[key] end

function Session:set(key, value)
  self.data[key] = value
  self.dirty = true
  return self
end

function Session:all() return self.data end

--- Issues a NEW id carrying the same data.
---
--- Session fixation: an attacker who can plant a cookie in your browser before
--- you log in knows your session id after you log in, and is then logged in as
--- you. Rotating at the moment privileges change is the fix, and it is cheap.
--- Call it on login; `akkar.auth` does.
function Session:regenerate()
  local old = self.id
  self.id = crypto.token(32)
  self.dirty = true
  self.rotated_from = old
  return self
end

--- Ends the session, on the server as well as in the browser.
---
--- Both halves matter. Clearing the cookie alone leaves the state in the
--- store, so a stolen cookie value keeps working after the user pressed
--- "log out" -- which is exactly the failure a token-based session cannot
--- avoid and this design exists to avoid.
function Session:destroy()
  self.store:destroy(self.id)
  if self.rotated_from then self.store:destroy(self.rotated_from) end
  self.data = {}
  self.destroyed = true
  self.dirty = true
  return self
end

--- Writes the session out and returns the `Set-Cookie` value, or nil.
---
--- Returns nil when nothing changed, which is not an optimisation but a
--- correctness property: rewriting the cookie on every response resets its
--- expiry on every poll, and a session that never expires while a tab is open
--- is a session that outlives the laptop being stolen.
function Session:commit()
  if not self.dirty then return nil end

  if self.destroyed then
    return M.cookie_header(self.name, "", {
      max_age = 0, path = self.options.path,
      http_only = self.options.http_only, secure = self.options.secure,
      same_site = self.options.same_site, domain = self.options.domain,
    })
  end

  if self.rotated_from then self.store:destroy(self.rotated_from) end
  self.store:save(self.id, self.data)

  return M.cookie_header(self.name, sign(self.secret, self.id), {
    max_age = self.options.ttl, path = self.options.path,
    http_only = self.options.http_only, secure = self.options.secure,
    same_site = self.options.same_site, domain = self.options.domain,
  })
end

-- ================================================================== the door

--- Builds a session manager.
---
--- `secret` is required and is checked for length, because a signing key
--- somebody typed by hand is a signing key an attacker guesses. Thirty-two
--- bytes is the shortest thing worth calling a key; `akkar.crypto.token(32)`
--- produces one.
function M.new(options)
  options = options or {}
  local secret = options.secret
  if type(secret) ~= "string" or #secret < 32 then
    error("akkar.session: `secret` must be a string of at least 32 bytes; " ..
          "generate one with akkar.crypto.token(32) and keep it out of the " ..
          "source", 0)
  end

  local manager = {
    secret  = secret,
    name    = options.cookie or DEFAULTS.cookie,
    options = {
      ttl       = options.ttl or DEFAULTS.ttl,
      path      = options.path or DEFAULTS.path,
      domain    = options.domain,
      same_site = options.same_site or DEFAULTS.same_site,
      http_only = options.http_only ~= false,
      secure    = options.secure ~= false,
      prefix    = options.prefix or DEFAULTS.prefix,
    },
  }

  --- Loads the session for a request, creating an empty one if there is none.
  function manager:open(cache, cookie_header)
    local store = Store.new(cache, self.options)
    local cookies = M.parse_cookies(cookie_header)
    local id = unsign(self.secret, cookies[self.name])

    local data
    if id then data = store:load(id) end
    if not data then
      -- A NEW ID FOR AN UNKNOWN COOKIE, not a reused one. Accepting an
      -- attacker-supplied id for an empty session is session fixation with
      -- extra steps: they choose the id, wait for the victim to log in, and
      -- then hold it.
      id, data = crypto.token(32), {}
    end

    return setmetatable({
      id = id, data = data, store = store, secret = self.secret,
      name = self.name, options = self.options, dirty = false,
    }, Session)
  end

  return manager
end

M.Session = Session
M.Store = Store

return M
