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
    --
    -- LOWERED, 2,600 -> 2,350, and the reason is the second half of that
    -- sentence rather than tidiness. The figure is 2,118 now: the execution
    -- extraction took it to 2,105 and the header work in
    -- `akkar/vendor/http/` gave a little back on the response side. At 2,600
    -- the ceiling no longer did what it says -- re-introducing the 257-byte
    -- watchdog closure would land at 2,375 and pass. It fails now.
    --
    -- Byte-identical across three runs, so 232 bytes of headroom is room for
    -- a change somebody thought about and none for one nobody priced.
    local bytes = bytes_per_request(client, "/ping", 2000)
    assert.is_true(bytes < 2350,
      string.format("allocation regressed: %.0f bytes/request, ceiling 2350", bytes))
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

-- ========================================================= the validated route
--
-- THE CEILING ABOVE WATCHES A ROUTE WITH NO SCHEMA, so it has never seen the
-- validation path at all. `/ping` declares nothing, therefore never calls
-- `validate`, therefore could not notice that a route WITH a schema was
-- rebuilding every shorthand rule on every request for the life of the process.
--
-- Measured before the repair, four shorthand rules:
--
--     /ping                      2,452 bytes/request
--     shorthand schema           4,428
--     the same schema via v.*    4,012      <- 416 bytes cheaper, for nothing
--
-- Two different numbers for two spellings of the same schema. That difference
-- IS the defect, and the property below is a stronger guard than any ceiling:
-- it cannot drift, because it compares the two forms against each other rather
-- than against a constant somebody will edit.

describe("allocation on a route that validates", function()
  local shorthand, builder

  local function app_with(params, query)
    local app = akkar.new()
    app:get("/s/:id", { params = params, query = query },
            function(req) return { id = req.params.id } end)
    return app:test()
  end

  local PATH = "/s/7?limit=10&cursor=abc&sort=name"

  setup(function()
    shorthand = app_with(
      { id = "integer" },
      { limit = "integer?", cursor = "string?", sort = "string?" })
    builder = app_with(
      { id = akkar.v.integer { min = 1 } },
      { limit  = akkar.v.integer { optional = true },
        cursor = akkar.v.string  { optional = true },
        sort   = akkar.v.string  { optional = true } })
    bytes_per_request(shorthand, PATH, 200)
    bytes_per_request(builder,   PATH, 200)
  end)

  it("costs the same whether the schema is written short or with v.*", function()
    -- The two describe the same schema, so they must cost the same. Before
    -- schemas were expanded at registration they differed by 416 bytes -- one
    -- table per shorthand rule, per request, for ever.
    local short = bytes_per_request(shorthand, PATH, 2000)
    local built = bytes_per_request(builder,   PATH, 2000)
    assert.is_true(math.abs(short - built) < 40,
      string.format("the two spellings cost differently: shorthand %.0f, v.* %.0f",
                    short, built))
  end)

  it("stays under the ceiling for a validated route", function()
    -- The ceiling is deliberately BELOW the figure with `failures` allocated
    -- eagerly, so that reintroducing that one empty table per `validate` call
    -- fails here rather than passing as noise.
    --
    -- LOWERED, 4,000 -> 3,650, to keep that property rather than to be tidy.
    -- It was 3,900 when 4,000 was chosen and eager `failures` cost 112 bytes;
    -- the figure is 3,550 now, so the regression would land at 3,662 and a
    -- ceiling of 4,000 would wave it through. 3,650 refuses it.
    --
    -- 100 bytes of headroom is deliberately tight, and it is affordable
    -- because this instrument has no socket in it: `app:test` runs in
    -- process, and three consecutive runs give 3,550 exactly. If a legitimate
    -- change needs more, raise it and say what it bought -- the number only
    -- means something while somebody has to argue for each rise.
    local bytes = bytes_per_request(shorthand, PATH, 2000)
    assert.is_true(bytes < 3650,
      string.format("validated-route allocation regressed: %.0f bytes/request, "
                    .. "ceiling 3650", bytes))
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
    --
    -- NOT RAISED, and the attempt is worth recording.
    --
    -- Turning off cqueues controller recycling -- the leading suspect for the
    -- segfault in docs/substrate/SEGFAULT.md -- costs 719 bytes here, taking
    -- 14,708 to 15,427, and this ceiling was briefly raised to 15,600 to let
    -- it through. Then the throughput cost was measured on the study box:
    -- -6.9%%, with the p99 going from 6.19 ms to 8.48 ms.
    --
    -- Against evidence at p of about 0.09, that is too much to pay, so the
    -- recycling stayed on and this number stayed where it was. The ceiling did
    -- its job twice: it refused the change quietly, and it made somebody go and
    -- find out what the change actually cost.
    --
    -- LOWERED, 14,900 -> 11,900, and lowering it is the point.
    --
    -- Five changes in `akkar/vendor/http/` took the figure from 14,610 to
    -- 11,450, each measured on its own and byte-identical across three runs:
    -- two conditions nobody could wait on, ten `nil` keys that were only
    -- documentation, a header index that holds an integer until a name
    -- repeats, the header entry flattened into parallel arrays, and the
    -- read-ahead chunk queue built only when something is read ahead.
    -- `bench/study/HTTP-OPTIMISATION.md` has each with its number.
    --
    -- A ceiling left at 14,900 would have let every one of those 3,160 bytes
    -- come back without a single test going red. A ceiling only detects
    -- regression while it sits close to the truth, so it follows the number
    -- down -- with the same 240 bytes of headroom the paragraph above argued
    -- for, and for the same reason.
    -- LOWERED AGAIN, 11,900 -> 9,400, for the reason the paragraph above
    -- gives and with the same headroom.
    --
    -- `with_deadline` stopped creating a coroutine per request and runs the
    -- handler on a pooled worker instead. Measured through this same shape,
    -- three samples, the no-wrap control byte-identical in all three:
    --
    --     a fresh coroutine per request   11,404 B/request
    --     a pooled worker                  9,151 B/request
    --
    -- 2,253 bytes, and the deadline covers exactly what it covered before --
    -- a handler parked outside a capability is still answered TIMEOUT at the
    -- budget. `spec/worker_pool_spec.lua` pins the reuse and the one rule
    -- that makes reuse safe.
    -- LOWERED AGAIN, 9,400 -> 5,600, and this is the last of the two
    -- per-request coroutines.
    --
    -- `akkar/vendor/http/server.lua` ran the stream handler on a coroutine of
    -- its own, one per REQUEST. In HTTP/1.1 it bought no concurrency: the
    -- connection loop parks inside `get_next_incoming_stream` while the stream
    -- runs, because h1 is serial, so the two never ran together. The wrap is
    -- there for HTTP/2, which left when this half was vendored -- and it stays
    -- reachable behind `conn.version < 2` so reintroducing h2 does not have to
    -- rediscover which line to restore.
    --
    --     with the stream coroutine   9,151 B/request
    --     inline for h1               5,376 B/request
    --
    -- Together with the deadline worker pool, a request now allocates 5,376
    -- bytes against the 14,610 this study started from.
    assert.is_true(bytes < 5600,
      string.format("allocation through the real server regressed: " ..
                    "%.0f bytes/request, ceiling 5600", bytes))
  end)
end)
