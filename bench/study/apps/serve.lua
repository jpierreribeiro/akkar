-- The akkar side of the study.  One file, three routes, and it proves which
-- tree it loaded before binding a port.
--
--   /ping        the framework alone
--   /users/:id   one indexed query
--   /rows/:n     a payload sweep, straight from the database
--
-- `AKKAR_ROOT` selects the tree, `AKKAR_LEAN` turns off the two features the
-- peers do not have, so akkar can be reported as-shipped AND like for like.
local root = assert(os.getenv "AKKAR_ROOT", "set AKKAR_ROOT")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
-- `akkar.pq_native` is a C module and lives in the tree, not in the rock tree,
-- so selecting a tree means selecting its `cpath` too. Without this line
-- `AKKAR_DRIVER=pq` fails on a module-not-found that reads like a broken
-- install and is actually a search path nobody stated.
package.cpath = root .. "/?.so;" .. package.cpath

local akkar = require "akkar"
local db    = require "akkar.db"

io.stderr:write(("tree=%s\n"):format(package.searchpath("akkar", package.path)))

-- WHICH DRIVER, proved at boot rather than discovered at the first request.
--
-- `db.connect` returns a factory and only opens a connection when a request
-- arrives, so a missing `pq_native.so` would surface as a 500 in the middle of
-- a timed run -- and a run that reports errors is refused by the harness, but
-- only after the time has been spent. Loading it here turns that into a
-- refusal to start, and prints the name into the same stream that already
-- carries the tree, so the log says which of the two was measured.
local driver = os.getenv "AKKAR_DRIVER"
if driver == "pq" then assert(require "akkar.pq", "akkar.pq did not load") end
io.stderr:write(("driver=%s\n"):format(driver or "pgmoon"))

local lean = os.getenv "AKKAR_LEAN" == "1"

-- HOW MUCH OF THE FRAMEWORK'S COST IS THE COLLECTOR?
--
-- akkar allocates about 2,166 bytes per request; the hand-written floor in
-- `bench/study/floors.lua` allocates a small fraction of that. Collector work
-- scales with allocation, so some unknown share of akkar's per-request cost
-- is not akkar's code running but Lua reclaiming what it produced.
--
-- This is a knob, not a rewrite, which makes it worth pricing before anyone
-- proposes a rewrite. `AKKAR_GC=off` is not a shipping configuration -- memory
-- grows without bound -- it exists to put an upper bound on what collector
-- tuning could ever buy.
local gc = os.getenv "AKKAR_GC"
if gc == "off" then collectgarbage "stop"
elseif gc == "gen" then collectgarbage "generational"
elseif gc == "lazy" then collectgarbage("incremental", 400, 400, 13)
end
if gc then io.stderr:write(("gc=%s\n"):format(gc)) end

local app = akkar.new()
app:get("/ping", function() return { pong = true } end)

app:get("/users/:id", { params = { id = akkar.v.integer { min = 1 } } },
  function(req)
    return req.db:one("select id, name, email from users where id = $1",
                      req.params.id) or akkar.not_found "user not found"
  end)

app:get("/rows/:n", { params = { n = akkar.v.integer { min = 1, max = 2000 } } },
  function(req)
    return { rows = req.db:many(
      "select id, name, email, note from bench_rows order by id limit $1",
      req.params.n) }
  end)

app:run {
  port = tonumber(arg[1]) or 8500,
  reuseport = true,
  check_capabilities = false,
  -- The deadline is akkar's, not Gin's and not uvicorn's.  Reporting akkar
  -- with it on is honest; reporting ONLY that hides what the feature costs.
  timeout = lean and 0 or nil,
  -- THE DRIVER IS SELECTABLE, and until this line existed it was not.
  --
  -- `akkar.pq` was measured in isolation and never once through HTTP: the
  -- comparison against Gin and FastAPI, the saturation sweep and the eight-hour
  -- soak all ran pgmoon, because pgmoon is the default and no benchmark server
  -- ever passed `driver`. So the only published driver numbers are one
  -- connection, one query at a time, on a different machine from every other
  -- measurement in this repository.
  --
  -- `AKKAR_DRIVER=pq` makes the same server, the same routes and the same
  -- harness answer the question end to end.
  db = db.connect { port = 55432, database = "akkar", user = "postgres",
                    password = "akkar", pool_size = tonumber(arg[2]) or 10,
                    driver = os.getenv "AKKAR_DRIVER" },
  log = akkar.log.new { level = "error" },
}
