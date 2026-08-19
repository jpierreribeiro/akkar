--- WebSocket, as a route kind rather than as a second programming model.
---
--- ## The problem this had to solve first
---
--- akkar's first invariant is that **handlers return the response and never
--- mutate a context**. A WebSocket connection has no response: it opens, it
--- lives, and messages arrive on it in both directions for as long as both
--- ends want. A handler that "handles" one cannot return, and a design that
--- let it run for hours inside the request path would quietly undo the
--- guarantee the rest of the framework is built on.
---
--- So a socket is not a long-running handler here. It is **three callbacks
--- and an object**:
---
---     app:websocket("/chat/:room", {
---       open    = function(ws) ws:send "hello" end,
---       message = function(ws, text) ws:send(text:upper()) end,
---       close   = function(ws, code, reason) end,
---     })
---
--- `ws:send` and `ws:close` are the only mutations, they are on an explicit
--- object rather than on a context, and each callback returns. The unit of
--- work is a MESSAGE, which is the same shape a request has, and everything
--- akkar knows how to do to a request applies to it.
---
--- ## Capabilities, and the slot nobody would have noticed
---
--- `req.db` inside a socket callback is the obvious thing to want and the
--- wrong thing to give. A pool slot acquired when the socket opens is held
--- until it closes -- minutes, hours, a browser tab somebody left open -- and
--- `README.md` already lists the smaller version of this under known gaps:
--- "a slow client reading a streamed export keeps a pool slot for as long as
--- it reads". At WebSocket lifetimes that is not a gap, it is an outage with
--- a delay on it.
---
--- So capabilities are acquired per unit of work, exactly as they are for a
--- request, and the unit of work is a message:
---
---     message = function(ws, text)
---       ws:scope(function(req)
---         req.db:query("insert into messages ...")
---       end)                                   -- released here, every path
---     end
---
--- One line of ceremony, and it is the line that says where the slot is held.
---
--- ## What closes a socket
---
--- Three things, and all of them are bounded:
---
---   * the peer closing it, which is ordinary;
---   * `idle_timeout` with no message in either direction, because a socket
---     that will never speak again still costs a descriptor and eight
---     kilobytes of buffer;
---   * `app:stop`, which sends a close frame to every open socket before the
---     process goes. Without the registry below, a graceful shutdown would
---     hang on `while in_flight > 0` waiting for connections that have no
---     reason to end.
local websocket = require "akkar.vendor.http.websocket"

local M = {}

--- The marker a WebSocket route's handler returns.
---
--- Routing, validation, middleware and the deadline all run first and unchanged
--- -- a WebSocket handshake IS an ordinary GET until the moment it is accepted,
--- and treating it as one means `:params`, `query` schemas and `before` hooks
--- work on it for free. `App:run` recognises this marker on the way out and
--- takes the stream over instead of writing a body.
local MARKER = {}
M.MARKER = MARKER

function M.upgrade(handlers)
  return setmetatable({ handlers = handlers }, { __index = MARKER,
                                                 __name = "akkar.websocket" })
end

function M.is_upgrade(value)
  return type(value) == "table" and getmetatable(value)
     and getmetatable(value).__index == MARKER
end

--- Is this request asking for a WebSocket at all?
---
--- Checked before the marker is honoured, so a plain GET to a socket route
--- gets an ordinary refusal rather than a hijacked stream. `upgrade` is a
--- comma-separated list and the token is case-insensitive, which is the shape
--- of the bug reports every server eventually gets.
--- `headers` here is akkar's NORMALISED table -- lower-cased keys, plain
--- indexing -- and not lua-http's headers object. The two are different types
--- with different accessors, and reaching for `:get` on the wrong one is a
--- 500 on the handshake: measured, on the first run of this file.
function M.wants_upgrade(headers)
  if not headers then return false end
  local upgrade = headers.upgrade or headers["Upgrade"]
  local connection = headers.connection or headers["Connection"]
  if type(upgrade) ~= "string" or type(connection) ~= "string" then
    return false
  end
  if not upgrade:lower():find("websocket", 1, true) then return false end
  return connection:lower():find("upgrade", 1, true) ~= nil
end

local Socket = {}
Socket.__index = Socket
Socket.__name = "akkar.websocket.socket"

--- Sends a text message. Returns true, or nil and a reason.
---
--- Never raises. A socket write fails for exactly the reason an HTTP write
--- fails -- the peer went away -- and a callback should not have to pcall
--- every `send` to survive an ordinary disconnection.
function Socket:send(text, timeout)
  if self.closed then return nil, "socket is closed" end
  local ok, err = pcall(self.ws.send, self.ws, text, "text",
                        timeout or self.send_timeout)
  if not ok then
    self.closed = true
    return nil, tostring(err)
  end
  return true
end

--- Closes the socket with a code and a reason the peer can read.
function Socket:close(code, reason, timeout)
  if self.closed then return true end
  self.closed = true
  pcall(self.ws.close, self.ws, code or 1000, reason, timeout or 2)
  return true
end

--- Runs `fn` inside an execution scope with capabilities, and releases them
--- when it returns -- on every path, including a raise.
---
--- This is where `req.db` comes from inside a socket. See the header: the slot
--- is held for the work and not for the connection.
function Socket:scope(fn)
  return self.make_scope(fn)
end

--- Serves one accepted WebSocket until it closes.
---
--- `req` is the handshake request, already routed and validated, so
--- `req.params`, `req.query` and `req.headers` are what the callbacks read.
--- `raw_headers` is lua-http's headers OBJECT, which the handshake needs and
--- `req.headers` is not: akkar normalises headers into a plain table on first
--- read, and `new_from_stream` reads `:get`.
function M.serve(stream, req, raw_headers, handlers, options)
  options = options or {}

  local ws = websocket.new_from_stream(stream, raw_headers)
  if not ws then return nil, "not a websocket handshake" end

  -- THE BOUND, BEFORE ANY MESSAGE IS READ.
  --
  -- akkar's first paragraph says bodies are bounded by default so that an
  -- unbounded request cannot happen, and a WebSocket message went through
  -- none of it. Measured on the day this shipped: one 64 MB message cost
  -- 192 MB of resident memory -- buffered, unmasked into a second string,
  -- concatenated into a third -- against an application that had set
  -- `body_limit = 1 MB`.
  --
  -- So a message is bounded by the same number a body is. It is the same
  -- promise about the same kind of thing, and a second knob would have been a
  -- second thing to forget.
  ws.max_message = options.max_message

  local ok, err = ws:accept({ headers = options.headers }, options.handshake_timeout or 10)
  if not ok then return nil, tostring(err) end

  local sock = setmetatable({
    ws = ws,
    req = req,
    id = req.id,
    log = req.log,
    params = req.params,
    query = req.query,
    headers = req.headers,
    closed = false,
    send_timeout = options.send_timeout or 10,
    make_scope = options.make_scope or function(fn) return fn(req) end,
  }, Socket)

  if options.register then options.register(sock) end

  local closed_code, closed_reason
  -- WHY THE SOCKET ENDED, which the close callback cannot otherwise tell.
  -- A peer that closes sends a code; an idle timeout is akkar's own decision
  -- and the peer sent nothing, so the code is nil either way round without
  -- this. Inventing a code the peer never sent would be a lie in a field that
  -- exists to report what the peer said, so the REASON carries it instead.
  local timed_out = false

  local function safely(name, fn, ...)
    if not fn then return true end
    local fine, why = pcall(fn, ...)
    if not fine and req.log then
      -- A CALLBACK THAT RAISED IS NOT TRANSPORT NOISE, the same distinction
      -- `akkar/init.lua` draws for `onstream`. The socket is closed rather
      -- than left running against a handler that has already failed once.
      req.log:error("websocket callback failed",
                    { callback = name, detail = tostring(why) })
    end
    return fine
  end

  if safely("open", handlers.open, sock) then
    local idle = options.idle_timeout or 300
    while not sock.closed do
      local message, opcode = ws:receive(idle)
      if message == nil then
        timed_out = ws.got_close_code == nil
        -- nil is either the peer closing or the idle timeout expiring. Both
        -- end the socket; only the second is worth a line, because a peer
        -- going away is the ordinary case and logging it would drown the log
        -- on any real chat.
        if ws.got_close_code == nil and req.log then
          req.log:info("websocket idle", { idle_timeout = idle })
        end
        break
      end
      if opcode == "text" or opcode == "binary" then
        if not safely("message", handlers.message, sock, message, opcode) then
          break
        end
      end
    end
  end

  closed_code, closed_reason = ws.got_close_code, ws.got_close_message
  if timed_out and closed_reason == nil then
    closed_reason = "idle timeout"
  end
  sock.closed = true
  pcall(ws.close, ws, closed_code or 1000, closed_reason, 2)
  if options.unregister then options.unregister(sock) end
  safely("close", handlers.close, sock, closed_code, closed_reason)
  return true
end

return M
