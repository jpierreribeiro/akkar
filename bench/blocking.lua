--[[
What one blocking handler costs everyone else, under load.

This is the measurement a unit test cannot make, because it needs a real load
generator hitting a real socket while the blocking call runs.

  /ping                 cheap, the victim
  /expensive            ~250 ms of CPU, the way bcrypt at cost 12 behaves
  /expensive-yielding   the same work through work.yielding

Run with N processes (see bench/scale.sh) and watch /ping p99 while
/expensive is being called.  With one process it stalls everything.  With
eight it stalls an eighth of capacity, which is the honest answer to
CPU-bound work in a single-threaded runtime.

  lua5.4 bench/blocking.lua [port]
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local work  = require "akkar.work"

local port = tonumber(arg[1]) or 8300
local ITERATIONS = 3000000     -- roughly 200 ms on a c5.2xlarge

local app = akkar.new()

app:get("/ping", function() return { pong = true } end)

app:get("/expensive", function()
  local x = 0
  for i = 1, ITERATIONS do x = x + i % 7 end
  return { burned = x }
end)

app:get("/expensive-yielding", function()
  local x = 0
  work.yielding(2000, function(yield)
    for i = 1, ITERATIONS do x = x + i % 7 yield() end
  end)
  return { burned = x }
end)

app:handle_signals()
app:run { port = port, reuseport = true, log = akkar.log.new { level = "warn" } }
