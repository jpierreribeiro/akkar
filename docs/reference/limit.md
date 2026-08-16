# akkar.limit

Three middlewares that refuse work instead of queueing it: a token bucket on
requests per second, a cap on requests in flight at once, and a shedder that
drops low-priority work when the process is loaded.

**When you need it.** When one caller can send more than the service can serve,
and the answer should be an immediate `429` rather than a slow `200` for
everybody else.

```lua no-run
local limit = require "akkar.limit"
```

`akkar.limit` is this same module table, so `akkar.limit.rate` and
`require("akkar.limit").rate` are the same function.

## Contents

- [limit.concurrent(options)](#limitconcurrentoptions)
- [limit.CONCURRENT_SCRIPT](#limitconcurrent_script)
- [limit.rate(options)](#limitrateoptions)
- [limit.RATE_SCRIPT](#limitrate_script)
- [limit.scriptable(cache)](#limitscriptablecache)
- [limit.shared(cache)](#limitsharedcache)
- [limit.shed(options)](#limitshedoptions)
- [limit.store_failures](#limitstore_failures)
- [Which caller is counted](#which-caller-is-counted)
- [When the store fails](#when-the-store-fails)
- [Response headers](#response-headers)

## limit.concurrent(options)

Middleware capping how many requests one caller may have **in flight** at once.
A slot is taken before the handler runs and given back on every exit, including
a raised error. On a streamed response the slot is held until the last byte is
produced.

| field | type | default | meaning |
|---|---|---|---|
| `limit` | number | `10` | slots one caller may hold at once |
| `ttl` | number | `30` | seconds a slot may be held before it is swept |
| `prefix` | string | `"akkar:concurrent:"` | prepended to the key |
| `key` | function | see below | `key(req)` returns the string to count against |
| `cache` | cache | `req.cache` | the store to count in |
| `retry_after_ms` | number | `1000` | the `retry-after` value on a refusal |
| `on_store_error` | function | none | `on_store_error(err, req)` on a failed store call |

A refusal is `429` with body `{ error = "too many requests", retry_after = 1 }`
and a `retry-after` header. No `ratelimit-*` headers: a concurrency slot comes
back when one of this caller's own requests finishes, which is not a number
this middleware can predict.

`ttl` is the backstop for a slot that is never released, which is what an
abandoned request leaves behind. Entries older than `ttl` are dropped on every
acquire, so a lost release costs one slot for one `ttl` and not for the life of
the process.

**Returns** middleware.

**Raises** at request time, not at construction, when there is no store at all:

```
akkar.limit.concurrent has no cache to count in: pass `cache = ...` to
app:run{} (or `cache = ...` in the limiter's own options). A limiter with no
store cannot limit anything, and quietly allowing every request would hide that.
```

```lua
local akkar  = require "akkar"
local limit  = require "akkar.limit"
local memory = require "akkar.cache.memory"

local app = akkar.new()
app:use(limit.concurrent { limit = 1, key = function() return "one" end })

local client
app:get("/outer", function()
  -- Still inside /outer's handler, so this second request is the same
  -- caller's second slot.
  return { inner = client:get("/inner").status }
end)
app:get("/inner", function() return { ok = true } end)

client = app:test { cache = memory.new() }

local res = client:get "/outer"
assert(res.status == 200)
assert(res.body.inner == 429)          -- the slot was already held

-- The slot came back, so a later request is served.
assert(client:get("/inner").status == 200)
```

## limit.CONCURRENT_SCRIPT

The Redis Lua script `limit.concurrent` runs, as a string. Exported so a test
can assert on it. Reading it is not part of using the module.

```lua
local limit = require "akkar.limit"
assert(type(limit.CONCURRENT_SCRIPT) == "string")
```

## limit.rate(options)

Middleware metering requests per second with a token bucket. A caller may make
a run of `burst` requests, and after that gets `per_second` a second for as long
as it likes.

| field | type | default | meaning |
|---|---|---|---|
| `per_second` | number | `10` | tokens added to the bucket each second |
| `burst` | number | `per_second` | bucket capacity, the largest run allowed |
| `cost` | number | `1` | tokens one request takes |
| `prefix` | string | `"akkar:rate:"` | prepended to the key |
| `key` | function | see below | `key(req)` returns the string to count against |
| `cache` | cache | `req.cache` | the store to count in |
| `headers` | boolean | `true` | send the `ratelimit-*` headers; `false` suppresses them |
| `exempt` | list or `false` | `{ "/health", "/healthz", "/livez", "/readyz" }` | path prefixes that skip the limiter entirely |
| `on_store_error` | function | none | `on_store_error(err, req)` on a failed store call |

`exempt` is a prefix match, checked before the store is touched, so an exempt
path costs no round trip. `exempt = false` turns the exemption off and counts
health probes like everything else. A list replaces the default rather than
adding to it.

A refusal is `429` with body `{ error = "too many requests", retry_after = N }`,
a `retry-after` header, and the quota headers unless `headers = false`.

**Returns** middleware.

**Raises** at request time, not at construction, when there is no store at all:

```
akkar.limit.rate has no cache to count in: pass `cache = ...` to app:run{}
(or `cache = ...` in the limiter's own options). A limiter with no store cannot
limit anything, and quietly allowing every request would hide that.
```

```lua
local akkar  = require "akkar"
local limit  = require "akkar.limit"
local memory = require "akkar.cache.memory"

local app = akkar.new()
app:use(limit.rate {
  per_second = 1,
  burst      = 2,
  key        = function() return "one-caller" end,
})
app:get("/tasks", function() return { ok = true } end)
app:get("/health/live", function() return { ok = true } end)

local client = app:test { cache = memory.new() }

local first = client:get "/tasks"
assert(first.status == 200)
assert(first.headers["ratelimit-limit"] == "2")
assert(first.headers["ratelimit-remaining"] == "1")

assert(client:get("/tasks").status == 200)    -- the burst is spent

local refused = client:get "/tasks"
assert(refused.status == 429)
assert(refused.body.error == "too many requests")
assert(refused.headers["retry-after"] == "1")

-- Health probes are exempt by default, so an orchestrator is never refused.
for _ = 1, 5 do
  assert(client:get("/health/live").status == 200)
end
```

## limit.RATE_SCRIPT

The Redis Lua script `limit.rate` runs, as a string. Exported so a test can
assert on it. Reading it is not part of using the module.

Timestamps inside it come from Redis `TIME`, not from the caller, so a client
with a wrong clock cannot move the window.

```lua
local limit = require "akkar.limit"
assert(type(limit.RATE_SCRIPT) == "string")
```

## limit.scriptable(cache)

Whether the store can run a Lua script at all. Implemented by sending
`EVAL "return 1" 0` inside a `pcall`.

**Returns** `true` or `false`.

**Raises** nothing. A `nil` argument returns `false`.

This is **not** the question to ask before believing a limit is a limit.
`akkar.cache.memory` answers `true` here and is still per process. Use
`limit.shared`.

```lua
local limit  = require "akkar.limit"
local memory = require "akkar.cache.memory"

assert(limit.scriptable(memory.new()) == true)
assert(limit.scriptable(nil) == false)
```

## limit.shared(cache)

Whether the store is shared by every process that talks to it. `false` for
`nil`, `false` for any store declaring `per_process`, otherwise whatever
`limit.scriptable` says.

**Returns** `true` or `false`.

**Raises** nothing.

With a per-process store a fleet of six enforces six times the configured
limit. That is a useful development default and it is not rate limiting.

```lua
local limit  = require "akkar.limit"
local memory = require "akkar.cache.memory"
local redis  = require "akkar.redis"

assert(limit.shared(nil) == false)
assert(limit.shared(memory.new()) == false)   -- counts inside one process

local cache = redis.connect { host = "127.0.0.1", port = 6379 } ()
assert(limit.shared(cache) == true)           -- counts in one place for everybody
cache:close()
```

Against a real Redis the same limiter is a real limit. Note the `prefix`, which
is what the keys are named:

```lua
local akkar = require "akkar"
local limit = require "akkar.limit"
local redis = require "akkar.redis"

local cache = redis.connect { host = "127.0.0.1", port = 6379 } ()

local app = akkar.new()
app:use(limit.rate {
  per_second = 1,
  burst      = 2,
  prefix     = "ref_limit_",
  key        = function() return "demo" end,
})
app:get("/tasks", function() return { ok = true } end)

local client = app:test { cache = cache }
assert(client:get("/tasks").status == 200)
assert(client:get("/tasks").status == 200)
assert(client:get("/tasks").status == 429)

cache:del "ref_limit_demo"
assert(cache:get "ref_limit_demo" == nil)
cache:close()
```

## limit.shed(options)

Middleware refusing non-critical requests once the process is busier than a
fraction of its capacity. It reads `app.in_flight` and never touches the store.

| field | type | default | meaning |
|---|---|---|---|
| `app` | application | required unless `capacity` | read for `in_flight` and `max_concurrent` |
| `capacity` | number | from `app.max_concurrent` | the number `ceiling` is a fraction of |
| `ceiling` | number | `0.8` | shed above this fraction of `capacity` |
| `critical` | function | always false | `critical(req)` returns true for work never shed |
| `retry_after_ms` | number | `1000` | the `retry-after` value on a refusal |

A refusal is `429` with body `{ error = "too many requests", retry_after = 1 }`
and a `retry-after` header. The condition is
`in_flight > capacity * ceiling and not critical(req)`.

`app.in_flight` is maintained by `app:run`. Under `app:test{}` it is never set,
so a shedder given a live app sheds nothing in a test.

**Returns** middleware.

**Raises** at construction, when neither `app` nor `capacity` is given:

```
akkar.limit.shed needs `app = app`, so it can read the in-flight count and the
concurrency ceiling, or an explicit `capacity`. With neither it can never shed.
```

When a capacity cannot be derived at request time, it logs one warning through
`req.log` and passes every request through.

```lua
local akkar = require "akkar"
local limit = require "akkar.limit"

local app = akkar.new()
app:use(limit.shed {
  -- A real application passes `app = app`; this stand-in fixes the
  -- in-flight count so the threshold can be shown.
  app      = { in_flight = 9 },
  capacity = 4,                                  -- 9 > 4 * 0.8
  critical = function(req) return req.path:match "^/payments" ~= nil end,
})
app:get("/reports", function() return { ok = true } end)
app:get("/payments", function() return { ok = true } end)

local client = app:test {}
assert(client:get("/reports").status == 429)     -- shed
assert(client:get("/payments").status == 200)    -- critical, never shed
```

The fleet-wide worker-utilisation shedder is deliberately absent. See
[Not here](#not-here).

## limit.store_failures

A plain number field counting how many store calls have failed, process-wide,
since the process started. Every limiter in the process adds to the same
counter. It is never reset.

Read it into a gauge if you want it on `/metrics`. A rising value means the
configured limits are not being enforced.

```lua
local limit = require "akkar.limit"
assert(type(limit.store_failures) == "number")
```

## Which caller is counted

`rate` and `concurrent` share one default `key`:

1. `"user:" .. req.user.id` when there is an authenticated user
2. `"ip:" .. req.ip` otherwise, or `"ip:unknown"` when `req.ip` is nil

`req.ip` is the socket peer, and honours `X-Forwarded-For` only when the
connection came from a proxy named in `app:run { trusted_proxies = ... }`. A
caller cannot mint a fresh bucket by sending a header.

Never per path. A caller limited per path works through the paths in turn.

Pass `key` to override. The full key sent to the store is `prefix .. key(req)`.

## When the store fails

Every decision is a round trip, and every round trip can fail. When the store
cannot answer, **the request is allowed through**. A reply that is not a table
counts as a failure too.

On each failure:

- `limit.store_failures` goes up by one
- the first failure of an outage is logged at warn through `req.log`, and again
  each time the store recovers and fails afresh
- `on_store_error(err, req)` is called if given, inside a `pcall`

No quota headers go out with a request served this way: the numbers are unknown
and inventing them would be a lie a client would pace itself against.

A store that was never configured is a different failure and **raises** instead.
A limiter with no store cannot limit anything, and allowing every request
quietly would hide that.

## Response headers

`limit.rate` sends three headers on every answer it makes a decision about,
unless `headers = false`:

| header | means |
|---|---|
| `ratelimit-limit` | the bucket's capacity, which is `burst` |
| `ratelimit-remaining` | tokens left after this request |
| `ratelimit-reset` | seconds until the bucket is full again |

`retry-after` is sent only on a `429`, and is the wait for the one token this
request wanted. It is a smaller number than `ratelimit-reset`.

The names are the IETF draft's, not the `X-RateLimit-` spelling.

A header the response already carries wins. The limiter copies the response
rather than writing on it, so a handler returning a hoisted or memoised table
does not have one request's quota read by another.

## Not here

- **A fleet-wide worker-utilisation shedder.** It needs to know how many workers
  across the whole fleet are busy, and akkar has no such number. An
  approximation under the same name would be worse, because it would be trusted.
- **Per-route limits.** Install the middleware on a sub-app, or branch inside a
  middleware of your own on `req.path`.
- **A store.** `limit` counts in whatever `req.cache` is. See
  `akkar.cache.memory` and `akkar.redis`.

## See also

- [akkar](akkar.md) for `app:use`, which installs the middleware this module
  returns, and for `app:run { cache = ... }`, which supplies the store
- [akkar.idempotency](idempotency.md), which uses the same store and the same
  script-evaluation discipline
- the module source, `akkar/limit.lua`, for the measurements that argued for a
  concurrency limit and for why the failure mode is to allow
