-- The akkar side of the study.  One file, three routes, and it proves which
-- tree it loaded before binding a port.
--
--   /ping        the framework alone
--   /users/:id   one indexed query
--   /rows/:n     a payload sweep, straight from the database
--   /heap        the Lua heap, for the soak
--   /metrics     the pool, for the saturation sweep
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

local akkar   = require "akkar"
local db      = require "akkar.db"
local metrics = require "akkar.metrics"

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

-- The pool is built HERE rather than inline in `app:run` below, because
-- `/metrics` has to be able to reach it. `db.connect` returns a callable table
-- carrying `.pool` for exactly this -- "so the pool can be reached for
-- shutdown and diagnostics", `akkar/db.lua` says at the return.
local database = db.connect {
  port = 55432, database = "akkar", user = "postgres", password = "akkar",
  pool_size = tonumber(arg[2]) or 10,
  driver = os.getenv "AKKAR_DRIVER",
}

local app = akkar.new()
app:get("/ping", function() return { pong = true } end)

--- The Lua heap, in kilobytes, so a soak can tell a leak from fragmentation.
---
--- `bench/study/soak.sh` samples RSS out of `/proc`, and RSS alone cannot
--- separate two failures whose fixes are opposite:
---
---   * RSS climbs AND the Lua heap climbs -- something in akkar is holding a
---     table it should have dropped. That is a defect and it is ours;
---   * RSS climbs and the Lua heap is FLAT -- the collector is returning
---     memory that the C allocator is not returning to the kernel. That is
---     fragmentation or arena growth, and no amount of reading Lua code finds
---     it.
---
--- This project has already paid for that confusion once: a "regression" in
--- the per-connection memory figure turned out to be a single 1,024 KB
--- allocator step, invisible to `collectgarbage "count"` and wrongly blamed on
--- a commit for an afternoon.
---
--- No collection is forced here. `count` reports what is in use right now, and
--- collecting before reading would report what is reachable after a full
--- cycle, which is a different question and one that also perturbs the very
--- timing the soak is measuring.
app:get("/heap", function()
  return { kb = collectgarbage "count" }
end)

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

-- WHY THIS SERVER HAS A /metrics AND WHAT IT DELIBERATELY DOES NOT MEASURE.
--
-- `bench/study/saturation.sh` records four predictions before it runs, and the
-- third of them -- "time waiting for a connection becomes the majority of p99
-- above 2x capacity" -- is the only one that cannot be answered by wrk.
-- Throughput, p50, p99 and errors all come off the load generator; the SHARE
-- of that p99 which is queueing for a pool slot is inside this process, and
-- `bench/study/RESULTS.md` had to publish that prediction as "Not measured"
-- because this file mounted no route a scrape could reach. The counters were
-- there the whole time -- `Pool:stats()` has had `waits`, `waited` and
-- `waited_max` for as long as the pool has queued -- with nothing to read them.
--
-- ONLY THE POOL IS REGISTERED, and no middleware is installed. That is the
-- point rather than an omission:
--
--   * `registry:middleware()` would put a `pcall`, a monotonic clock read and
--     a histogram update on every request, on the exact routes whose cost is
--     what this study publishes. `/ping` is the framework-alone floor -- the
--     number every peer is compared against -- and it must not pay for an
--     instrument the peers are not carrying. `/ping` and `/users/:id` do not
--     touch this registry at all;
--   * the request rate is already measured, better, from outside. wrk counts
--     what it received; a counter inside one of several `reuseport` processes
--     counts a share of it and has to be summed across them.
--
-- So the endpoint reports the pool and nothing else, and it costs this server
-- nothing until the sweep curls it once at the end of the run. `Registry:pool`
-- keeps a reference and reads `stats()` inside `render()`; there is no sampler
-- on the scheduler competing with the load for it.
local registry = metrics.new()
registry:pool("db", database.pool)
registry:serve(app, "/metrics")

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
  db = database,
  log = akkar.log.new { level = "error" },
}
