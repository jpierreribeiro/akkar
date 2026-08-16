# akkar.auth

Decides who the caller is, once, before the handler runs, and puts the answer on
`req.auth`. Three schemes: a session cookie, a bearer token, and an API key.

**When you need it.** Any route that has to know which account is asking. It
answers authentication only; whether that account may do this particular thing
is your `if`, in your handler.

```lua no-run
local auth = require "akkar.auth"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`auth.api_key`](#authapi_keyreq-header_name) | function |
| [`auth.bearer`](#authbearerreq) | function |
| [`auth.compare_key`](#authcompare_keypresented-stored_hash) | function |
| [`auth.generate_key`](#authgenerate_keyprefix) | function |
| [`auth.hash_key`](#authhash_keykey) | function |
| [`auth.login`](#authloginreq-user_id-extra) | function |
| [`auth.logout`](#authlogoutreq) | function |
| [`auth.middleware`](#authmiddlewareoptions) | middleware |
| [`auth.unauthorized`](#authunauthorizedscheme-message) | response |
| [`req.auth`](#what-lands-on-the-request) | request field |
| [`req.auth_scheme`](#what-lands-on-the-request) | request field |
| [`req.session`](#what-lands-on-the-request) | request field |

## auth.api_key(req, header_name)

Pulls an API key out of a request. Looks in `header_name` first, then accepts
`Authorization: ApiKey <key>`, because half the clients in the world put
everything in that header.

| argument | type | default | meaning |
|---|---|---|---|
| `req` | table | required | anything with a `headers` table, or a headers object with a `get` method |
| `header_name` | string | `"x-api-key"` | the header to read |

**Returns** the key as a string, or `nil`. An empty header value is `nil`.

```lua
local auth = require "akkar.auth"

print(auth.api_key { headers = { ["x-api-key"] = "sk_abc" } })
print(auth.api_key { headers = { authorization = "ApiKey sk_abc" } })
print(auth.api_key { headers = { authorization = "Bearer t" } })   --> nil
print(auth.api_key({ headers = { ["x-tenant-key"] = "sk_abc" } }, "x-tenant-key"))
```

## auth.bearer(req)

Pulls a bearer token out of an `Authorization` header. The scheme is matched
case-insensitively, because RFC 7235 says it is and clients send `bearer`,
`Bearer` and occasionally `BEARER`.

**Returns** the token as a string, or `nil` when the header is absent or its
scheme is not bearer. The token is returned exactly as sent; nothing is trimmed
or decoded.

```lua
local auth = require "akkar.auth"

print(auth.bearer { headers = { authorization = "BEARER abc123" } })
print(auth.bearer { headers = { authorization = "Basic dXNlcjpwdw==" } })  --> nil
print(auth.bearer { headers = {} })                                        --> nil
```

## auth.compare_key(presented, stored_hash)

Hashes `presented` and compares it with `stored_hash` through
`akkar.crypto.equal`, in constant time.

**Returns** `true` or `false`. Either argument not being a string is `false`,
not an error, so a missing header does not need guarding first.

```lua
local auth = require "akkar.auth"

local key, hash = auth.generate_key "sk"
print(auth.compare_key(key, hash))          --> true
print(auth.compare_key(key .. "x", hash))   --> false
print(auth.compare_key(nil, hash))          --> false
```

## auth.generate_key(prefix)

Generates an API key and the hash you store for it. The key is 24 bytes of
CSPRNG output as hex, behind `prefix .. "_"`.

| argument | type | default | meaning |
|---|---|---|---|
| `prefix` | string | `"ak"` | the visible marker at the front of the key |

**Returns** two values, `key` and `hash`, in that order. Show the key to the
caller once and store the hash. They are returned as a pair so that whoever
writes `local key, hash = auth.generate_key()` has both names in front of them
and cannot store the wrong one by accident.

The prefix is a security feature as well as a convenience: secret scanners,
GitHub's included, find leaked credentials by pattern, and a key that looks like
any other hex string is a key nobody can detect in a public repository.

```lua
local auth = require "akkar.auth"

local key, hash = auth.generate_key "myapp"
print(key:match "^myapp_%x+$" ~= nil)     --> true
print(#key)                               --> 54
print(key == hash)                        --> false
```

## auth.hash_key(key)

The stored form of an API key: SHA-256, hex-encoded.

A single SHA-256 rather than PBKDF2, and that is deliberate. A key is 24 random
bytes, so there is no dictionary to run against it, and putting 600,000
iterations on a hot request path would be paying for a defence that is not
needed. A password is not high entropy, which is why
[`crypto.hash_password`](crypto.md#cryptohash_passwordpassword-options) is a
different function.

**Returns** a 64-character hex string.

```lua
local auth = require "akkar.auth"
print(auth.hash_key "sk_example")
print(#auth.hash_key "sk_example")        --> 64
```

## auth.login(req, user_id, extra)

Logs a principal in: rotates the session id first, then records them.

The rotation is not a detail. An attacker who planted a cookie before the login
knows the id afterwards unless it changes at exactly this moment, and making it
one call is how it stops being forgotten.

| argument | type | default | meaning |
|---|---|---|---|
| `req` | table | required | the request, which must carry `req.session` |
| `user_id` | any | required | stored under the key `user_id` |
| `extra` | table | `{}` | further key/value pairs written into the session |

**Returns** `req.session`. It also sets `req.auth = { user_id = user_id }` for
the rest of this request, without waiting for the store.

**Raises** `akkar.auth: login needs a session; configure `sessions` in the
middleware` when `req.session` is nil.

## auth.logout(req)

Destroys the session on the server, if there is one, and clears `req.auth`. The
cookie is cleared by the `commit` the middleware does on the way out.

**Returns** nothing. A request with no session is not an error.

```lua
local akkar   = require "akkar"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local crypto  = require "akkar.crypto"
local cache   = require "akkar.cache.memory"

local sessions = session.new { secret = crypto.token(32) }

local app = akkar.new()
app:use(auth.middleware { sessions = sessions, optional = true })

app:post("/login", function(req)
  auth.login(req, 1, { email = "ada@example.com" })
  return { ok = true }
end)

app:get("/me", function(req)
  if not req.auth then return akkar.unauthorized "log in first" end
  return { user_id = req.auth.user_id }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return { ok = true }
end)

local client = app:test { cache = cache.factory() }

print("anonymous:", client:get("/me").status)                --> 401

local login = client:post "/login"
local cookie = login.headers["set-cookie"]:match "^([^;]*)"
print("me:", client:get("/me", { headers = { cookie = cookie } }).status)

client:post("/logout", { headers = { cookie = cookie } })
print("after logout:", client:get("/me", { headers = { cookie = cookie } }).status)
```

## auth.middleware(options)

Builds the middleware. Every scheme is optional; the ones you configure are the
ones that run, in the order session, bearer, key. The first that produces a
principal wins and the rest are not tried, because a request carrying both a
cookie and a key is ambiguous and picking one deterministically beats merging
them.

| field | type | default | meaning |
|---|---|---|---|
| `sessions` | manager | none | an [`akkar.session`](session.md) manager. Opened only when `req.cache` is present |
| `load_session` | function | none | `f(req, session)` returning the principal. Replaces the built-in read of `user_id` |
| `bearer` | function | none | `f(req, token)` returning a principal, or nil |
| `keys` | function | none | `f(req, key)` returning a principal, or nil |
| `key_header` | string | `"x-api-key"` | passed to `auth.api_key` |
| `optional` | boolean | `false` | true lets an unauthenticated request through with `req.auth` nil |
| `message` | string | `"unauthorized"` | the `error` field of the 401 body |

A resolver returns any truthy value as the principal, or `nil` to decline. With
`sessions` and no `load_session`, the principal is `{ user_id = session:get
"user_id" }` when the session holds one.

**Returns** a middleware function for `app:use`.

When nothing produced a principal and `optional` is not true, it answers 401
without calling the handler. The `WWW-Authenticate` header advertises the
strongest scheme configured: `Cookie` when `sessions` is set, otherwise
`Bearer`, so a browser is not told to send a bearer token it does not have.

On the way out, if a session was opened and it changed, `Session:commit` is
called and the `Set-Cookie` is attached to a **copy** of the response. Never to
the table the handler returned: a hoisted or memoised response is shared between
requests, so writing onto it hands one user's session to another.

```lua
local akkar = require "akkar"
local auth  = require "akkar.auth"
local cache = require "akkar.cache.memory"

local KEYS = {}
local key, hash = auth.generate_key "sk"
KEYS[hash] = { account = "acme" }

local app = akkar.new()
app:use(auth.middleware {
  bearer = function(_, token)
    if token == "a-good-token" then return { user_id = 7 } end
  end,
  keys = function(_, presented)
    for stored, principal in pairs(KEYS) do
      if auth.compare_key(presented, stored) then return principal end
    end
  end,
})
app:get("/who", function(req)
  return { scheme = req.auth_scheme, account = req.auth.account or req.auth.user_id }
end)

local client = app:test { cache = cache.factory() }

local refused = client:get "/who"
print(refused.status, refused.headers["www-authenticate"])

print(client:get("/who", { headers = { authorization = "Bearer a-good-token" } }).body.scheme)
print(client:get("/who", { headers = { ["x-api-key"] = key } }).body.account)
print(client:get("/who", { headers = { ["x-api-key"] = "sk_wrong" } }).status)
```

## auth.unauthorized(scheme, message)

The 401 this module answers with. Note the argument order: the **scheme comes
first**, unlike `akkar.unauthorized(message)`, which takes only a message.

| argument | type | default | meaning |
|---|---|---|---|
| `scheme` | string | `"Bearer"` | the `WWW-Authenticate` value |
| `message` | string | `"unauthorized"` | the `error` field of the body |

**Returns** a real `akkar.response`, marked `__response`. That matters more than
it looks: a bare `{ status = 401, ... }` table is treated by akkar as a JSON
body, so it becomes a **200 whose body is the word "401"**, and an integration
testing `if res.status == 200` reads a refused request as an accepted one. This
module's first version had that bug.

`WWW-Authenticate` is not decoration. It is what tells a client which scheme to
try, and omitting it is why so many integrations guess.

```lua
local auth = require "akkar.auth"

local res = auth.unauthorized("Bearer", "token expired")
print(res.status, res.body.error, res.headers["www-authenticate"])
print(auth.unauthorized().headers["www-authenticate"])   --> Bearer
```

## What lands on the request

| field | set when | value |
|---|---|---|
| `req.auth` | a resolver produced a principal | whatever it returned |
| `req.auth_scheme` | the same | `"session"`, `"bearer"` or `"api_key"` |
| `req.session` | `sessions` is configured and `req.cache` is present | the Session, whether or not anybody is logged in |

`req.session` exists for an anonymous visitor too. It is an empty session with a
fresh id that is never written, because nothing marked it dirty.

If `sessions` is configured and `cache` is not passed to `app:run{}` or
`app:test{}`, the session block still runs, because the unconfigured `req.cache`
is a guard object rather than nil. Nothing fails until the store is actually
touched, which is the first login or logout, and then it raises `req.cache is not
configured; pass cache = ... to app:run{}`.

## Not here

**No authorization: no roles, no permissions, no policy language, no
`require_admin`.** From the module's own docstring, authorization "is application
logic, it depends on your resources and your rules, and a framework that guesses
at it produces a permission model nobody can read". What akkar gives you is
`req.auth`, populated and trustworthy, and the `if` is yours. For the tenant half
of the same problem, which is mechanical enough to automate, see
[akkar.scope](scope.md).

**No password handling.** Signing up, checking a password and rate limiting a
login are application code. See
[`crypto.hash_password`](crypto.md#cryptohash_passwordpassword-options) and
[akkar.limit](limit.md).

## See also

- [akkar.session](session.md), for the cookie and the store this opens
- [akkar.scope](scope.md), for keeping one account's rows away from another's
  once you know who is asking
- [akkar.csrf](csrf.md), which is what a cookie-authenticated write still needs
- the module source, `akkar/auth.lua`, for why an API key is the scheme most
  integrations actually use
