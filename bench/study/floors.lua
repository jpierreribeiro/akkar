--[[
The three floors under `/ping`, so the gap against Gin can be attributed
rather than guessed.

`docs/PERFORMANCE-STUDY.md` lists as line of investigation 7: *"How much of
the overhead is lua-http and cqueues rather than akkar?"* It was never
answered, and without it "akkar is 5x slower than Gin" cannot be split into
the part akkar could fix and the part it is standing on.

Three servers, each answering the same nine bytes on the same event loop:

  cqueues   a raw TCP socket, a hand-written 63-byte HTTP response, no
            parsing at all. This is the ceiling of the event loop itself --
            nothing written in Lua on cqueues can beat it.

  lua-http  the substrate akkar actually uses: real request parsing, real
            header objects, real response writing, and no akkar.

  akkar     `app:get("/ping", ...)`, which is the published number.

Run one at a time, pinned identically, measured by the same wrk.

  lua5.4 bench/study/floors.lua <cqueues|luahttp> [port]
]]

local which = arg[1] or "cqueues"
local port  = tonumber(arg[2]) or 8500

local cqueues = require "cqueues"
local socket  = require "cqueues.socket"

if which == "cqueues" then
  -- THE EVENT LOOP ALONE.
  --
  -- No HTTP parsing: the request is read until the blank line and thrown
  -- away, and a fixed response is written back. It is not a web server and is
  -- not meant to be -- it is the number that says how much of the cost is
  -- unavoidable on this substrate before any framework exists.
  local BODY = '{"pong":true}'
  local RESPONSE = table.concat {
    "HTTP/1.1 200 OK\r\n",
    "Content-Type: application/json\r\n",
    "Content-Length: ", tostring(#BODY), "\r\n",
    "\r\n", BODY,
  }

  local server = assert(socket.listen {
    host = "127.0.0.1", port = port, reuseport = true,
  })

  local cq = cqueues.new()
  cq:wrap(function()
    for conn in server:clients() do
      cq:wrap(function()
        conn:setmode("bn", "bn")
        conn:onerror(function(_, _, why) return why end)
        while true do
          -- Read the request line and headers, keep nothing.
          local line = conn:read "*l"
          if not line then break end
          -- The blank line that ends the headers arrives as "\r", not "".
          -- `*l` drops the newline; in BINARY mode it does not drop the
          -- carriage return, so testing for the empty string alone loops for
          -- ever and the server accepts connections it never answers.
          repeat
            local h = conn:read "*l"
          until not h or h == "" or h == "\r"
          if not conn:write(RESPONSE) then break end
          conn:flush()
        end
        conn:close()
      end)
    end
  end)
  io.stderr:write(("floor=cqueues port=%d\n"):format(port))
  assert(cq:loop())

elseif which == "luahttp" then
  -- THE SUBSTRATE akkar IS BUILT ON, with akkar removed.
  --
  -- Same library, same parsing, same header objects, same write path. What is
  -- missing is the router, the middleware chain, the request table, the
  -- deadline, the capabilities and the JSON encoder -- everything akkar adds.
  local http_server  = require "http.server"
  local http_headers = require "http.headers"

  local BODY = '{"pong":true}'

  local server = assert(http_server.listen {
    -- `tls = false` STATED, not omitted. lua-http does not default a plain
    -- listener: leave it out and the server accepts the connection and then
    -- waits for a handshake that a plain HTTP client never sends, so it looks
    -- alive, listens on the port, and answers nothing.
    host = "127.0.0.1", port = port, reuseport = true, tls = false,
    onstream = function(_, stream)
      -- The request must be READ before it is answered. lua-http will not
      -- write a response on a stream whose headers have not been consumed,
      -- and an onerror that swallows silently turns that into a server which
      -- listens, accepts, and answers nothing.
      local ok, err = stream:get_headers()
      if not ok then
        io.stderr:write("get_headers failed: " .. tostring(err) .. "\n")
        return
      end
      local h = http_headers.new()
      h:append(":status", "200")
      h:append("content-type", "application/json")
      h:append("content-length", tostring(#BODY))
      assert(stream:write_headers(h, false))
      assert(stream:write_chunk(BODY, true))
    end,
    onerror = function(_, context, op, err)
      io.stderr:write(("onerror ctx=%s op=%s err=%s\n")
        :format(tostring(context), tostring(op), tostring(err)))
    end,
  })
  io.stderr:write(("floor=luahttp port=%d\n"):format(port))
  assert(server:listen())
  assert(server:loop())

else
  io.stderr:write("usage: floors.lua <cqueues|luahttp> [port]\n")
  os.exit(2)
end
