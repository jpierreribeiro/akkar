-- Latency at LOW load, which no benchmark here has measured.
--
-- Every throughput figure is taken at saturation, where p50 is Little's law:
-- concurrency / throughput, i.e. queueing, not the framework's own work. At
-- 100 connections over 10,417 req/s that is 9.6 ms, and the measured p50 was
-- 9.31 -- the queue, not akkar.
--
-- The number a reader at 5% utilisation actually gets is the SERVICE TIME: one
-- request, alone, start to finish, with no queue in front of it. That is what
-- this measures, through `app:test` so it is pure akkar CPU with no socket or
-- kernel in the way, interleaved and minimum-kept.
package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local time  = require "akkar.time"

local quiet = akkar.log.new { level = "error", sink = function() end }

-- Three shapes, from trivial to a validated POST, because service time is not
-- one number and a /ping figure understates a real endpoint.
local ping = akkar.new()
ping:get("/ping", function() return { pong = true } end)
local ping_c = ping:test { log = quiet }

local param = akkar.new()
param:get("/users/:id", { params = { id = akkar.v.integer { min = 1 } } },
  function(req) return { id = req.params.id } end)
local param_c = param:test { log = quiet }

local post = akkar.new()
post:post("/orders", { body = {
  item = "string", qty = akkar.v.integer { min = 1 }, note = "string?",
} }, function(req) return { ok = req.body.item } end)
local post_c = post:test { log = quiet }

local N = tonumber(os.getenv "N") or 100000
local ROUNDS = tonumber(os.getenv "ROUNDS") or 9

local arms = {
  ["GET /ping"] = function() ping_c:get "/ping" end,
  ["GET /users/:id (validated param)"] = function() param_c:get "/users/42" end,
  ["POST /orders (validated body)"] = function()
    post_c:post("/orders", { body = { item = "x", qty = 3, note = "hi" } })
  end,
}

local samples = {}
for name in pairs(arms) do samples[name] = {} end
for _ = 1, ROUNDS do
  for name, fn in pairs(arms) do
    fn()
    collectgarbage(); collectgarbage()      -- coleta ENTRE rounds, nao durante
    local t0 = time.monotime()
    for _ = 1, N do fn() end
    samples[name][#samples[name] + 1] = (time.monotime() - t0) / N * 1e6
  end
end

print(("service time at low load, best of %d rounds x %d\n"):format(ROUNDS, N))
for _, name in ipairs { "GET /ping", "GET /users/:id (validated param)",
                        "POST /orders (validated body)" } do
  local list = samples[name]
  table.sort(list)
  local best, worst = list[1], list[#list]
  print(("  %-36s %6.2f us   (spread %4.1f%%)")
    :format(name, best, (worst - best) / best * 100))
end

print()
print("This is the number a service at low utilisation delivers per request,")
print("in akkar's own code, before any network or database. At 4 ms for a real")
print("Postgres query, the runtime is a rounding error on the response.")
