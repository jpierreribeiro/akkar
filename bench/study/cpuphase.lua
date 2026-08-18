-- Where does a request's CPU go, by the same ablation the allocation study
-- used?
--
-- Allocation said: vendored HTTP 54%, akkar 44%, cqueues ~0. That is bytes.
-- CPU is a different question and nobody has asked it -- and it is the one
-- that decides what a C layer could ever be worth, because a C parser buys
-- CPU and not bytes.
--
-- Three servers answering the SAME wire bytes, driven by the same client in
-- the same process:
--
--   bare      a cqueues socket server writing a fixed string
--   http      the vendored HTTP stack, no akkar
--   akkar     everything
--
-- The client is in the process for all three, so absolutes are meaningless
-- and differences are exact. Same bargain as `measure-http.lua`.
package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local socket  = require "cqueues.socket"

local N    = tonumber(os.getenv "N") or 4000
local WHAT = os.getenv "WHAT" or "bare"
local PORT = tonumber(os.getenv "PORT") or (9200 + math.random(0, 300))

local BODY = '{"pong":true}'
local RESPONSE = ("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: %d\r\n\r\n%s")
  :format(#BODY, BODY)

local cq = cqueues.new()
local stop_server

if WHAT == "bare" then
  local srv = assert(socket.listen("127.0.0.1", PORT))
  cq:wrap(function()
    for con in srv:clients() do
      cq:wrap(function()
        con:setmode("bn", "bn")
        while true do
          repeat
            local line = con:read "*l"
            if not line then return end
          until line == "" or line == "\r"
          con:write(RESPONSE)
        end
      end)
    end
  end)
  stop_server = function() srv:close() end

elseif WHAT == "http" then
  local server  = require "akkar.vendor.http.server"
  local headers = require "akkar.vendor.http.headers"
  local s = assert(server.listen {
    host = "127.0.0.1", port = PORT,
    onstream = function(_, stream)
      pcall(function()
        assert(stream:get_headers())
        local h = headers.new()
        h:append(":status", "200")
        h:append("content-type", "application/json")
        h:append("content-length", tostring(#BODY))
        assert(stream:write_headers(h, false))
        assert(stream:write_chunk(BODY, true))
      end)
      stream:shutdown()
    end,
  })
  assert(s:listen(5))
  cq:wrap(function() pcall(s.loop, s) end)
  stop_server = function() s:close() end

else
  local akkar = require "akkar"
  local app = akkar.new()
  app:get("/ping", function() return { pong = true } end)
  cq:wrap(function()
    pcall(function()
      app:run { port = PORT, check_capabilities = false,
                log = akkar.log.new { level = "error", sink = function() end } }
    end)
  end)
  stop_server = function() app:stop(1) end
end

local micros
cq:wrap(function()
  cqueues.sleep(0.4)
  local c = assert(socket.connect("127.0.0.1", PORT))
  c:setmode("bn", "bn")
  c:settimeout(10)
  local REQ = "GET /ping HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"

  local function once()
    c:write(REQ)
    local len
    while true do
      local line = c:read "*l"
      if not line then error "closed" end
      if line == "" or line == "\r" then break end
      local n = line:lower():match "^content%-length:%s*(%d+)"
      if n then len = tonumber(n) end
    end
    if len and len > 0 then c:read(len) end
  end

  for _ = 1, 500 do once() end
  collectgarbage(); collectgarbage()
  local t0 = os.clock()
  for _ = 1, N do once() end
  micros = (os.clock() - t0) / N * 1e6

  c:close()
  stop_server()
end)

pcall(function() return cq:loop(120) end)
print(("%-6s %8.2f us/request (client and server together)"):format(WHAT, micros or -1))
