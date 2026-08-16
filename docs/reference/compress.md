# akkar.compress

Response compression: content negotiation, the `Vary` header, a size threshold,
a content-type allowlist and the ETag rename. Everything a compressing server
has to get right except the compression itself, which the application supplies.

**When you need it.** When nothing in front of akkar compresses for you: a
container speaking HTTP straight to the edge, a proxy that cannot see the body,
or a generated response large enough that shrinking it at the source saves the
copy. If nginx or a CDN terminates TLS in front of akkar, configure compression
there and do not register this middleware.

```lua no-run
local compress = require "akkar.compress"
```

There is no `akkar.compress` on the `akkar` table. Register the middleware as
`app:use(compress.new { ... })`.

## There is no compressor in this module

`compress.new` raises unless you pass at least one encoder, and akkar ships
none. An encoder is a `function(bytes) -> bytes`.

```lua no-run
encoders = { gzip = function(bytes) return my_gzip(bytes) end },
```

The reason is in `akkar/compress.lua`: no zlib binding is installed or
declarable as a dependency here, and a hand-rolled deflate on the hot path of
every response is a worse answer than saying so. The failure of getting it
subtly wrong is a body no client can read.

## Ordering: register this first

```lua no-run
app:use(compress.new { encoders = encoders })   -- outermost
app:use(akkar.etag { require_on = { "PUT" } })
```

`build_chain` in `akkar/init.lua` wraps from the last registration inwards, so
`middleware[1]` is outermost and sees the response last. Compression has to be
the last transformation applied to a body: a compressed response no longer has
a `body`, it has `raw` bytes, and [etag](etag.md) registered outside this one
would tag nothing and quietly stop answering `304`. Nothing raises.

## compress.accepted(header)

Parses an `Accept-Encoding` header into a table of `token = qvalue`. A missing
`q` parameter is `1`. A `q` that will not parse is also `1`, so one unparseable
parameter cannot disable compression for that client. Tokens are lowercased.

**Returns** a table. An empty table for a `nil` or empty header.

## compress.compressible(content_type)

The default allowlist test. The type is taken from before the first `;`, so
`application/json; charset=utf-8` is recognised. Matching is on an exact list,
the prefix `text/`, and the structured suffixes `+json` and `+xml`.

The exact list is `application/json`, `application/javascript`,
`application/xml`, `application/xhtml+xml`, `application/rss+xml`,
`application/atom+xml`, `application/wasm`, `image/svg+xml` and
`application/x-ndjson`.

**Returns** a boolean. `false` for `nil`.

## compress.merge_vary(existing)

Adds `Accept-Encoding` to a `Vary` header without destroying what is already
there. Returns `existing` unchanged when it already lists `Accept-Encoding`,
compared case-insensitively and with surrounding whitespace trimmed.

**Returns** a string.

## compress.negotiate(header, available, prefer)

Picks an encoding. `available` is a set of names you hold a codec for, `prefer`
is the server's tie-break order as a list. The chosen encoding is the one in
`prefer` with the highest acceptable q, and `*` supplies the q for a token the
client did not name.

An absent or empty `header` returns `nil`, which means send it as it is. RFC
9110 permits reading an absent header as "anything goes"; doing that would send
gzip to a client that never advertised it, so it is not done here. `q=0` is
"not acceptable", which is what makes `identity;q=0` and `*;q=0` work.

**Returns** an encoding name, or `nil`.

```lua
local compress = require "akkar.compress"

local q = compress.accepted "gzip, deflate;q=0.5, *;q=0"
print(q.gzip, q.deflate, q["*"])                 --> 1   0.5   0

print(compress.compressible "application/json; charset=utf-8")  --> true
print(compress.compressible "image/svg+xml")                    --> true
print(compress.compressible "image/png")                        --> false

local available = { gzip = true, deflate = true }
print(compress.negotiate("gzip, deflate", available, { "br", "gzip", "deflate" }))
--> gzip
print(compress.negotiate("identity", available, { "gzip" }))    --> nil
print(compress.negotiate(nil, available, { "gzip" }))           --> nil

print(compress.merge_vary "Origin")     --> Origin, Accept-Encoding
print(compress.merge_vary(nil))         --> Accept-Encoding

local ok, message = pcall(compress.new, {})
print(ok)                               --> false
print(message)
```

## compress.new(options)

Middleware.

| field | type | default | meaning |
|---|---|---|---|
| `encoders` | table of `name = function(bytes)` | none, required | the codecs you hold; the name is what goes in `Content-Encoding` |
| `min_size` | number | `1024` | bodies smaller than this are never compressed |
| `prefer` | list of strings | `{ "br", "gzip", "deflate" }` | server tie-break order when the client is indifferent |
| `compressible` | function(content_type) | `compress.compressible` | replaces the allowlist test |
| `on_error` | function(err, req) | none | called when an encoder raises or returns a non-string |

The body it considers is `res.raw` if present, otherwise `akkar.json.encode(res.body)`,
under `res.content_type` or `application/json`. That mirrors exactly what the
writer in `akkar/init.lua` puts on the wire.

`Vary: Accept-Encoding` is added to responses this middleware weighed up and
declined to compress, not only to the ones it compressed. Without it a shared
cache stores whichever representation it saw first under a key that does not
mention the encoding.

Passed through with `Vary` added, and nothing else:

- a streamed response (`res.stream`), because a `function(bytes) -> bytes`
  codec cannot encode a stream incrementally
- a response that already carries `Content-Encoding`
- a payload shorter than `min_size`
- no acceptable encoding for this client
- an encoder that raised, or returned a non-string, or produced output at least
  as long as its input

Passed through completely untouched, with no `Vary` either:

- status `204`, `304`, or below `200`
- a content type the `compressible` test rejects, such as `image/png`
- a nil `res.body` with no `res.raw`, a body that will not JSON-encode, or a
  payload that is not a string

An encoder failure never becomes a `500`. It fails open: the client gets a
correct, larger answer, and `on_error` is called if you supplied one.

When it does compress, the response is a **copy**. `content-encoding` is set,
`vary` is merged, `release` and `__pending` travel with it, and an existing
`etag` gets the encoding appended inside the quotes (`"abc"` becomes
`"abc-gzip"`), because the encoded bytes are a different representation and
shipping both under one tag is the oldest bug in HTTP compression.

**Returns** a `function(req, next)`.

**Raises** at registration, not at runtime:

- `akkar.compress needs encoders = { gzip = function(bytes) ... end }; akkar
  ships no compressor ...` when `encoders` is missing or empty
- `akkar.compress: encoder 'NAME' is a TYPE, not a function(bytes)` when a
  value in `encoders` is not a function

```lua
local akkar    = require "akkar"
local compress = require "akkar.compress"

-- A stand-in codec, so this page runs anywhere. A real deployment names the
-- encoder `gzip` and passes a real gzip; akkar ships none.
local function squash(bytes)
  return (bytes:gsub("aaaa+", "~"))
end

local app = akkar.new()

app:use(compress.new {
  encoders = { squash = squash },
  prefer   = { "squash" },
  min_size = 64,
})

app:get("/report", function()
  return { rows = akkar.array { ("a"):rep(4000) } }
end)

local client = app:test {}

local plain = client:get "/report"
print(plain.status, plain.headers["content-encoding"], plain.headers["vary"])
--> 200   nil   Accept-Encoding

local encoded = client:get("/report", {
  headers = { ["accept-encoding"] = "squash" },
})
print(encoded.status, encoded.headers["content-encoding"], #encoded.raw)
--> 200   squash   14
```

## compress.vary(akkar, res)

Returns a copy of `res` carrying `Vary: Accept-Encoding`, or `res` itself when
the header is already there and nothing needs allocating. The first argument is
the `akkar` module, passed in rather than required at the top of the file to
avoid a require cycle.

**Returns** a response.

## Not here

- **A compressor.** See the section above.
- **Streaming compression.** A streamed response is passed through with `Vary`
  and nothing else. Buffering it to compress it would undo the reason it was
  streamed.
- **Request body decompression.** A request arriving with
  `Content-Encoding: gzip` is not decoded anywhere in akkar.
- **A `206` guard.** A partial response from [static](static.md) is compressed
  like any other, and its `Content-Range` then describes the identity bytes
  while the body is encoded. Set `compressible` to reject the types you serve
  ranges of, or register this middleware only on the routes that need it.
- **Option-name checking.** An unknown key in `options` is ignored silently.

## See also

- [akkar](akkar.md) for `app:use`, `akkar.raw` and `akkar.stream`
- [etag](etag.md), which must be registered inside this middleware
- [static](static.md), whose responses this middleware also sees
- the module source, `akkar/compress.lua`, for the full account of why no gzip
  ships with akkar and why a byte-correct gzip container is a trap
