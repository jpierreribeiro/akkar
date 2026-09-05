--[[
A peer is allowed to advertise a zero HTTP/2 stream window. It is not allowed
to hold a server request for ever by never sending WINDOW_UPDATE afterwards.

The request below is valid and its response is tiny. The hostile part is only
SETTINGS_INITIAL_WINDOW_SIZE=0 followed by silence. This reaches the exact
wait inside h2_stream:write_chunk without needing traffic volume or a remote
machine, and proves the runtime's write budget releases its in-flight slot
while the peer remains connected.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local socket  = require "cqueues.socket"
local headers = require "akkar.vendor.http.headers"
local hpack   = require "akkar.vendor.http.hpack"
local request = require "http.request"
local h2_stream = require "akkar.vendor.http.h2_stream"
local h2_connection = require "akkar.vendor.http.h2_connection"

local PORT = 8681
local PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

local function frame(kind, flags, stream, payload)
  payload = payload or ""
  local n = #payload
  return string.char((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff,
                     kind, flags,
                     (stream >> 24) & 0x7f, (stream >> 16) & 0xff,
                     (stream >> 8) & 0xff, stream & 0xff) .. payload
end

local function request_block()
  local h = headers.new()
  h:append(":method", "GET")
  h:append(":scheme", "http")
  h:append(":authority", "127.0.0.1:" .. PORT)
  h:append(":path", "/answer")
  local encoder = hpack.new(4096)
  encoder:encode_headers(h)
  return encoder:render_data()
end

describe("HTTP/2 hostile flow control", function()
  it("refuses WINDOW_UPDATE overflow on the connection and a stream", function()
    local handler = assert(h2_stream.frame_handlers[0x8])
    local connection = {
      peer_flow_credits = 0x7fffffff,
      peer_flow_credits_change = { signal = function() end },
    }
    local stream0 = { id = 0, connection = connection }
    local ok0, err0 = handler(stream0, 0, string.pack(">I4", 1))
    assert.is_nil(ok0)
    assert.equal(0x3, err0.code) -- FLOW_CONTROL_ERROR
    assert.equal(0x7fffffff, connection.peer_flow_credits)

    local stream = {
      id = 1, state = "open", connection = connection,
      peer_flow_credits = 0x7fffffff,
      peer_flow_credits_change = { signal = function() end },
    }
    local ok1, err1 = handler(stream, 0, string.pack(">I4", 1))
    assert.is_nil(ok1)
    assert.equal(0x3, err1.code)
    assert.is_true(err1.stream_error)
    assert.equal(0x7fffffff, stream.peer_flow_credits)
  end)

  it("tracks a SETTINGS window reduction below zero until credit returns", function()
    local signalled = 0
    local stream = {
      peer_flow_credits = 10,
      peer_flow_credits_change = {
        signal = function() signalled = signalled + 1 end,
      },
    }
    local connection = setmetatable({
      peer_settings = { [0x4] = 65535 },
      streams = { [1] = stream },
      peer_settings_cond = { signal = function() end },
    }, h2_connection.mt)

    connection:set_peer_settings { [0x4] = 0 }
    assert.equal(10 - 65535, stream.peer_flow_credits)
    assert.equal(1, signalled)

    -- WINDOW_UPDATE is added to the negative balance; sending may resume only
    -- after the whole SETTINGS reduction has been repaid.
    local handler = assert(h2_stream.frame_handlers[0x8])
    stream.id, stream.state, stream.connection = 1, "open", connection
    local ok = handler(stream, 0, string.pack(">I4", 65525))
    assert.is_true(ok)
    assert.equal(0, stream.peer_flow_credits)
  end)

  it("bounds a peer that advertises zero window and never updates it", function()
    local app = akkar.new()
    app:get("/answer", function() return akkar.raw("answer") end)
    app:get("/ping", function() return { pong = true } end)

    local run_error, slot_after_budget, ping_status
    local cq = cqueues.new()
    cq:wrap(function()
      local ok, why = pcall(function()
        app:run { port = PORT, h2c = true, write_timeout = 0.05,
                  check_capabilities = false,
                  log = akkar.log.new { level = "error", sink = function() end } }
      end)
      if not ok then run_error = why end
    end)
    cq:wrap(function()
      cqueues.sleep(0.25)
      if run_error then return end

      local hostile = assert(socket.connect("127.0.0.1", PORT))
      hostile:setmode("bn", "bn")
      hostile:onerror(function(_, _, why) return why end)
      hostile:settimeout(2)
      hostile:write(PREFACE)
      -- SETTINGS_INITIAL_WINDOW_SIZE (0x4) = zero.
      hostile:write(frame(0x4, 0, 0, string.pack(">I2I4", 0x4, 0)))
      hostile:write(frame(0x1, 0x5, 1, request_block())) -- END_HEADERS|END_STREAM
      hostile:flush()

      -- The peer stays connected and sends no WINDOW_UPDATE. The response
      -- writer must give the request slot back on its own budget.
      cqueues.sleep(0.2)
      slot_after_budget = app.in_flight

      local h, stream = request.new_from_uri(
        ("http://127.0.0.1:%d/ping"):format(PORT)):go(2)
      if h then ping_status = h:get ":status" end
      if stream then stream:get_body_as_string(2); stream:shutdown() end

      hostile:close()
      app:stop(1)
    end)
    assert(cq:loop(5))

    assert.is_nil(run_error, tostring(run_error))
    assert.equal(0, slot_after_budget,
      "a zero-window peer kept the request in flight past write_timeout")
    assert.equal("200", ping_status,
      "the server stopped answering other clients after the stalled write")
  end)
end)
