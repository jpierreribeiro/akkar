--[[
A request body that never finishes arriving.

`read_body` runs BEFORE `with_deadline` exists -- a handler cannot be handed a
body that has not been read -- so while it was unbounded the request deadline
covered every phase except the one the client controls completely. A caller
that announced a hundred bytes and then sent one held a descriptor pair and an
in-flight slot for as long as it cared to, and `max_concurrent` was the only
thing in its way. That is slowloris, against the one part of a request akkar
had left without a clock.

A raw socket rather than an HTTP client, because the whole point is to send a
request that no well-behaved client would send.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local socket  = require "cqueues.socket"

describe("a client that dribbles its body", function()
  it("is refused with 408 instead of holding the slot", function()
    local PORT = 8390
    local app = akkar.new()
    app:post("/echo", function(req) return { got = req.body } end)

    local status_line, elapsed
    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false, timeout = 0.5,
                  log = akkar.log.new { level = "error", sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.2)
      local conn = socket.connect("127.0.0.1", PORT)
      conn:setmode("bn", "bn")
      conn:onerror(function(_, _, why) return why end)

      -- Announce a hundred bytes, send one, and then simply stop.
      conn:write("POST /echo HTTP/1.1\r\nHost: localhost\r\n" ..
                 "Content-Type: application/json\r\n" ..
                 "Content-Length: 100\r\n\r\n")
      conn:write("{")

      local started = cqueues.monotime()
      status_line = conn:read "*L"
      elapsed = cqueues.monotime() - started
      conn:close()

      cqueues.sleep(0.2)
      app:stop(2)
    end)
    assert(cq:loop(20))

    assert.is_truthy(status_line, "the server never answered at all")
    assert.is_truthy(status_line:find("408", 1, true),
      "expected 408, got: " .. tostring(status_line):gsub("%s+$", ""))
    assert.is_true(elapsed < 3,
      ("the server waited %.2fs on a 0.5s budget"):format(elapsed))
    assert.equal(0, app.in_flight, "the in-flight count never came back")
  end)

  it("still reads an ordinary body that arrives in pieces", function()
    -- The budget must not punish a slow but honest client: a body split
    -- across several writes, all inside the budget, is normal on a real
    -- network and must still be read whole.
    local PORT = 8389
    local app = akkar.new()
    app:post("/echo", function(req) return { name = req.body and req.body.name } end)

    local body_line
    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false, timeout = 2,
                  log = akkar.log.new { level = "error", sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.2)
      local conn = socket.connect("127.0.0.1", PORT)
      conn:setmode("bn", "bn")
      conn:onerror(function(_, _, why) return why end)

      local payload = '{"name":"ada"}'
      conn:write("POST /echo HTTP/1.1\r\nHost: localhost\r\n" ..
                 "Content-Type: application/json\r\n" ..
                 "Content-Length: " .. #payload .. "\r\n\r\n")
      for i = 1, #payload do
        conn:write(payload:sub(i, i))
        cqueues.sleep(0.01)
      end

      -- Read past the headers to the body.
      for _ = 1, 40 do
        local line = conn:read "*L"
        if not line then break end
        if line:find("ada", 1, true) then body_line = line break end
      end
      conn:close()

      cqueues.sleep(0.2)
      app:stop(2)
    end)
    assert(cq:loop(20))

    assert.is_truthy(body_line, "a body sent in pieces inside the budget was refused")
  end)
end)
