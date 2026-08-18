--[[
The peer address is read from the socket ONCE PER CONNECTION, not once per
request.

It used to be once per request, and that is a `getpeername` system call each
time. Counted with `strace -c` against a server straced alone, it was exactly
1.00 per request out of 10.87 syscalls total -- nearly a tenth of the server's
whole system-call budget, spent re-reading a value that cannot change while
the connection is open.

TWO CLAIMS, AND THE SECOND IS THE ONE THAT MATTERS.

The first is the optimisation: N requests down one keep-alive connection ask
the socket once.

The second is that the cache is per CONNECTION and not per anything wider. If
it were shared, one client would be told another client's address -- and
`req.ip` feeds rate limiting and audit logging, so that is a security defect
rather than a wrong number. It cannot be caught by comparing addresses on a
loopback test, where every peer is 127.0.0.1 and a leak is invisible. So this
counts calls instead, which is the shape of the claim rather than a proxy for
it.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues     = require "cqueues"
local socket      = require "cqueues.socket"
-- h1_stream, NOT stream_common. `h1_stream.lua:57` copies stream_common's
-- methods into its own table at LOAD time, so patching stream_common
-- afterwards changes a table nothing reads -- the first version of this file
-- counted zero calls for that reason and looked like the cache was perfect.
local h1_stream = require "akkar.vendor.http.h1_stream"
local akkar       = require "akkar"

--- Counts `peername` calls while `body(port)` runs.
---
--- Patching the vendored method rather than the socket, because that is the
--- seam akkar actually goes through -- `init.lua` calls `stream:peername()`.
local function counting_peername(config, body)
  local original = h1_stream.methods.peername
  local calls = 0
  h1_stream.methods.peername = function(self, ...)
    calls = calls + 1
    return original(self, ...)
  end

  local port = 8500 + math.random(0, 400)
  local app = akkar.new()
  app:get("/ping", function(req) return { ip = req.ip or "none" } end)

  local cq = cqueues.new()
  local err
  cq:wrap(function()
    local ok, why = pcall(function()
      config.port = port
      config.check_capabilities = false
      config.log = akkar.log.new { level = "error", sink = function() end }
      app:run(config)
    end)
    if not ok then err = why end
  end)
  cq:wrap(function()
    cqueues.sleep(0.3)
    local ok, why = pcall(body, port)
    app:stop(1)
    if not ok then err = err or why end
  end)
  assert(cq:loop(60))

  h1_stream.methods.peername = original
  if err then error(err, 0) end
  return calls
end

local function connect(port)
  local c = assert(socket.connect("127.0.0.1", port))
  c:setmode("bn", "bn")
  c:settimeout(20)
  return c
end

local function ask(c)
  c:write "GET /ping HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
  local len
  while true do
    local line = assert(c:read "*l")
    -- `read "*l"` keeps the trailing CR.
    if line == "" or line == "\r" then break end
    local n = line:lower():match "^content%-length:%s*(%d+)"
    if n then len = tonumber(n) end
  end
  return len and len > 0 and c:read(len) or ""
end

describe("the peer address", function()
  it("is read once for a connection, however many requests it carries", function()
    local calls = counting_peername({}, function(port)
      local c = connect(port)
      for _ = 1, 20 do
        local body = ask(c)
        assert.is_truthy(body:find("127.0.0.1", 1, true),
          "the request did not see its own peer: " .. body)
      end
      c:close()
    end)
    assert.equal(1, calls,
      ("the socket was asked %d times for one connection's peer"):format(calls))
  end)

  it("is read again for a second connection", function()
    -- The cache must not outlive the connection it belongs to. If it did,
    -- `req.ip` would report the FIRST client's address to every client
    -- afterwards -- and `req.ip` feeds rate limiting and audit logs, so that
    -- is not a wrong number, it is one tenant charged for another's traffic.
    local calls = counting_peername({}, function(port)
      for _ = 1, 3 do
        local c = connect(port)
        ask(c)
        c:close()
      end
    end)
    assert.equal(3, calls,
      ("three connections asked %d times; the cache is not per connection")
        :format(calls))
  end)

  it("does not ask again on a connection whose socket refused once", function()
    -- `false` is stored for "asked, and the socket would not say". Storing
    -- nil would read as "not asked yet" and buy the failing call back on
    -- every request of that connection -- the exact cost this removes, on
    -- precisely the connection least able to afford it.
    local original = h1_stream.methods.peername
    local calls = 0
    h1_stream.methods.peername = function()
      calls = calls + 1
      error "no peer for you"
    end

    local port = 8500 + math.random(0, 400)
    local app = akkar.new()
    app:get("/ping", function(req) return { ip = req.ip or "none" } end)

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = port, check_capabilities = false,
                  log = akkar.log.new { level = "error", sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.3)
      pcall(function()
        local c = connect(port)
        for _ = 1, 5 do
          local body = ask(c)
          assert(body:find("none", 1, true), "expected no ip, got " .. body)
        end
        c:close()
      end)
      app:stop(1)
    end)
    assert(cq:loop(60))
    h1_stream.methods.peername = original

    assert.equal(1, calls,
      ("a refusing socket was asked %d times over five requests"):format(calls))
  end)
end)
