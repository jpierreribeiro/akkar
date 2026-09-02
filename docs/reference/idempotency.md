# akkar.idempotency

Middleware that remembers the response to a request carrying an
`Idempotency-Key` header, so the same request sent twice runs once. Deduplication
at the door, not an idempotent handler.

**When you need it.** When a client retries a `POST` it never got an answer to
(a dropped connection, a proxy timing out) and running the handler a second time
would charge a card twice or create a second row.

```lua no-run
local idempotency = require "akkar.idempotency"
```

The top-level spelling is the constructor, not the module: `akkar.idempotency`
is `idempotency.new`, so `akkar.idempotency { namespace = false }` and
`idempotency.new { ttl = 86400 }` build the same middleware. `fingerprint_of`
and `CLAIM_SCRIPT` are reachable only through `require "akkar.idempotency"`.

## idempotency.CLAIM_SCRIPT

The Redis Lua script that claims, replays or refuses, as a string. Exported so
a test can assert on it. Reading it is not part of using the module.

The whole decision is one script because the retry that matters is the one
arriving while the first request is still running.

```lua
local idempotency = require "akkar.idempotency"
assert(type(idempotency.CLAIM_SCRIPT) == "string")
```

## idempotency.fingerprint_of(req)

Builds the summary of a request that decides whether a reused key names the same
request. It is
`req.method .. " " .. req.path .. " " .. #material .. ":" .. sha256_hex(material)`,
where `material` is `#query .. ":" .. query .. #body .. ":" .. body`, and
`query` and `body` are the canonical encodings of `req.query` and `req.body`, or
`""` for one that is nil. The whole body is hashed, so no part of it is outside
the comparison -- and so is the query string, because `req.path` does not carry
it: `POST /transfers?to=alice` and `POST /transfers?to=bob` with the same body
and the same key are two requests, and the second is answered `422`, not with
alice's stored response. The two parts are length-prefixed so a boundary cannot
slide between them, and a query is a set, so `?a=1&b=2` and `?b=2&a=1` are one
request.

Not a cryptographic hash. It separates an honest client's retry from an honest
client's mistake, and it is not a defence against somebody who already chooses
the key.

**Returns** a string.

**Raises** nothing. An unencodable body falls back to `tostring(req.body)`.

```lua
local idempotency = require "akkar.idempotency"

local print_ = idempotency.fingerprint_of {
  method = "POST", path = "/charges", body = { amount = 100 },
}
assert(print_ ==
  "POST /charges 19:" ..
  "202d200fdbb28db28018dfbe6093c14ba7e5ec289ad46facc6314fc3dfe35170")

-- No body at all still fingerprints -- the material is then `0:0:`.
assert(idempotency.fingerprint_of { method = "POST", path = "/charges" } ==
  "POST /charges 4:" ..
  "390feabc786e369e55b904251d643b52b52b691c60eb74a498ef7c6df993bf12")

-- The query string is part of the request's identity.
local alice = idempotency.fingerprint_of {
  method = "POST", path = "/charges", query = { to = "alice" }, body = { amount = 100 },
}
local bob = idempotency.fingerprint_of {
  method = "POST", path = "/charges", query = { to = "bob" }, body = { amount = 100 },
}
assert(alice ~= bob and alice ~= print_)
```

Two limits used to follow from the shape, and both are gone; they are recorded
here because a reader who learned them elsewhere should know they no longer
hold.

Only the first 512 bytes of the encoded body were compared, so two long bodies
of the same length agreeing on their first 512 bytes were one request -- and
the second was answered with the first's stored response and
`idempotent-replay: true`. The whole body is hashed now, so a difference
anywhere in it is a difference here.

And the encoding's key order was `cjson`'s, which is not stable between
processes, so one body encoded by two workers produced two fingerprints and a
retry landing on the other worker was answered `422`. `canonical` sorts keys,
so it does not.

What remains true is the sentence above: this is not a defence against
somebody who already chooses the key.

## idempotency.new(options)

Builds the middleware.

| field | type | default | meaning |
|---|---|---|---|
| `ttl` | number | `86400` | seconds a stored response stays replayable |
| `lock_ttl` | number | `60` | seconds a claim on a running request lives |
| `prefix` | string | `"akkar:idem:"` | prepended to the key |
| `header` | string | `"idempotency-key"` | the header read, lowercase |
| `methods` | list of string | `{ "POST", "PATCH" }` | methods this applies to, upper-cased |
| `max_bytes` | number | `65536` | largest encoded response body that is stored |
| `required` | boolean | `false` | refuse a covered request that carries no key |
| `cache` | cache | `req.cache` | the store to remember in |

`methods` defaults to the two that HTTP does not already define as idempotent.
`GET`, `HEAD`, `PUT` and `DELETE` are, so they pass straight through.

`lock_ttl` must outlive a request and must not outlive the day. Sixty seconds
against the 30-second default deadline. Raise it if you raised `timeout`: a
claim that expires while its request is still running lets a retry in beside it,
which is the double charge this module prevents.

**Returns** middleware.

**Raises** without a `namespace`. The idempotency key is a header the client
chooses, so one global keyspace lets a tenant replay another tenant's stored
response body; pass `namespace = function(req) return req.tenant.id end`, or
`namespace = idempotency.GLOBAL` (which is `false`) to state that the
application is single-tenant. At request time it raises whatever the store
raises when there is no store configured at all.

A store that cannot answer -- one that cannot run the scripts, or a Redis that
blinked -- gets **503** with `retry-after: 1`, and the handler does not run.
Failing open here would be the double charge this middleware exists to prevent,
so it fails closed and says which guarantee is unavailable.

```lua
local akkar        = require "akkar"
local idempotency  = require "akkar.idempotency"
local memory       = require "akkar.cache.memory"

local app = akkar.new()
app:use(idempotency.new { ttl = 60, namespace = idempotency.GLOBAL })

local runs = 0
app:post("/charges", { body = { amount = "integer" } }, function(req)
  runs = runs + 1
  return akkar.created { id = "ch_1", amount = req.body.amount }
end)

local client = app:test { cache = memory.new() }
local headers = { ["idempotency-key"] = "ref_idem_charge_1" }

local first = client:post("/charges", { body = { amount = 100 }, headers = headers })
assert(first.status == 201)
assert(first.headers["idempotent-replay"] == nil)

local retry = client:post("/charges", { body = { amount = 100 }, headers = headers })
assert(retry.status == 201)
assert(retry.headers["idempotent-replay"] == "true")

assert(runs == 1)                     -- the handler ran once
```

### What happens to each request

| situation | answer |
|---|---|
| method not in `methods` | passes through, nothing stored |
| no key, `required = false` | passes through, nothing stored |
| no key, `required = true` | `400`, body `{ error = "this endpoint requires an idempotency-key header" }` |
| key longer than 255 characters | `400`, body `{ error = "idempotency-key must be at most 255 characters" }` |
| first time this key is seen | the handler runs; a `2xx` is stored for `ttl` |
| repeat, first one still running | `409` with `retry-after: 1` |
| repeat, same key, different body | `422` |
| repeat after completion | the stored status and body, plus `idempotent-replay: true` |
| the handler raised | the claim is released, the error is re-raised |
| the response is streamed | the claim is released, nothing stored |
| the status is not `2xx` | the claim is released, nothing stored |
| the encoded body is over `max_bytes` | the claim is released, a warning is logged, nothing stored |

Only `2xx` is remembered. Caching a `500` would mean the retry, which is the
whole point, could never succeed.

A repeat with the same key and a different body:

```lua
local akkar        = require "akkar"
local idempotency  = require "akkar.idempotency"
local memory       = require "akkar.cache.memory"

local app = akkar.new()
app:use(idempotency.new { namespace = idempotency.GLOBAL })
app:post("/charges", { body = { amount = "integer" } }, function(req)
  return akkar.created { amount = req.body.amount }
end)

local client = app:test { cache = memory.new() }
local headers = { ["idempotency-key"] = "ref_idem_charge_2" }

assert(client:post("/charges", { body = { amount = 100 }, headers = headers }).status == 201)

local wrong = client:post("/charges", { body = { amount = 999 }, headers = headers })
assert(wrong.status == 422)
assert(wrong.body.error ==
       "this idempotency-key was already used for a different request")
```

A repeat while the first is still running:

```lua
local akkar        = require "akkar"
local idempotency  = require "akkar.idempotency"
local memory       = require "akkar.cache.memory"

local app = akkar.new()
app:use(idempotency.new { namespace = idempotency.GLOBAL })

local client
app:post("/charges", function()
  -- Sent from inside the handler, so the first claim is still held.
  local again = client:post("/charges", {
    headers = { ["idempotency-key"] = "ref_idem_charge_3" },
  })
  return { second = again.status, retry_after = again.headers["retry-after"] }
end)

client = app:test { cache = memory.new() }

local res = client:post("/charges", {
  headers = { ["idempotency-key"] = "ref_idem_charge_3" },
})
assert(res.status == 200)
assert(res.body.second == 409)
assert(res.body.retry_after == "1")
```

### A replayed body is the JSON round trip

The response is stored by encoding it and replayed by decoding it, so a replay
is not the table the handler returned. Two consequences:

- a table marked by `json.array` loses the marker, so an empty list replays as
  `{}` rather than `[]`
- an integer comes back as whatever the serializer decodes, which with the
  default is a float

```lua
local akkar        = require "akkar"
local json         = require "akkar.json"
local idempotency  = require "akkar.idempotency"
local memory       = require "akkar.cache.memory"

local app = akkar.new()
app:use(idempotency.new { namespace = idempotency.GLOBAL })
app:post("/tasks", function() return { tasks = json.array {} } end)

local client = app:test { cache = memory.new() }
local headers = { ["idempotency-key"] = "ref_idem_tasks_1" }

local first = client:post("/tasks", { headers = headers })
assert(json.encode(first.body) == '{"tasks":[]}')

local replay = client:post("/tasks", { headers = headers })
assert(replay.headers["idempotent-replay"] == "true")
assert(json.encode(replay.body) == '{"tasks":{}}')     -- the marker did not survive
```

## Not here

- **An idempotent handler.** If the handler charges a card and then crashes
  before returning, the charge happened and nothing here knows. That needs the
  payment processor's own idempotency key underneath this one.
- **A guarantee stronger than the store.** With `akkar.cache.memory` the record
  is per process, so a fleet of six deduplicates six times over, which is not
  deduplication. `akkar.limit.shared(cache)` says which one you have.
- **Storage of a streamed or oversized response.** Both release the claim and
  re-run the handler on a repeat.
- **Key generation.** The client chooses the key.

## See also

- [akkar](akkar.md) for `app:use`, which installs the middleware, and for
  `akkar.idempotency`, the same constructor under its top-level name
- [akkar.limit](limit.md) for `limit.shared`, which answers whether the store is
  shared, and for the same script-evaluation discipline
- [akkar.json](json.md) for the encoding a stored response goes through
- the module source, `akkar/idempotency.lua`, for why there are two ttls
