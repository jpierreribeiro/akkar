# akkar.multipart

Parses `multipart/form-data`, the encoding a browser uses to send a file. Two
functions, both pure: no filesystem, no network, no state.

**When you need it.** Almost never directly. `akkar/init.lua` calls both
functions when a request arrives with `content-type: multipart/form-data`, so a
handler already receives the parsed fields as `req.body`. Call them yourself
when you hold a multipart body that did not come through a route, such as one
read from a queue or a stored webhook payload.

```lua no-run
local multipart = require "akkar.multipart"
```

A parsed body is an ordinary table, so validation and handlers do not learn a
new shape:

```lua no-run
local title        = req.body.title                 -- a plain field, a string
local filename     = req.body.avatar.filename       -- a file part
local content_type = req.body.avatar.content_type
local data         = req.body.avatar.data
local size         = req.body.avatar.size
```

## multipart.boundary(content_type)

Pulls the boundary out of a `Content-Type` header value. RFC 2046 allows the
boundary to be quoted and browsers differ on whether it is, so both spellings
are accepted; the quoted form is tried first.

**Returns** the boundary string, or `nil` when `content_type` is `nil` or names
no boundary.

## multipart.parse(body, boundary)

Parses a whole multipart body that is already in memory. Parts are walked
delimiter to delimiter with plain (non-pattern) string search, so a boundary
containing characters Lua patterns treat as magic is handled literally.

A part with a `filename` parameter in its `Content-Disposition` becomes a
table:

| field | type | meaning |
|---|---|---|
| `filename` | string | the name as the client sent it, not sanitised |
| `content_type` | string | the part's own `Content-Type`, or `application/octet-stream` |
| `data` | string | the bytes, with the framing CRLF before the next delimiter removed |
| `size` | number | `#data` |

A part without a `filename` becomes a plain string. A part whose
`Content-Disposition` names no `name` is skipped entirely.

**Returns** `fields` on success, or `nil, message`. The messages, in full:

- `multipart body has no boundary` (`boundary` is `nil` or `""`)
- `multipart body has no opening boundary`
- `multipart part has no header block`
- `multipart part is not terminated`
- `multipart body contained no named parts`

It never raises.

```lua
local multipart = require "akkar.multipart"

local content_type = 'multipart/form-data; boundary="--------akkar42"'
local boundary = multipart.boundary(content_type)
print(boundary)                      --> --------akkar42

local CRLF = "\r\n"
local body = table.concat {
  "--", boundary, CRLF,
  'content-disposition: form-data; name="title"', CRLF, CRLF,
  "a cat", CRLF,
  "--", boundary, CRLF,
  'content-disposition: form-data; name="avatar"; filename="cat.png"', CRLF,
  "content-type: image/png", CRLF, CRLF,
  "PNGBYTES", CRLF,
  "--", boundary, "--", CRLF,
}

local fields, err = multipart.parse(body, boundary)
assert(fields, err)

print(fields.title)                  --> a cat
print(fields.avatar.filename)        --> cat.png
print(fields.avatar.content_type)    --> image/png
print(fields.avatar.size)            --> 8

local nothing, why = multipart.parse(body, nil)
print(nothing, why)                  --> nil   multipart body has no boundary
```

## Behaviour worth knowing before you rely on it

**The whole body is buffered in memory**, bounded by `body_limit` on
`app:run{}` (1 MB by default). A 200 MB upload needs `body_limit` set to 200 MB
and then costs 200 MB of resident memory per concurrent upload. Streaming parts
to disk as they arrive is a different feature with a different shape.

**Repeated names do not accumulate.** Two parts named `tag` leave one string in
`fields.tag`, the last one. There is no list form.

**An empty `filename` still makes a file part.** A browser sends
`filename=""` for a file input the user never touched, and that part parses as
a table with `data = ""` and `size = 0` rather than as a plain string field.
Test for `type(field) == "table"` rather than for a truthy `filename`.

**`filename` is not sanitised.** It is whatever the client sent, including a
path or a `..`. Never join it onto a directory. See
[static](static.md) for the resolution rules a path from a client needs.

## Not here

- **Streaming parts to disk.** The body is buffered, always.
- **`Content-Transfer-Encoding`.** A `base64` part is handed back as its base64
  text, undecoded.
- **`multipart/mixed` and nested multiparts.** Only the flat `form-data` shape
  is parsed.
- **Charset handling.** `data` is bytes, and a field value is bytes.
- **The `413`.** Refusing an oversized upload happens in `akkar/init.lua`
  before this module is reached.

## See also

- [akkar](akkar.md) for `app:run{ body_limit = ... }` and for how `req.body` is
  produced from the request
- the module source, `akkar/multipart.lua`, for why buffering is stated as a
  limitation before the code rather than after it
