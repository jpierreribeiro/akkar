--[[
Does the Postgres driver YIELD the coroutine, or does it block?

This is the question that decides the substrate.  If pgmoon blocks under
cqueues, the whole "one coroutine per request" model collapses: a slow query
freezes the entire process, and the framework is a sequential server wearing
a costume.

The test is direct.  N connections run `select pg_sleep(1)` at the same time.

  yields  -> ~1 s total   (the N waits overlap)
  blocks  -> ~N s total   (the N waits queue up)

There is no middle ground, and the result needs no calibration.

  run: lua5.4 docs/substrate/01_concurrency.lua
]]

local cqueues = require "cqueues"
local pgmoon  = require "pgmoon"

local N = 8

local function config()
  return {
    host = "127.0.0.1", port = 55432,
    database = "akkar", user = "postgres", password = "akkar",
    socket_type = "cqueues",
  }
end

local function timed(label, fn)
  local t = cqueues.monotime()
  local ok, err = pcall(fn)
  local dt = cqueues.monotime() - t
  if not ok then
    print(string.format("  %-24s FAILED: %s", label, tostring(err):sub(1, 90)))
    return nil
  end
  print(string.format("  %-24s %6.3f s", label, dt))
  return dt
end

print(("="):rep(62))
print("Does pgmoon yield the coroutine under cqueues?")
print(("="):rep(62))
print()

-- Control: a single connection, N queries in sequence.  Must take about N s.
local sequential
do
  print(string.format("sequential control (%d one-second queries, one connection):", N))
  sequential = timed("sequential", function()
    local pg = pgmoon.new(config())
    assert(pg:connect())
    for _ = 1, N do assert(pg:query("select pg_sleep(1)")) end
    pg:disconnect()
  end)
  print()
end

-- The test: N concurrent connections inside one cqueues controller.
local concurrent
do
  print(string.format("concurrent (%d connections, one one-second query each):", N))
  concurrent = timed("concurrent", function()
    local cq = cqueues.new()
    local failures = {}
    for _ = 1, N do
      cq:wrap(function()
        local pg = pgmoon.new(config())
        local ok, err = pg:connect()
        if not ok then failures[#failures + 1] = err return end
        local res, qerr = pg:query("select pg_sleep(1)")
        if not res then failures[#failures + 1] = qerr end
        pg:disconnect()
      end)
    end
    assert(cq:loop())
    if #failures > 0 then error(failures[1], 0) end
  end)
  print()
end

print(("="):rep(62))
if sequential and concurrent then
  print(string.format("speedup ................ %.2fx  (ideal would be ~%dx)",
                      sequential / concurrent, N))
  print()
  if concurrent < sequential * 0.4 then
    print("VERDICT: pgmoon YIELDS the coroutine under cqueues.")
    print("         one coroutine per request works.  substrate approved.")
  else
    print("VERDICT: pgmoon BLOCKS.  the waits queued up.")
    print("         the concurrency model does not hold with this driver.")
  end
else
  print("VERDICT: inconclusive — see the failure above.")
end
print(("="):rep(62))
