--[[
Allocation per request, as a regression assertion.

Rule 4 of the performance study, taken from the previous framework: timing
belongs in a benchmark against a noise floor, but **allocation is exact and
machine-independent**, so it is the thing a test can assert. This file is
where a change that quietly starts allocating again gets caught, on a laptop,
in a second, with no benchmark box involved.

The number is a ceiling, not an equality. An equality would fail on any
unrelated change and would be edited until it meant nothing.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

--- Bytes allocated per request, with the collector stopped.
---
--- Stopping it is the whole method: with the collector running,
--- `collectgarbage "count"` reports *live* memory, which stays flat no matter
--- how much a request allocates. Measured that way this suite would have read
--- 189 bytes per request against a true 2,814.
local function bytes_per_request(client, path, n)
  collectgarbage(); collectgarbage()
  collectgarbage "stop"
  local before = collectgarbage "count"
  for _ = 1, n do client:get(path) end
  local after = collectgarbage "count"
  collectgarbage "restart"
  return (after - before) * 1024 / n
end

describe("allocation per request", function()
  local client

  setup(function()
    local app = akkar.new()
    app:get("/ping", function() return { pong = true } end)
    client = app:test()
    bytes_per_request(client, "/ping", 200)     -- compile chains, warm caches
  end)

  it("stays under the ceiling for a trivial route", function()
    -- History, so a future reader knows which way this has moved:
    --   2,814  before the guards and the request id were fixed
    --   2,423  after
    --   2,166  with the watchdog closure pooled as well -- reverted, because
    --          that last 257 bytes measured +2.1% against a 3.4% noise floor
    -- The ceiling sits above the current figure with room for an honest
    -- change, and low enough that re-introducing either allocation breaks it.
    local bytes = bytes_per_request(client, "/ping", 2000)
    assert.is_true(bytes < 2600,
      string.format("allocation regressed: %.0f bytes/request, ceiling 2600", bytes))
  end)

  it("is flat in the number of requests, so nothing accumulates", function()
    -- A pool that grows without bound, or a table keyed by request, shows up
    -- here as a rising figure rather than as a leak nobody finds for months.
    local few  = bytes_per_request(client, "/ping", 500)
    local many = bytes_per_request(client, "/ping", 5000)
    assert.is_true(math.abs(many - few) < 200,
      string.format("allocation grows with request count: %.0f -> %.0f", few, many))
  end)
end)

-- ============================================================ the real server
--
-- THE CEILING ABOVE WAS WATCHING THE WRONG PATH, and that cost 4% of `/ping`
-- for a day before anyone noticed.
--
-- `app:test()` never calls `app:run`, so it never touches lua-http, the socket
-- or `akkar/substrate.lua`. The substrate repair wraps `h1_stream:shutdown`,
-- and in HTTP/1.1 keep-alive a stream IS a request, so it was allocating a
-- closure, an instance-table slot and a `table.pack` result on every request
-- -- entirely invisible to a ceiling measured through `app:test`.
--
-- It surfaced only because a benchmark on another machine noticed akkar had
-- lost 6.7% against its own published number while Gin reproduced to within
-- 0.2%. That is luck, not a process. This is the process.
--
-- WHAT THIS NUMBER INCLUDES, stated because it is not the same measurement as
-- the one above: server and client run in the same process, so the figure
-- carries the client's allocations too. That makes it useless as an absolute
-- statement about akkar and perfectly good as a regression detector, which is
-- what it is for -- the client is fixed, so a rise is the server's.
describe("allocation per request, through a real socket", function()
  local cqueues = require "cqueues"
  local socket  = require "cqueues.socket"

  local PORT = 8387
  local REQUEST = "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n"

  --- Drives `n` keep-alive requests over one connection and returns the bytes
  --- allocated per request by the whole process.
  local function measure(n)
    local app = akkar.new()
    app:get("/ping", function() return { pong = true } end)

    local bytes
    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false,
                  log = akkar.log.new { level = "error", sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.2)
      local conn = socket.connect("127.0.0.1", PORT)
      conn:setmode("bn", "bn")
      conn:onerror(function(_, _, why) return why end)

      -- One round trip, reading the response whole, so the connection is in a
      -- steady state before anything is counted.
      local function round_trip()
        conn:write(REQUEST)
        conn:flush()
        repeat
          local line = conn:read "*l"
        until not line or line == "" or line == "\r"
        return conn:read(13)                    -- exactly {"pong":true}
      end

      for _ = 1, 50 do round_trip() end         -- warm chains and caches

      collectgarbage(); collectgarbage()
      collectgarbage "stop"
      local before = collectgarbage "count"
      for _ = 1, n do round_trip() end
      local after = collectgarbage "count"
      collectgarbage "restart"
      bytes = (after - before) * 1024 / n

      conn:close()
      cqueues.sleep(0.1)
      app:stop(2)
    end)
    assert(cq:loop(30))
    return bytes
  end

  it("stays under the ceiling on the path a client actually takes", function()
    local bytes = measure(600)
    -- THE CEILING IS SET FROM EVIDENCE, and the evidence includes proving this
    -- case fails on the code it was written for. Measured on one laptop:
    --
    --   repair_substrate = false          14,710   14,708 bytes/request
    --   repair_substrate = true, today    14,708   14,708      the repair is free
    --   repair_substrate = true, 0ff3c80  15,220   15,220      +511 per request
    --
    -- Two samples of six hundred requests each, and the four figures that
    -- should agree agree to within two bytes. That is a small enough noise
    -- floor to sit a ceiling two hundred bytes above the current number: it
    -- refuses the 511 that actually shipped, with room for a change somebody
    -- thought about and none for three allocations nobody priced.
    --
    -- If an honest change needs more, raise it and say why -- the number only
    -- means something while somebody has to argue for each rise.
    assert.is_true(bytes < 14900,
      string.format("allocation through the real server regressed: " ..
                    "%.0f bytes/request, ceiling 14900", bytes))
  end)
end)
