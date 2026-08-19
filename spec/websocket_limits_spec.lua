--[[
A WebSocket message is bounded by the same number that bounds a body.

## The defect this was written for

`README.md`'s first paragraph says akkar turns server mistakes into impossible
states, and names one of them: "Bodies and deadlines are bounded by default, so
an unbounded request cannot happen." WebSocket shipped on 2026-08-19 and went
through none of it.

Measured the same day, against an application that had set
`body_limit = 1 MB`:

    one 64 MB message      192 MB of resident memory

Three times the message, because the payload is buffered by `sock:fill`,
unmasked into a second string, and concatenated into a third. One client, no
credentials beyond the handshake, and the process is gone.

## What is bounded, and where

Two places, because one is not enough:

  * **the frame**, on the length the peer DECLARED, before `fill` commits a
    byte of it. A check after the fill has already paid for the attack;
  * **the sum of the fragments**, which the per-frame bound cannot see. A
    thousand fragments of a megabyte each are a thousand legal frames and one
    illegal message, and that is where an attacker looks second.

The refusal is close code **1009**, which RFC 6455 defines for exactly this and
which tells a client to send less rather than that it did something wrong.

## Why it reuses `body_limit`

It is the same promise about the same kind of thing, and a separate knob is a
separate thing to forget. `websocket_max_message` exists for an application
that genuinely wants them different, and defaults to `body_limit`.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local socket  = require "cqueues.socket"

local LIMIT = 64 * 1024

--- One masked client frame. Built by hand because the point is to send frames
--- a client library would not.
local function frame(fin, opcode, payload)
  local b1 = (fin and 0x80 or 0) | opcode
  local n = #payload
  local out
  if n < 126 then
    out = string.char(b1, 0x80 | n)
  elseif n < 65536 then
    out = string.char(b1, 0x80 | 126, (n >> 8) & 0xff, n & 0xff)
  else
    out = string.char(b1, 0x80 | 127)
    for i = 7, 0, -1 do out = out .. string.char((n >> (i * 8)) & 0xff) end
  end
  local key = "\1\2\3\4"
  local masked = {}
  for i = 1, n do
    masked[i] = string.char(payload:byte(i) ~ key:byte((i - 1) % 4 + 1))
  end
  return out .. key .. table.concat(masked)
end

--- Reads one frame back; returns its opcode and, for a close, its code.
local function read_reply(c)
  local head = c:read(2)
  if not head or #head < 2 then return nil end
  local b1, b2 = head:byte(1, 2)
  local opcode, len = b1 & 0x0f, b2 & 0x7f
  if len == 126 then
    local ext = c:read(2)
    len = (ext:byte(1) << 8) | ext:byte(2)
  end
  local body = len > 0 and c:read(len) or ""
  if opcode == 0x8 and #body >= 2 then
    return opcode, (body:byte(1) << 8) | body:byte(2)
  end
  return opcode
end

local function run(port, body)
  local delivered = {}

  local app = akkar.new()
  app:websocket("/ws", {
    message = function(_, text) delivered[#delivered + 1] = #text end,
  })

  local function connect()
    local c = socket.connect("127.0.0.1", port)
    c:setmode("bn", "bn")
    c:onerror(function(_, _, why) return why end)
    c:settimeout(10)
    c:write("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n"
            .. "Connection: Upgrade\r\n"
            .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            .. "Sec-WebSocket-Version: 13\r\n\r\n")
    c:flush()
    local status = c:read "*l"
    repeat local l = c:read "*l" until not l or l == "" or l == "\r"
    return c, status
  end

  local result, failure
  local cq = cqueues.new()
  cq:wrap(function()
    pcall(function()
      app:run { port = port, check_capabilities = false, body_limit = LIMIT,
                log = akkar.log.new { level = "error", sink = function() end } }
    end)
  end)
  cq:wrap(function()
    cqueues.sleep(0.4)
    local ok, res = pcall(body, connect, delivered)
    if ok then result = res else failure = res end
    app:stop(2)
  end)
  assert(cq:loop(30))
  if failure then error(failure, 0) end
  return result, delivered
end

describe("how many sockets there may be", function()
  it("refuses past websocket_max_connections, and keeps serving HTTP",
     function()
    -- THE INTERACTION NOBODY READS ABOUT UNTIL IT HAPPENS. A socket is a
    -- connection that lasts, and `max_concurrent` counts connections.
    -- Measured before this bound existed: ten IDLE sockets against
    -- `max_concurrent = 10`, and the eleventh client -- an ordinary GET to an
    -- ordinary route -- was never accepted at all. A chat feature took the
    -- API down with it.
    local request = require "http.request"
    local port = 8465
    local CEILING = 3

    local app = akkar.new()
    app:get("/ping", function() return { pong = true } end)
    app:websocket("/ws", { message = function() end })

    local accepted, refused, ping_status = 0, 0, nil
    local held = {}

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = port, check_capabilities = false,
                  websocket_max_connections = CEILING,
                  log = akkar.log.new { level = "error",
                                        sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.4)
      for _ = 1, CEILING + 3 do
        local c = socket.connect("127.0.0.1", port)
        c:setmode("bn", "bn")
        c:onerror(function(_, _, why) return why end)
        c:settimeout(5)
        c:write("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n"
                .. "Connection: Upgrade\r\n"
                .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                .. "Sec-WebSocket-Version: 13\r\n\r\n")
        c:flush()
        local status = c:read "*l"
        repeat local l = c:read "*l" until not l or l == "" or l == "\r"
        if status and status:find "101" then
          accepted = accepted + 1
          held[#held + 1] = c
        else
          refused = refused + 1
          c:close()
        end
      end

      -- The point of the ceiling: ordinary requests still get through.
      local ok, h, st = pcall(function()
        local hh, ss = request.new_from_uri(
          ("http://127.0.0.1:%d/ping"):format(port)):go(3)
        return hh, ss
      end)
      if ok and h then ping_status = h:get ":status" end
      if st and st.shutdown then pcall(function() st:get_body_as_string(2) end)
        st:shutdown() end

      for _, c in ipairs(held) do c:close() end
      cqueues.sleep(0.2)
      app:stop(2)
    end)
    assert(cq:loop(30))

    assert.equal(CEILING, accepted,
      ("%d sockets were accepted against a ceiling of %d")
        :format(accepted, CEILING))
    assert.equal(3, refused, "the sockets past the ceiling were not refused")
    -- A 503 is a refusal the client can act on. A stalled accept queue is not.
    assert.equal("200", ping_status,
      "HTTP stopped being answered while sockets were at capacity")
  end)
end)

describe("a WebSocket message", function()
  it("arrives whole when it is inside the limit", function()
    -- The guard must not have turned every message into a refusal. Four sizes,
    -- the last one a thousand bytes under the bound, because an off-by-one in
    -- a size check is the classic way to make a limit useless in the other
    -- direction.
    local _, delivered = run(8461, function(connect)
      local c = connect()
      for _, size in ipairs { 100, 1000, 60000, LIMIT - 1000 } do
        c:write(frame(true, 0x1, string.rep("a", size)))
        c:flush()
        cqueues.sleep(0.3)
      end
      c:close()
    end)

    assert.same({ 100, 1000, 60000, LIMIT - 1000 }, delivered)
  end)

  it("is refused with 1009 when one frame is too big", function()
    local answer, delivered = run(8462, function(connect)
      local c = connect()
      c:write(frame(true, 0x1, string.rep("b", LIMIT * 4)))
      c:flush()
      local opcode, code = read_reply(c)
      c:close()
      return { opcode = opcode, code = code }
    end)

    assert.equal(0x8, answer.opcode, "the server did not send a close frame")
    assert.equal(1009, answer.code)
    -- And it never reached the application, which is the part that matters:
    -- a callback that saw it would already have paid for it.
    assert.equal(0, #delivered)
  end)

  it("is refused with 1009 when the FRAGMENTS sum to too much", function()
    -- Every frame here is legal on its own. Bounding the frame alone would
    -- pass all twenty-one of them and hand the application 168 KB against a
    -- 64 KB limit.
    local answer, delivered = run(8463, function(connect)
      local c = connect()
      local piece = string.rep("c", 8 * 1024)
      c:write(frame(false, 0x1, piece))
      for _ = 1, 20 do
        if not c:write(frame(false, 0x0, piece)) then break end
        c:flush()
      end
      local opcode, code = read_reply(c)
      c:close()
      return { opcode = opcode, code = code }
    end)

    assert.equal(0x8, answer.opcode)
    assert.equal(1009, answer.code)
    assert.equal(0, #delivered)
  end)

  it("leaves the server serving afterwards", function()
    -- The refusal is per socket. A client that sends too much loses its own
    -- connection and nothing else.
    local _, delivered = run(8464, function(connect)
      local hostile = connect()
      hostile:write(frame(true, 0x1, string.rep("d", LIMIT * 4)))
      hostile:flush()
      read_reply(hostile)
      hostile:close()

      local ordinary, status = connect()
      assert(status and status:find "101",
             "the server stopped accepting websockets: " .. tostring(status))
      ordinary:write(frame(true, 0x1, "still here"))
      ordinary:flush()
      cqueues.sleep(0.3)
      ordinary:close()
    end)

    assert.same({ 10 }, delivered)          -- "still here"
  end)
end)
