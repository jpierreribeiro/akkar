# akkar.session

Server-side sessions behind a signed, opaque cookie. The cookie carries
`<id>.<hmac>`; the data lives in `req.cache` under `session:<id>`.

**When you need it.** A browser, a human, and a login that has to survive the
next request and be revocable on the one after that. For scripts and machine
callers, see [akkar.auth](auth.md).

```lua no-run
local session = require "akkar.session"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`manager:open`](#manageropencache-cookie_header) | method |
| [`session.cookie_header`](#sessioncookie_headername-value-options) | function |
| [`session.new`](#sessionnewoptions) | function |
| [`session.parse_cookies`](#sessionparse_cookiesheader) | function |
| [`session.Session`](#session) | metatable |
| [`session.Store`](#store) | metatable |
| [`Session:all`](#sessionall) | method |
| [`Session:commit`](#sessioncommit) | method |
| [`Session:destroy`](#sessiondestroy) | method |
| [`Session:get`](#sessiongetkey) | method |
| [`Session:regenerate`](#sessionregenerate) | method |
| [`Session:set`](#sessionsetkey-value) | method |
| [`Store.new`](#storenewcache-options) | function |
| [`Store:destroy`](#storedestroyid) | method |
| [`Store:key`](#storekeyid) | method |
| [`Store:load`](#storeloadid) | method |
| [`Store:save`](#storesaveid-data) | method |

## session.cookie_header(name, value, options)

Renders one `Set-Cookie` value. Used by `Session:commit`, and exported because
[akkar.csrf](csrf.md) issues its own cookie with it.

| field | type | default | meaning |
|---|---|---|---|
| `options.path` | string | `"/"` | `Path=` |
| `options.max_age` | number | omitted | `Max-Age=`, floored. `0` is written, not skipped |
| `options.domain` | string | omitted | `Domain=` |
| `options.http_only` | boolean | on | `HttpOnly` is written unless this is exactly `false` |
| `options.secure` | boolean | on | `Secure` is written unless this is exactly `false` |
| `options.same_site` | string | `"Lax"` | `SameSite=` |

**Returns** the header value as a string. The three protective attributes
default on: an option nobody sets is the option everybody gets.

```lua
local session = require "akkar.session"

print(session.cookie_header("akkar_session", "abc", { max_age = 3600 }))
print(session.cookie_header("readable", "abc", { http_only = false,
                                                same_site = "Strict" }))
```

## session.new(options)

Builds a session manager. One manager is made at startup and reused; it holds
the signing secret and the cookie settings, and it holds no per-request state.

| field | type | default | meaning |
|---|---|---|---|
| `secret` | string | required | the HMAC signing key, at least 32 bytes |
| `cookie` | string | `"akkar_session"` | the cookie name |
| `ttl` | number | `1209600` (two weeks) | cookie `Max-Age` and the store's expiry, in seconds |
| `path` | string | `"/"` | cookie `Path` |
| `domain` | string | none | cookie `Domain` |
| `same_site` | string | `"Lax"` | cookie `SameSite` |
| `http_only` | boolean | `true` | set to `false` to drop `HttpOnly`, which a session cookie should not do |
| `secure` | boolean | `true` | set to `false` to drop `Secure` |
| `prefix` | string | `"session:"` | prefix for the cache keys |

**Returns** the manager, which has one method, `manager:open`.

**Raises** when `secret` is not a string of at least 32 bytes:
`akkar.session: `secret` must be a string of at least 32 bytes; generate one
with akkar.crypto.token(32) and keep it out of the source`. The length is
checked in bytes, so `crypto.token(32)` (64 hex characters) passes comfortably.

```lua
local session = require "akkar.session"
local crypto  = require "akkar.crypto"

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
  ttl    = 60 * 60 * 24,
}
print(type(sessions.open))

local ok, why = pcall(session.new, { secret = "hunter2" })
print(ok, why)
```

## session.parse_cookies(header)

Splits a `Cookie:` request header into a table of name to value. Values are not
unescaped and not validated.

**Returns** a table. An absent or non-string header gives an empty table, never
`nil`.

```lua
local session = require "akkar.session"

local cookies = session.parse_cookies "akkar_session=abc; theme=dark"
print(cookies.akkar_session, cookies.theme)
print(next(session.parse_cookies(nil)))     --> nil
```

## Manager

The object `session.new` returns.

### manager:open(cache, cookie_header)

Loads the session for one request. Called for you by
[`auth.middleware`](auth.md#authmiddlewareoptions) when `sessions` is
configured.

| argument | type | meaning |
|---|---|---|
| `cache` | table | a cache capability: `get`, `set(key, value, ttl)`, `del`. `req.cache` |
| `cookie_header` | string | the raw `Cookie:` header, or nil |

**Returns** a Session, always. There is no failure path a caller has to handle:
a missing cookie, a cookie whose signature does not verify, an id with nothing
behind it in the store, and state the store cannot decode all produce a fresh
empty session with a **new** random id. The presented id is never reused, because
accepting an attacker-supplied id for an empty session is session fixation with
extra steps.

The cache is not touched unless the cookie's signature verified, so a forged
cookie costs one HMAC rather than a round trip to Redis.

## Session

The per-request object `manager:open` returns. akkar puts it on `req.session`.

### Session:all()

**Returns** the underlying data table, by reference. Writing to it does not mark
the session dirty, so `commit` will not save it. Use `Session:set`.

### Session:commit()

Writes the session to the store and renders the cookie.

**Returns** the `Set-Cookie` value, or `nil` when nothing changed. The `nil` is a
correctness property rather than an optimisation: rewriting the cookie on every
response resets its expiry on every poll, and a session that never expires while
a tab is open is a session that outlives the laptop being stolen.

When the session was destroyed, it returns a cookie with `Max-Age=0` and an
empty value and writes nothing to the store. When the id was rotated, the old
key is deleted before the new one is saved.

`auth.middleware` calls this for you and attaches the result to a **copy** of the
response, never to the table the handler returned.

### Session:destroy()

Deletes the session from the store immediately, including the id it was rotated
from, empties the data, and marks it destroyed and dirty so the next `commit`
clears the cookie. Both halves matter: clearing the cookie alone leaves the state
in the store, so a stolen cookie value keeps working after the user pressed log
out.

**Returns** the Session, for chaining.

### Session:get(key)

**Returns** the stored value, or `nil`.

### Session:regenerate()

Issues a new random 32-byte id carrying the same data, and remembers the old one
so `commit` can delete it. Call it at the moment privileges change;
[`auth.login`](auth.md#authloginreq-user_id-extra) already does.

**Returns** the Session, for chaining.

### Session:set(key, value)

Sets a value and marks the session dirty, which is what makes `commit` write.

**Returns** the Session, for chaining.

```lua
local session = require "akkar.session"
local crypto  = require "akkar.crypto"
local cache   = require "akkar.cache.memory"

local sessions = session.new { secret = crypto.token(32) }
local store = cache.new()

-- No cookie: a fresh empty session, and nothing is written.
local first = sessions:open(store, nil)
print("empty commit:", first:commit())     --> nil

first:set("user_id", 1)
local set_cookie = first:commit()
print(set_cookie)

-- The browser sends it back on the next request.
local value = set_cookie:match "^akkar_session=([^;]*)"
local second = sessions:open(store, "akkar_session=" .. value)
print("carried:", second:get "user_id")

-- One byte of the signature changed: a new, empty session.
local forged = sessions:open(store, "akkar_session=" .. value:gsub("%x$", "0"))
print("forged:", forged:get "user_id")     --> nil

second:destroy()
second:commit()
local third = sessions:open(store, "akkar_session=" .. value)
print("after destroy:", third:get "user_id")   --> nil
```

## Store

The cache wrapper a Session holds. Exported as `session.Store` so an application
can reach a session that is not the current request's, for example to log
somebody else out.

`cache` rather than `db` on purpose: a session is expiring key/value data, and
putting it in Postgres makes every request that touches a session a database
round trip. The cost is that a cache flush logs everybody out, which is annoying
and not dangerous.

### Store.new(cache, options)

| field | type | default | meaning |
|---|---|---|---|
| `options.prefix` | string | `"session:"` | key prefix |
| `options.ttl` | number | `1209600` | expiry passed to `cache:set` |

**Returns** a Store.

### Store:destroy(id)

Deletes the key. **Returns** whatever the cache's `del` returns.

### Store:key(id)

**Returns** `prefix .. id`, the cache key.

### Store:load(id)

Reads the key and JSON-decodes it. Undecodable state, and state that does not
decode to a table, is treated as no session rather than raised: raising would
turn one corrupt key into a user who can neither log in nor log out, because
every request would die before reaching a handler.

**Returns** the data table, or `nil`.

### Store:save(id, data)

JSON-encodes `data` and writes it with the store's ttl.

```lua
local session = require "akkar.session"
local cache   = require "akkar.cache.memory"

local store = session.Store.new(cache.new(), { prefix = "ref_session_", ttl = 60 })
print(store:key "abc")

store:save("abc", { user_id = 1 })
print(store:load("abc").user_id)

store:destroy "abc"
print(store:load "abc")            --> nil
```

## What the store holds

Session data goes through `akkar.json` on the way in and on the way out, so what
comes back on the next request is what JSON can represent, not what you put in.
The one that surprises people: a Lua integer returns as a float, so `1` written
on login reads back as `1.0`. It compares equal to `1` in Lua and it is not the
same value in a log line or a JSON response.

Anything JSON cannot encode does not survive a round trip either. Keep sessions
to strings, numbers, booleans and plain tables.

## Not here

**No self-contained token, and no JWT.** From the module's own docstring: "A
signed token that carries its own claims cannot be revoked before it expires, and
revocation is the thing a session most needs." [akkar.jwt](jwt.md) verifies a
token somebody else issued, and it has no `issue` either.

**No `flash`, no `csrf`, no session-scoped helpers beyond get and set.** A flash
message is two lines of `set` and `get` in an application. The CSRF token is a
separate module, [akkar.csrf](csrf.md), because it applies to requests that have
no session at all.

**No way to list or enumerate live sessions.** The store is a cache keyed by id,
and a cache does not offer a scan. To log one person out from elsewhere, hold the
id and call `Store:destroy`.

## See also

- [akkar.auth](auth.md), which opens and commits the session for you and gives
  you `req.auth`
- [akkar.csrf](csrf.md), whose token is bound to this cookie's value and
  therefore stops verifying when `regenerate` runs
- [akkar.crypto](crypto.md), for the `token`, `hmac` and `equal` this is built
  from
- the module source, `akkar/session.lua`, for the argument against JWT at length
