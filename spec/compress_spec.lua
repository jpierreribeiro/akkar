--[[
akkar.compress — what the middleware can prove without a compressor.

akkar ships no gzip; `akkar/compress.lua` records at length why, and the codec
is a function the application passes in. That turns out to make the tests
BETTER rather than worse: a fake encoder is deterministic, so every assertion
here is about the decision -- did we compress, under which name, with which
headers -- rather than about zlib's output. The three that carry the design
are the ones about `Vary`, about the ETag rename, and about not mutating the
handler's own response.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar    = require "akkar"
local compress = require "akkar.compress"

--- A codec that is not a codec: it brackets the input so a test can see that
--- the bytes went through it, and it SHRINKS, which is what lets the
--- "refuse to grow a response" test be about the opposite case.
local function fake(name)
  return function(bytes)
    return "<" .. name .. ":" .. #bytes .. ">"
  end
end

local BIG = string.rep("a", 4096)

local function app_with(options, handler)
  local app = akkar.new()
  options = options or {}
  if options.encoders == nil then options.encoders = { gzip = fake "gzip" } end
  app:use(compress.new(options))
  app:get("/thing", handler or function() return akkar.raw(BIG, "text/plain") end)
  return app
end

describe("negotiating an encoding", function()
  it("parses q-values, and keeps a q of zero distinct from an absent one", function()
    local q = compress.accepted "gzip, deflate;q=0.5, *;q=0"
    assert.equal(1, q.gzip)
    assert.equal(0.5, q.deflate)
    assert.equal(0, q["*"])
    -- The distinction is the whole of `identity;q=0`: storing a missing q and
    -- a q of zero the same way makes "not acceptable" unsayable.
    assert.is_nil(compress.accepted("gzip").deflate)
  end)

  it("sends nothing when the client did not ask", function()
    -- An absent Accept-Encoding is read as identity. RFC 9110 permits reading
    -- it as "anything goes", and doing so would hand gzip to a client that
    -- never advertised it.
    assert.is_nil(compress.negotiate(nil, { gzip = true }, { "gzip" }))
    assert.is_nil(compress.negotiate("", { gzip = true }, { "gzip" }))
  end)

  it("honours q=0 as a refusal", function()
    assert.is_nil(compress.negotiate("gzip;q=0", { gzip = true }, { "gzip" }))
    assert.is_nil(compress.negotiate("*;q=0", { gzip = true }, { "gzip" }))
  end)

  it("takes the highest q, not the first token", function()
    local chosen = compress.negotiate("gzip;q=0.1, br;q=0.9",
                                      { gzip = true, br = true }, { "gzip", "br" })
    assert.equal("br", chosen, "the client's preference beats ours")
  end)

  it("breaks a tie by the server's order, not by table iteration", function()
    -- Both are equally acceptable to the client, so the server chooses -- and
    -- it must choose the SAME one every time. Iterating a Lua table to decide
    -- would make the answer depend on hash layout.
    local available = { gzip = true, br = true }
    for _ = 1, 20 do
      assert.equal("br", compress.negotiate("gzip, br", available, { "br", "gzip" }))
      assert.equal("gzip", compress.negotiate("gzip, br", available, { "gzip", "br" }))
    end
  end)

  it("ignores an encoding it has no codec for", function()
    assert.is_nil(compress.negotiate("br", { gzip = true }, { "br", "gzip" }))
  end)

  it("takes * as permission for what it does hold", function()
    assert.equal("gzip", compress.negotiate("*", { gzip = true }, { "gzip" }))
  end)
end)

describe("choosing what is worth compressing", function()
  it("accepts text, JSON and the structured suffixes", function()
    assert.is_true(compress.compressible "text/html")
    assert.is_true(compress.compressible "text/css; charset=utf-8")
    assert.is_true(compress.compressible "application/json")
    assert.is_true(compress.compressible "application/vnd.api+json")
    assert.is_true(compress.compressible "image/svg+xml")
  end)

  it("refuses what is already compressed", function()
    -- Deflating a PNG spends full compression cost to make the file bigger.
    assert.is_false(compress.compressible "image/png")
    assert.is_false(compress.compressible "video/mp4")
    assert.is_false(compress.compressible "application/zip")
    assert.is_false(compress.compressible "application/octet-stream")
  end)

  it("looks past the parameters", function()
    -- akkar's own writer sends `application/json` and a handler may well send
    -- `application/json; charset=utf-8`. Matching the whole header string
    -- would skip the second, silently, for ever.
    assert.is_true(compress.compressible "application/json; charset=utf-8")
    assert.is_true(compress.compressible "  TEXT/HTML ; charset=UTF-8")
  end)
end)

describe("compressing a response", function()
  it("compresses a large text body when the client asks", function()
    local res = app_with():test():get("/thing",
      { headers = { ["accept-encoding"] = "gzip" } })

    assert.equal(200, res.status)
    assert.equal("gzip", res.headers["content-encoding"])
    assert.equal("<gzip:4096>", res.raw)
  end)

  it("leaves the body alone when the client cannot decode it", function()
    local res = app_with():test():get "/thing"
    assert.is_nil(res.headers["content-encoding"])
    assert.equal(BIG, res.raw)
  end)

  it("compresses a JSON body a handler returned as a table", function()
    -- The middleware has to encode it itself, exactly the way the writer
    -- would, or it would be compressing bytes the client never receives.
    local rows = {}
    for i = 1, 300 do rows[i] = { id = i, name = "row " .. i } end
    local app = app_with(nil, function() return { rows = rows } end)

    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal("gzip", res.headers["content-encoding"])
    assert.is_truthy(res.raw:match "^<gzip:%d+>$")
  end)
end)

describe("the three rules that are not optional", function()
  it("never compresses below the threshold", function()
    -- gzip has an 18-byte framing floor, so a small body comes out bigger,
    -- having spent CPU to get there.
    local app = app_with(nil, function() return akkar.raw("tiny", "text/plain") end)
    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })

    assert.is_nil(res.headers["content-encoding"])
    assert.equal("tiny", res.raw)
  end)

  it("never compresses an already-compressed content type", function()
    local png = string.rep("\137PNG", 2000)
    local app = app_with(nil, function() return akkar.raw(png, "image/png") end)
    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })

    assert.is_nil(res.headers["content-encoding"])
    assert.equal(png, res.raw)
  end)

  it("sends Vary: Accept-Encoding EVEN WHEN IT DID NOT COMPRESS", function()
    -- This is the one that stops a shared cache handing gzipped bytes to a
    -- client that cannot read them. The identity response is just as much a
    -- representation that depended on the request header, so a cache that
    -- stored it unkeyed would serve it to everybody.
    local client = app_with():test()

    local plain = client:get "/thing"
    assert.equal("Accept-Encoding", plain.headers["vary"])

    local gzipped = client:get("/thing", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal("Accept-Encoding", gzipped.headers["vary"])

    local small = app_with(nil, function() return akkar.raw("tiny", "text/plain") end)
      :test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal("Accept-Encoding", small.headers["vary"],
      "below the threshold the answer still varied on the header")
  end)

  it("extends an existing Vary instead of destroying it", function()
    -- A handler already varying on Origin must keep varying on it. Overwriting
    -- produces a cache that serves one origin's response to another, which is
    -- a security bug rather than a slow page.
    local app = app_with(nil, function()
      local res = akkar.raw(BIG, "text/plain")
      res.headers = { ["vary"] = "Origin" }
      return res
    end)
    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal("Origin, Accept-Encoding", res.headers["vary"])
  end)

  it("does not add Accept-Encoding to a Vary that already lists it", function()
    local app = app_with(nil, function()
      local res = akkar.raw(BIG, "text/plain")
      res.headers = { ["vary"] = "accept-encoding" }
      return res
    end)
    local res = app:test():get "/thing"
    assert.equal("accept-encoding", res.headers["vary"])
  end)
end)

describe("the ETag, which must not survive unchanged", function()
  it("renames the tag when the representation changed", function()
    -- The oldest bug in HTTP compression. Ship the identity bytes and the
    -- gzipped bytes under one tag and a shared cache holding the gzipped copy
    -- answers 304 to an If-None-Match from a client that cannot decode it.
    -- Apache grew `DeflateAlterETag` for this.
    local app = app_with(nil, function()
      local res = akkar.raw(BIG, "text/plain")
      res.headers = { ["etag"] = '"abc123"' }
      return res
    end)
    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })

    assert.equal('"abc123-gzip"', res.headers["etag"])
    assert.is_truthy(res.headers["etag"]:match '^".*"$',
      "RFC 7232 says an entity-tag is a quoted string; the suffix goes inside")
  end)

  it("leaves the tag alone when it did not compress", function()
    local app = app_with(nil, function()
      local res = akkar.raw(BIG, "text/plain")
      res.headers = { ["etag"] = '"abc123"' }
      return res
    end)
    assert.equal('"abc123"', app:test():get("/thing").headers["etag"])
  end)
end)

describe("not mutating what the handler returned", function()
  it("leaves a hoisted response untouched across requests", function()
    -- THE DEFECT THIS IS HERE FOR. A handler may return a hoisted or memoised
    -- response -- a constant page, a cached payload -- and then ONE table is
    -- shared by every request that reaches it. Writing `content-encoding:
    -- gzip` onto it means the next request, from a client that sent no
    -- Accept-Encoding at all, gets a header promising gzip over plain text.
    -- The browser shows binary garbage or nothing.
    --
    -- `akkar/etag.lua` and `akkar/init.lua` both carry this defect's history.
    -- It is worse here: the etag version served a stale 304, which is
    -- invisible-but-wrong; this one is a body the client cannot parse.
    local shared = akkar.raw(BIG, "text/plain")
    shared.headers = { ["etag"] = '"constant"' }

    local app = akkar.new()
    app:use(compress.new { encoders = { gzip = fake "gzip" } })
    app:get("/thing", function() return shared end)
    local client = app:test()

    local first = client:get("/thing", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal("gzip", first.headers["content-encoding"])

    assert.is_nil(shared.headers["content-encoding"],
      "the handler's own table was mutated")
    assert.equal('"constant"', shared.headers["etag"],
      "the handler's own etag was renamed under it")
    assert.equal(BIG, shared.raw, "the handler's own bytes were replaced")

    local second = client:get "/thing"
    assert.is_nil(second.headers["content-encoding"],
      "a client that never asked for gzip was told the body was gzipped")
    assert.equal(BIG, second.raw)
    assert.equal('"constant"', second.headers["etag"])
  end)

  it("returns a real response, not a bare table", function()
    -- A bare table is not a response: akkar marks real ones with `__response`
    -- and turns anything else into a 200 whose body is that table.
    local res = app_with():test():get("/thing",
      { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal(200, res.status)
    assert.is_nil(res.body)
    assert.equal("<gzip:4096>", res.raw)
  end)
end)

describe("refusing to make things worse", function()
  it("sends the original when the codec grew the body", function()
    local app = app_with { encoders = { gzip = function(b) return b .. b end } }
    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })

    assert.is_nil(res.headers["content-encoding"])
    assert.equal(BIG, res.raw)
  end)

  it("fails OPEN when the codec raises", function()
    -- The same trade `akkar/limit.lua` documents for an unreachable store: a
    -- bug in an optional accelerator must not become 500 on every request in
    -- the fleet. The client gets a correct, larger answer.
    local seen
    local app = app_with {
      encoders = { gzip = function() error "zlib went away" end },
      on_error = function(err) seen = err end,
    }
    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })

    assert.equal(200, res.status)
    assert.equal(BIG, res.raw)
    assert.equal("Accept-Encoding", res.headers["vary"])
    assert.is_truthy(tostring(seen):find("zlib went away", 1, true))
  end)

  it("fails open when the codec returns something that is not a string", function()
    local app = app_with { encoders = { gzip = function() return nil end } }
    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal(200, res.status)
    assert.equal(BIG, res.raw)
  end)

  it("never double-encodes a body that is already encoded", function()
    local app = app_with(nil, function()
      local res = akkar.raw(BIG, "text/plain")
      res.headers = { ["content-encoding"] = "gzip" }
      return res
    end)
    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal(BIG, res.raw, "a second pass would produce a body decoded twice")
    assert.equal("gzip", res.headers["content-encoding"])
  end)

  it("leaves a 204 and a 304 alone", function()
    local app = akkar.new()
    app:use(compress.new { encoders = { gzip = fake "gzip" } })
    app:get("/empty", function() return akkar.no_content() end)
    app:get("/fresh", function()
      local res = akkar.response(304, nil)
      res.headers = { ["etag"] = '"x"' }
      return res
    end)
    local client = app:test()

    local empty = client:get("/empty", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal(204, empty.status)
    assert.is_nil(empty.headers["content-encoding"])

    -- A content-encoding on a 304 describes bytes that are not there.
    local fresh = client:get("/fresh", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal(304, fresh.status)
    assert.is_nil(fresh.headers["content-encoding"])
  end)

  it("passes a streamed body through, and still says Vary", function()
    -- Compressing a stream needs an INCREMENTAL codec, which is a different
    -- contract; buffering it to compress in one go undoes the only reason the
    -- handler streamed. Whether it WOULD have been compressed still depended
    -- on the request header, so a cache needs the Vary.
    local app = akkar.new()
    app:use(compress.new { encoders = { gzip = fake "gzip" } })
    app:get("/export", function()
      return akkar.stream(function(write) write(BIG) end, { content_type = "text/plain" })
    end)

    local res = app:test():get("/export", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal(BIG, res.raw)
    assert.is_nil(res.headers["content-encoding"])
    assert.equal("Accept-Encoding", res.headers["vary"])
  end)
end)

describe("registration", function()
  it("refuses to install with no codec at all", function()
    -- A compressing middleware with nothing to compress with is a line of
    -- configuration that looks like it works and does nothing, for ever. The
    -- only way anyone finds out is by reading response headers in production.
    local ok, err = pcall(compress.new, {})
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("encoders", 1, true))
    assert.is_truthy(tostring(err):find("akkar ships no compressor", 1, true))
  end)

  it("refuses a codec that is not a function", function()
    local ok, err = pcall(compress.new, { encoders = { gzip = "zlib" } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("not a function", 1, true))
  end)
end)

describe("the codec contract, exercised end to end", function()
  it("round-trips through a real, invertible codec", function()
    -- The point of a pluggable compressor is that a REAL one drops in. This
    -- is a real one -- run-length encoding, genuinely smaller on this input,
    -- genuinely reversible -- standing in for gzip to prove the seam carries
    -- bytes rather than to prove anything about deflate.
    -- Written as an explicit loop rather than as `gmatch "((.)%2*)"`, which
    -- was the first attempt and silently produced an EMPTY string: Lua
    -- patterns accept a back-reference but do not accept a quantifier on one,
    -- so the `*` was matched as a literal asterisk, nothing ever matched, and
    -- `#compressed < #original` was trivially satisfied by zero bytes. The
    -- size assertion below passed while the codec did nothing at all, which is
    -- exactly the failure a round-trip assertion exists to catch.
    local function rle(bytes)
      local out, i, n = {}, 1, #bytes
      while i <= n do
        local char, last = bytes:sub(i, i), i
        while last < n and bytes:sub(last + 1, last + 1) == char do last = last + 1 end
        out[#out + 1] = (last - i + 1) .. "x" .. char
        i = last + 1
      end
      return table.concat(out)
    end
    local function unrle(bytes)
      return (bytes:gsub("(%d+)x(.)", function(n, c) return c:rep(tonumber(n)) end))
    end

    local body = string.rep("a", 2000) .. string.rep("b", 2000)
    local app = akkar.new()
    app:use(compress.new { encoders = { gzip = rle } })
    app:get("/thing", function() return akkar.raw(body, "text/plain") end)

    local res = app:test():get("/thing", { headers = { ["accept-encoding"] = "gzip" } })
    assert.equal("gzip", res.headers["content-encoding"])
    assert.is_true(#res.raw < #body, "the codec must actually have shrunk it")
    assert.equal(body, unrle(res.raw), "the bytes on the wire must decode back")
  end)
end)
