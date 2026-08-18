--[[
akkar.compress — negotiating an encoding, and the compressor akkar does not have.

## Read this first: there is no gzip in this module

This module implements everything about response compression EXCEPT the
compression. The application supplies the codec:

    app:use(akkar.compress {
      encoders = { gzip = function(bytes) return my_gzip(bytes) end },
    })

That is not a design preference, it is what the environment permits, and the
check was run rather than assumed:

  * `luaossl` is linked here and does TLS, digests, HMAC and ciphers. It does
    not expose deflate at all -- there is no `openssl.deflate` to call.
  * `lua-http` ships `http/zlib.lua`, which is a *normaliser* over two rival
    bindings, and its first line is `require "zlib"`. Neither `lua-zlib` nor
    `lzlib` is installed, so `require "http.zlib"` raises
    `module 'zlib' not found` here. Verified by requiring it.
  * `zlib.ffi` (lua-zlib-ffi) is not installed either.
  * `libz.so.1` exists on this machine and `cffi-lua` is installed, so a raw
    FFI binding to the system zlib is *technically* reachable. It is refused:
    `cffi-lua` is not among akkar's declared dependencies, nothing in the
    tree uses it, and binding libz by hand here would make a C library that
    nobody chose a hard requirement of `luarocks install akkar`. That is the
    identical argument `akkar-dev-1.rockspec` already makes about `libpq` and
    `akkar.pq_native`, and it does not stop being true for zlib.
  * Shelling out to `gzip(1)` is not a candidate. `akkar/migrate.lua` says at
    its own `io.popen` call that popen blocks the whole OS process; a static
    asset served through a fork-and-pipe would block the event loop for every
    concurrent request, which is worse than not compressing.

**So the honest outcome is a hole with a shape.** What is missing is one
function, `string -> string`, and everything a correct compressing server has
to get right around it -- negotiation, `Vary`, the threshold, the type
allowlist, the ETag rename -- is here, tested, and works the moment that
function is passed in. What is NOT here is a gzip implementation invented for
the occasion. A hand-rolled deflate would be a few hundred lines of unproven
bit-packing on the hot path of every response, and the failure mode of getting
it subtly wrong is a body no client can read.

There is a tempting near-miss worth naming so nobody ships it by accident: a
byte-correct gzip *container* is easy -- a ten-byte header, deflate "stored"
blocks, CRC32, length -- and it needs no compression algorithm at all. It
produces a stream every browser accepts and that is **larger than the input**.
It would pass a test that decompresses and compares, and it would make every
response slightly worse. It is not here.

## Why this exists at all, when nginx is right there

A reverse proxy usually should do this, and if one is terminating TLS in front
of akkar, configure it there and do not register this middleware. In-process
compression is worth it in three cases:

  1. **There is no proxy.** A container on Railway, Fly or Cloud Run speaking
     HTTP directly to the edge. The edge may or may not compress for you, and
     "may or may not" is not a plan.
  2. **The proxy cannot see the body.** End-to-end TLS to the application, or
     a proxy configured to pass bytes through untouched.
  3. **The response is generated and huge.** A JSON export that is 40 MB of
     repetitive rows is 40 MB crossing the loopback to the proxy before the
     proxy shrinks it. Compressing at the source is the only place that
     saves the memory and the copy.

## The three rules that are not optional

**Never compress a small body.** gzip has an 18-byte floor of framing before a
single byte of payload, plus block overhead, so a 40-byte JSON error object
comes out *bigger*, and it comes out bigger having spent CPU. Below one packet
there is nothing to win at all: the response was going to be one segment
either way. `min_size` defaults to 1024.

**Never compress an already-compressed type.** A PNG, a JPEG, an MP4 and a
zip are deflate-hostile: the output is the input plus overhead, and you paid
full compression cost to grow the file. This is enforced by an *allowlist* --
naming what is compressible rather than what is not -- because the deny-list
version is a list that is permanently one new media type out of date.

**Always send `Vary: Accept-Encoding`.** Without it a shared cache stores
whichever representation it saw first under a key that does not mention the
encoding, and then hands gzipped bytes to a client that never asked for them
and cannot read them. The symptom is binary garbage in a browser for one user
in a hundred, it depends on who warmed the cache, and it is unreproducible on
the machine of whoever is asked to fix it. `Vary` goes on responses this
middleware *considered*, not only on the ones it compressed -- the identity
response is just as much a representation that depended on the request header,
and a cache that stored it without `Vary` would serve it to everybody.

## Ordering: register this FIRST

    app:use(akkar.compress { ... })   -- outermost
    app:use(akkar.etag { ... })

`build_chain` in `akkar/init.lua` wraps from the last registration inwards, so
`middleware[1]` is the outermost layer and sees the response last. Compression
must be the last transformation applied to a body, because a compressed
response no longer *has* a `body` -- it has bytes. Registered the other way
round, `akkar.etag` would receive a response whose `body` is nil, tag nothing,
and its 304 path would quietly stop working. Nothing would raise.
]]

local text = require "akkar.text"
local M = {}

--- Types worth compressing. Prefixes and exact matches, plus the structured
--- suffixes `+json` and `+xml`, which is how every vendor media type in the
--- wild spells "this is really JSON" (`application/vnd.api+json`).
---
--- `image/svg+xml` is here and is the reason the suffix rule matters: SVG is
--- an image by media type and text by content, and it compresses about as
--- well as HTML.
local COMPRESSIBLE = {
  exact = {
    ["application/json"]        = true,
    ["application/javascript"]  = true,
    ["application/xml"]         = true,
    ["application/xhtml+xml"]   = true,
    ["application/rss+xml"]     = true,
    ["application/atom+xml"]    = true,
    ["application/wasm"]        = true,
    ["image/svg+xml"]           = true,
    ["application/x-ndjson"]    = true,
  },
  prefixes = { "text/" },
  suffixes = { "+json", "+xml" },
}

--- Does this content type want compressing?
---
--- The type is taken from before the first `;` so that
--- `application/json; charset=utf-8` -- which is what akkar's own writer would
--- send -- is not treated as an unknown type and skipped. That exact miss is
--- easy to write and impossible to notice: everything keeps working, nothing
--- is ever compressed, and the middleware looks installed.
function M.compressible(content_type)
  if not content_type then return false end
  local kind = content_type:match "^[^;]*"
  kind = kind:gsub("%s", ""):lower()
  if kind == "" then return false end

  if COMPRESSIBLE.exact[kind] then return true end
  for _, prefix in ipairs(COMPRESSIBLE.prefixes) do
    if kind:sub(1, #prefix) == prefix then return true end
  end
  for _, suffix in ipairs(COMPRESSIBLE.suffixes) do
    if #kind > #suffix and kind:sub(-#suffix) == suffix then return true end
  end
  return false
end

--- Parses `Accept-Encoding` into `{ token = qvalue }`.
---
---     gzip, deflate;q=0.5, *;q=0   ->   { gzip = 1, deflate = 0.5, ["*"] = 0 }
---
--- **q=0 means "not acceptable", not "absent"**, and the difference is the
--- whole of `identity;q=0` and `*;q=0`. Storing a missing q as 1 and a q of 0
--- as 0 keeps them distinguishable; treating a malformed q as 1 rather than
--- dropping the token is deliberate, because the alternative is that one
--- unparseable parameter silently disables compression for that client.
function M.accepted(header)
  local out = {}
  if not header or header == "" then return out end
  for part in header:gmatch "[^,]+" do
    local token = part:match "^%s*([^;%s]+)"
    if token then
      local q = part:match ";%s*[qQ]%s*=%s*([%d%.]+)"
      out[token:lower()] = q and (tonumber(q) or 1) or 1
    end
  end
  return out
end

--- Picks an encoding, or nil for "send it as it is".
---
--- `available` is the set of encodings we actually hold a codec for, and
--- `prefer` breaks ties in OUR favour -- the client expressed indifference by
--- giving two encodings the same q, so the server is entitled to choose, and
--- choosing by iteration order over a Lua table would make the answer depend
--- on hash layout and differ between processes.
function M.negotiate(header, available, prefer)
  -- No header at all is NOT "anything goes". RFC 9110 permits reading it that
  -- way, and doing so would send gzip to a client that never advertised it.
  -- Every deployed server treats the absent header as identity, and a client
  -- that wants compression has exactly one way to say so.
  if not header or header == "" then return nil end

  local q = M.accepted(header)
  local star = q["*"]

  local best, best_q
  for _, name in ipairs(prefer) do
    if available[name] then
      local weight = q[name] or star
      if weight and weight > 0 and (best_q == nil or weight > best_q) then
        best, best_q = name, weight
      end
    end
  end
  return best
end

--- Middleware.
---
--- Options:
---   encoders   { name = function(bytes) -> bytes|nil[, err] }   REQUIRED
---   min_size   bytes below which nothing is compressed (default 1024)
---   prefer     server tie-break order (default { "br", "gzip", "deflate" })
---   compressible  function(content_type) -> boolean, to replace the allowlist
---   on_error   function(err, req) called when an encoder fails
function M.new(options)
  options = options or {}
  local akkar = require "akkar"

  local encoders = options.encoders or {}
  if next(encoders) == nil then
    -- Loud at registration, not silent at runtime. A compressing middleware
    -- with nothing to compress with is a line of configuration that looks
    -- like it works and does nothing at all, for ever, and the only way
    -- anyone finds out is by reading response headers in production. See the
    -- module comment for why akkar cannot supply a default.
    error("akkar.compress needs encoders = { gzip = function(bytes) ... end }; " ..
          "akkar ships no compressor -- no zlib binding is available to it, " ..
          "and inventing one is worse than saying so", 2)
  end
  for name, fn in pairs(encoders) do
    if type(fn) ~= "function" then
      error("akkar.compress: encoder '" .. name .. "' is a " .. type(fn) ..
            ", not a function(bytes)", 2)
    end
  end

  local min_size = options.min_size or 1024
  local prefer   = options.prefer or { "br", "gzip", "deflate" }
  local wants    = options.compressible or M.compressible

  return function(req, next)
    local res = next(req)
    if not res or not res.status then return res end

    -- 204 and 304 have no body by definition, and a 1xx never carries one.
    -- Attaching `Vary` to a 304 is harmless but attaching `content-encoding`
    -- to one is not: the header would describe bytes that are not there.
    if res.status == 204 or res.status == 304 or res.status < 200 then
      return res
    end

    -- A streamed body is deliberately passed through untouched.
    --
    -- Compressing it correctly means an INCREMENTAL encoder -- feed a chunk,
    -- get some output, flush at the end -- which is a different contract from
    -- `function(bytes) -> bytes` and cannot be faked by buffering: buffering
    -- the whole stream to compress it in one go undoes the only reason the
    -- handler streamed. `akkar/init.lua` is explicit that a stream exists so
    -- a 200 MB export never lands in memory.
    --
    -- It still gets `Vary`, because whether it *would* have been compressed
    -- depended on the request header, and a cache needs to know that.
    if res.stream then
      return M.vary(akkar, res)
    end

    -- What bytes would go on the wire, and under what type. This mirrors
    -- exactly what the writer in `akkar/init.lua` does --
    -- `res.raw or cjson.encode(res.body)`, content type defaulting to
    -- application/json -- because compressing anything else would be
    -- compressing a body the client is not going to receive.
    -- `application/json` is the default because that is what the writer in
    -- `akkar/init.lua` falls back to, verbatim, for a response that names no
    -- type. Choosing a different default here -- `text/plain` was the first
    -- attempt -- means this middleware decides compressibility from one type
    -- while the client is told another, and the two only have to disagree
    -- across the allowlist boundary once for a body to be compressed and
    -- labelled as something that is not.
    local content_type = res.content_type or "application/json"
    local payload = res.raw
    if payload == nil then
      if res.body == nil then return res end
      local ok_encode, encoded = pcall(akkar.json.encode, res.body)
      if not ok_encode then
        -- Not our failure to report. The writer is about to hit the same
        -- error and produce the real diagnostic; swallowing it here would
        -- turn an encoding bug into a mysteriously uncompressed response.
        return res
      end
      payload = encoded
    end

    if type(payload) ~= "string" then return res end
    if not wants(content_type) then return res end

    -- Already encoded by something upstream -- a handler serving a `.gz` from
    -- disk, or a second copy of this middleware. Compressing it again
    -- produces a body the client must decode twice and will not.
    local existing = res.headers and (res.headers["content-encoding"] or
                                      res.headers["Content-Encoding"])
    if existing then return M.vary(akkar, res) end

    -- Below the threshold there is nothing to win, but the answer still
    -- varied on the request header: this same URL with a bigger body WOULD
    -- have been compressed, and a cache keyed without `Vary` would then be
    -- wrong about it.
    if #payload < min_size then return M.vary(akkar, res) end

    local available = {}
    for name in pairs(encoders) do available[name] = true end
    local chosen = M.negotiate(req.headers and req.headers["accept-encoding"],
                               available, prefer)
    if not chosen then return M.vary(akkar, res) end

    local ok, compressed = pcall(encoders[chosen], payload)
    if not ok or type(compressed) ~= "string" then
      -- FAIL OPEN, ALWAYS. A codec that raises is a bug in the codec, and the
      -- worst possible response to it is 500 on every request in the fleet --
      -- the identical trade `akkar/limit.lua` documents for an unreachable
      -- store. The client gets a correct, larger answer.
      if options.on_error then
        pcall(options.on_error, ok and "encoder returned a " .. type(compressed)
                                   or compressed, req)
      end
      return M.vary(akkar, res)
    end

    -- The compressor lost. It happens: already-entropic content inside a
    -- compressible type, a tiny body just over the threshold. Sending the
    -- bigger one because we already made it would be spending the client's
    -- bandwidth to justify our own CPU.
    if #compressed >= #payload then return M.vary(akkar, res) end

    -- A COPY. Never a mutation of the table the handler returned.
    --
    -- `akkar/etag.lua` carries the full account of this defect and
    -- `akkar/init.lua` carries it again for `x-request-id`: a handler may
    -- return a hoisted or memoised response -- a constant 404, a cached
    -- payload -- and then ONE table is shared by every request that reaches
    -- it. Writing `content-encoding: gzip` onto it means the NEXT request,
    -- from a client that sent no `Accept-Encoding` at all, is handed a header
    -- promising gzip over a body that is plain text. That client shows the
    -- user binary garbage, or nothing.
    --
    -- Worse here than for an etag, in fact: the etag version served a stale
    -- 304, which is invisible-but-wrong. This one is a body the browser
    -- cannot parse.
    local out = akkar.response(res.status, nil)
    out.raw = compressed
    out.content_type = content_type

    local headers = {}
    for name, value in pairs(res.headers or {}) do headers[name] = value end
    headers["content-encoding"] = chosen
    headers["vary"] = M.merge_vary(headers["vary"])

    -- THE ETAG MUST CHANGE, and this is the oldest bug in HTTP compression.
    --
    -- An entity tag identifies a *representation*, and the gzipped bytes are
    -- a different representation from the identity bytes. Ship both under one
    -- tag and a shared cache holding the gzipped copy will answer 304 to an
    -- `If-None-Match` from a client that cannot decode it -- so the client
    -- keeps serving from a cache entry it believes is current and is not, or
    -- receives the compressed body it just told the server it already had.
    -- Apache shipped this for years; it is why `mod_deflate` grew
    -- `DeflateAlterETag`.
    --
    -- The suffix goes INSIDE the quotes because RFC 7232 defines an
    -- entity-tag as a quoted string and `"abc"-gzip` is not one. Any
    -- unrecognised tag body is fine -- it is opaque to the client, which only
    -- ever compares it for equality.
    local tag = headers["etag"]
    if tag then
      local inner = tag:match '^"(.*)"$'
      headers["etag"] = inner and ('"' .. inner .. "-" .. chosen .. '"')
                              or (tag .. "-" .. chosen)
    end

    out.headers = headers
    -- `release` and `__pending` travel with the response or they are lost:
    -- the first releases the request's capabilities and the second carries a
    -- deferred 500 to `handle`. Dropping either by building a fresh response
    -- is a leak and a swallowed error respectively.
    out.release  = res.release
    out.__pending = res.__pending
    return out
  end
end

--- `Vary: Accept-Encoding`, added without destroying what was already there.
---
--- A handler that already varies on `Origin` -- which `akkar.cors` has every
--- reason to set -- must keep varying on it. Overwriting the header instead of
--- extending it produces a cache that serves one origin's response to
--- another, which is a security bug rather than a performance one.
function M.merge_vary(existing)
  if not existing or existing == "" then return "Accept-Encoding" end
  for field in existing:gmatch "[^,]+" do
    if text.trim(field):lower() == "accept-encoding" then
      return existing
    end
  end
  return existing .. ", Accept-Encoding"
end

--- Returns a COPY of `res` carrying `Vary: Accept-Encoding`.
---
--- Copying costs two tables on a path that did not compress, and that is the
--- price of not mutating a response the handler may be reusing. See the long
--- note at the compression site. When the header is already there, the
--- original is returned untouched and nothing is allocated at all.
---
--- `akkar` is a PARAMETER rather than a module-level `require`, and that is
--- not style. `akkar/init.lua` ends with `akkar.etag = require("akkar.etag")`
--- and will want the same line for this module, so requiring `akkar` at the
--- top of this file would close a cycle. `akkar/etag.lua` solves it by
--- requiring inside `M.new`; a helper called from there has to be handed the
--- result.
function M.vary(akkar, res)
  local headers = {}
  for name, value in pairs(res.headers or {}) do headers[name] = value end
  local merged = M.merge_vary(headers["vary"])
  if headers["vary"] == merged and res.headers then return res end
  headers["vary"] = merged

  local out = akkar.response(res.status, res.body)
  out.headers      = headers
  out.raw          = res.raw
  out.stream       = res.stream
  out.release      = res.release
  out.content_type = res.content_type
  out.__pending    = res.__pending
  return out
end

return M
