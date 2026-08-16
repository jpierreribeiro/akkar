# akkar.etag

Conditional requests over HTTP entity tags. It tags successful responses,
answers `304` to a client that already holds the current version, and refuses a
write whose `If-Match` no longer matches with `412`.

**When you need it.** Two clients read the same record, both edit it, both save,
and the second write silently overwrites the first with no error anywhere. This
module turns that into a `412` the second client can see.

```lua no-run
local etag = require "akkar.etag"
```

`akkar.etag` is `etag.new` and `akkar.etag_of` is `etag.of`, so the middleware
is reachable without a second `require`.

## etag.canonical(value)

Encodes `value` as JSON with object keys sorted. `pairs()` has no defined order
in Lua, so plain encoding of one table can produce different bytes on different
runs and therefore different tags. Arrays and empty tables encode as `[]`.

**Returns** a string.

## etag.fnv1a(s)

FNV-1a over `s`, 64-bit, formatted as 16 lowercase hex digits. Not a
cryptographic hash and not meant to be one.

**Returns** a string of 16 characters.

## etag.matches(header, tag)

Tests one `If-Match` or `If-None-Match` header value against one tag. `*`
matches anything. A comma-separated list is split and each candidate is
trimmed. A weak validator (`W/"x"`) never matches, because RFC 7232 forbids
using one for a conditional write.

**Returns** a boolean.

## etag.new(options)

Middleware. Checks preconditions before the handler runs and tags the response
after it returns.

| field | type | default | meaning |
|---|---|---|---|
| `require_on` | list of strings | `{}` | methods that must carry `If-Match`; a request without one answers `428` |
| `current` | function(req) | none | reads the resource as it is now, so its tag can be compared against `If-Match` |

Method names in `require_on` are upper-cased, so `{ "put" }` and `{ "PUT" }`
are the same list. `GET` and `HEAD` are treated as safe and skip every
precondition check.

`current` is required in practice, not only when you want strictness. When
`If-Match` is present and no `current` is configured, the current tag is `nil`
and the request is refused with `412` whatever the client sent, including
`If-Match: *`. Configure `current` on any route reachable by a conditional
write.

Behaviour, in the order the middleware applies it:

- unsafe method, listed in `require_on`, no `If-Match`: `428` with body
  `{ error = "this request requires an if-match header", hint = "read the resource first and send the etag it returned" }`
- unsafe method with `If-Match` that does not match `etag.of(current(req))`:
  `412` with body `{ error = "the resource has changed since you read it" }`
- handler runs; a response with status 200 to 299 and a non-nil `body` gets an
  `etag` header
- safe method whose `If-None-Match` matches that tag: `304` with the `etag`
  header and no body

The tagged response is a copy. The table the handler returned is never
mutated, so a handler that returns a hoisted or memoised response does not
leak one request's tag into another's answer.

**Returns** a `function(req, next)`.

```lua
local akkar = require "akkar"

local document = { title = "the plan" }

local app = akkar.new()

app:use(akkar.etag {
  require_on = { "PUT" },
  current = function() return document end,
})

app:get("/document", function() return document end)

app:put("/document", { body = { title = "string" } }, function(req)
  document = { title = req.body.title }
  return document
end)

local client = app:test {}

local read = client:get "/document"
local tag = read.headers["etag"]

-- The same version again: 304, and no body.
local again = client:get("/document", { headers = { ["if-none-match"] = tag } })
print(again.status)                                   --> 304

-- A write with no `if-match`, on a method named in `require_on`.
print(client:put("/document", { body = { title = "a new plan" } }).status)
--> 428

-- A write carrying a tag that is no longer current.
print(client:put("/document", {
  body = { title = "a new plan" },
  headers = { ["if-match"] = '"0000000000000000"' },
}).status)                                            --> 412

-- A write carrying the tag the read returned.
print(client:put("/document", {
  body = { title = "a new plan" },
  headers = { ["if-match"] = tag },
}).status)                                            --> 200
```

## etag.of(body)

The tag for a response body: `canonical` then `fnv1a`, wrapped in double
quotes because RFC 7232 defines an entity-tag as a quoted string.

**Returns** a quoted 16-hex-digit string, or `nil` when `body` is `nil` or when
encoding it raises. `etag.of` never raises.

```lua
local etag = require "akkar.etag"

print(etag.canonical { b = 2, a = 1 })    --> {"a":1,"b":2}
print(etag.of { a = 1, b = 2 })           --> "a0ebc03bdc71de7b"
print(etag.of { b = 2, a = 1 })           --> "a0ebc03bdc71de7b"
print(etag.of(nil))                       --> nil

local tag = etag.of { a = 1 }
print(etag.matches("*", tag))             --> true
print(etag.matches('"x", ' .. tag, tag))  --> true
print(etag.matches("W/" .. tag, tag))     --> false
```

## Not here

- **A row version.** The tag is derived from the response body, so two edits
  that produce the same body are indistinguishable and an A-then-B-then-A
  sequence can let a stale write through. The strong form is a version column
  the database increments inside the same transaction as the write, and only
  the application knows which column that is.
- **Option-name checking.** `etag.new` reads the two fields above and ignores
  everything else, so a misspelled option is silent.
- **`If-Match` on a safe method.** `GET` and `HEAD` skip the precondition
  branch entirely.
- **File tags.** `akkar.static` computes its own tags from `mtime` and size.
  See [static](static.md).

## See also

- [akkar](akkar.md) for `app:use`, `akkar.response` and `app:test`
- [compress](compress.md), which renames the tag when it encodes a body,
  and must be registered outside this middleware
- the module source, `akkar/etag.lua`, for why 428 is treated as the line
  between a feature and an invariant
