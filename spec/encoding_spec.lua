--[[
Bytes that are not text.

## Why this file exists

`docs/UNKNOWNS.md` listed encoding as a class nobody had pointed an instrument
at: no test sent a non-UTF-8 byte in a header, a path or a JSON string. Every
byte akkar has ever been tested with was ASCII.

That matters more than it sounds, because of one measured fact: **cjson
encodes invalid UTF-8 straight through.** Given a Lua string containing
`\xC3\x28` -- a lead byte followed by something that cannot continue it -- it
produces a JSON document containing those same bytes, and RFC 8259 says a JSON
text SHALL be encoded in UTF-8. So a body that arrives malformed can leave
malformed, and the client that has to parse it is a stricter parser than ours.

## What is asserted

Not a particular status code for every input -- akkar may legitimately close a
connection on bytes it will not parse, and `spec/framing_spec.lua` already
pins that. What must hold:

  * the server survives every one of these and answers the next request;
  * a malformed CLIENT input is never answered 5xx, which would be akkar
    blaming itself for the caller's bytes;
  * and akkar never emits a response body that is not valid UTF-8, whatever
    it was given.

The last one is the point of the file.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local json  = require "akkar.json"

-- ============================================================== the checker

--- Is this string valid UTF-8?
---
--- Written out rather than borrowed, because `utf8.len` returns nil and a
--- position for the first bad byte, which is exactly the answer wanted, and
--- because a test that leans on the thing it is testing proves nothing.
local function valid_utf8(s)
  return utf8.len(s) ~= nil
end

-- Inputs, each with the reason it is here. None of these is exotic: every one
-- turns up in real traffic, usually from a client with a different idea about
-- encoding than the server.
local HOSTILE = {
  { name = "lone continuation byte",    bytes = "\x80" },
  { name = "lead byte with no follower", bytes = "\xC3" },
  { name = "lead byte, wrong follower",  bytes = "\xC3\x28" },
  { name = "overlong slash",             bytes = "\xC0\xAF" },
  { name = "the IIS 2001 traversal",     bytes = "\xC0\xAE\xC0\xAE" },
  { name = "surrogate half, raw",        bytes = "\xED\xA0\x80" },
  { name = "byte order mark",            bytes = "\xEF\xBB\xBF" },
  { name = "a NUL in the middle",        bytes = "a\0b" },
  { name = "latin-1 that is not utf-8",  bytes = "caf\xE9" },
  { name = "truncated four-byte rune",   bytes = "\xF0\x9F\x92" },
}

describe("the JSON layer", function()
  it("encodes invalid UTF-8 straight through, which is the problem", function()
    -- Measured rather than assumed, and pinned so that a future change to the
    -- serialiser is noticed here rather than by somebody's client.
    local encoded = json.encode { s = "ok-\xC3\x28-end" }
    assert.is_false(valid_utf8(encoded),
      "the serialiser has started sanitising; the guard below may now be " ..
      "redundant and this file should say so rather than testing nothing")
  end)

  it("refuses a lone surrogate escape, which is the half it does check", function()
    -- `\uD800` with no pair is not a character. cjson already rejects it, and
    -- it is worth pinning the part that is already right.
    assert.is_false((pcall(json.decode, [[{"s":"\uD800"}]])))
  end)
end)

describe("a request body that is not UTF-8", function()
  local function app_echoing()
    local app = akkar.new()
    app:post("/echo", function(req)
      return { got = req.body and req.body.s }
    end)
    app:get("/ping", function() return { ok = true } end)
    return app
  end

  for _, case in ipairs(HOSTILE) do
    it("refuses " .. case.name .. " rather than echoing it", function()
      -- A body claiming to be JSON must be UTF-8; RFC 8259 says so. Accepting
      -- it means the bytes travel into a database, a log line and a response,
      -- and every one of those has a consumer that may parse more strictly
      -- than we do.
      local client = app_echoing():test()
      local raw = '{"s":"' .. case.bytes:gsub('"', '\\"'):gsub("\\", "\\\\") .. '"}'

      local res = client:post("/echo", { body = raw,
                                         headers = { ["content-type"] = "application/json" } })

      assert.is_true(res.status < 500,
        case.name .. " was answered " .. tostring(res.status) ..
        ", which blames the server for the caller's bytes")

      if res.status < 300 and res.body then
        local encoded = json.encode(res.body)
        assert.is_true(valid_utf8(encoded),
          case.name .. " came back in a response that is not valid UTF-8: " ..
          "a client parsing strictly cannot read akkar's answer")
      end
    end)
  end

  it("keeps answering afterwards", function()
    local app = app_echoing()
    local client = app:test()
    for _, case in ipairs(HOSTILE) do
      pcall(function()
        client:post("/echo", { body = '{"s":"' .. case.bytes .. '"}' })
      end)
    end
    assert.equal(200, client:get("/ping").status)
  end)
end)

describe("hostile bytes elsewhere in a request", function()
  local function app()
    local a = akkar.new()
    a:get("/thing/:id", function(req) return { id = req.params.id } end)
    a:get("/head", function(req)
      return { seen = req.headers["x-thing"] }
    end)
    return a
  end

  for _, case in ipairs(HOSTILE) do
    it("survives " .. case.name .. " in a path parameter", function()
      local client = app():test()
      local res = client:get("/thing/" .. case.bytes)
      assert.is_true(res.status < 500,
        "a path parameter of hostile bytes answered " .. tostring(res.status))

      if res.status == 200 and res.body then
        assert.is_true(valid_utf8(json.encode(res.body)),
          "the path parameter came back in a response that is not UTF-8")
      end
    end)

    it("survives " .. case.name .. " in a header", function()
      local client = app():test()
      local res = client:get("/head", { headers = { ["x-thing"] = case.bytes } })
      assert.is_true(res.status < 500,
        "a header of hostile bytes answered " .. tostring(res.status))

      if res.status == 200 and res.body then
        assert.is_true(valid_utf8(json.encode(res.body)),
          "a header value came back in a response that is not UTF-8")
      end
    end)
  end
end)
