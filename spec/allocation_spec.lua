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
