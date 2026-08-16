--[[
akkar.auth — who the caller is, decided once, before the handler.

## What this is and is not

It answers **authentication**: which principal is making this request.
It does not answer **authorization**: whether that principal may do this
thing. The second is application logic — it depends on your resources and
your rules — and a framework that guesses at it produces a permission model
nobody can read. What akkar gives you is `req.auth`, populated and trustworthy,
and the `if` is yours.

## Three schemes, because real systems have all three

**Session** — a browser, a human, a cookie. `akkar.session`, server-side,
revocable. This is the one for people.

**API key** — a long-lived opaque string in a header. This is the one for
scripts, and it is here because of a fact about who actually uses an API:
many of them are not professional engineers. They are analysts, operators,
scientists and hobbyists, and every integration starts life as a script
somebody pastes into a terminal. An API that requires an OAuth handshake to
make the first request is an API most of those people never make a second
one to. A key is less sophisticated and more used.

**Bearer token** — an `Authorization: Bearer` header, verified by a function
you supply. akkar does not decide what the token means. If it is a JWT from
an identity provider you verify it there; if it is a session id you look it
up. The point is that the header parsing, the constant-time comparison and
the 401 shape are not written five times per application.

## The comparison is constant time, everywhere

An API key checked with `==` leaks its prefix through timing, and a key is
exactly the kind of secret an attacker can guess a byte at a time because
they may retry freely. `akkar.crypto.equal` is used for every comparison here
and `M.compare_key` is exported so an application's own lookup does the same.

## THE KEY IS STORED HASHED

`M.hash_key` and the `keys` table this module expects take a HASH of the key,
not the key. A database of API keys in plaintext is a database that leaks
every integration at once, and unlike passwords a key is usually written into
somebody else's deployment where rotating it is expensive.

Because a key is high-entropy — unlike a password, which is not — a single
SHA-256 is the right cost here rather than PBKDF2: there is no dictionary to
run against 32 random bytes, and putting 600,000 iterations on a hot request
path would be paying for a defence that is not needed.
]]

local crypto = require "akkar.crypto"

local M = {}

-- ============================================================== 401 and 403

--- The response for "I do not know who you are".
---
--- `WWW-Authenticate` is not decoration: it is what tells a client which
--- scheme to try, and omitting it is why so many integrations guess.
---
--- BUILT WITH `akkar.response`, AND THE FIRST VERSION WAS NOT.
---
--- It returned a bare `{ status = 401, headers = ..., body = ... }`, which
--- looks exactly like a response and is not one. akkar marks a real response
--- with `__response`, and anything else returned from a handler or middleware
--- is treated as a JSON body -- so this 401 became a **200 whose body was the
--- word "401"**. The spec caught it because it asserts the status of a
--- rejected key; without that assertion every wrong credential in every
--- application would have been answered "OK" with a convincing-looking
--- payload.
---
--- It is worth being precise about why this is the worst possible place for
--- that mistake: a 200 is what a client checks for. An integration testing
--- `if res.status == 200` treats a refused request as an accepted one.
local function unauthorized(scheme, message)
  return require("akkar").response(401, { error = message or "unauthorized" },
                                   { ["www-authenticate"] = scheme or "Bearer" })
end

M.unauthorized = unauthorized

-- ================================================================ API keys

--- The stored form of an API key. Store this, never the key itself.
function M.hash_key(key)
  return crypto.to_hex(crypto.sha256(key))
end

--- Compares a presented key against a stored hash, in constant time.
function M.compare_key(presented, stored_hash)
  if type(presented) ~= "string" or type(stored_hash) ~= "string" then
    return false
  end
  return crypto.equal(M.hash_key(presented), stored_hash)
end

--- Generates a key and its stored hash. The key is shown ONCE.
---
--- Returned as a pair so the calling code cannot accidentally store the
--- wrong one: whoever writes `local key, hash = generate_key()` has both
--- names in front of them.
---
--- The prefix is a real convenience and a real security feature. Secret
--- scanners — GitHub's included — find leaked credentials by pattern, and a
--- key that looks like any other hex string is a key nobody can detect in a
--- public repository.
function M.generate_key(prefix)
  local key = (prefix or "ak") .. "_" .. crypto.token(24)
  return key, M.hash_key(key)
end

-- =============================================================== extraction

local function header(req, name)
  local headers = req.headers or {}
  if type(headers.get) == "function" then return headers:get(name) end
  return headers[name] or headers[name:lower()]
end

--- Pulls a bearer token out of an Authorization header.
---
--- The scheme is matched case-insensitively because RFC 7235 says it is
--- case-insensitive, and clients in the wild send `bearer`, `Bearer` and
--- occasionally `BEARER`. Rejecting those is a support ticket, not security.
function M.bearer(req)
  local value = header(req, "authorization")
  if type(value) ~= "string" then return nil end
  local scheme, token = value:match "^(%a+)%s+(.+)$"
  if not scheme or scheme:lower() ~= "bearer" then return nil end
  return token
end

function M.api_key(req, header_name)
  local value = header(req, header_name or "x-api-key")
  if type(value) == "string" and value ~= "" then return value end
  -- Also accepted as `Authorization: ApiKey <key>`, because half the clients
  -- in the world put everything in that header and telling them they are
  -- wrong does not make the integration work.
  local auth = header(req, "authorization")
  if type(auth) == "string" then
    local scheme, key = auth:match "^(%a+)%s+(.+)$"
    if scheme and scheme:lower() == "apikey" then return key end
  end
  return nil
end

-- ============================================================== middleware

--- Builds authentication middleware.
---
--- Every scheme is optional; the ones you configure are the ones that run, in
--- the order session, bearer, key. The FIRST that produces a principal wins,
--- and the rest are not tried — a request carrying both a cookie and a key is
--- ambiguous and picking one deterministically beats merging them.
---
---   app:use(auth.middleware {
---     sessions = session_manager,          -- akkar.session
---     load_session = function(req, data) ... end,
---     bearer = function(req, token) ... end,
---     keys   = function(req, key) ... end,
---     optional = false,
---   })
---
--- Each resolver returns a principal (any truthy value) or nil. `req.auth` is
--- that principal; `req.session` is the session when one was opened.
---
--- `optional = true` lets an unauthenticated request through with `req.auth`
--- nil, for a route that behaves differently rather than refusing.
function M.middleware(options)
  options = options or {}

  return function(req, next)
    local principal, scheme

    if options.sessions and req.cache then
      local sess = options.sessions:open(req.cache, header(req, "cookie"))
      req.session = sess
      if options.load_session then
        principal = options.load_session(req, sess)
      elseif sess:get "user_id" then
        principal = { user_id = sess:get "user_id" }
      end
      if principal then scheme = "session" end
    end

    if not principal and options.bearer then
      local token = M.bearer(req)
      if token then
        principal = options.bearer(req, token)
        if principal then scheme = "bearer" end
      end
    end

    if not principal and options.keys then
      local key = M.api_key(req, options.key_header)
      if key then
        principal = options.keys(req, key)
        if principal then scheme = "api_key" end
      end
    end

    if not principal and not options.optional then
      -- The scheme advertised is the strongest one configured, so a browser
      -- is not told to send a bearer token it does not have.
      local advertise = options.sessions and "Cookie" or "Bearer"
      return unauthorized(advertise, options.message)
    end

    req.auth = principal
    req.auth_scheme = scheme

    local res = next(req)

    -- THE SESSION COMMIT RIDES ON THE RESPONSE, and this is the one place
    -- this module touches what a handler returned.
    --
    -- It cannot mutate that table: `akkar/init.lua` documents at length why
    -- writing a header onto a handler's return value is a real defect -- a
    -- hoisted or memoised response is shared between requests, so request A's
    -- cookie lands in a table request B also returns. A stray `x-request-id`
    -- was merely confusing; a stray `Set-Cookie` is one user's session handed
    -- to another.
    --
    -- So a copy. And the copy has to be a RESPONSE.
    --
    -- CORRECTION, because the first version of this comment explained the bug
    -- wrongly while fixing it correctly. It said a middleware sits ABOVE
    -- normalisation and receives whatever the handler literally returned.
    -- That is false: akkar normalises at every hop, and a middleware is handed
    -- a real response -- `__response = true`, `status = 200`, `body` filled in
    -- -- even when the handler returned a bare table. Measured, after another
    -- agent reading this file said the claim did not match what they saw.
    --
    -- The actual defect was on the other side of the copy. `res` was fine;
    -- the COPY was a plain table with no `__response`, so akkar treated it as
    -- a JSON body and normalised it into a 200 whose body was the copy. The
    -- body vanished and the header with it, silently.
    --
    -- Worth keeping the correction rather than editing the sentence: a
    -- comment that explains a real bug with a wrong mechanism is how the next
    -- person builds on a false model of the framework.
    --
    -- `akkar.response` is the constructor that marks a table as already
    -- normalised (`__response`), so building one here is how a middleware adds
    -- a header without pretending to know what the handler meant.
    --
    -- Required lazily rather than at the top of the file: `akkar` does not
    -- require this module, but keeping the edge one-directional at load time
    -- means nobody has to reason about the order later.
    if req.session then
      local set_cookie = req.session:commit()
      if set_cookie then
        local akkar = require "akkar"
        local normalised = res
        if type(res) ~= "table" or res.__response ~= true then
          normalised = akkar.response(res == nil and 204 or 200, res)
        end

        local headers = {}
        for k, v in pairs(normalised.headers or {}) do headers[k] = v end
        headers["set-cookie"] = set_cookie

        local copy = akkar.response(normalised.status, normalised.body, headers)
        -- A streamed response carries its producer and its release, and
        -- dropping either would truncate the body or leak the capability it
        -- was holding.
        copy.raw, copy.stream, copy.release =
          normalised.raw, normalised.stream, normalised.release
        return copy
      end
    end

    return res
  end
end

--- Logs a principal in: rotates the session id, then records them.
---
--- Rotation first, and not as a detail. An attacker who planted a cookie
--- before the login knows the id afterwards unless it changes at exactly this
--- moment. Making it one call is how it stops being forgotten.
function M.login(req, user_id, extra)
  if not req.session then
    error("akkar.auth: login needs a session; configure `sessions` in the " ..
          "middleware", 0)
  end
  req.session:regenerate()
  req.session:set("user_id", user_id)
  for key, value in pairs(extra or {}) do req.session:set(key, value) end
  req.auth = { user_id = user_id }
  return req.session
end

--- Logs them out, on the server as well as in the browser.
function M.logout(req)
  if req.session then req.session:destroy() end
  req.auth = nil
end

return M
