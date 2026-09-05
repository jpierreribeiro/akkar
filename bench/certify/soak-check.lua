-- Turn bench/soak.sh's samples into a repeatable pass/fail gate.
-- Thresholds are deliberately configurable because allocator baselines differ
-- by libc and workload; the defaults catch large, sustained drift.

local path = assert(arg[1], "usage: lua5.4 bench/certify/soak-check.lua FILE")
local max_rss_percent = tonumber(os.getenv "MAX_RSS_GROWTH_PERCENT") or 20
local max_rss_kb = tonumber(os.getenv "MAX_RSS_GROWTH_KB") or 128 * 1024
local max_heap_percent = tonumber(os.getenv "MAX_HEAP_GROWTH_PERCENT") or 20
local max_heap_kb = tonumber(os.getenv "MAX_HEAP_GROWTH_KB") or 32 * 1024

local samples = {}
for line in assert(io.lines(path)) do
  if line:match "^%d" then
    local row = {}
    for value in line:gmatch "[^	]+" do row[#row + 1] = tonumber(value) end
    if #row == 7 then samples[#samples + 1] = row end
  end
end

assert(#samples >= 10, ("need at least 10 samples, got %d"):format(#samples))

local function median(column, first, last)
  local values = {}
  for i = first, last do values[#values + 1] = samples[i][column] end
  table.sort(values)
  return values[math.floor((#values + 1) / 2)]
end

local window = math.max(3, math.floor(#samples / 5))
local function drift(column)
  local before = median(column, 1, window)
  local after = median(column, #samples - window + 1, #samples)
  local delta = after - before
  local percent = before > 0 and delta / before * 100 or math.huge
  return before, after, delta, percent
end

local failures = {}
local function check(name, column, max_percent, max_kb)
  local before, after, delta, percent = drift(column)
  io.write(("%-10s %d -> %d KiB (%+.1f%%, %+.0f KiB)\n")
    :format(name, before, after, percent, delta))
  if delta > max_kb or (delta > 4096 and percent > max_percent) then
    failures[#failures + 1] = name .. " drift exceeded its gate"
  end
end

check("lua heap", 2, max_heap_percent, max_heap_kb)
check("rss", 3, max_rss_percent, max_rss_kb)

local first_requests = samples[1][7]
local last_requests = samples[#samples][7]
if last_requests <= first_requests then
  failures[#failures + 1] = "request counter did not advance"
end
if samples[#samples][6] > tonumber(os.getenv "MAX_FINAL_PG_CONNECTIONS" or "20") then
  failures[#failures + 1] = "final Postgres connection count exceeded its gate"
end

if #failures > 0 then
  for _, failure in ipairs(failures) do io.stderr:write("FAIL: ", failure, "\n") end
  os.exit(1)
end
print(("PASS: %d samples, request counter %d -> %d")
  :format(#samples, first_requests, last_requests))
