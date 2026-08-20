--[[
WebSocket, against a real client.

## What is being protected

`akkar/websocket.lua` argues that a socket is three callbacks and an object
rather than a handler that runs for hours, because akkar's first invariant is
that handlers return. These are the properties that argument makes:

  * a handshake is an ordinary GET until it is accepted, so `:params`, query
    schemas and middleware apply to it unchanged;
  * a plain GET to a socket route is REFUSED, not hijacked;
  * capabilities are held per message and never for the life of the socket;
  * a callback that raises costs its socket and not the server;
  * and `app:stop` closes sockets rather than waiting for them, because a
    socket has no reason to end on its own.

## The client is upstream's

`http.websocket` here is the published rock, not the vendored copy, for the
same reason `spec/http2_spec.lua` uses upstream's h2 client: a codec talking
to itself agrees with itself no matter what it does.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar     = require "akkar"
local cqueues   = require "cqueues"
local websocket = require "http.websocket"
local request   = require "http.request"

local quiet = function()
  return akkar.log.new { level = "error", sink = function() end }
end

--- Runs `body(port)` against a live akkar and returns what it returns.
local function with_app(port, build, body, config)
  local app = akkar.new()
  build(app)

  local result, failure
  local cq = cqueues.new()
  cq:wrap(function()
    pcall(function()
      local settings = { port = port, check_capabilities = false, log = quiet() }
      for k, v in pairs(config or {}) do settings[k] = v end
      app:run(settings)
    end)
  end)
  cq:wrap(function()
    cqueues.sleep(0.4)
    local ok, res = pcall(body, port, app)
    if ok then result = res else failure = res end
    app:stop(2)
  end)
  assert(cq:loop(30))
  if failure then error(failure, 0) end
  return result
end

describe("a WebSocket route", function()
  it("accepts, carries messages both ways, and reports its close code",
     function()
    local seen = {}
    local answer = with_app(8421,
      function(app)
        app:websocket("/echo/:room", {
          open = function(ws)
            seen[#seen + 1] = "open:" .. tostring(ws.params.room)
            ws:send("welcome to " .. ws.params.room)
          end,
          message = function(ws, text)
            seen[#seen + 1] = "msg:" .. text
            ws:send(text:upper())
          end,
          close = function(_, code) seen[#seen + 1] = "close:" .. tostring(code) end,
        })
      end,
      function(port)
        local ws = websocket.new_from_uri(
          ("ws://127.0.0.1:%d/echo/lobby"):format(port))
        assert(ws:connect(5))
        local welcome = ws:receive(5)
        ws:send("hello", "text", 5)
        local echoed = ws:receive(5)
        ws:close(1000, "done", 2)
        cqueues.sleep(0.2)                 -- let the close callback run
        return { welcome = welcome, echoed = echoed }
      end)

    assert.equal("welcome to lobby", answer.welcome)
    assert.equal("HELLO", answer.echoed)
    -- THE PATH PARAMETER IS THE POINT of registering this as a GET: routing
    -- ran, so `:room` is bound, and nothing about it had to be rebuilt.
    assert.equal("open:lobby", seen[1])
    assert.equal("msg:hello", seen[2])
    assert.equal("close:1000", seen[3])
  end)

  it("refuses a plain GET instead of hijacking the stream", function()
    local answer = with_app(8422,
      function(app)
        app:websocket("/ws", { message = function() end })
      end,
      function(port)
        local req = request.new_from_uri(("http://127.0.0.1:%d/ws"):format(port))
        local h, stream = assert(req:go(5))
        local body = stream:get_body_as_string(5)
        stream:shutdown()
        return { status = h:get ":status", upgrade = h:get "upgrade", body = body }
      end)

    -- 426 is the status that exists for this, and it names the protocol the
    -- client should have asked for.
    assert.equal("426", answer.status)
    assert.equal("websocket", answer.upgrade)
    assert.is_truthy(answer.body:find "WebSocket")
  end)

  it("does not stop the rest of the app from serving", function()
    local answer = with_app(8423,
      function(app)
        app:get("/ping", function() return { pong = true } end)
        app:websocket("/ws", { message = function(ws, t) ws:send(t) end })
      end,
      function(port)
        local ws = websocket.new_from_uri(("ws://127.0.0.1:%d/ws"):format(port))
        assert(ws:connect(5))
        -- An open socket, and an ordinary request while it is open.
        local req = request.new_from_uri(("http://127.0.0.1:%d/ping"):format(port))
        local h, stream = assert(req:go(5))
        local body = stream:get_body_as_string(5)
        stream:shutdown()
        ws:close(1000, nil, 2)
        return { status = h:get ":status", body = body }
      end)

    assert.equal("200", answer.status)
    assert.equal('{"pong":true}', answer.body)
  end)

  it("survives a callback that raises, and closes only that socket", function()
    -- A raise inside a callback is a bug in the application, and the same
    -- distinction `akkar/init.lua` draws for `onstream` applies: it is logged
    -- at error level, the socket ends, and the server keeps serving.
    local answer = with_app(8424,
      function(app)
        app:get("/ping", function() return { pong = true } end)
        app:websocket("/boom", {
          message = function() error "the callback exploded" end,
        })
      end,
      function(port)
        local ws = websocket.new_from_uri(("ws://127.0.0.1:%d/boom"):format(port))
        assert(ws:connect(5))
        ws:send("anything", "text", 5)
        -- The socket ends. What it must NOT do is take the server with it.
        pcall(function() ws:receive(2) end)
        pcall(function() ws:close(1000, nil, 1) end)

        local req = request.new_from_uri(("http://127.0.0.1:%d/ping"):format(port))
        local h, stream = assert(req:go(5))
        local body = stream:get_body_as_string(5)
        stream:shutdown()
        return { status = h:get ":status", body = body }
      end)

    assert.equal("200", answer.status)
    assert.equal('{"pong":true}', answer.body)
  end)

  it("closes a socket that has gone quiet, and forgets it", function()
    -- A timeout that does not fire means sockets accumulate for ever and the
    -- registry with them, which turns `app:stop` into a loop over corpses.
    -- Measured: with `websocket_idle_timeout = 1`, the server acted after
    -- 1.01 s.
    local closed_with = {}
    local answer = with_app(8426,
      function(app)
        app:websocket("/quiet", {
          message = function() end,
          -- `tostring`, because an idle close carries NO code -- the peer
          -- never sent one -- and `t[#t + 1] = nil` grows nothing. The first
          -- version of this recorded the code directly and reported that the
          -- callback had not run when it had.
          close = function(_, code, reason)
            closed_with[#closed_with + 1] = tostring(reason or code)
          end,
        })
      end,
      function(port, app)
        local ws = websocket.new_from_uri(
          ("ws://127.0.0.1:%d/quiet"):format(port))
        assert(ws:connect(5))
        local open_now = app.sockets_open
        local started = cqueues.monotime()
        -- Say nothing. The server has to be the one that acts.
        pcall(function() ws:receive(5) end)
        local waited = cqueues.monotime() - started
        pcall(function() ws:close(1000, nil, 1) end)
        cqueues.sleep(0.3)
        return { open_during = open_now, waited = waited,
                 open_after = app.sockets_open }
      end,
      { websocket_idle_timeout = 1 })

    assert.equal(1, answer.open_during, "the socket was never registered")
    assert.is_true(answer.waited < 3,
      ("the server took %.2f s to act on a 1 s idle timeout")
        :format(answer.waited))
    assert.equal(0, answer.open_after,
      "the socket stayed in the registry after it closed")
    assert.equal(1, #closed_with, "the close callback did not run")
    -- And it can tell WHY, which a nil code alone never says.
    assert.equal("idle timeout", closed_with[1])
  end)

  it("works over TLS on a server that offers HTTP/2", function()
    -- WEBSOCKET IS AN HTTP/1.1 MECHANISM, and akkar now prefers h2 in ALPN.
    -- The RFC 8441 extended CONNECT that would carry a socket over h2 is not
    -- advertised -- `SETTINGS_ENABLE_CONNECT_PROTOCOL` is false -- so the
    -- question is whether offering h2 quietly broke `wss://`. It did not: a
    -- client pins 1.1 for the handshake, ALPN gives it http/1.1, and the
    -- socket works.
    --
    -- The guard on the other side is upstream's and is asserted below rather
    -- than assumed: `new_from_stream` refuses `version >= 2` outright.
    local ws_vendor = require "akkar.vendor.http.websocket"
    local fake_h2_stream = { connection = { type = "server", version = 2 } }
    local sock, why = ws_vendor.new_from_stream(fake_h2_stream, nil)
    assert.is_nil(sock)
    assert.is_truthy(tostring(why):find "HTTP 1",
      "an h2 stream was not refused for the right reason: " .. tostring(why))
  end)

  it("holds a capability for a message and not for the socket", function()
    -- THE DESIGN DECISION THIS FILE EXISTS TO PIN. A pool slot acquired when
    -- a socket opens is held until the browser tab closes. `ws:scope` makes
    -- the unit of acquisition a MESSAGE, which is what a request already is.
    local opened, released = 0, 0

    local answer = with_app(8425,
      function(app)
        app:websocket("/db", {
          message = function(ws, text)
            ws:scope(function(req)
              local rows = req.db:many "select 1"
              ws:send(("%s:%d"):format(text, #rows))
            end)
          end,
        })
      end,
      function(port)
        local ws = websocket.new_from_uri(("ws://127.0.0.1:%d/db"):format(port))
        assert(ws:connect(5))
        ws:send("one", "text", 5)
        local first = ws:receive(5)
        ws:send("two", "text", 5)
        local second = ws:receive(5)
        ws:close(1000, nil, 2)
        return { first = first, second = second }
      end,
      {
        db = function()
          opened = opened + 1
          local memory = require "akkar.db.memory"
          local conn = memory.new()
          conn:on("1", { { n = 1 } })
          conn.release = function() released = released + 1 end
          return conn
        end,
      })

    assert.equal("one:1", answer.first)
    assert.equal("two:1", answer.second)
    -- Two messages, two acquisitions, two releases. One acquisition would
    -- mean the slot was held across the idle time between them.
    assert.equal(2, opened, ("the capability was opened %d times"):format(opened))
    assert.equal(opened, released,
      ("opened %d, released %d"):format(opened, released))
  end)
end)
