--[[
Hostile HTTP/2 frames against a running server.

## Why this file exists

`spec/fuzz_spec.lua` throws hostile input at a live server and states plainly
what it does not cover: **framing**. Everything there goes through lua-http's
client, so every request is well-framed by construction, and framing is exactly
where an attacker reaches first. That gap was acceptable while akkar spoke only
HTTP/1.1, because `spec/framing_spec.lua` covers h1 framing with raw bytes.

HTTP/2 arrived on 2026-08-18 and arrived with the gap open: its framing layer
is upstream lua-http 0.4's, unmodified and unfuzzed by anything here. A second
framing layer is the largest thing h2 adds to the attack surface, and "upstream
wrote it" is a reason to expect it to be good, not a reason not to check.

## The harness, and why it works where the other one did not

`fuzz_spec` records that a raw-socket client in the same `cqueues` controller
as the server deadlocked, and left framing to a separate process. That is true
of a BLOCKING client. `spec/allocation_spec.lua` drives raw HTTP/1.1 bytes at a
live akkar from the same controller without deadlocking, because its socket is
`setmode("bn", "bn")` with an `onerror` that returns rather than raises -- so
every read yields to the server instead of blocking on it. This file uses that
pattern.

## The properties, for every frame below

  * the process survives;
  * the connection is refused or reset, never hung -- a hang is worse than a
    crash because it holds a descriptor and answers nothing;
  * and **the server still answers the next client**, which is the property
    that matters: one hostile peer must not take the door off its hinges.

## What this does NOT establish

That lua-http's h2 implementation is correct. It establishes that the shapes
below do not take akkar down, which is a smaller and checkable claim. A
conformance suite -- h2spec -- is a different piece of work and belongs in
`bench/`, against a server in another process.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local socket  = require "cqueues.socket"
local request = require "http.request"

local PORT = 8396
local PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

--- One HTTP/2 frame: 24-bit length, 8-bit type, 8-bit flags, 31-bit stream id.
---
--- Built by hand rather than through `h2_connection` on purpose. A frame this
--- library would refuse to WRITE is exactly the frame worth sending, and a
--- helper that validates its arguments cannot express one.
local function frame(kind, flags, stream, payload)
  payload = payload or ""
  local n = #payload
  return string.char((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff)
      .. string.char(kind, flags)
      .. string.char((stream >> 24) & 0x7f, (stream >> 16) & 0xff,
                     (stream >> 8) & 0xff, stream & 0xff)
      .. payload
end

--- A frame whose LENGTH FIELD lies: it declares `claimed` and carries `#body`.
--- Written separately because `frame` cannot express it and that is the point.
local function lying_frame(kind, flags, stream, claimed, body)
  return string.char((claimed >> 16) & 0xff, (claimed >> 8) & 0xff,
                     claimed & 0xff)
      .. string.char(kind, flags)
      .. string.char((stream >> 24) & 0x7f, (stream >> 16) & 0xff,
                     (stream >> 8) & 0xff, stream & 0xff)
      .. (body or "")
end

local SETTINGS_ACK = frame(0x4, 0x1, 0)

--- Every case is (label, bytes sent after the preface).
local function corpus()
  local settings = frame(0x4, 0x0, 0)          -- empty SETTINGS, which is legal

  return {
    { "a frame type nobody has defined",
      settings .. frame(0xfa, 0x0, 1, "whatever") },

    { "SETTINGS whose length is not a multiple of six",
      settings .. frame(0x4, 0x0, 0, "abcd") },

    { "SETTINGS carrying an ACK flag AND a payload",
      settings .. frame(0x4, 0x1, 0, string.rep("\0", 6)) },

    { "a length field that claims far more than was sent",
      settings .. lying_frame(0x1, 0x4, 1, 0xffff, "short") },

    { "a frame longer than the default 16 KiB maximum",
      settings .. frame(0x0, 0x0, 1, string.rep("x", 17 * 1024)) },

    { "DATA on the connection stream, which has no streams",
      settings .. frame(0x0, 0x0, 0, "payload") },

    { "HEADERS on stream zero",
      settings .. frame(0x1, 0x4, 0, "\130\134\132\65\138") },

    { "HEADERS on an EVEN stream id, which only a server may open",
      settings .. frame(0x1, 0x4, 2, "\130\134\132\65\138") },

    { "CONTINUATION with no HEADERS before it",
      settings .. frame(0x9, 0x4, 1, "\130") },

    { "HPACK that indexes past the end of the table",
      settings .. frame(0x1, 0x5, 1, "\255\255\255\255\255\127") },

    { "an HPACK dynamic table update larger than the table",
      settings .. frame(0x1, 0x5, 1, "\63\255\255\255\127") },

    { "WINDOW_UPDATE with a zero increment",
      settings .. frame(0x8, 0x0, 0, "\0\0\0\0") },

    { "WINDOW_UPDATE with the wrong payload length",
      settings .. frame(0x8, 0x0, 0, "\0\0") },

    { "PING with the wrong payload length",
      settings .. frame(0x6, 0x0, 0, "short") },

    { "PING on a stream, which is a connection-level frame",
      settings .. frame(0x6, 0x0, 1, string.rep("\0", 8)) },

    { "RST_STREAM with the wrong payload length",
      settings .. frame(0x3, 0x0, 1, "\0\0") },

    { "RST_STREAM for a stream that was never opened",
      settings .. frame(0x3, 0x0, 99, "\0\0\0\0") },

    { "PRIORITY making a stream depend on itself",
      settings .. frame(0x2, 0x0, 1, "\0\0\0\1\16") },

    { "GOAWAY from the client, then more frames after it",
      settings .. frame(0x7, 0x0, 0, "\0\0\0\0\0\0\0\0")
               .. frame(0x1, 0x4, 3, "\130\134\132\65\138") },

    { "the preface and then nothing at all",
      "" },

    { "a truncated frame header, three bytes and a hang up",
      settings .. "\0\0\1" },

    { "many empty frames in one write",
      settings .. string.rep(frame(0x6, 0x1, 0, string.rep("\0", 8)), 200) },
  }
end

describe("hostile HTTP/2 frames", function()
  it("survive, and the server still answers the next client", function()
    local cases = corpus()
    local outcomes, still_serving = {}, {}

    local app = akkar.new()
    app:get("/ping", function() return { pong = true } end)

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, h2c = true, check_capabilities = false,
                  log = akkar.log.new { level = "error",
                                        sink = function() end } }
      end)
    end)

    cq:wrap(function()
      cqueues.sleep(0.3)                       -- the listener is up by here

      for i, case in ipairs(cases) do
        local label, bytes = case[1], case[2]

        -- THE HOSTILE CONNECTION. Non-blocking with an `onerror` that
        -- returns, so a server that closes on us yields an error value
        -- instead of raising through the controller.
        local hostile = socket.connect("127.0.0.1", PORT)
        if hostile then
          hostile:setmode("bn", "bn")
          hostile:onerror(function(_, _, why) return why end)
          -- BOUNDED, AND THE FIRST VERSION WAS NOT. `read(64, 1)` is not
          -- "64 bytes, one second" -- cqueues takes a list of FORMATS, so it
          -- read sixty-four bytes and then one more, and blocked until both
          -- arrived. One hostile peer that answers nothing stalled the whole
          -- controller, and all twenty-two cases reported the server dead
          -- including the one that sends nothing at all.
          hostile:settimeout(1)
          hostile:write(PREFACE)
          if #bytes > 0 then hostile:write(bytes) end
          hostile:flush()
          -- `-64` is "up to sixty-four bytes", so a shorter refusal returns
          -- rather than waiting for a sixty-fourth byte that is not coming.
          -- A refusal, a GOAWAY or a close are all correct here; what is not
          -- correct is blocking for ever.
          hostile:read(-64)
          hostile:close()
        end
        outcomes[i] = ("%s: connected=%s"):format(label, tostring(not not hostile))

        -- AND THE PROPERTY THAT MATTERS. A fresh, ordinary client, over h2,
        -- immediately after. One hostile peer must not take the door off its
        -- hinges.
        local req = request.new_from_uri(
          ("http://127.0.0.1:%d/ping"):format(PORT))
        req.version = 2
        local ok, headers, stream = pcall(function()
          local h, s = req:go(3)
          return h, s
        end)
        if ok and headers then
          local body = stream and stream:get_body_as_string(3)
          if stream then stream:shutdown() end
          still_serving[i] = (headers:get ":status" == "200"
                              and body == '{"pong":true}')
        else
          still_serving[i] = false
        end
      end

      app:stop(2)
    end)
    assert(cq:loop(90))

    -- Reported all at once: one failing frame should not hide the twenty
    -- after it, and a list of which shapes broke is the useful output.
    local broke = {}
    for i, case in ipairs(cases) do
      if not still_serving[i] then
        broke[#broke + 1] = ("  %s"):format(case[1])
      end
    end
    assert.equal(0, #broke,
      "the server stopped answering after:\n" .. table.concat(broke, "\n"))

    -- And the run has to have done something. Every case reporting
    -- "connected=false" would satisfy the assertion above and prove nothing.
    assert.equal(#cases, #outcomes)
    local connected = 0
    for _, line in ipairs(outcomes) do
      if line:find "connected=true" then connected = connected + 1 end
    end
    assert.is_true(connected >= #cases - 1,
      ("only %d of %d hostile connections were even established")
        :format(connected, #cases))
  end)

  it("bounds a CONTINUATION flood, the CVE-2024-27983 class", function()
    -- A HEADERS frame without END_HEADERS, then CONTINUATION frames that never
    -- end the block. The vendored h2_stream caps the SUM of the header
    -- fragments at 400 KB (`MAX_HEADER_BUFFER_SIZE`, rechecked on every
    -- CONTINUATION), so an unbounded flood is refused rather than buffered.
    -- Proven end to end on the box at ~448 KB / GOAWAY 0x1;
    -- `bench/study/continuation-flood.py` is that proof. This is the cheap
    -- regression: send past the cap and require the server to still answer.
    local survived
    local app = akkar.new()
    app:get("/ping", function() return { pong = true } end)

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT + 2, h2c = true, check_capabilities = false,
                  log = akkar.log.new { level = "error",
                                        sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.3)
      local c = socket.connect("127.0.0.1", PORT + 2)
      c:setmode("bn", "bn")
      c:onerror(function(_, _, why) return why end)
      c:settimeout(2)
      c:write(PREFACE)
      c:write(frame(0x4, 0x0, 0))                       -- SETTINGS
      -- HEADERS, no END_HEADERS: a short valid-enough HPACK block.
      c:write(frame(0x1, 0x0, 1, "\130\134\132\65\138"))
      -- 32 CONTINUATION frames of 16 KB = 512 KB, past the 400 KB cap. Never
      -- END_HEADERS. `pcall` the writes, because a refused connection closes
      -- under us mid-flood and that is the point.
      local blob = string.rep("\0", 16384)
      for _ = 1, 32 do
        local ok = pcall(function() c:write(frame(0x9, 0x0, 1, blob)); c:flush() end)
        if not ok then break end
      end
      c:read(-64)
      c:close()

      -- THE PROPERTY: an ordinary client, right after, is still answered.
      local req = request.new_from_uri(
        ("http://127.0.0.1:%d/ping"):format(PORT + 2))
      req.version = 2
      local ok, h, stream = pcall(function()
        local hh, ss = req:go(3); return hh, ss
      end)
      survived = ok and h and h:get ":status" == "200"
      if stream then pcall(function() stream:get_body_as_string(2) end); stream:shutdown() end
      app:stop(2)
    end)
    assert(cq:loop(30))

    assert.is_true(survived,
      "the server did not survive a CONTINUATION flood past its header cap")
  end)

  it("bounds a flood of EMPTY CONTINUATION frames, which the byte cap cannot see",
     function()
    -- The case above sends 32 frames of 16 KB and passes, because 512 KB
    -- crosses the 400 KB byte cap. It tests the variant the cap catches.
    --
    -- A CONTINUATION frame with a ZERO-LENGTH payload adds nothing to that
    -- total, so `len > MAX_HEADER_BUFFER_SIZE` can never fire on a stream of
    -- them -- while each one still appends to the buffer table.
    -- `h2_connection` forbids every other frame type while a header block is
    -- open, so the attacker is confined to exactly the frame that works, and
    -- nothing puts a deadline on an incomplete block.
    --
    -- Measured with the accumulation isolated from the socket: two million
    -- empty frames accepted, byte total still zero, 32 MB of Lua heap, nothing
    -- refused. On the wire that is nine bytes per frame.
    --
    -- The bound is now a frame COUNT beside the byte cap.
    --
    -- This asserts the REFUSAL, not survival. Survival is what the case above
    -- asserts, and it is the wrong instrument here: measured, a server with no
    -- frame cap at all survives forty thousand empty frames comfortably, so a
    -- survival assertion passes with the bound removed and proves nothing. The
    -- attack needs millions of frames to exhaust memory and a test must not.
    --
    -- So this drives `handle_continuation_frame` directly, past the cap, and
    -- requires it to answer with an error rather than keep appending.
    local h2_stream = require "akkar.vendor.http.h2_stream"
    local handler = h2_stream.frame_handlers[0x9]
    assert.is_function(handler, "no CONTINUATION handler to drive")

    -- The minimum a CONTINUATION handler reads: an open header block on a
    -- connection, and the counters it accumulates into.
    local connection = {
      recv_headers_buffer = {},
      recv_headers_buffer_items = 1,
      recv_headers_buffer_length = 0,
      recv_headers_end_stream = false,
      need_continuation = true,
    }
    local stream = { connection = connection, id = 1 }
    connection.recv_headers_buffer[1] = ""

    local accepted, err = 0, nil
    for _ = 1, 200000 do
      local ok, why = handler(stream, 0x0, "")   -- zero-length payload
      if ok == nil then err = why break end
      accepted = accepted + 1
    end

    assert.is_truthy(err,
      ("%d empty CONTINUATION frames were accepted with no refusal; the byte "
       .. "cap cannot see them and nothing else counts"):format(accepted))
    assert.equal(0, connection.recv_headers_buffer_length,
      "the byte total moved, so this was not the empty-frame path")
    assert.is_true(accepted < 200000,
      "every frame was accepted")
  end)

  it("does not accept a frame larger than it advertises", function()
    -- SETTINGS_MAX_FRAME_SIZE defaults to 16,384 and akkar sends no override.
    -- A peer that ignores it must be refused rather than allocated for: this
    -- is the shape where a framing layer turns one packet into a memory
    -- exhaustion.
    local answered
    local app = akkar.new()
    app:get("/ping", function() return { pong = true } end)

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT + 1, h2c = true, check_capabilities = false,
                  log = akkar.log.new { level = "error",
                                        sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.3)
      local hostile = socket.connect("127.0.0.1", PORT + 1)
      hostile:setmode("bn", "bn")
      hostile:onerror(function(_, _, why) return why end)
      hostile:settimeout(2)
      hostile:write(PREFACE)
      hostile:write(frame(0x4, 0x0, 0))
      -- A megabyte on one DATA frame, sixty-four times the advertised
      -- maximum, with a length field that says so.
      hostile:write(frame(0x0, 0x0, 1, string.rep("x", 1024 * 1024)))
      hostile:flush()
      answered = hostile:read(-64)
      hostile:close()

      local req = request.new_from_uri(
        ("http://127.0.0.1:%d/ping"):format(PORT + 1))
      req.version = 2
      local ok, headers, stream = pcall(function()
        local h, s = req:go(3)
        return h, s
      end)
      if stream then stream:shutdown() end
      assert.is_true(ok and headers ~= nil and headers:get ":status" == "200",
        "the server did not survive a frame sixty-four times the maximum")
      app:stop(2)
    end)
    assert(cq:loop(30))

    -- Either a GOAWAY or a close is a refusal. Silence with the connection
    -- still open would mean the megabyte was being buffered.
    assert.is_true(answered == nil or #answered > 0,
      "the oversized frame was neither refused nor answered")
  end)
end)
