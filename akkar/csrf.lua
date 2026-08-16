--[[
akkar.csrf — for the requests a browser sends on its own, and for no others.

## What the attack actually is

A browser attaches a cookie to a request because of WHERE the request is
going, not because of where it came from. So a page on `evil.example` can
submit a form to `bank.example/transfer`, and the browser -- doing exactly
what it was designed to do in 1994 -- attaches the victim's session cookie.
The request is authenticated. The victim did not make it.

Nothing about that involves reading a response, so `SameSite` and CORS do not
end it: a cross-site POST is *sent* whether or not the attacker may read what
comes back, and `SameSite=Lax` -- which `akkar.session` defaults to -- still
permits top-level navigations, which includes a form auto-submitted by script.
`Lax` is a real and large improvement and it is not a proof.

The property that ends it is simple to state: **the request must carry a value
the attacker's page could not have read.** A cookie is not that value, because
the browser sends it regardless. A header the page had to fetch and set is.

## Cookie-authenticated requests only, and this is the important paragraph

This middleware applies to a request that is authenticated BY A COOKIE. It
exempts anything carrying `Authorization` or an API key.

That is not a convenience, it is a correctness requirement. A bearer token or
an API key is attached by the CLIENT, deliberately, on every request --
`evil.example` cannot make a victim's `curl` add a header, and there is no
ambient credential to ride on. So CSRF protection buys such a request nothing
at all, and demanding it breaks every script, every integration and every
`curl` in every runbook, on the day it is switched on, for no security.

`akkar.auth` makes the same argument from the other side: API keys exist
because many callers are analysts and operators pasting a script into a
terminal, and an API that requires a handshake to make the first request is an
API most of those people never make a second one to. Forcing a CSRF token onto
those callers is that mistake with a security justification that does not
apply to them.

The test is made on the REQUEST'S HEADERS, deliberately, and never on
`req.auth_scheme`. Reading what `akkar.auth` decided would make this
protection depend on middleware ORDER, and CSRF silently switching itself off
because somebody reordered two `app:use` lines is the worst failure this file
could have.

## Why double-submit, and why the token is signed

**A synchronizer token** -- one value per session, held on the server -- is the
textbook answer and it is the wrong shape here. akkar's session store is a
CACHE (`akkar.session` argues for that at length), so it may be flushed; a
flush would then invalidate every outstanding form as well as every session,
and it adds a store round trip to every page render.

**Plain double-submit** -- a random value in a cookie, echoed in a header,
compared for equality -- needs no server state and has one real hole:
**cookies are not origin-scoped**. An attacker who controls any subdomain, or
who can inject a `Set-Cookie` through a proxy or an XSS on a sibling host, can
plant a cookie on the parent domain. They then fetch a perfectly valid token
of their own -- by visiting the site themselves, which anybody may do -- plant
it as the victim's CSRF cookie, and send the matching header. Cookie equals
header, and the check passes.

**So the token is bound with an HMAC.** It is
`nonce . HMAC(secret, nonce | binding)`, where the binding is the victim's
session cookie value. A token the attacker minted is bound to the ATTACKER'S
session, so its signature does not verify against the victim's, and planting it
fails. That single HMAC is the difference between double-submit as it is
usually shipped and double-submit that holds.

Both halves are still checked -- the signature AND cookie-equals-presented --
because they fail independently: the signature covers a planted token, and the
equality covers the case where there is no session yet and the binding is
empty.

## The consequence of binding to the session, stated plainly

`akkar.session:regenerate()` issues a new id on login, which is right and which
CHANGES THE BINDING. A CSRF token minted before login stops verifying after
it, by construction. The next safe request issues a fresh one.

That is deliberate -- a token that survived a privilege change would be a token
minted for the anonymous visitor and honoured for the logged-in user -- and it
means a client that logs in and immediately POSTs, with no navigation in
between, is refused once. The 403 says so. A browser navigates; a script uses
an API key and is exempt.

## Where the cookie is issued, and a framework limit found writing this

The token cookie is issued on responses to SAFE methods only.

The reason is a limitation of akkar, not a design preference: a response's
headers are a plain table keyed by name, and `set-cookie` is one key. The
server writes each key once (`akkar/init.lua`, `rh:append`), so **akkar can
send exactly one `Set-Cookie` per response** -- a list value would be stored by
lua-http and then fail when it reached the wire, while the in-process test
client would copy it happily and never notice. `akkar.auth` already owns that
slot on any response that commits a session.

Issuing only on safe methods means this file never contends for it: a login
POST keeps its session cookie, and the GET after it collects a CSRF token. The
alternative -- writing `set-cookie` whenever it happens to be free -- would
make whether a user gets a CSRF token depend on whether their session was
touched, which is not a rule anybody could reason about.

## The cookie is NOT HttpOnly, and that is not an oversight

The whole mechanism requires the page's own JavaScript to read the value and
put it in a header. A CSRF token is not a credential: on its own it
authenticates nobody, and it is bound to a session it does not grant. An XSS
that can read it has already lost you the game by other means.

For a plain HTML form there is no JavaScript, so the token is also accepted
from a body field -- `_csrf` by default -- and `req.csrf_token` is set for a
template to render into a hidden input.
]]

local crypto  = require "akkar.crypto"
local session = require "akkar.session"

local M = {}

-- The methods RFC 7231 calls safe, plus OPTIONS.
--
-- Exempt because they are not supposed to change anything, so forging one
-- achieves nothing an attacker could not achieve by asking their own browser
-- to fetch the URL. OPTIONS is in the list because a CORS preflight is sent by
-- the browser before the real request and cannot carry a token -- rejecting it
-- would break the very request the preflight was clearing.
--
-- A handler that mutates state on GET is outside what this can protect, and
-- that is the handler's defect: it is also cached, prefetched and retried by
-- things that have nothing to do with security.
local SAFE = { GET = true, HEAD = true, OPTIONS = true }

local DEFAULTS = {
  cookie  = "akkar_csrf",
  header  = "x-csrf-token",
  field   = "_csrf",
  -- Must match `akkar.session`'s cookie name, because that is what tells this
  -- module a request is cookie-authenticated at all.
  session_cookie = "akkar_session",
  ttl     = 12 * 60 * 60,
}

-- ================================================================ the token

--- Mints a token bound to `binding`.
---
--- `binding` is whatever identifies the caller this token is for -- the
--- session cookie value, by default. It is HMAC'd rather than stored, so
--- verifying costs one HMAC and no lookup, which is the same argument
--- `akkar.session` makes for signing its cookie: a forged value is refused by
--- arithmetic instead of by a round trip to the store.
---
--- The separator is `|`, which cannot appear in either half: the nonce is hex
--- and the binding is a cookie value. Without a separator that cannot occur,
--- `nonce="ab", binding="cd"` and `nonce="abc", binding="d"` would sign the
--- same bytes -- an ambiguity that is worth nothing to an attacker here and is
--- still not a habit to have.
function M.issue(secret, binding)
  local nonce = crypto.token(16)
  return nonce .. "." ..
         crypto.to_hex(crypto.hmac(secret, nonce .. "|" .. (binding or "")))
end

--- True when `token` was minted by us for `binding`.
---
--- Constant time, through `akkar.crypto.equal`. A CSRF token is compared on
--- every unsafe request and an attacker may retry freely, which is exactly the
--- shape `==` leaks a prefix through.
function M.valid(secret, token, binding)
  if type(token) ~= "string" then return false end
  local nonce, signature = token:match "^(%x+)%.(%x+)$"
  if not nonce then return false end
  local expected = crypto.to_hex(crypto.hmac(secret, nonce .. "|" ..
                                             (binding or "")))
  return crypto.equal(expected, signature)
end

-- =============================================================== middleware

--- Reads the presented token from the header, then from the body.
---
--- The header first because that is the case that matters: only same-origin
--- script can set it, which is the property the whole mechanism rests on. The
--- body field is for a plain HTML form, which has no script to set a header,
--- and it is only as good as the form being same-origin -- which it is,
--- because the token in it was rendered by us.
local function presented(req, options)
  local value = req.headers[options.header]
  if type(value) == "string" and value ~= "" then return value end
  local body = req.body
  if type(body) == "table" then
    local field = body[options.field]
    if type(field) == "string" and field ~= "" then return field end
  end
  return nil
end

--- Is this request authenticated by a cookie, and therefore forgeable?
---
--- Three questions, in the order that costs least, and every one of them
--- answered from the request's own headers so that no middleware ordering can
--- change the answer.
local function cookie_authenticated(req, cookies, options)
  -- A caller who sent `Authorization` chose to. `evil.example` cannot make a
  -- victim's client add that header, so there is nothing here to forge.
  if type(req.headers["authorization"]) == "string" then return false end
  if type(req.headers[options.key_header]) == "string" then return false end

  -- No session cookie means nothing ambient is authenticating this request,
  -- so there is no privilege for a forged request to borrow. This is the
  -- clause that keeps an unauthenticated POST -- a signup, a contact form --
  -- from being refused for want of a token it was never given.
  return cookies[options.session_cookie] ~= nil
end

--- Builds the middleware.
---
---     app:use(akkar.csrf { secret = os.getenv "CSRF_SECRET" })
---
--- Options: `secret` (required), `cookie`, `header`, `field`,
--- `session_cookie`, `key_header`, `ttl`, `applies`, `bind`.
---
--- `applies(req)` replaces the built-in "is this cookie-authenticated" test
--- for an application whose auth does not look like akkar's. Returning false
--- exempts the request entirely.
function M.new(options)
  options = options or {}

  local secret = options.secret
  if type(secret) ~= "string" or #secret < 32 then
    -- The same refusal, and the same reasoning, as `akkar.session`: a signing
    -- key somebody typed by hand is a signing key an attacker guesses, and a
    -- guessable key here lets them mint tokens bound to the victim's session,
    -- which is the one thing the binding exists to prevent.
    error("akkar.csrf: `secret` must be a string of at least 32 bytes; " ..
          "generate one with akkar.crypto.token(32) and keep it out of the " ..
          "source", 0)
  end

  local settings = {
    cookie         = options.cookie or DEFAULTS.cookie,
    header         = (options.header or DEFAULTS.header):lower(),
    field          = options.field or DEFAULTS.field,
    session_cookie = options.session_cookie or DEFAULTS.session_cookie,
    key_header     = (options.key_header or "x-api-key"):lower(),
    ttl            = options.ttl or DEFAULTS.ttl,
  }

  local akkar = require "akkar"

  return function(req, next)
    local cookies = session.parse_cookies(req.headers["cookie"])

    -- The binding, read straight from the Cookie header rather than from
    -- `req.session`. `req.session` exists only after `akkar.auth` has run, so
    -- depending on it would make the strength of this protection depend on
    -- `app:use` order -- and a binding that silently became empty is a
    -- protection that silently became plain double-submit.
    local binding = options.bind and options.bind(req)
                    or cookies[settings.session_cookie] or ""

    local applies = options.applies and options.applies(req)
                    or (options.applies == nil and
                        cookie_authenticated(req, cookies, settings))

    if not SAFE[req.method] and applies then
      local from_cookie = cookies[settings.cookie]
      local from_client = presented(req, settings)

      if not from_cookie or not from_client then
        return akkar.response(403, {
          error = "this request needs a csrf token",
          hint = "read the " .. settings.cookie .. " cookie and send it back " ..
                 "in the " .. settings.header .. " header. Requests " ..
                 "authenticated with Authorization or an api key do not " ..
                 "need one.",
        })
      end

      -- BOTH CHECKS, AND THEY FAIL INDEPENDENTLY.
      --
      -- The equality is the double-submit half: the value had to be read from
      -- a cookie by same-origin script, which a cross-site page cannot do.
      --
      -- The signature is the half that survives a planted cookie. An attacker
      -- who can set a cookie on the parent domain -- from a subdomain, a
      -- proxy, or an XSS on a sibling host -- can make the two values equal
      -- trivially, by choosing both. They cannot make either one verify
      -- against the VICTIM'S session, because the binding is in the HMAC and
      -- the key is not theirs.
      if not crypto.equal(from_cookie, from_client) then
        return akkar.response(403, {
          error = "the csrf token does not match the one in the cookie",
        })
      end
      if not M.valid(secret, from_client, binding) then
        return akkar.response(403, {
          error = "the csrf token is not valid for this session",
          hint = "a token minted before you logged in stops working when the " ..
                 "session id rotates; fetch a page and try again",
        })
      end
    end

    -- Published so a template can render it into a hidden input, and so a
    -- handler can hand it to a single-page app in a login response body --
    -- which is the way around the one-Set-Cookie-per-response limit described
    -- at the top of this file.
    local current = cookies[settings.cookie]
    local fresh = M.valid(secret, current, binding) and current
                  or M.issue(secret, binding)
    req.csrf_token = fresh

    local res = next(req)

    -- Issue the cookie when the caller does not already hold a valid one, and
    -- only on a safe method -- see the header comment for why this file does
    -- not contend for `set-cookie` with `akkar.session`.
    if SAFE[req.method] and fresh ~= current then
      -- NORMALISED FIRST, BECAUSE MIDDLEWARE SITS ABOVE NORMALISATION.
      --
      -- What comes back from `next` is whatever the handler literally
      -- returned: a bare `{ ok = true }` with no `status`, no `body` and no
      -- `headers`. `akkar.auth` records the debugging session this cost --
      -- copying those fields off a bare table produced three nils carrying a
      -- cookie, akkar normalised THAT into a 200 whose body was the copy, and
      -- the body and the header both vanished silently.
      local normalised = res
      if type(res) ~= "table" or res.__response ~= true then
        normalised = akkar.response(res == nil and 204 or 200, res)
      end

      -- A COPY, NEVER A MUTATION. A handler may return a hoisted or memoised
      -- table -- a constant 404, a cached payload -- and writing onto it hands
      -- one request's `Set-Cookie` to every other request that reaches the
      -- same handler. `akkar.etag`, `akkar.limit` and `akkar.auth` were each
      -- fixed for exactly this, and a stray CSRF cookie is the mild version of
      -- the defect whose severe version is a stray session cookie.
      local headers = {}
      for name, value in pairs(normalised.headers or {}) do
        headers[name] = value
      end

      if headers["set-cookie"] == nil then
        headers["set-cookie"] = session.cookie_header(settings.cookie, fresh, {
          max_age = settings.ttl,
          path = options.path,
          domain = options.domain,
          -- NOT HttpOnly, on purpose: the page's own script has to read this
          -- to echo it back, and the token grants nothing by itself.
          http_only = false,
          secure = options.secure ~= false,
          -- Strict rather than Lax. This cookie is never needed on a request
          -- arriving from somewhere else -- by definition, since a request
          -- from somewhere else is the one being refused.
          same_site = options.same_site or "Strict",
        })
      end

      local copy = akkar.response(normalised.status, normalised.body, headers)
      copy.raw, copy.stream, copy.release =
        normalised.raw, normalised.stream, normalised.release
      copy.content_type = normalised.content_type
      copy.__pending = normalised.__pending
      return copy
    end

    return res
  end
end

M.SAFE = SAFE
M.DEFAULTS = DEFAULTS

return M
