# akkar.csrf

Middleware that refuses a cookie-authenticated write which did not carry a token
the calling page had to read first. Double submit, with the token bound to the
session by an HMAC.

**When you need it.** A browser posts to your API with a session cookie. Requests
carrying `Authorization` or an API key are exempt, and that is a correctness
requirement rather than a convenience: an attacker's page cannot make a victim's
`curl` add a header, so there is no ambient credential to ride on.

```lua no-run
local csrf = require "akkar.csrf"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`csrf.DEFAULTS`](#csrfdefaults) | table |
| [`csrf.issue`](#csrfissuesecret-binding) | function |
| [`csrf.new`](#csrfnewoptions) | middleware |
| [`csrf.SAFE`](#csrfsafe) | table |
| [`csrf.valid`](#csrfvalidsecret-token-binding) | function |
| [`req.csrf_token`](#csrfnewoptions) | request field |

## csrf.DEFAULTS

The default names and the default cookie lifetime, as a table: `cookie`,
`header`, `field`, `session_cookie`, `ttl`. Exported so a test or a frontend
build can read the names rather than repeat them.

`session_cookie` must match [`akkar.session`](session.md)'s cookie name, because
that is what tells this module a request is cookie-authenticated at all.

**Returns** a table.

```lua
local csrf = require "akkar.csrf"

for _, name in ipairs { "cookie", "header", "field", "session_cookie", "ttl" } do
  print(name, csrf.DEFAULTS[name])
end
```

## csrf.issue(secret, binding)

Mints a token bound to `binding`. The token is `nonce . HMAC(secret, nonce ..
"|" .. binding)`, where the nonce is 16 bytes of hex.

`binding` is whatever identifies the caller this token is for. The middleware
passes the victim's session cookie value, which is what makes a planted token
useless: an attacker's token is bound to the attacker's session, so it does not
verify against the victim's.

| argument | type | default | meaning |
|---|---|---|---|
| `secret` | string | required | the HMAC key |
| `binding` | string | `""` | what the token is bound to. `nil` is treated as `""` |

**Returns** the token as a string. It carries no expiry of its own: see `ttl` on
`csrf.new`.

```lua
local csrf   = require "akkar.csrf"
local crypto = require "akkar.crypto"

local token = csrf.issue(crypto.token(32), "session-abc")
print(token:match "^%x+%.%x+$" ~= nil)     --> true
print(#token)                              --> 97
```

## csrf.valid(secret, token, binding)

True when `token` was minted by `issue` under the same `secret` and `binding`.
The comparison runs through `akkar.crypto.equal`, in constant time, because a
CSRF token is compared on every unsafe request and an attacker may retry freely.

**Returns** `true` or `false`. A `token` that is not a string, or that does not
match `^(%x+)%.(%x+)$`, is `false` rather than an error.

There is no time check here. A token stays valid for as long as its binding does,
which in practice is until the session id rotates.

```lua
local csrf   = require "akkar.csrf"
local crypto = require "akkar.crypto"

local SECRET = crypto.token(32)

local token = csrf.issue(SECRET, "session-abc")
print(csrf.valid(SECRET, token, "session-abc"))     --> true

-- Bound to one session, worthless against another. This is the line that
-- makes it more than plain double submit.
print(csrf.valid(SECRET, token, "session-xyz"))     --> false
print(csrf.valid(crypto.token(32), token, "session-abc"))   --> false
print(csrf.valid(SECRET, "not a token", "session-abc"))     --> false
```

## csrf.new(options)

Builds the middleware.

| field | type | default | meaning |
|---|---|---|---|
| `secret` | string | required | the HMAC key, at least 32 bytes |
| `cookie` | string | `"akkar_csrf"` | the cookie the token is delivered in |
| `header` | string | `"x-csrf-token"` | the header the page echoes it in. Lowercased |
| `field` | string | `"_csrf"` | the body field a plain HTML form uses instead |
| `session_cookie` | string | `"akkar_session"` | the cookie whose presence means "authenticated by a cookie", and whose value is the binding |
| `key_header` | string | `"x-api-key"` | a request carrying this is exempt. Lowercased |
| `ttl` | number | `43200` (12 hours) | the cookie's `Max-Age`. Not a token lifetime |
| `applies` | function | none | `f(req)` replacing the built-in test. Returning false exempts the request entirely |
| `bind` | function | none | `f(req)` returning the binding, for an application whose session is not akkar's |
| `path` | string | none | passed to the cookie |
| `domain` | string | none | passed to the cookie |
| `secure` | boolean | `true` | `Secure` unless exactly `false` |
| `same_site` | string | `"Strict"` | Strict rather than Lax: this cookie is never needed on a request arriving from somewhere else, by definition |

**Returns** a middleware function for `app:use`.

**Raises** `akkar.csrf: `secret` must be a string of at least 32 bytes; generate
one with akkar.crypto.token(32) and keep it out of the source` when the secret is
short or missing. A guessable key here lets an attacker mint tokens bound to the
victim's session, which is the one thing the binding exists to prevent.

Two things it sets on every request, refused or not:

- **`req.csrf_token`**, so a template can render it into a hidden input and a
  handler can hand it to a single page application in a login response body. The
  existing cookie value is reused when it is still valid for this binding;
  otherwise a fresh one is minted.
- **the `akkar_csrf` cookie**, but only on a response to a safe method, and only
  when the response does not already carry a `set-cookie`. akkar writes one
  `Set-Cookie` per response, and [`akkar.auth`](auth.md) owns that slot on any
  response that commits a session. So a login POST keeps its session cookie and
  the GET after it collects a CSRF token.

The cookie is deliberately **not** `HttpOnly`. The page's own script has to read
the value and echo it in a header, which is the whole mechanism. A CSRF token
authenticates nobody on its own, and an XSS that can read it has already won by
other means.

```lua
local akkar  = require "akkar"
local csrf   = require "akkar.csrf"
local crypto = require "akkar.crypto"

local SECRET = crypto.token(32)

local app = akkar.new()
app:use(csrf.new { secret = SECRET })
app:get("/page", function(req) return { token = req.csrf_token } end)
app:post("/transfer", function() return { moved = true } end)

local client = app:test {}

-- A safe request collects the cookie. The token is bound to the session
-- cookie the browser was already carrying, so send that here too.
local session_cookie = "akkar_session=abc"
local page = client:get("/page", { headers = { cookie = session_cookie } })
local cookie = page.headers["set-cookie"]:match "^akkar_csrf=([^;]*)"
print("issued:", cookie == page.body.token)

-- A cookie-authenticated write with no token is refused.
local refused = client:post("/transfer", {
  headers = { cookie = session_cookie .. "; akkar_csrf=" .. cookie },
  body = {},
})
print("no header:", refused.status, refused.body.error)

-- The same write, echoing the cookie in the header, is allowed.
local allowed = client:post("/transfer", {
  headers = {
    cookie = session_cookie .. "; akkar_csrf=" .. cookie,
    ["x-csrf-token"] = cookie,
  },
  body = {},
})
print("with header:", allowed.status)

-- An api key request is exempt: nothing ambient authenticates it.
print("api key:", client:post("/transfer", {
  headers = { ["x-api-key"] = "sk_whatever" }, body = {},
}).status)
```

## csrf.SAFE

The methods that are never checked, as a set: `GET`, `HEAD`, `OPTIONS`.

`OPTIONS` is in the list because a CORS preflight is sent by the browser before
the real request and cannot carry a token; rejecting it would break the very
request the preflight was clearing.

A handler that mutates state on `GET` is outside what this can protect, and that
is the handler's defect: such a route is also cached, prefetched and retried by
things that have nothing to do with security.

**Returns** a table.

```lua
local csrf = require "akkar.csrf"

local methods = {}
for name in pairs(csrf.SAFE) do methods[#methods + 1] = name end
table.sort(methods)
print(table.concat(methods, " "))     --> GET HEAD OPTIONS
```

## When the middleware applies

A request is checked when **both** are true: the method is not in `csrf.SAFE`,
and the request looks cookie-authenticated. The second is three questions,
answered from the request's own headers:

1. no `Authorization` header, and
2. no `key_header`, and
3. a `session_cookie` is present.

The test is made on the headers deliberately, and never on `req.auth_scheme`.
Reading what `akkar.auth` decided would make this protection depend on middleware
order, and CSRF silently switching itself off because somebody reordered two
`app:use` lines is the worst failure this file could have.

Question 3 is also what keeps an unauthenticated POST, a signup or a contact
form, from being refused for want of a token it was never given.

`options.applies(req)` replaces all three. It is read as an `if` rather than an
`and`/`or` chain, so returning `false` genuinely exempts the request instead of
falling through to the built-in test.

The token reads the header first and the body field second. The header is the
case that matters, because only same-origin script can set one. The body field is
for a plain HTML form, which has no script, and it is only as good as the form
being same-origin, which it is, because the token in it was rendered by you.

## The three refusals

All are `403` with a real `akkar.response`.

| body | when |
|---|---|
| `this request needs a csrf token` (with a `hint` naming the cookie and the header) | the cookie or the presented value is missing |
| `the csrf token does not match the one in the cookie` | they differ. The double-submit half |
| `the csrf token is not valid for this session` (with a `hint`) | the HMAC does not verify against this binding. The half that survives a planted cookie |

Both checks are run, because they fail independently. The equality covers the
case where there is no session yet and the binding is empty; the signature covers
a cookie an attacker planted on the parent domain, where they chose both values
and equality passes trivially.

The third refusal has a consequence worth planning for.
`Session:regenerate()` issues a new id on login, which **changes the binding**, so
a token minted before the login stops verifying after it. A client that logs in
and immediately POSTs, with no navigation in between, is refused once. A browser
navigates, and a script uses an API key and is exempt.

## Not here

**No synchronizer token.** Nothing is stored server-side, and there is no list of
outstanding tokens to check against or revoke. From the module's own docstring:
akkar's session store is a cache which may be flushed, "a flush would then
invalidate every outstanding form as well as every session, and it adds a store
round trip to every page render". The HMAC binding buys the property the stored
copy would have, for one hash and no lookup.

**No token expiry.** `ttl` is the cookie's `Max-Age` and nothing more;
`csrf.valid` does not look at the clock. What ends a token's life is the binding
changing, which happens on login.

**No Origin or Referer check.** The binding is what this module relies on. A
header check would be a second mechanism with its own list of browsers that omit
the header, and `applies` is where an application adds one if it wants it.

## See also

- [akkar.session](session.md), whose cookie value is the binding and whose
  `regenerate` invalidates outstanding tokens
- [akkar.auth](auth.md), for why an API key request is exempt, and for the one
  `Set-Cookie` slot the two modules share
- the module source, `akkar/csrf.lua`, for the attack and for why plain double
  submit is not enough
