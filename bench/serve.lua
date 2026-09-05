--[[
Throughput and latency target.

Two routes on purpose:

  /ping       the framework with nothing behind it
  /users/:id  the realistic case, where the database dominates

The gap between them is the useful number.  If /ping is an order of magnitude
faster, then in a real request the framework is noise and the database is the
thing to optimise -- which is what every measurement in this project has said
so far, and which a benchmark should confirm rather than assume.

  lua5.4 bench/serve.lua [port] [pool_size]
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local db      = require "akkar.db"
local metrics = require "akkar.metrics"

local port = tonumber(arg[1]) or 8300
local pool = tonumber(arg[2]) or 10

local app = akkar.new()
local registry = metrics.new()
app:use(registry:middleware())

-- No logging middleware here.  Writing a line per request would measure the
-- terminal, not the server.
app:get("/ping", function() return { pong = true } end)

app:get("/users/:id", {
  params   = { id = akkar.v.integer { min = 1 } },
  response = { id = "integer", name = "string", email = "string?" },
}, function(req)
  local user = req.db:one("select id, name, email from users where id = $1",
                          req.params.id)
  return user or akkar.not_found "user not found"
end)

local factory = os.getenv("BENCH_NO_DB") ~= "1" and db.connect {
  host = os.getenv("PGHOST") or "127.0.0.1",
  port = tonumber(os.getenv("PGPORT")) or 55432,
  database = os.getenv("PGDATABASE") or "akkar", user = os.getenv("PGUSER") or "postgres",
  password = os.getenv("PGPASSWORD") or "akkar",
  pool_size = pool,
}

registry:serve(app, "/metrics", {
  akkar_db_pool_idle = function() return factory and factory.pool.stats and factory.pool:stats().idle or 0 end,
  akkar_db_pool_live = function() return factory and factory.pool.stats and factory.pool:stats().live or 0 end,
})

app:handle_signals()
app:run {
  port = port,
  reuseport = true,      -- several of these share the port; see bench/run.sh
  db = factory or nil,
  log = akkar.log.new { level = "warn" },   -- warnings only; info would be noise
}
