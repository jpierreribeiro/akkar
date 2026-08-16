# akkar.http

The outbound HTTP client: a deadline, a response ceiling enforced where the
bytes arrive, a retry policy that knows what is safe to repeat, connection
pooling per origin, and trace propagation. The response is a plain value.

**When you need it.** When a handler has to call another service: a payment
provider, a geocoder, a webhook you send rather than receive. Configure it once
as the `http` capability and handlers use `req.http`.

```lua no-run
local http = require "akkar.http"
```

`http` is one of akkar's five capabilities (`db`, `cache`, `log`, `clock`,
`http`). Pass the factory `http.connect` returns as a field of `app:run{}`:

```lua no-run
http = http.connect { timeout = 5, retries = 2 },
```

The capability contract is `request`, `get` and `post`. The verb helpers are
conveniences over `request`, so an adapter answering only those three is a
valid one, which is what makes a fake possible without reimplementing six
methods that all do the same thing.

## Contents

- [http.Client](#httpclient)
- [http.SAFE_TO_RETRY](#httpsafe_to_retry)
- [http.connect(config)](#httpconnectconfig)
- [The response value](#the-response-value)
- [Request options](#request-options)
- [Client](#client)
  - [client:close()](#clientclose)
  - [client:delete(url, options)](#clientdeleteurl-options)
  - [client:get(url, options)](#clientgeturl-options)
  - [client:head(url, options)](#clientheadurl-options)
  - [client:json(method, url, options)](#clientjsonmethod-url-options)
  - [client:patch(url, options)](#clientpatchurl-options)
  - [client:post(url, options)](#clientposturl-options)
  - [client:put(url, options)](#clientputurl-options)
  - [client:release()](#clientrelease)
  - [client:request(method, url, options)](#clientrequestmethod-url-options)
  - [client:stats()](#clientstats)
- [Not here](#not-here)
- [See also](#see-also)

## http.Client

The metatable every client carries. Exported so a test can check
`getmetatable(req.http) == http.Client`, and so an adapter can borrow a method.
Not something to construct directly; use `http.connect`.

## http.SAFE_TO_RETRY

The set of methods a failed request may be repeated on:
`GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS`, `TRACE`.

`POST` and `PATCH` are absent and that is the point. A retried `POST` is a
second charge, a second email, a second order. A caller who knows their
endpoint is idempotent says so per call with `retry_unsafe = true`.

## http.connect(config)

Builds one client and returns a factory that hands it out. The shape matches
`db.connect` and `redis.connect`, so a capability field is written the same way
for all of them. Every call to the returned function gives back the same
client, so the pools are shared.

| field | type | default | meaning |
|---|---|---|---|
| `headers` | table | none | headers added to every request, before per-call ones |
| `timeout` | number | `10` | seconds for one attempt, covering connect, headers and body |
| `max_body` | number | `8388608` | response ceiling in bytes |
| `retries` | number | `0` | attempts **beyond** the first |
| `retry_backoff` | number | `0.1` | seconds before the first retry, doubling each time |
| `pool_size` | number | `8` | live connections per `scheme://host:port` |
| `reuse` | boolean | `true` | `false` gives a connection per request through the same code path |
| `http_version` | number | none | left unset so lua-http negotiates; pin `1.1` for a peer that mis-advertises h2 |

The pool key comes from the parsed uri, so `http://x/a` and `http://x:80/b`
share a pool and `http://x` and `https://x` never do.

**Returns** a `function() -> client`.

**Raises** nothing. An unknown key in `config` is ignored silently.

```lua
local http = require "akkar.http"

-- `connect` returns a factory. Calling it hands back the one shared client.
local factory = http.connect { timeout = 5, retries = 2, pool_size = 4 }
local client = factory()
print(factory() == client)          --> true

local stats = client:stats()
print(stats.stale_reused, stats.retried_stale, next(stats.origins))
--> 0   0   nil

client:release()          -- a no-op, kept so `req.http` has the same shape
client:close()            -- idempotent
client:close()
```

## The response value

Every successful call returns a table with three fields and nothing else.
Nothing is mutated and nothing is streamed, for the same reason handlers return
instead of writing: a value can be logged, retried and asserted on.

| field | type | meaning |
|---|---|---|
| `status` | number | the numeric status |
| `headers` | table | lowercase name to value; a **repeated** header becomes a list, because `set-cookie` legitimately repeats |
| `body` | string | the whole body, always a string, never `nil` |

Pseudo-headers (`:status` and friends) are not in `headers`. An informational
`1xx` response is skipped and the next set of headers is read, except `101`,
which is final and is handed back as-is.

## Request options

The `options` table accepted by every call.

| field | type | default | meaning |
|---|---|---|---|
| `headers` | table | none | per-call headers; names are lowercased, values are `tostring`ed, and these override the client's `headers` |
| `body` | string or table | none | a table is JSON-encoded and sets `content-type: application/json` |
| `timeout` | number | the client's | seconds for one attempt |
| `max_body` | number | the client's | response ceiling for this call |
| `retries` | number | the client's | attempts beyond the first |
| `retry_backoff` | number | the client's | seconds before the first retry |
| `retry_unsafe` | boolean | `false` | allow retrying a `POST` or `PATCH` |
| `traceparent` | string | none | sent as the `traceparent` header |

`content-length` is set from the body and no `expect: 100-continue` is ever
generated. That header is what `request:set_body` in lua-http appends above
1024 bytes, and it cost a measured 1.005 s and a `408` on a two-thousand-byte
body against akkar's own server.

## Client

### client:close()

Closes every pooled connection and drops the pools. Idempotent.

**Returns** nothing.

### client:delete(url, options)

`client:request("DELETE", url, options)`.

### client:get(url, options)

`client:request("GET", url, options)`.

### client:head(url, options)

`client:request("HEAD", url, options)`.

### client:json(method, url, options)

Makes a request and decodes the body as JSON.

**Returns** `decoded, res` on success, where `res` is the full response value,
or `nil, message` on failure. Note that the second return means two different
things depending on the first, so test the first return rather than the second.

The failure messages: whatever `client:request` failed with, `empty body` when
the body is `""` (which includes every legitimate `204`), and
`response was not JSON: ...`.

### client:patch(url, options)

`client:request("PATCH", url, options)`. Not retried unless
`retry_unsafe = true`.

### client:post(url, options)

`client:request("POST", url, options)`. Not retried unless
`retry_unsafe = true`.

### client:put(url, options)

`client:request("PUT", url, options)`.

### client:release()

A no-op. Kept rather than deleted because `req.http` is handed to handlers the
way `req.db` is, and a capability whose release the caller has to remember is a
capability that leaks. Here there is nothing to remember. Connections go back
to their pool on every path inside the client, including the failing ones.

**Returns** nothing.

### client:request(method, url, options)

Makes a request. `method` is upper-cased. This is the whole contract; the verb
helpers above are one line each.

Retries, in the order they apply:

- `retries` is silently reduced to `0` for a method not in `SAFE_TO_RETRY`
  unless `retry_unsafe` is set. Not an error: the request still happens once,
  because refusing outright would make `retries` a setting nobody could apply
  globally.
- a `5xx` is retried; a `4xx` never is, because the server telling you the
  request was wrong will tell you again.
- the backoff before attempt `n` is `retry_backoff * 2^n`.
- separately from `retries`, one failed attempt on a **reused** pooled
  connection is repeated once on a fresh one, and only for a repeatable method.
  The liveness probe cannot be atomic with the write, so a connection can die in
  that gap.

**Returns** a response value, or `nil, reason`. The reasons are strings and
include `"timed out reading the response body"`,
`"response exceeded max_body of N bytes"`, `"the pooled connection was closed"`,
`"the pool for KEY kept returning connections the peer had closed"`, and
whatever lua-http reported for a failed connect, write or header read. A
response over `max_body` is **refused, not truncated**: a truncated body is
indistinguishable from a complete one at the call site.

**Raises** nothing on a network failure. It returns `nil` and a reason.

```lua
local akkar = require "akkar"
local http  = require "akkar.http"

-- The retry policy, as a table you can read.
print(http.SAFE_TO_RETRY.GET, http.SAFE_TO_RETRY.POST)   --> true   nil

-- A fake standing in for the capability. `req.http` needs `request`, `get`
-- and `post`; the other verbs are conveniences over `request`.
local fake = {}
function fake:request(method, url, options)
  return { status = 200, headers = {}, body = '{"rate":0.91}' }
end
function fake:get(url, options)  return self:request("GET", url, options)  end
function fake:post(url, options) return self:request("POST", url, options) end

local app = akkar.new()

app:get("/rate", function(req)
  local res, why = req.http:get "https://example.test/rates/eur"
  if not res then return akkar.unavailable(why) end
  return { body = res.body, status = res.status }
end)

local client = app:test { http = fake }
local answer = client:get "/rate"
print(answer.status, answer.body.body)
--> 200   {"rate":0.91}
```

The examples on this page never reach the network. A real call looks like this:

```lua no-run
local res, why = req.http:post("https://api.example.com/charges", {
  headers = { ["authorization"] = "Bearer " .. token },
  body    = { amount = 500, currency = "eur" },
  timeout = 3,
})
if not res then
  return akkar.unavailable("the payment provider did not answer: " .. why)
end
if res.status >= 400 then
  return akkar.bad_request("the payment provider refused it")
end
```

### client:stats()

What the pools are doing, per origin rather than as one total: a single number
cannot say whether one host is saturated or every host is idle, and those want
opposite responses.

**Returns** `{ stale_reused = n, retried_stale = n, origins = { ["scheme://host:port"] = pool_stats } }`.
`stale_reused` counts connections taken out of the idle set because they were
dead; `retried_stale` counts requests repeated on a fresh connection after a
reused one failed.

## Not here

- **Redirect following.** The client drives the stream itself rather than going
  through `request:go()`, so a `301` or `302` is returned to you as a response
  value with a `location` header. Follow it yourself if you want it followed.
- **A cookie jar.** Nothing is stored between calls. `set-cookie` arrives as a
  header (a list when it repeats) and is yours to handle.
- **Streaming a request or a response body.** Both are strings. The response
  ceiling is `max_body` and it refuses rather than truncates.
- **A circuit breaker, or per-host rate limiting.** [limit](limit.md) is the
  inbound half and has no outbound counterpart.
- **Option-name checking.** Unknown keys in `config` and in a call's `options`
  are ignored silently, unlike `app:run{}`.
- **`client:acquire`, `client:attempt`, `client:pool_for`.** They are on
  `http.Client` and they are internal. Their signatures change without notice.

## See also

- [akkar](akkar.md) for how a capability is configured and how `req.http`
  reaches a handler
- [pool](pool.md), whose `pool:stats()` is what appears under `origins`
- the module source, `akkar/http.lua`, for the two defects found while building
  the pool (a body read with no timeout, and a fixed second per body over 1 KiB)
  and for what pooling is measured to be worth
