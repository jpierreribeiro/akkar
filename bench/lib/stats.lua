--[[
Distributions, never a single figure.

Borrowed wholesale from the benchmark methodology of an earlier project of
mine (`uruquim-odin`, `planning/benchmark-methodology.md`), which had already
paid for these lessons:

  * No mean.  A mean hides the tail, and the tail is the whole question for a
    request pipeline.  p99 is what an operator feels.

  * Nearest-rank percentiles, so every reported value is one the machine
    actually observed.  An interpolated p99 is a number that never happened.

  * A tolerance derived from the machine rather than chosen.  Run the
    unchanged baseline many times and take the observed p95 spread as the
    noise floor; a difference smaller than that is not a result.  That project
    measured a floor of ±57.6% on its hardware, which invalidated an entire
    class of comparison it had been about to make.

  * Spread in basis points, not absolute units, so the floor survives a move
    to a faster machine.
]]

local M = {}

--- Nearest-rank, so the value is one that was observed.
function M.percentile(sorted, q)
  if #sorted == 0 then return 0 end
  local rank = math.ceil(q * #sorted)
  if rank < 1 then rank = 1 end
  if rank > #sorted then rank = #sorted end
  return sorted[rank]
end

--- n, min, p50, p95, p99, max.  Deliberately no mean.
function M.summary(samples)
  local sorted = {}
  for i, v in ipairs(samples) do sorted[i] = v end
  table.sort(sorted)
  return {
    n   = #sorted,
    min = sorted[1] or 0,
    p50 = M.percentile(sorted, 0.50),
    p95 = M.percentile(sorted, 0.95),
    p99 = M.percentile(sorted, 0.99),
    max = sorted[#sorted] or 0,
  }
end

--- Spread of a set of repetitions, in basis points of the median.
--- 10000 bp = 100%.
function M.spread_bp(values)
  local s = M.summary(values)
  if s.p50 == 0 then return 0 end
  return math.floor((s.p95 - s.min) / s.p50 * 10000)
end

function M.format(label, s, unit)
  unit = unit or "ms"
  return string.format(
    "  %-24s n=%-6d min %8.2f  p50 %8.2f  p95 %8.2f  p99 %8.2f  max %8.2f %s",
    label, s.n, s.min, s.p50, s.p95, s.p99, s.max, unit)
end

--- Is a difference between two medians larger than the machine's noise?
--- Returns (verdict, percent_difference).
function M.significant(baseline_median, candidate_median, floor_bp)
  if baseline_median == 0 then return false, 0 end
  local delta_bp = math.abs(candidate_median - baseline_median) / baseline_median * 10000
  return delta_bp > floor_bp, (candidate_median - baseline_median) / baseline_median * 100
end

return M
