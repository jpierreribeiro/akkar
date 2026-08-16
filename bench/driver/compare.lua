--[[
pgmoon against akkar.pq, on the same query, in the same process.

## What is being measured, and what is deliberately not

`bench/compare/RESULTS.md` established the number this driver exists to move:
the same query against the same Postgres costs 32 us through pgx, 82 us
through asyncpg and 330 us through pgmoon. `docs/PERFORMANCE-STUDY.md`
decomposes it and finds pgmoon's fetch and row decoding at 85-99% of the
request path.

So this measures the DRIVER, not the server: no HTTP, no router, no JSON. A
number produced here cannot be compared to a req/s figure from `bench/compare`
and is not meant to be. What it can say is whether the 330 us moved, and by
how much, on this machine.

## The honesty rules, taken from bench/compare/METHOD.md

  * **Alternating order.** pgmoon, then pq, then pgmoon, then pq -- because a
    machine that warms up or thermally throttles gives the first contender a
    systematic advantage, and running all of one then all of the other bakes
    it in.
  * **A warmup that is discarded.** The first connection pays for DNS, the
    handshake and page faults that nothing after it pays.
  * **Nearest-rank median over the repetitions**, not the best -- this
    project shipped a best-of-three labelled a median once already, and
    `bench/study/RESULTS.md` section 8 carries the retraction.
  * **The same rows, verified.** If the two drivers do not return identical
    data the comparison is meaningless, so it is checked rather than assumed.

Run: lua5.4 bench/driver/compare.lua [rows] [iterations] [reps]
]]

package.path  = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

local cqueues = require "cqueues"

local ROWS  = tonumber(arg[1]) or 1
local ITERS = tonumber(arg[2]) or 2000
local REPS  = tonumber(arg[3]) or 5

local CONFIG = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
}

local SQL = ROWS == 1
  and "select 42 as id, 'ada'::text as name"
  or  ("select i as id, i::text as name from generate_series(1, %d) as i"):format(ROWS)

-- ------------------------------------------------------------------ drivers

local function with_pgmoon(fn)
  local pgmoon = require "pgmoon"
  local conn = pgmoon.new {
    host = CONFIG.host, port = CONFIG.port, database = CONFIG.database,
    user = CONFIG.user, password = CONFIG.password, socket_type = "cqueues",
  }
  assert(conn:connect())
  local ok, err = pcall(fn, function(sql) return conn:query(sql) end)
  conn:disconnect()
  if not ok then error(err, 0) end
end

local function with_pq(fn)
  local pq = require "akkar.pq"
  local conn = assert(pq.connect(CONFIG))
  local ok, err = pcall(fn, function(sql) return conn:query(sql) end)
  conn:close()
  if not ok then error(err, 0) end
end

-- --------------------------------------------------------------- the timing

local function time_one(with)
  local seconds
  local cq = cqueues.new()
  cq:wrap(function()
    with(function(query)
      -- Warmup, discarded: the first query pays for the plan cache, the
      -- protocol negotiation and a page fault or two.
      for _ = 1, 50 do query(SQL) end

      local started = cqueues.monotime()
      for _ = 1, ITERS do query(SQL) end
      seconds = cqueues.monotime() - started
    end)
  end)
  assert(cq:loop(300))
  return seconds / ITERS * 1e6            -- microseconds per query
end

--- Do the two drivers actually return the same thing?
local function verify_identical()
  local from_pgmoon, from_pq
  local cq = cqueues.new()
  cq:wrap(function()
    with_pgmoon(function(query) from_pgmoon = query(SQL) end)
    with_pq(function(query) from_pq = query(SQL) end)
  end)
  assert(cq:loop(60))

  assert(#from_pgmoon == #from_pq,
    ("row counts differ: pgmoon %d, pq %d"):format(#from_pgmoon, #from_pq))
  for i = 1, #from_pgmoon do
    for key, value in pairs(from_pgmoon[i]) do
      local mine = from_pq[i][key]
      assert(tostring(mine) == tostring(value),
        ("row %d field %s differs: pgmoon %s, pq %s")
        :format(i, key, tostring(value), tostring(mine)))
    end
  end
  return #from_pgmoon
end

local function median(values)
  table.sort(values)
  return values[math.ceil(#values / 2)]
end

-- -------------------------------------------------------------------- run it

local rows = verify_identical()
io.write(("# driver comparison: %d row(s), %d queries per repetition, %d reps\n")
         :format(rows, ITERS, REPS))
io.write(("# %s\n"):format(SQL))
io.write("# identical rows from both drivers: verified\n\n")

local pgmoon_runs, pq_runs = {}, {}
for rep = 1, REPS do
  -- ALTERNATING, and the order flips each repetition so that neither
  -- contender is always the one that runs on a cold cache.
  if rep % 2 == 1 then
    pgmoon_runs[#pgmoon_runs + 1] = time_one(with_pgmoon)
    pq_runs[#pq_runs + 1]         = time_one(with_pq)
  else
    pq_runs[#pq_runs + 1]         = time_one(with_pq)
    pgmoon_runs[#pgmoon_runs + 1] = time_one(with_pgmoon)
  end
  io.write(("rep %d: pgmoon %8.2f us   pq %8.2f us\n")
           :format(rep, pgmoon_runs[#pgmoon_runs], pq_runs[#pq_runs]))
end

local m_pgmoon, m_pq = median(pgmoon_runs), median(pq_runs)
io.write("\n")
io.write(("pgmoon   median %8.2f us/query\n"):format(m_pgmoon))
io.write(("akkar.pq median %8.2f us/query\n"):format(m_pq))
io.write(("speedup  %.2fx\n"):format(m_pgmoon / m_pq))

-- DO THE RANGES OVERLAP? -- which is the question, and comparing the gap to
-- the spread was not it.
--
-- The first version of this gate divided the difference of the medians by the
-- within-contender spread and called anything under twice it noise. That
-- rejected a threefold difference on a noisy machine, because a contender
-- that varies by 50% between repetitions makes every gap look small next to
-- it -- while EVERY repetition of one was still slower than EVERY repetition
-- of the other. Spread and separation are different questions and only the
-- second one is being asked here.
--
-- So: if the fastest run of the slower driver is still slower than the
-- slowest run of the faster one, the distributions do not touch, and no
-- amount of within-run variance explains the difference away.
local function spread(values)
  return (values[#values] - values[1]) / values[1] * 100
end
io.write(("\nspread: pgmoon %.1f%%, pq %.1f%%\n")
         :format(spread(pgmoon_runs), spread(pq_runs)))

local slower, faster = pgmoon_runs, pq_runs
local slower_name, faster_name = "pgmoon", "akkar.pq"
if m_pq > m_pgmoon then
  slower, faster = pq_runs, pgmoon_runs
  slower_name, faster_name = "akkar.pq", "pgmoon"
end
-- Both are sorted by `median` above.
local best_of_slower, worst_of_faster = slower[1], faster[#faster]

io.write(("%s best %.2f us vs %s worst %.2f us\n")
         :format(slower_name, best_of_slower, faster_name, worst_of_faster))
if best_of_slower > worst_of_faster then
  io.write(("SEPARATED -- every %s run beat every %s run\n")
           :format(faster_name, slower_name))
else
  io.write("OVERLAPPING -- the runs interleave, so this is not a difference\n")
end
