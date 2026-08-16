# akkar.storage

Object storage over HTTP against anything S3-compatible: S3, R2, B2, Spaces,
MinIO, Garage. Four object operations, a presigned URL builder, and the AWS
Signature Version 4 machinery underneath them, all exported.

**When you need it.** Your application accepts uploads and has to put them
somewhere, or hands a browser a URL that uploads or downloads directly without
the bytes passing through this process. It adds no dependency: the transport is
`akkar.http` and the arithmetic is `akkar.crypto`.

```lua no-run
local storage = require "akkar.storage"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`storage.EMPTY_SHA256`](#storageempty_sha256) | constant |
| [`storage.Store`](#store) | metatable |
| [`storage.UNSIGNED`](#storageunsigned) | constant |
| [`storage.authority_of`](#storageauthority_ofendpoint) | function |
| [`storage.canonical_headers`](#storagecanonical_headersheaders) | function |
| [`storage.canonical_query`](#storagecanonical_queryquery) | function |
| [`storage.canonical_request`](#storagecanonical_requestrequest) | function |
| [`storage.connect`](#storageconnectconfig) | function |
| [`storage.encode_key`](#storageencode_keykey) | function |
| [`storage.hex_sha256`](#storagehex_sha256data) | function |
| [`storage.parse_endpoint`](#storageparse_endpointendpoint) | function |
| [`storage.presign_query`](#storagepresign_queryrequest-credentials) | function |
| [`storage.sign`](#storagesignrequest-credentials) | function |
| [`storage.signing_key`](#storagesigning_keysecret-date-region-service) | function |
| [`storage.uri_encode`](#storageuri_encodetext-encode_slash) | function |
| [`Store:address`](#storeaddresskey) | method |
| [`Store:call`](#storecallmethod-key-options) | method |
| [`Store:delete`](#storedeletekey-options) | method |
| [`Store:get`](#storegetkey-options) | method |
| [`Store:head`](#storeheadkey-options) | method |
| [`Store:presign`](#storepresignmethod-key-options) | method |
| [`Store:put`](#storeputkey-body-options) | method |

## storage.EMPTY_SHA256

The hex SHA-256 of the empty string,
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. It is the
payload hash of every request with no body.

## storage.UNSIGNED

The string `UNSIGNED-PAYLOAD`. The payload hash a presigned URL carries,
because the body of an upload that has not happened yet cannot be hashed.

## storage.authority_of(endpoint)

The authority exactly as lua-http will write it, given a table from
`storage.parse_endpoint`.

**Returns** `host` when the port is the default for the scheme (443 for
`https`, 80 for `http`), and `host:port` otherwise.

It must match, because `host` is a signed header. Signing `host:443` against a
request that says `host` is a 403 whose message names the signature and not the
cause.

```lua
local storage = require "akkar.storage"

assert(storage.authority_of(storage.parse_endpoint "https://s3.example.com")
       == "s3.example.com")
assert(storage.authority_of(storage.parse_endpoint "http://127.0.0.1:9000")
       == "127.0.0.1:9000")
assert(storage.authority_of(storage.parse_endpoint "https://s3.example.com:443")
       == "s3.example.com")
```

## storage.canonical_headers(headers)

Lowercases each name, trims each value and collapses its internal runs of
whitespace to one space, then sorts by name.

**Returns** two values: the canonical header block, which ends with a newline
of its own, and the signed-header list, lowercase and semicolon-joined.

The trailing newline is not optional. The blank line that separates the block
from the signed-header list comes from the join in
`storage.canonical_request`, so there are two newlines in a row and neither can
be dropped.

```lua
local storage = require "akkar.storage"

local block, signed = storage.canonical_headers {
  ["Host"] = "s3.example.com",
  ["X-Amz-Date"] = "  20130524T000000Z  ",
  ["Content-Type"] = "text/plain",
}
assert(signed == "content-type;host;x-amz-date")
assert(block == "content-type:text/plain\nhost:s3.example.com\nx-amz-date:20130524T000000Z\n")
```

## storage.canonical_query(query)

The canonical query string.

| `query` | result |
|---|---|
| `nil` | `""` |
| a string | returned unchanged, on the caller's word |
| a table of `[key] = value` | each side encoded with slashes escaped, sorted by encoded key then encoded value |
| a list of `{name, value}` pairs | the same, and how duplicate keys or a fixed order are expressed |

A table may mix the two: a numeric key whose value is a table is read as a
pair, anything else as a key and a value.

Every parameter carries an `=`, even when its value is empty. A parameter
written bare signs differently from one written `name=`.

```lua
local storage = require "akkar.storage"

assert(storage.canonical_query { b = "2", a = "" } == "a=&b=2")
assert(storage.canonical_query { { "x", "1" }, { "x", "2" } } == "x=1&x=2")
assert(storage.canonical_query "already=canonical" == "already=canonical")
assert(storage.canonical_query(nil) == "")
```

## storage.canonical_request(request)

The canonical request, as AWS defines it: method, path, canonical query,
canonical header block, signed-header list and payload hash, joined with
newlines.

| field | type | meaning |
|---|---|---|
| `method` | string | used verbatim, and not upper-cased here |
| `path` | string | used verbatim. Encoded but never normalised |
| `query` | table, string or `nil` | passed to `storage.canonical_query` |
| `headers` | table | passed to `storage.canonical_headers` |
| `payload_hash` | string | the hex hash of the bytes on the wire, or `storage.UNSIGNED` |

**Returns** the canonical request and the signed-header list.

**Raises** if `headers` is absent, from indexing `nil` inside
`canonical_headers`.

## storage.connect(config)

Builds a `Store` and returns a factory that answers it, matching `db.connect`,
`redis.connect` and `http.connect`.

| field | type | default | meaning |
|---|---|---|---|
| `endpoint` | string | required | `scheme://host[:port][/prefix]` |
| `bucket` | string | required | the bucket name |
| `access_key` | string | required | |
| `secret_key` | string | required | |
| `region` | string | `"us-east-1"` | goes in the credential scope |
| `service` | string | `"s3"` | goes in the credential scope |
| `session_token` | string | none | sent as `x-amz-security-token`, and as `X-Amz-Security-Token` in a presigned URL |
| `path_style` | boolean | `true` | `false` selects virtual-host addressing |
| `http` | client | a new one | a connected `akkar.http` client, shared across every call |
| `timeout` | number | `30` | seconds, used only when building the default client |
| `max_body` | number | `67108864` | bytes, used only when building the default client |

Path style is the default because it is the one thing every S3-compatible
server agrees on. Virtual-host style needs DNS entries nobody made, and breaks
TLS hostname matching for a bucket whose name contains a dot.

The client is shared because the connection pool lives on it, and injectable
because a spec needs a transport it can watch.

**Returns** a function of no arguments that returns the same `Store` every
time.

**Raises** `akkar.storage: an endpoint is required`,
`akkar.storage: a bucket is required`,
`akkar.storage: access_key and secret_key are required`, and whatever
`storage.parse_endpoint` refused with.

```lua
local storage = require "akkar.storage"

local connect = storage.connect {
  endpoint = "https://s3.amazonaws.com",
  bucket = "examplebucket",
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}
local store = connect()
assert(connect() == store)          -- the same store, every time
assert(store.region == "us-east-1")
assert(store.path_style == true)
```

## storage.encode_key(key)

Encodes an object key as a canonical S3 path: every segment between slashes is
percent-encoded, the slashes are not.

**Returns** a string.

Not normalised. `a//b` and `a/./b` are different objects to S3, so collapsing
them, which every generic URL library does, would sign a path other than the
one requested.

```lua
local storage = require "akkar.storage"

assert(storage.encode_key "/test$file.text" == "/test%24file.text")
assert(storage.encode_key "photos/my cat.jpg" == "photos/my%20cat.jpg")
assert(storage.encode_key "a//b" == "a//b")
```

## storage.hex_sha256(data)

The hex SHA-256 of `data`. `nil` is hashed as the empty string.

**Returns** a 64 character lowercase hex string.

```lua
local storage = require "akkar.storage"
assert(storage.hex_sha256 "" == storage.EMPTY_SHA256)
assert(storage.hex_sha256(nil) == storage.EMPTY_SHA256)
assert(#storage.hex_sha256 "hello" == 64)
```

## storage.parse_endpoint(endpoint)

Splits `scheme://host[:port][/prefix]` into its parts.

**Returns** `{ scheme = ..., host = ..., port = ..., prefix = ... }`. The port
defaults to 443 for `https` and 80 for anything else. A `prefix` of exactly
`/` becomes the empty string; any other path is kept as written, leading slash
included.

**Returns `nil` and a reason** for `the endpoint needs a scheme: <endpoint>`.

```lua
local storage = require "akkar.storage"

local parsed = storage.parse_endpoint "https://s3.example.com/base"
assert(parsed.scheme == "https")
assert(parsed.host == "s3.example.com")
assert(parsed.port == 443)
assert(parsed.prefix == "/base")

assert(storage.parse_endpoint("s3.example.com") == nil)
local _, why = storage.parse_endpoint "s3.example.com"
assert(why == "the endpoint needs a scheme: s3.example.com")
```

## storage.presign_query(request, credentials)

The query parameters of a presigned URL, signature included. Makes no request.

Takes the same `request` fields as `storage.sign`, without `payload_hash`,
which is always `storage.UNSIGNED`, plus:

| field | type | default | meaning |
|---|---|---|---|
| `expires` | number | `3600` | seconds, written into `X-Amz-Expires` |

The caller's `request.query` is copied, then `X-Amz-Algorithm`,
`X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires`, `X-Amz-SignedHeaders` and,
where there is a `session_token`, `X-Amz-Security-Token` are added. The result
is signed, and `X-Amz-Signature` is added to the same table afterwards.

Note the default here is 3600 seconds, and `Store:presign`'s is 900. A caller
reaching this function directly does not get the shorter one.

**Returns** the query table and the full signing result from `storage.sign`.
Feed the table to `storage.canonical_query` to build the URL.

```lua
local storage = require "akkar.storage"

local query = storage.presign_query({
  method = "GET",
  path = "/examplebucket/test.txt",
  headers = { host = "s3.amazonaws.com" },
  expires = 86400,
  amzdate = "20130524T000000Z",
}, {
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
})

assert(query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256")
assert(query["X-Amz-Expires"] == "86400")
assert(query["X-Amz-SignedHeaders"] == "host")
assert(#query["X-Amz-Signature"] == 64)
```

## storage.sign(request, credentials)

Signs a request. Touches nothing on the network.

| `request` field | type | default | meaning |
|---|---|---|---|
| `method` | string | required | |
| `path` | string | required | already encoded, never normalised |
| `query` | table or string | `nil` | |
| `headers` | table | required | |
| `payload_hash` | string | required | |
| `amzdate` | string | now, as `!%Y%m%dT%H%M%SZ` | accepted directly so a test can pin the clock |
| `timestamp` | number | `time.now()` | used only when `amzdate` is absent |

| `credentials` field | type | default |
|---|---|---|
| `access_key` | string | required |
| `secret_key` | string | required |
| `region` | string | `"us-east-1"` |
| `service` | string | `"s3"` |

**Returns** a table:

| field | meaning |
|---|---|
| `amzdate` | the timestamp used, which is what must go in the `x-amz-date` header |
| `scope` | `<date>/<region>/<service>/aws4_request` |
| `signed_headers` | the semicolon-joined list |
| `canonical_request` | the full canonical request |
| `string_to_sign` | the full string to sign |
| `signature` | 64 hex characters |
| `credential` | `<access_key>/<scope>` |
| `authorization` | the complete `Authorization` header value |

`canonical_request` and `string_to_sign` are returned because a signature
mismatch says only "wrong" and those two say where.

```lua
local storage = require "akkar.storage"

-- AWS's own published GET Object example, credentials included.
local signed = storage.sign({
  method = "GET",
  path = "/test.txt",
  headers = {
    ["host"] = "examplebucket.s3.amazonaws.com",
    ["range"] = "bytes=0-9",
    ["x-amz-content-sha256"] = storage.EMPTY_SHA256,
    ["x-amz-date"] = "20130524T000000Z",
  },
  payload_hash = storage.EMPTY_SHA256,
  amzdate = "20130524T000000Z",
}, {
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  region = "us-east-1",
  service = "s3",
})

assert(signed.signature ==
  "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
assert(signed.scope == "20130524/us-east-1/s3/aws4_request")
assert(signed.signed_headers == "host;range;x-amz-content-sha256;x-amz-date")
```

## storage.signing_key(secret, date, region, service)

The four-step SigV4 signing key. Each step's output is the next step's key,
starting from `"AWS4" .. secret` and ending with `"aws4_request"`.

**Returns** raw bytes, not hex.

The literal `AWS4` prefix is part of it and is not a typo. The chain is what
makes a leaked signature useless tomorrow, in another region, for another
service.

```lua
local storage = require "akkar.storage"
local crypto  = require "akkar.crypto"

local key = storage.signing_key(
  "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "20130524", "us-east-1", "s3")
assert(#key == 32)                         -- raw HMAC-SHA256 output
assert(#crypto.to_hex(key) == 64)
```

## storage.uri_encode(text, encode_slash)

RFC 3986 percent-encoding, as SigV4 defines it: a space is `%20` and never
`+`, `~` is left alone, and the hex digits are upper case. `encode_slash` is
false by default, so `/` survives.

**Returns** a string. `text` is passed through `tostring`, so a number is
accepted.

Lowercase hex produces a signature mismatch and no explanation. So does
escaping `~`.

```lua
local storage = require "akkar.storage"

assert(storage.uri_encode "a b~c/d" == "a%20b~c/d")
assert(storage.uri_encode("a b~c/d", true) == "a%20b~c%2Fd")
assert(storage.uri_encode "$" == "%24")
```

## Store

What `storage.connect(config)()` returns. Exported as `storage.Store` for a
caller who wants to extend it. Every method returns a value and a reason
rather than raising, except where noted.

### Store:address(key)

Where an object lives.

**Returns** three values: the host to sign, the canonical path, and the full
URL. The path always has exactly one leading slash, however the pieces fell
out: `//bucket` is a different canonical request from `/bucket`, and since the
path is signed unnormalised the difference is a 403 rather than a redirect.

With `path_style` (the default) the host is the endpoint's authority and the
bucket is the first path segment. Without it the host is
`<bucket>.<authority>` and the bucket is not in the path.

```lua
local storage = require "akkar.storage"

local store = storage.connect {
  endpoint = "https://s3.amazonaws.com",
  bucket = "examplebucket",
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}()

local host, path, url = store:address "photos/cat.jpg"
assert(host == "s3.amazonaws.com")
assert(path == "/examplebucket/photos/cat.jpg")
assert(url == "https://s3.amazonaws.com/examplebucket/photos/cat.jpg")

local virtual = storage.connect {
  endpoint = "https://s3.amazonaws.com",
  bucket = "examplebucket",
  path_style = false,
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}()
local vhost, vpath = virtual:address "photos/cat.jpg"
assert(vhost == "examplebucket.s3.amazonaws.com")
assert(vpath == "/photos/cat.jpg")
```

### Store:call(method, key, options)

Signs one request and sends it. Every other method goes through this.

| `options` field | type | default | meaning |
|---|---|---|---|
| `body` | string | none | hashed and signed, and sets `content-length` |
| `headers` | table | `{}` | names are lowercased, values passed through `tostring` |
| `query` | table or string | none | signed, and appended to the URL in canonical form |
| `timeout` | number | the client's | seconds |
| `max_body` | number | the client's | bytes |

`host` and `x-amz-content-sha256` are set before signing. `x-amz-date` and
`authorization` are set after. `host` is then removed from what is sent, and
kept only in what was signed: lua-http writes the authority itself from the
URL, and a second `host` header on the wire is a request most servers reject.

**Returns** the response, or `nil` and the transport's reason. A non-2xx status
is a returned response, not an error: interpreting it is each method's job.

### Store:delete(key, options)

Deletes an object. `options` is passed straight to `Store:call`.

**Returns** `true`, or `nil`, a message and a details table.

Idempotent, because S3 is: deleting what is not there answers 204.

### Store:get(key, options)

Fetches an object. `options` is passed straight to `Store:call`, so `headers`
(a `range`, for instance) and `timeout` reach it.

**Returns** the body and the whole response, or `nil`, a message and a details
table.

A missing object is an error value and not an empty body: `no such object:
<key>` with `{ status = 404 }`. An empty object is a thing that exists, and
telling the two apart is the entire question a `get` is asked.

### Store:head(key, options)

**Returns** `true` and the response headers when the object exists, `false`
and nothing when the status is 404, and `nil`, a message and a details table
for any other non-2xx.

Three shapes, and the 404 one returns a single value. `if store:head(key) then`
reads correctly; `local ok, headers = store:head(key)` leaves `headers` as
`nil` on a miss, which is the same as a hit with no headers.

### Store:presign(method, key, options)

A URL that works on its own for `expires` seconds. Makes no request, and can be
called on a machine with no route to the store at all.

| `options` field | type | default | meaning |
|---|---|---|---|
| `expires` | number | `900` | seconds |
| `query` | table | none | extra parameters, signed along with the rest |
| `timestamp` | number | now | |
| `amzdate` | string | from `timestamp` | pins the clock |

`method` is upper-cased, and defaults to `GET` when `nil`.

**Returns** the URL, as one string.

The default of fifteen minutes is deliberately short. A presigned URL is a
bearer credential in a string that ends up in a log, a referrer header and
somebody's chat history. AWS's own ceiling is seven days; nothing here defaults
near it.

```lua
local storage = require "akkar.storage"

local store = storage.connect {
  endpoint = "https://s3.amazonaws.com",
  bucket = "examplebucket",
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}()

local url = store:presign("PUT", "uploads/report.pdf", {
  expires = 300,
  amzdate = "20130524T000000Z",
})

assert(url:find("https://s3.amazonaws.com/examplebucket/uploads/report.pdf?", 1, true) == 1)
assert(url:find("X-Amz-Expires=300", 1, true))
assert(url:find("X-Amz-Signature=", 1, true))
```

### Store:put(key, body, options)

Stores an object.

| `options` field | type | default | meaning |
|---|---|---|---|
| `content_type` | string | `"application/octet-stream"` | wins over a `content-type` in `headers` |
| `headers` | table | `{}` | copied, then the content type is applied |
| `timeout` | number | the client's | seconds |

**Returns** `true` and the response's `etag`, or `nil`, a message and a details
table.

**Raises** `akkar.storage: a body must be a string`. This is the one method
here that raises on a bad argument.

Note that `options.query` and `options.max_body` are not forwarded: `put`
builds its own options table for `Store:call` from `headers`, `body` and
`timeout` only.

### The error value

Every non-2xx that is not a 404 answered by `get` or `head` comes back the same
way: `nil`, a message, and a details table.

| details field | meaning |
|---|---|
| `status` | the HTTP status |
| `code` | the `<Code>` element of the S3 error document, or `nil` |
| `message` | the `<Message>` element, or `nil` |
| `body` | the whole body, untouched |

The message reads `<Code>: <Message>`, falling back to
`HTTP <status>: the store refused the request`.

The two elements are pulled out with a pattern rather than a parser.
Adding an XML parser to read one element would be a dependency to read one
element, and the full body is in `details.body` for anything the pattern does
not cover.

## Not here

**Listing a bucket.** Four object operations and a presigned URL. There is no
`list`.

**Multipart upload, and chunked upload signing.** Not implemented. A large
object goes in one request or it does not go.

**Retries.** Whatever the injected `akkar.http` client does, and nothing on top
of it.

**A `new`.** `storage.connect` is the only constructor, and it hands back a
factory rather than the store.

**Verification against a live store.** The signer is checked against all three
of AWS's published worked examples, at the canonical request, the string to
sign and the signature. What that cannot reach is TLS, virtual-host addressing
against real DNS, and the redirect a region mismatch produces.

## See also

- [akkar.http](http.md), which is the transport, and whose client can be
  injected here
- [akkar.crypto](crypto.md), for `sha256`, `hmac` and `to_hex`, which are the
  arithmetic
- `spec/storage_spec.lua`, for the three AWS vectors asserted at three depths
  each
- the module source, `akkar/storage.lua`, for the encoding rules that are
  easiest to get wrong
