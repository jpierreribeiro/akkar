-- Does reset_on_release throw away a Postgres plan cache?
--
-- An external research report warned that DISCARD ALL destroys the plan cache
-- and that a named prepared statement needs ~5 executions to compile a generic
-- plan, so resetting a pooled connection every release could cost far more
-- than the round-trip. Worth checking, because a cost claim left at "167 us"
-- is a cost claim left half-measured.
--
-- RESULT on the box: it does NOT apply to akkar. pgmoon uses the UNNAMED
-- statement (akkar/db.lua top), re-parsing every call, so there is no named
-- plan to lose. Interleaved, 9 rounds: reset overhead 243 us, DISCARD alone
-- 191 us, the 52 us between them far under the 760 us noise floor of a
-- networked query.
--
-- AND THE FIRST, SEQUENTIAL RUN LIED: it reported 331 us and "a plan was lost".
-- Spreads of 175% on a network round-trip, arms measured one after another,
-- drift larger than the effect. Kept interleaved for the same reason
-- validate-cost.lua and hex-cost.lua are.

-- Take two, interleaved. The first run measured the three arms in sequence and
-- got "reset adds 331 us, more than DISCARD's 180" -- which would mean a plan
-- is lost. But sequential arms on a network round-trip drift, and this project
-- has been burned three times by exactly that. Interleave, keep the minimum,
-- report the spread as the floor.
package.path = "./?.lua;./?/init.lua;" .. package.path

local db = require "akkar.db"
local time = require "akkar.time"

local CONFIG = { host = "127.0.0.1", port = 55432, database = "akkar",
                 user = "postgres", password = "akkar", pool_size = 0 }
local ok, factory = pcall(db.connect, CONFIG)
if not ok then print("Postgres inalcancavel"); os.exit(0) end
local conn = factory()

pcall(function() conn:exec "DROP TABLE IF EXISTS plan_probe" end)
conn:exec "CREATE TABLE plan_probe (id int primary key, v text)"
for i = 1, 1000 do conn:exec(("INSERT INTO plan_probe VALUES (%d, 'x%d')"):format(i, i)) end
conn:exec "ANALYZE plan_probe"

local arms = {
  ["query"]         = function() conn:one "SELECT v FROM plan_probe WHERE id = 42" end,
  ["query+discard"] = function()
    conn:one "SELECT v FROM plan_probe WHERE id = 42"
    conn:exec "DISCARD ALL"
  end,
  ["discard"]       = function() conn:exec "DISCARD ALL" end,
}

local N = 1000
local ROUNDS = 9
local samples = {}
for name in pairs(arms) do samples[name] = {} end

for _ = 1, ROUNDS do
  for name, fn in pairs(arms) do
    fn()
    local t0 = time.monotime()
    for _ = 1, N do fn() end
    samples[name][#samples[name] + 1] = (time.monotime() - t0) / N * 1e6
  end
end

local best, worst = {}, {}
for name, list in pairs(samples) do
  table.sort(list)
  best[name], worst[name] = list[1], list[#list]
end

for _, name in ipairs { "query", "discard", "query+discard" } do
  print(("  %-16s best %7.2f us   worst %7.2f us   spread %4.1f%%")
    :format(name, best[name], worst[name],
            (worst[name] - best[name]) / best[name] * 100))
end

local overhead = best["query+discard"] - best["query"]
local floor = math.max(worst.query - best.query, worst.discard - best.discard)
print()
print(("reset overhead: %.2f us | DISCARD alone: %.2f us | floor: %.2f us")
  :format(overhead, best.discard, floor))
if math.abs(overhead - best.discard) <= floor then
  print("=> overhead == DISCARD round-trip, within noise. No plan lost.")
else
  print(("=> overhead is %.0f us MORE than DISCARD; investigate a lost plan.")
    :format(overhead - best.discard))
end

pcall(function() conn:exec "DROP TABLE plan_probe" end)
conn:release()
