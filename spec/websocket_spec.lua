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
