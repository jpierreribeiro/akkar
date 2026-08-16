# akkar.static

Serves files from a directory as middleware: content types by extension,
`ETag` and `Last-Modified`, `304`, single byte ranges, and a path resolver that
refuses traversal. The path resolver is pure and exported, so it can be tested
without creating a file.

**When you need it.** When the same process that answers your API also hands out
a built frontend, or a favicon, or a `.well-known` file, and putting a second
server in front of it is not worth it.

```lua no-run
local static = require "akkar.static"
```

There is no `akkar.static` on the `akkar` table. Register the middleware as
`app:use(static.new { root = "public" })`.

## Contents

- [static.TYPES](#statictypes)
- [static.content_type(path, types, default)](#staticcontent_typepath-types-default)
- [static.decode(s)](#staticdecodes)
- [static.etag_for(info)](#staticetag_forinfo)
- [static.http_date(epoch)](#statichttp_dateepoch)
- [static.lfs_available](#staticlfs_available)
- [static.new(options)](#staticnewoptions)
- [static.parse_http_date(value)](#staticparse_http_datevalue)
- [static.parse_range(header, size)](#staticparse_rangeheader-size)
- [static.resolve(root, request_path, options)](#staticresolveroot-request_path-options)
- [static.stat(path)](#staticstatpath)
- [static.stat_io(path)](#staticstat_iopath)
- [static.stat_lfs(path)](#staticstat_lfspath)
- [static.symlink_check](#staticsymlink_check)
- [static.symlink_free(base, relative)](#staticsymlink_freebase-relative)
- [Not here](#not-here)
- [See also](#see-also)

## static.TYPES

The extension to content type table, keyed by lowercase extension without the
dot. Readable and extendable, though `options.types` on `static.new` is the
supported way to add to it for one mount.

It covers `html`, `htm`, `css`, `js`, `mjs`, `json`, `map`, `txt`, `md`, `csv`,
`xml`, `svg`, `ico`, `png`, `jpg`, `jpeg`, `gif`, `webp`, `avif`, `woff`,
`woff2`, `ttf`, `otf`, `pdf`, `zip`, `gz`, `wasm`, `mp4`, `webm`, `mp3` and
`wav`. Text types carry `; charset=utf-8`.

## static.content_type(path, types, default)

The type for a path, from its extension only, never from its contents. The
extension is the part after the last dot of the last `/`-separated segment, so
a directory named `assets.js` does not decide the type of the files under it.

`types` is consulted before `static.TYPES`. `default` is returned when neither
has the extension, and defaults to `application/octet-stream`.

**Returns** a string.

## static.decode(s)

Percent-decoding. `+` is deliberately not treated as a space: that convention
belongs to form-encoded query strings, not to path segments, and a file named
`c++.txt` would otherwise be unreachable.

Called exactly once per request by `static.resolve`. Calling it a second time
on an already-decoded path is itself the vulnerability, because `%252e%252e%252f`
is a literal filename after one pass and `../` after two.

**Returns** a string.

## static.etag_for(info)

The tag for a file, from its metadata: `"MTIME-SIZE"` in hex, quoted. This is
nginx's exact scheme, so a fleet running nginx in front of akkar for some paths
does not produce two tag formats for one asset.

**Returns** a quoted string, or `nil` when `info` is `nil` or has no `mtime`. A
tag from size alone would call two different files of equal length the same
representation, so no tag is returned rather than a wrong one.

## static.http_date(epoch)

Epoch seconds to an IMF-fixdate: `Sun, 06 Nov 1994 08:49:37 GMT`. The day and
month names are spelled out rather than taken from `os.date "%a"`, which is
locale-dependent.

**Returns** a string.

## static.lfs_available

`true` when `require "lfs"` succeeded at load time. See
[static.symlink_check](#staticsymlink_check) for what depends on it.

## static.new(options)

Middleware.

| field | type | default | meaning |
|---|---|---|---|
| `root` | string | none, required | directory to serve from |
| `prefix` | string | `""` (every path) | URL prefix this mount owns; a trailing `/` is stripped |
| `index` | string or `false` | `"index.html"` | filename served for a directory; `false` refuses directories |
| `dotfiles` | boolean | `false` | allow segments starting with `.` |
| `follow_symlinks` | boolean | `false` | serve through symlinks (needs `lfs` to have any effect) |
| `max_bytes` | number | `1048576` | buffer up to this many bytes, stream above it |
| `chunk_size` | number | `65536` | bytes per chunk when streaming |
| `max_age` | number | none | seconds for `cache-control: public, max-age=N`; the header is omitted without it |
| `types` | table | none | extra or overriding extension to content type |
| `stat` | function(path) | `static.stat` | replacement metadata source |
| `fallthrough` | boolean | `false` | call `next(req)` instead of answering `404` |

Every response carries `x-content-type-options: nosniff` and
`accept-ranges: bytes`.

What it answers:

- a path outside its `prefix`: `next(req)`, untouched
- a method other than `GET` or `HEAD`: `405` with `allow: GET, HEAD`
- a path `static.resolve` refuses, or anything that is not a regular file:
  `404` with body `{ error = "not found" }`, or `next(req)` when
  `fallthrough` is set
- a directory: the file named by `index` inside it, resolved by the same rules;
  `404` when `index` is `false` or the joined path escapes the root
- a path reached through a symlink, with `follow_symlinks` unset and `lfs`
  installed: `404`. `fallthrough` does not apply to this one, nor to a file
  that turns out to be unreadable between the stat and the read.
- a fresh `If-None-Match` or `If-Modified-Since`: `304` with the validators and
  no body
- an unsatisfiable `Range`: `416` with `content-range: bytes */SIZE`
- a satisfiable single `Range`: `206` with `content-range`
- otherwise `200`

**One status for every refusal**, and no detail in the body. `403` for a
traversal and `404` for a missing file is an oracle: it tells a prober which of
its guesses touched a real directory. Traversal attempts are logged at `warn`
through `req.log` with the reason; a missing file is logged at `debug`. With
`fallthrough` set the two branches it covers are handed on before the refusal
is reached, so nothing is logged for them either.

A response larger than `max_bytes` is streamed, which means chunked transfer
encoding and no `content-length`. A `206` still carries `content-range`, which
is what a media player seeks on.

**Returns** a `function(req, next)`.

**Raises** `akkar.static needs root = "some/directory"` at registration when
`root` is missing or not a non-empty string.

```lua
local akkar  = require "akkar"
local static = require "akkar.static"

local root = "/tmp/ref_static_1"
os.execute("mkdir -p " .. root)
local file = assert(io.open(root .. "/hello.txt", "w"))
file:write "hello from disk"
file:close()

local app = akkar.new()
app:use(static.new { root = root, prefix = "/assets", max_age = 3600 })
app:get("/", function() return { ok = true } end)

local client = app:test {}

local hit = client:get "/assets/hello.txt"
print(hit.status, hit.raw, hit.headers["cache-control"])
--> 200   hello from disk   public, max-age=3600

local part = client:get("/assets/hello.txt", {
  headers = { ["range"] = "bytes=0-4" },
})
print(part.status, part.raw, part.headers["content-range"])
--> 206   hello   bytes 0-4/15

-- Refused, and logged as a traversal attempt. The client learns nothing.
print(client:get("/assets/../../etc/passwd").status)    --> 404

-- Outside the prefix, so it reaches the route.
print(client:get("/").status)                           --> 200

os.remove(root .. "/hello.txt")
os.execute("rmdir " .. root)
```

## static.parse_http_date(value)

An IMF-fixdate to epoch seconds. Only that one form is accepted; the two
obsolete formats RFC 9110 lists are refused. The consequence of refusing one is
a `200` with the full body, which is correct if not optimal, whereas
mis-parsing one into the wrong epoch would not be.

The arithmetic has no timezone in it. `os.time{...}` reads its table as local
time, which is why the obvious implementation is off by the machine's UTC
offset on any developer laptop that is not set to UTC.

**Returns** a number, or `nil` for anything that is not a string in that exact
shape.

## static.parse_range(header, size)

Parses a single-range `Range` header against a known size. `bytes=0-499`,
`bytes=500-` and the suffix form `bytes=-500` (the **last** 500 bytes) are
understood. A `last` beyond the end is clamped to `size - 1`, per RFC 9110.

**Returns** `first, last` inclusive, or `nil, "ignore"`, or
`nil, "unsatisfiable"`. The two failure words are not interchangeable:
`"ignore"` must produce a normal `200`, because a range a server will not
honour is not an error, while `"unsatisfiable"` must produce `416`.

`"ignore"` covers a non-string header, a header that is not `bytes=...`,
multiple comma-separated ranges, and anything that does not parse.
`"unsatisfiable"` covers `bytes=-0`, a first byte at or past `size`, and a last
byte before the first.

## static.resolve(root, request_path, options)

The whole security surface of this module, in one pure function. No `io`, no
`lfs`, no `os`.

It decodes exactly once, splits on `/`, discards empty segments and `.`, and
compares whole segments. A segment equal to `..` is rejected outright rather
than resolved by popping a stack, so there is no arithmetic anywhere that could
underflow past the root. The root is normalised by the same walker, and the
assembled path is then checked for containment inside it. That last check is
unreachable today and is meant to be: it is there so the day the walker is
"simplified", the failure is a refusal and a red test.

`options.dotfiles` allows segments starting with `.`. The reason to set it is
`.well-known`; the reason it is off is that the two most valuable files in a
deployed directory are `.env` and `.git/config`.

**Returns** `absolute, relative` on success, or `nil, reason`. The reasons:
`"nul byte in path"`, `"backslash in path"`, `"newline in path"`,
`"parent segment in path"`, `"dotfile"`, `"root escapes the filesystem"`,
`"resolved outside the root"`. The reason is for your log and never for the
client.

```lua
local static = require "akkar.static"

print(static.resolve("public", "/css/app.css"))
--> public/css/app.css   css/app.css
print(static.resolve("public", "/../etc/passwd"))
--> nil   parent segment in path
print(static.resolve("public", "/%2e%2e/etc/passwd"))
--> nil   parent segment in path
print(static.resolve("public", "/.env"))
--> nil   dotfile
print(static.resolve("public", "/.well-known/x", { dotfiles = true }))
--> public/.well-known/x   .well-known/x

print(static.content_type "app/index.html")   --> text/html; charset=utf-8
print(static.content_type "logo.unknown")     --> application/octet-stream
print(static.decode "a%20b%2Fc")              --> a b/c

print(static.etag_for { kind = "file", size = 4096, mtime = 1700000000 })
--> "6553f100-1000"
print(static.http_date(784111777))            --> Sun, 06 Nov 1994 08:49:37 GMT
print(static.parse_http_date "Sun, 06 Nov 1994 08:49:37 GMT")  --> 784111777

print(static.parse_range("bytes=0-499", 1000))    --> 0     499
print(static.parse_range("bytes=-500", 1000))     --> 500   999
print(static.parse_range("bytes=5000-", 1000))    --> nil   unsatisfiable
print(static.parse_range("bytes=0-1,5-6", 1000))  --> nil   ignore
```

## static.stat(path)

The metadata source the middleware uses unless you pass `options.stat`. It is
`static.stat_lfs` when `lfs` is present and `static.stat_io` otherwise, chosen
once at load time.

**Returns** `{ kind = "file"|"directory"|"other", size = number, mtime = number|nil }`,
or `nil` when the path does not exist.

Assigning to `static.stat` does not change what the middleware calls. The
supported seam is `static.new { stat = ... }`.

## static.stat_io(path)

The `lfs`-free fallback, exported by name so a machine that has `lfs` can still
test the path CI takes.

It tells a directory from a file by the **error message** of a zero-length
read, not by the `nil`. `io.open` on a directory succeeds on Linux and reports
a size of 2^63-1, and a zero-length read returns `nil` for a directory and for
an empty file alike. Lua returns a bare `nil` at end of file and
`nil, message, errno` on a real error, which separates them exactly.

It cannot produce an `mtime`, so without `lfs` there is no `Last-Modified`, no
`ETag`, and every request is a full `200`.

**Returns** the same shape as `static.stat`, always with `mtime = nil`.

## static.stat_lfs(path)

The `lfs` implementation: one `lfs.attributes` call, everything the middleware
needs including `mtime`.

**Returns** the same shape as `static.stat`, or `nil`. The field itself is
`nil` when `lfs` is not installed.

## static.symlink_check

`true` when the symlink protection is actually active in this process, which
means `lfs` is installed. Read it in a health check if the answer matters to
you. When it is `false`, a symlink inside the root pointing outside it is
served, because catching it requires `lfs.symlinkattributes` and
`luafilesystem` is not a dependency of akkar.

## static.symlink_free(base, relative)

Walks every component of `base .. "/" .. relative` from the root outwards and
reports whether any of them is a symlink. Every component, because a symlinked
**directory** is the interesting case: `public/data -> /var/lib` puts every file
"under" `public` somewhere else entirely.

**Returns** `true` when the path is clean, `false` when it is not, and **`true`
when `lfs` is absent**. There is no third answer, and failing every request on a
machine without an optional rock would be worse than the risk it guards.
`static.symlink_check` is the field that tells you which of those two answers
you are getting.

## Not here

- **Directory listings.** A missing index file is a `404`, never a generated
  listing, and there is no option to change that.
- **Multiple ranges.** `Range: bytes=0-9,20-29` is ignored and the whole body
  is sent with `200`. RFC 9110 permits ignoring a `Range` a server will not
  honour, so this is a legal answer. Doing it properly means generating a
  `multipart/byteranges` body.
- **Content sniffing.** Types come from the extension, and `nosniff` is sent so
  the browser does not sniff either.
- **Symlink protection without `lfs`.** See `static.symlink_check`.
- **Conditional requests without `lfs`.** No `mtime` means no `ETag` and no
  `Last-Modified`, so every request is a full `200`.
- **A content hash `ETag`.** The tag is `mtime-size`, which is O(1). `mtime`
  has one-second granularity, so two writes in the same second that leave the
  size unchanged produce the same tag. The fix is a content digest in the
  filename, which is what an asset pipeline already does.
- **Option-name checking.** An unknown key in `options` is ignored silently.

## See also

- [akkar](akkar.md) for `app:use`, `akkar.raw`, `akkar.stream` and `app:test`
- [compress](compress.md), which sees these responses and will encode a `206`
  along with everything else
- [etag](etag.md) for conditional requests on handler responses rather than
  files
- the module source, `akkar/static.lua`, for why `..` is rejected instead of
  resolved and why the `io.open` fallback probes the error message
