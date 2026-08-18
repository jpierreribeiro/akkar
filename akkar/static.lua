--[[
akkar.static — serving files, and the one bug that matters.

## The whole security surface is the path

Everything else in this module is comfort. Content types, 304s, ranges, the
size threshold -- get any of those wrong and a client sees a slow page or a
badly rendered one. Get the path wrong and

    GET /assets/../../../../etc/passwd

returns `/etc/passwd`, or `.env` with the production database URL in it, or
`.git/config` with a deploy token. This module is therefore built around one
function, `M.resolve`, which is pure, has no filesystem in it, and can be
hammered directly by a spec without creating a single file.

### How it is done, and why not the other way

**Decode exactly once, then split on `/`, then compare whole segments.**

That sentence is the design. The three parts each remove a class of bypass
that has shipped in real servers:

*Decode once.* `%2e%2e%2f` is `../`, and a filter that inspects the path
before decoding never sees it. So decoding happens first, before any
inspection. It happens **once**: a server that decodes, checks, and decodes
again turns `%252e%252e%252f` -- which is the harmless literal filename
`%2e%2e%2f` after one pass -- into `../` on the second. Double-decoding is
itself the vulnerability, and it is the reason this module has exactly one
call to `M.decode` and the comment above it says so.

*Split on `/`.* Once decoded, `%2f` has become a real separator and is treated
as one, which is correct here and NOT correct in `akkar/init.lua`'s router --
that file decodes per-parameter precisely so `%2f` cannot smuggle a segment
break into a `:id`. The difference is that a route parameter is one segment by
definition and a file path is not.

*Compare whole segments.* This is what kills `....//`. That string defeats
every filter that works by deleting the substring `../` from the path,
because deleting the inner `../` from `....//` leaves `../` behind. Nothing
here deletes anything. `....//` splits into the segments `....`, `` and ``,
and `....` is a perfectly ordinary (and almost certainly nonexistent)
directory name. It gets a 404 like any other missing file, not because it was
recognised as an attack but because it never was one under this parser.

A segment equal to `..` is **rejected outright** rather than resolved by
popping a stack. Popping is defensible -- `/a/../b` is `/b` and harmless --
but "reject" is a shorter proof: there is then no arithmetic anywhere that
could underflow past the root, and no client has a legitimate reason to ask a
static asset server for `..`. The cost is refusing a request nobody sends.

Then, after all that, the assembled path is checked for containment inside the
root anyway. That check is dead code today and is meant to be: it exists so
that the day someone "simplifies" the segment walker, the failure is a 403 and
a red test rather than `/etc/passwd`.

### Two more path rules that are not about traversal

**A NUL byte is refused.** `%00` truncates a string in C, so `image.png%00.txt`
is `image.png\0.txt` to Lua and `image.png` to anything underneath that ends up
holding a C string. The extension check would pass on `.txt` and the file
served would be the `.png`. Cheaper to refuse the byte than to reason about
every consumer.

**A backslash is refused.** It is a separator on Windows and not on Linux, so
`..\..\etc` is one segment here and three there. Refusing it means this module
does not have to have an opinion about which platform it is on.

**Dotfiles are refused by default.** Not traversal -- just the observation that
the two most valuable files in a deployed application directory are `.env` and
`.git/config`, and the way they get served is that somebody points a static
root at a directory that has them in it. `dotfiles = true` allows them, and the
reason to set it is `.well-known`.

## Symlinks: an honest partial answer

A symlink INSIDE the root pointing outside it defeats every lexical check in
this file, because lexically the path never leaves. Catching it requires
asking the filesystem whether a component is a link, and that requires
`lfs.symlinkattributes`.

**`luafilesystem` is not a dependency of akkar** -- verified against
`akkar-dev-1.rockspec`, and verified again against
`.github/workflows/ci.yml`, which installs `luaossl http lua-cjson pgmoon
luasocket busted` and nothing else. So it is soft-required. When it is
present, every component of the resolved path is checked and anything reached
through a link is refused with 403 unless `follow_symlinks = true`. When it is
absent, `M.symlink_check` is `false`, and that protection **does not exist**.
This is stated here, reported by the field, and not papered over.

## The `stat` seam, and why it is not just for tests

    akkar.static { root = "public", stat = function(path) ... end }

`stat` answers `{ kind = "file"|"directory", size = n, mtime = epoch }` or
nil. Everything conditional -- ETag, Last-Modified, 304 -- is computed from
that answer and from nothing else, which is what lets the spec prove the 304
logic on a machine with no `lfs` at all. It is the same shape as every other
adapter akkar owns.

The default implementation uses `lfs` when present. Without `lfs` it falls
back to `io.open`, and that fallback is **weaker in a way worth writing down**,
because it was measured rather than guessed:

    io.open("/tmp", "rb")        ->  a file handle, no error
    handle:seek("end")           ->  9223372036854775807
    handle:read(0)               ->  nil, "Is a directory", 21

Opening a directory SUCCEEDS on Linux and reports a size of nine exabytes. A
static server built on `io.open` alone therefore answers 200 with an empty
body for every directory under its root, and believes each one is 8 EiB.

The fallback tells the two apart by the **error message**, not by the nil,
and the difference is a defect this module's own spec caught. A zero-length
read returns nil for a directory *and* for an empty file, because an empty
file is at end of file from its first byte -- so probing on the nil alone made
every zero-byte `.gitkeep` a directory and every request for one a 404. Lua
returns a bare `nil` at EOF and `nil, message, errno` on a real error, which
separates them exactly.

The fallback still cannot produce an mtime, so without `lfs` there is no
`Last-Modified`, no ETag, and every request is a full 200. `M.stat_io` is
exported so that a spec running on a machine that HAS `lfs` can still test the
path CI actually takes.

### Why the ETag is not a hash of the content

The obvious ETag for a file is a hash of its bytes, and it was refused on a
measurement. `akkar.etag.fnv1a` -- the project's existing hash, and the only
one here -- runs at **3.9 MB/s** in this interpreter:

    1,024,000 bytes   0.253 s
    4 KB              0.99 ms

A millisecond of un-yielding CPU per 4 KB request is a quarter of a second on
a 1 MB asset, on the event loop, per request, and `akkar/init.lua`'s watchdog
exists to complain about exactly that. So the tag is `mtime-size` in hex, which
is what nginx uses and is O(1).

Its limit, stated rather than discovered: **mtime has one-second granularity**,
so two writes to the same file within the same second that leave the size
unchanged produce the same tag, and a client holding the first gets a 304 for
the second. That is a real staleness window and it is one second wide. The fix
is not a faster hash; it is a build step that puts a content digest in the
filename, which is what every asset pipeline already does and what this module
cannot do for you.

## Ranges: single only, and deliberately

`Range: bytes=1000-1999` is implemented, including `bytes=500-`, the suffix
form `bytes=-500`, `If-Range`, and 416 with `Content-Range: bytes */size` for
an unsatisfiable one. That is enough for a `<video>` element to seek, which is
the reason ranges exist in practice.

**Multiple ranges in one request are NOT implemented**, and the response is a
normal 200 with the whole body. RFC 9110 explicitly permits a server to ignore
a Range header it will not honour, so this is a legal answer rather than a
broken one. Doing it properly means generating a `multipart/byteranges` body
with its own boundary and per-part headers -- a second body format inside a
response -- and the honest position is that it is not written here rather than
written approximately.

## Never a directory listing

A missing index file is a 404, never a generated listing. A listing is an
information-disclosure default that nobody consciously chose, and every server
that shipped one on by default later shipped an advisory about it.
]]

local bitwise = require "akkar.bitwise"
local text = require "akkar.text"
local M = {}

--- Whether the symlink protection above is actually active in this process.
--- Read it in a health check if the answer matters to you.
M.symlink_check = false

local lfs
do
  local ok, module = pcall(require, "lfs")
  if ok then lfs, M.symlink_check = module, true end
end

M.lfs_available = lfs ~= nil

-- ==================================================================== types
--
-- BY EXTENSION, NEVER BY CONTENT. Guessing a type from the first bytes of a
-- file is how an uploaded `.txt` whose contents begin with `<html>` becomes a
-- script executing on your origin. The extension is a fact the operator
-- controls; the content is a fact the uploader controls.
--
-- The default is `application/octet-stream`, which browsers download rather
-- than render, and it is paired with `x-content-type-options: nosniff` on
-- every response from this module -- because without that header a browser
-- performs exactly the content sniffing this table exists to avoid, and
-- octet-stream stops being a safe default.
M.TYPES = {
  html = "text/html; charset=utf-8",
  htm  = "text/html; charset=utf-8",
  css  = "text/css; charset=utf-8",
  js   = "text/javascript; charset=utf-8",
  mjs  = "text/javascript; charset=utf-8",
  json = "application/json; charset=utf-8",
  map  = "application/json; charset=utf-8",
  txt  = "text/plain; charset=utf-8",
  md   = "text/markdown; charset=utf-8",
  csv  = "text/csv; charset=utf-8",
  xml  = "application/xml; charset=utf-8",
  svg  = "image/svg+xml; charset=utf-8",
  ico  = "image/x-icon",
  png  = "image/png",
  jpg  = "image/jpeg",
  jpeg = "image/jpeg",
  gif  = "image/gif",
  webp = "image/webp",
  avif = "image/avif",
  woff = "font/woff",
  woff2 = "font/woff2",
  ttf  = "font/ttf",
  otf  = "font/otf",
  pdf  = "application/pdf",
  zip  = "application/zip",
  gz   = "application/gzip",
  wasm = "application/wasm",
  mp4  = "video/mp4",
  webm = "video/webm",
  mp3  = "audio/mpeg",
  wav  = "audio/wav",
}

--- The type for a path, from its extension only.
---
--- The extension is taken from the last dot of the last SEGMENT. Matching on
--- the whole path would let a directory named `assets.js` decide the type of
--- every file beneath it.
function M.content_type(path, types, default)
  local name = path:match "([^/]*)$" or path
  local ext = name:match "%.([^%.]+)$"
  if ext then
    local found = (types and types[ext:lower()]) or M.TYPES[ext:lower()]
    if found then return found end
  end
  return default or "application/octet-stream"
end

-- ===================================================================== paths

--- Percent-decoding. Called EXACTLY ONCE per request; see the module comment
--- for why a second call is a vulnerability rather than a robustness measure.
---
--- `+` is deliberately NOT treated as a space. That convention belongs to
--- `application/x-www-form-urlencoded` query strings, not to path segments,
--- and a file legitimately named `c++.txt` would otherwise be unreachable.
function M.decode(s)
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Splits a path into segments, discarding empties and `.`.
local function segments(path)
  local out = {}
  for segment in path:gmatch "[^/]+" do
    if segment ~= "." then out[#out + 1] = segment end
  end
  return out
end

--- Resolves a request path against a root.
---
--- Returns `absolute, relative` on success, or `nil, reason` on refusal. The
--- reason is for the server's log and never for the client: telling a caller
--- whether it was stopped by a `..` or by a missing file hands it a probe.
---
--- Pure. No `io`, no `lfs`, no `os`. That is what makes the traversal cases
--- testable as a table of strings rather than as a directory tree.
function M.resolve(root, request_path, options)
  options = options or {}

  -- ONCE. Not before this line, not after it.
  local decoded = M.decode(request_path or "")

  if decoded:find("\0", 1, true) then return nil, "nul byte in path" end
  if decoded:find("\\", 1, true) then return nil, "backslash in path" end
  if decoded:find("[\r\n]")      then return nil, "newline in path" end

  local parts = {}
  for _, segment in ipairs(segments(decoded)) do
    if segment == ".." then
      return nil, "parent segment in path"
    end
    if not options.dotfiles and segment:sub(1, 1) == "." then
      return nil, "dotfile"
    end
    parts[#parts + 1] = segment
  end

  local relative = table.concat(parts, "/")

  -- Normalise the ROOT too, and by the same walker. A root of `./public/` or
  -- `public//` or one carrying a `..` of its own is a configuration mistake,
  -- not an attack, but the containment check below compares strings and a
  -- root that is not in normal form makes that comparison meaningless.
  local root_parts = {}
  local absolute_root = root:sub(1, 1) == "/"
  for _, segment in ipairs(segments(root)) do
    if segment == ".." then
      if #root_parts == 0 then return nil, "root escapes the filesystem" end
      root_parts[#root_parts] = nil
    else
      root_parts[#root_parts + 1] = segment
    end
  end
  local base = (absolute_root and "/" or "") .. table.concat(root_parts, "/")
  if base == "" then base = "." end

  local absolute = relative == "" and base or (base .. "/" .. relative)

  -- THE ASSERTION THAT IS SUPPOSED TO BE UNREACHABLE.
  --
  -- Nothing above can produce a path outside `base`: `..` was refused, not
  -- resolved, so there is no popping to underflow. This check exists for the
  -- edit that has not happened yet -- the one that "improves" the walker into
  -- resolving `..` and gets the boundary condition wrong. When that day comes
  -- the result is a refusal and a failing test.
  local prefix = base == "." and "" or (base .. "/")
  if absolute ~= base and absolute:sub(1, #prefix) ~= prefix then
    return nil, "resolved outside the root"
  end

  return absolute, relative
end

--- Refuses any path reached through a symlink.
---
--- Every component is checked, from the root outwards, because a symlinked
--- DIRECTORY is the interesting case: `public/data -> /var/lib` means every
--- file "under" `public` is somewhere else entirely, and checking only the
--- final component would miss all of them.
---
--- Returns true when the path is clean, false when it is not, and **true when
--- `lfs` is absent** -- there is no third answer available, and failing every
--- request on a machine without an optional rock would be worse than the risk
--- it guards. `M.symlink_check` is the field that tells the truth about which
--- of those two answers you are getting.
function M.symlink_free(base, relative)
  if not lfs then return true end
  local path = base
  for segment in relative:gmatch "[^/]+" do
    path = path .. "/" .. segment
    local attributes = lfs.symlinkattributes(path)
    if attributes and attributes.mode == "link" then return false end
  end
  return true
end

-- ===================================================================== stat

--- The `lfs` implementation: one syscall, everything needed.
local function stat_lfs(path)
  local attributes = lfs.attributes(path)
  if not attributes then return nil end
  return {
    kind  = attributes.mode == "directory" and "directory" or
            (attributes.mode == "file" and "file" or "other"),
    size  = attributes.size,
    mtime = attributes.modification,
  }
end

--- The fallback, and the reason it exists is in the module comment: `io.open`
--- on a directory succeeds on Linux and reports a size of 2^63-1.
---
--- The probe is the ERROR MESSAGE, not the nil, and getting that wrong was a
--- defect this spec caught rather than a hypothetical. The first version read
--- zero bytes and treated `nil` as "directory", which is right for a directory
--- and WRONG FOR AN EMPTY FILE -- both are at EOF, both answer nil, and a
--- zero-byte `.gitkeep` or a freshly truncated log came back as a 404.
---
--- Lua's `file:read` returns a bare `nil` at end of file and `nil, message,
--- errno` on a real error, so the second return value separates them exactly.
--- Measured here rather than assumed:
---
---     empty file   read(0) -> nil, nil, nil          seek "end" -> 0
---     directory    read(0) -> nil, "Is a directory", 21
---                                                    seek "end" -> 2^63-1
--- Runs `fn(handle)` and closes the handle afterwards, on every path.
---
--- This is `local file <close> = handle` written so LuaJIT can parse it. A
--- to-be-closed variable is Lua 5.4 syntax and a SYNTAX ERROR on 5.1, which
--- is what LuaJIT is -- so `static.lua` was the last of nine files that would
--- not compile there. `docs/substrate/LUAJIT.md` has the inventory.
---
--- WHY A HELPER RATHER THAN AN EXPLICIT CLOSE BEFORE EACH RETURN: every one
--- of these functions returns from more than one place, and one forgotten
--- close is a leaked descriptor that only shows up under load. Avoiding
--- exactly that is what `<close>` is for, so replacing it with discipline
--- would be trading a compiler guarantee for a habit.
---
--- WHAT IT COSTS: one closure per call, on the file-serving path only. akkar's
--- JSON routes never reach this module, and a request that reads a file from
--- disk is not one where 80 bytes decide anything.
---
--- The raise is re-thrown at level 0 so the message keeps the position the
--- caller gave it, exactly as an uncaught error would have.
local function using(handle, fn)
  local ok, a, b, c = pcall(fn, handle)
  handle:close()
  if not ok then error(a, 0) end
  return a, b, c
end

local function stat_io(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  return using(handle, function()
    local _, failure = handle:read(0)
    if failure then
      return { kind = "directory", size = 0, mtime = nil }
    end

    local size = handle:seek "end"
    if not size or size == math.maxinteger then
      return { kind = "other", size = 0, mtime = nil }
    end
    -- No mtime is available here at all, and the caller must cope rather than
    -- invent one. `os.time()` would produce a Last-Modified of "now" on every
    -- request, which is not a weaker validator -- it is a wrong one.
    return { kind = "file", size = size, mtime = nil }
  end)
end

local default_stat = lfs and stat_lfs or stat_io

M.stat = default_stat

--- Both implementations, exported by name.
---
--- `M.stat_io` is the one CI runs, because `.github/workflows/ci.yml` does not
--- install `luafilesystem`. Exporting it means a spec on a developer machine
--- -- which does have `lfs`, and would otherwise never execute a line of it --
--- can still test the code path that ships.
M.stat_io  = stat_io
M.stat_lfs = lfs and stat_lfs or nil

-- ====================================================================== time
--
-- Epoch seconds to and from an HTTP-date, with no timezone anywhere.
--
-- `os.time{...}` interprets its table as LOCAL time, so the obvious way to
-- parse `If-Modified-Since` is off by the machine's UTC offset -- which is
-- zero on most servers and is exactly why it survives review and then
-- misbehaves on the one developer laptop set to UTC+2. The civil-date
-- arithmetic below has no locale in it and gives the same answer everywhere.

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
                 Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

--- Days since 1970-01-01 for a proleptic Gregorian date. Hinnant's algorithm,
--- which is exact for every date rather than for a window around now.
local function days_from_civil(y, m, d)
  y = y - (m <= 2 and 1 or 0)
  local era = bitwise.idiv((y >= 0 and y or y - 399), 400)
  local yoe = y - era * 400
  local doy = bitwise.idiv(153 * (m + (m > 2 and -3 or 9)) + 2, 5) + d - 1
  local doe = yoe * 365 + bitwise.idiv(yoe, 4) - bitwise.idiv(yoe, 100) + doy
  return era * 146097 + doe - 719468
end

--- Epoch seconds -> `Sun, 06 Nov 1994 08:49:37 GMT`.
---
--- `!` gives UTC, and the format is spelled out rather than taken from `%c`
--- or `%a`/`%b` alone because those are locale-dependent: on a machine with a
--- French locale `os.date "%a"` is `dim.`, and an HTTP-date with `dim.` in it
--- is not one.
function M.http_date(epoch)
  local t = os.date("!*t", epoch)
  local days = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
  local names = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
  return string.format("%s, %02d %s %04d %02d:%02d:%02d GMT",
    days[t.wday], t.day, names[t.month], t.year, t.hour, t.min, t.sec)
end

--- `Sun, 06 Nov 1994 08:49:37 GMT` -> epoch seconds, or nil.
---
--- Only the IMF-fixdate form is accepted. RFC 9110 lists two obsolete
--- formats a server "must" also parse; they are refused here and the
--- consequence is bounded and small -- an unparseable `If-Modified-Since`
--- means a 200 with the full body, which is always correct, merely not
--- optimal. Silently mis-parsing one into the wrong epoch would not be.
function M.parse_http_date(value)
  if type(value) ~= "string" then return nil end
  local day, month, year, hour, minute, second =
    value:match "^%a%a%a, (%d%d) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT$"
  if not day then return nil end
  local m = MONTHS[month]
  if not m then return nil end
  return days_from_civil(tonumber(year), m, tonumber(day)) * 86400
       + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
end

-- ==================================================================== ranges

--- Parses a single-range `Range` header against a known size.
---
--- Returns `first, last` (inclusive, clamped), or `nil, "ignore"` for anything
--- this module declines to honour, or `nil, "unsatisfiable"` for a range that
--- names bytes the file does not have.
---
--- The distinction is the whole of the RFC's design: "ignore" must produce a
--- normal 200 -- a Range a server will not honour is not an error -- while
--- "unsatisfiable" must produce 416, because answering 200 to `bytes=5000-`
--- on a 100-byte file lets a client believe it received the tail it asked for.
function M.parse_range(header, size)
  if type(header) ~= "string" then return nil, "ignore" end

  -- The `bytes=` prefix still needs a pattern; only the trailing trim,
  -- which walked the whole value, is replaced.
  local spec = header:match "^%s*bytes%s*=%s*(.*)$"
  if spec then spec = text.trim(spec) end
  if not spec then return nil, "ignore" end

  -- Multiple ranges: declined, see the module comment. Not an error.
  if spec:find(",", 1, true) then return nil, "ignore" end

  local first, last = spec:match "^(%d*)%-(%d*)$"
  if not first then return nil, "ignore" end

  if first == "" then
    -- Suffix form: `bytes=-500` is the LAST 500 bytes, not the first 500.
    -- Reading it as the first 500 is a one-character mistake that returns a
    -- plausible body and corrupts every resumed download.
    local wanted = tonumber(last)
    if not wanted or wanted == 0 then return nil, "unsatisfiable" end
    if wanted >= size then return 0, size - 1 end
    return size - wanted, size - 1
  end

  local from = tonumber(first)
  if not from then return nil, "ignore" end
  if from >= size then return nil, "unsatisfiable" end

  local to = last == "" and (size - 1) or tonumber(last)
  if not to then return nil, "ignore" end
  if to >= size then to = size - 1 end          -- clamped, per RFC 9110
  if to < from then return nil, "unsatisfiable" end

  return from, to
end

-- ================================================================ middleware

local SAFE = { GET = true, HEAD = true }

--- Reads a whole file. Returns bytes, or nil.
---
--- The zero case is special and is NOT an oversight being papered over:
--- `file:read(0)` returns `nil` at end of file, and an empty file is at end of
--- file from its first byte. Passing the known size straight through therefore
--- turned every zero-byte file -- a `.gitkeep`, a truncated log, a placeholder
--- an asset pipeline wrote -- into "unreadable", and this module answered 404
--- for a file that plainly exists. `file:read("a")` returns `""` for the same
--- file, which is the correct answer, so the size is only used when there is
--- a size to use.
local function read_all(path, size)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  return using(handle, function()
    if not size or size == 0 then return handle:read "a" end
    return handle:read(size)
  end)
end

--- The tag for a file, from its metadata. Hex, quoted, and nginx's exact
--- scheme -- so a fleet running nginx in front of akkar for some paths and
--- akkar directly for others does not produce two tag formats for one asset.
---
--- nil when there is no mtime, which is the `lfs`-less case. A tag derived
--- from size alone would call two different files of equal length the same
--- representation, and every edit that preserved a file's length would be
--- invisible to every cache. Better to have no validator than a wrong one.
function M.etag_for(info)
  if not info or not info.mtime then return nil end
  return string.format('"%x-%x"', info.mtime, info.size or 0)
end

--- Middleware.
---
---     app:use(akkar.static { root = "public", prefix = "/assets" })
---
--- Options:
---   root             directory to serve from (required)
---   prefix           URL prefix it owns (default "", meaning every path)
---   index            filename served for a directory (default "index.html")
---   dotfiles         allow segments starting with `.` (default false)
---   follow_symlinks  serve through symlinks (default false; needs lfs to matter)
---   max_bytes        buffer up to this many bytes; stream above (default 1 MiB)
---   chunk_size       bytes per chunk when streaming (default 64 KiB)
---   max_age          seconds for `cache-control` (default: header omitted)
---   types            extra or overriding extension -> content type
---   stat             replacement metadata source; see the module comment
---   fallthrough      call `next(req)` instead of 404 when nothing matched
function M.new(options)
  options = options or {}
  local akkar = require "akkar"

  local root = options.root
  if type(root) ~= "string" or root == "" then
    error("akkar.static needs root = \"some/directory\"", 2)
  end

  local prefix = options.prefix or ""
  if prefix:sub(-1) == "/" then prefix = prefix:sub(1, -2) end

  local index       = options.index == nil and "index.html" or options.index
  local max_bytes   = options.max_bytes or 1024 * 1024
  local chunk_size  = options.chunk_size or 64 * 1024
  local stat        = options.stat or default_stat
  local types       = options.types

  -- The root in normal form, computed ONCE. `M.resolve` normalises it on
  -- every call and the answer cannot change between requests, so recomputing
  -- it per request was work bought with nothing.
  local root_base = M.resolve(root, "/")

  local base_headers = {}
  -- Without this, a browser is free to sniff the content of an
  -- `application/octet-stream` and decide it is HTML, which reintroduces
  -- every risk that serving by-extension exists to remove. It costs 33 bytes.
  base_headers["x-content-type-options"] = "nosniff"
  -- A byte range can be asked for whether or not this header is present, but
  -- a client that does not see it will not try -- so a video would download
  -- whole before it played.
  base_headers["accept-ranges"] = "bytes"
  if options.max_age then
    base_headers["cache-control"] = "public, max-age=" .. tostring(options.max_age)
  end

  --- Fresh headers per response. Never a shared table: `base_headers` is
  --- built once at registration and handing it out would make every response
  --- from this middleware alias one table -- the exact defect
  --- `akkar/etag.lua` and `akkar/init.lua` both document at length, except
  --- reached by sharing rather than by mutation.
  local function headers_for()
    local out = {}
    for name, value in pairs(base_headers) do out[name] = value end
    return out
  end

  -- Refusals that mean somebody is PROBING, as opposed to refusals that mean
  -- a file is missing. The client cannot tell them apart -- see below -- but
  -- an operator very much wants to, because a burst of these is the only
  -- warning that precedes a successful traversal against the next version of
  -- this code.
  local ATTACK = {
    ["nul byte in path"]        = true,
    ["backslash in path"]       = true,
    ["newline in path"]         = true,
    ["parent segment in path"]  = true,
    ["resolved outside the root"] = true,
    ["index escapes the root"]  = true,
    ["reached through a symlink"] = true,
  }

  local function refuse(req, reason)
    -- ONE STATUS FOR EVERY REFUSAL, and no detail in the body.
    --
    -- 403 for a traversal and 404 for a missing file is the natural coding and
    -- it is an oracle: it tells a prober which of its guesses touched a real
    -- directory and which did not, which is a free map of the filesystem
    -- handed over one request at a time. The client learns "no" and nothing
    -- else.
    --
    -- `req.log` is always present -- `akkar/init.lua` gives it the only
    -- capability default there is, and `akkar/limit.lua` relies on the same
    -- fact -- so this needs no guard.
    if ATTACK[reason] then
      req.log:warn("static: refused a path traversal attempt",
                   { path = req.path, reason = reason })
    else
      req.log:debug("static: no such file", { path = req.path, reason = reason })
    end
    return akkar.response(404, { error = "not found" })
  end

  return function(req, next)
    local path = req.path or ""

    -- Not ours: hand it on untouched.
    if prefix ~= "" then
      if path ~= prefix and path:sub(1, #prefix + 1) ~= prefix .. "/" then
        return next(req)
      end
      path = path:sub(#prefix + 1)
    end

    if not SAFE[req.method] then
      -- A file is readable and nothing else. 405 rather than 404 because the
      -- resource plainly exists as far as this middleware is concerned, and
      -- `Allow` is what makes a 405 useful at all.
      return akkar.response(405, { error = "method not allowed",
                                   allowed = { "GET", "HEAD" } },
                            { ["allow"] = "GET, HEAD" })
    end

    local absolute, relative = M.resolve(root, path, { dotfiles = options.dotfiles })
    if not absolute then
      if options.fallthrough then return next(req) end
      return refuse(req, relative)
    end

    local info = stat(absolute)

    -- A directory becomes its index file, and the index goes through the same
    -- resolution rules -- it is a segment like any other, and a configured
    -- `index` of `../secret` must not work.
    if info and info.kind == "directory" then
      if not index then return refuse(req, "directory, no index configured") end
      local joined = relative == "" and index or (relative .. "/" .. index)
      absolute, relative = M.resolve(root, "/" .. joined,
                                     { dotfiles = options.dotfiles })
      if not absolute then return refuse(req, "index escapes the root") end
      info = stat(absolute)
    end

    if not info or info.kind ~= "file" then
      if options.fallthrough then return next(req) end
      return refuse(req, "not a regular file")
    end

    if not options.follow_symlinks and root_base then
      if not M.symlink_free(root_base, relative) then
        return refuse(req, "reached through a symlink")
      end
    end

    local content_type = M.content_type(relative, types)
    local size = info.size or 0
    local tag  = M.etag_for(info)
    local headers = headers_for()
    if tag then headers["etag"] = tag end
    if info.mtime then headers["last-modified"] = M.http_date(info.mtime) end

    -- --------------------------------------------------------------- 304
    --
    -- `If-None-Match` beats `If-Modified-Since` when both are present, and
    -- that ordering is required rather than stylistic: the tag is exact and
    -- the date has one-second granularity, so honouring the date first would
    -- discard the better validator the client also sent.
    local if_none = req.headers and req.headers["if-none-match"]
    local fresh = false
    if if_none and tag then
      if if_none == "*" then
        fresh = true
      else
        -- A separate local, not a write back over the loop variable: Lua 5.5
        -- makes for-loop control variables const. See the same fix in
        -- `akkar/etag.lua`; these two were the only sites in the tree.
        for raw in if_none:gmatch "[^,]+" do
          local candidate = text.trim(raw)
          -- `W/"x"` is a weak validator and IS usable here: RFC 9110 says
          -- If-None-Match compares with the weak function, unlike If-Match.
          if candidate == tag or candidate == "W/" .. tag then fresh = true end
        end
      end
    elseif info.mtime then
      local since = M.parse_http_date(req.headers and req.headers["if-modified-since"])
      -- `<=`, not `<`. A file modified in the same second the client last
      -- fetched it is indistinguishable from one that was not, and answering
      -- 304 there is the standard reading -- the one-second window is the
      -- same one the ETag section admits to.
      if since and info.mtime <= since then fresh = true end
    end

    if fresh then
      -- 304 CARRIES THE VALIDATORS AND NO BODY. Returning a bare table here
      -- would not be a response at all -- `akkar/init.lua` marks real ones
      -- with `__response` and would treat a plain table as a 200 body -- so
      -- the client would receive 200 with `{status=304}` as JSON.
      local not_modified = akkar.response(304, nil)
      not_modified.headers = headers
      return not_modified
    end

    -- ------------------------------------------------------------- ranges
    local first, last, range_state = 0, size - 1, nil
    local range_header = req.headers and req.headers["range"]

    -- `If-Range` guards a resumed download: the client is saying "send me the
    -- rest ONLY if the file is the one I started". A mismatch is not an error
    -- -- it means send the whole thing, which is exactly what the client
    -- needs and would otherwise silently splice two different files together.
    if range_header then
      local if_range = req.headers["if-range"]
      if if_range and tag and if_range ~= tag then
        range_header = nil
      elseif if_range and not tag then
        range_header = nil       -- nothing to compare with; be safe, send all
      end
    end

    if range_header and size > 0 then
      local from, to = M.parse_range(range_header, size)
      if from then
        first, last, range_state = from, to, "partial"
      elseif to == "unsatisfiable" then
        local out = akkar.response(416, { error = "range not satisfiable" })
        local h = headers_for()
        h["content-range"] = "bytes */" .. tostring(size)
        out.headers = h
        return out
      end
    end

    local length = last - first + 1
    if size == 0 then first, last, length = 0, -1, 0 end

    if range_state == "partial" then
      headers["content-range"] =
        string.format("bytes %d-%d/%d", first, last, size)
    end
    local status = range_state == "partial" and 206 or 200

    -- ------------------------------------------------------------- body
    --
    -- Above `max_bytes` the file is streamed instead of buffered, because the
    -- alternative is that one request for a 400 MB asset holds 400 MB of RSS
    -- and ten concurrent ones hold four gigabytes. `akkar/multipart.lua`
    -- states the same limit for uploads and this is the mirror of it.
    --
    -- The cost is stated rather than hidden: a streamed response goes out with
    -- chunked transfer encoding and NO `content-length`, because
    -- `akkar/init.lua` does not emit one for a stream. A browser therefore
    -- cannot show a progress bar for it. A `content-range` on a 206 still
    -- tells it the extent, which is what a media player actually seeks on.
    if length > max_bytes then
      return akkar.stream(function(write)
        local handle = io.open(absolute, "rb")
        if not handle then
          -- The status is already committed by the time a producer runs, so
          -- there is no 404 to return from in here. `akkar/init.lua` says
          -- this explicitly: raising truncates the connection, which is the
          -- only honest signal left once the 200 is on the wire.
          error("akkar.static: " .. absolute .. " vanished between stat and read", 0)
        end
        using(handle, function()
          assert(handle:seek("set", first))
          local remaining = length
          while remaining > 0 do
            local chunk = handle:read(math.min(chunk_size, remaining))
            if not chunk or chunk == "" then break end
            remaining = remaining - #chunk
            write(chunk)
          end
        end)
      end, { status = status, headers = headers, content_type = content_type })
    end

    local bytes
    if range_state == "partial" then
      local handle = io.open(absolute, "rb")
      if not handle then return refuse(req, "unreadable") end
      local seekable = using(handle, function()
        if not handle:seek("set", first) then return false end
        bytes = handle:read(length) or ""
        return true
      end)
      if not seekable then return refuse(req, "unseekable") end

      -- The file can be rewritten between the stat and the read -- a deploy
      -- replacing an asset is the ordinary way it happens -- and a short read
      -- would leave `Content-Range` promising bytes the body does not have.
      -- The writer derives `Content-Length` from the payload, so the two
      -- headers would contradict each other and the client would be right to
      -- treat the response as truncated. Restating the extent from what was
      -- actually read is the only self-consistent answer available here.
      if #bytes ~= length then
        if #bytes == 0 then return refuse(req, "vanished between stat and read") end
        headers["content-range"] =
          string.format("bytes %d-%d/%d", first, first + #bytes - 1, size)
      end
    else
      bytes = read_all(absolute, size)
      if not bytes then return refuse(req, "unreadable") end
    end

    -- `akkar.raw`, not a bare table and not `akkar.response(status, bytes)`.
    -- A response `body` is a value the writer will run through `cjson.encode`,
    -- so handing it a PNG produces a JSON string of the PNG's bytes. `raw` is
    -- the field that goes on the wire untouched.
    local out = akkar.raw(bytes, content_type, status)
    out.headers = headers
    return out
  end
end

return M
