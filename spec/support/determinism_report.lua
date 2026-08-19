--[[
What exactly differs between two seeded runs, on a machine where they differ.

`spec/determinism_spec.lua` asserts that two seeded runs produce the same
trace, and on macOS CI they did not. The assertion prints both traces and
nothing else, which says THAT they differ and never says HOW, and three
hypotheses were killed on Linux without touching the real cause:

  * "the kernel's polling mechanism orders it" -- the workload opens no
    socket, so epoll and kqueue have no descriptor to order;
  * "the gap between `sleep(0)` calls decides it" -- burning up to a
    millisecond of CPU inside each handler step changed nothing across 40
    runs;
  * "the worker keepalive decides it" -- driving `WORKER_IDLE` from 0.1 s
    down to 0.1 ms changed nothing either.

So this file exists to stop guessing. It runs the same workload the spec runs
and reports the SHAPE of the difference rather than the traces:

  * do the two runs contain the same set of ids, or did a request vanish?
  * is it purely an ordering difference, or did a line's CONTENT change?
  * which positions differ, and what is on each side of the first one?

An ordering difference and a missing request are different defects with
different causes, and the current assertion cannot tell them apart. This is
run as an informational CI step on every platform, so the answer arrives from
the machine that has the problem instead of from reasoning on a machine that
does not.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar     = require "akkar"
local random    = require "akkar.random"
local time      = require "akkar.time"
local execution = require "akkar.execution"
local cqueues   = require "cqueues"
local portable  = require "spec.support.portable"

local M = {}

--- The spec's workload, verbatim in what it does.
function M.trace_under(seed, n)
  local restore_random = random.set(random.seeded(seed))
  local restore_clock = time.set(time.manual { now = 1755000000, monotime = 0 })
  execution.reset_id_prefix()

  local gen = random.seeded(seed * 7 + 1)
  local trace = {}

  local app = akkar.new()
  app:get("/ping", function(req)
    trace[#trace + 1] = "ping:" .. req.id
    return { pong = true }
  end)
  app:get("/work", { query = { n = "integer?" } }, function(req)
    local total = 0
    for i = 1, (req.query.n or 3) do
      total = total + i
      cqueues.sleep(0)
    end
    trace[#trace + 1] = ("work:%s:%d"):format(req.id, total)
    return { total = total }
  end)
  app:post("/echo", { body = { text = "string" } }, function(req)
    trace[#trace + 1] = ("echo:%s:%d"):format(req.id, #req.body.text)
    return { got = #req.body.text }
  end)

  local client = app:test {
    log = akkar.log.new { level = "error", sink = function() end },
  }

  local cq = cqueues.new()
  for _ = 1, n do
    cq:wrap(function()
      local pick = gen.integer(1, 3)
      if pick == 1 then
        client:get "/ping"
      elseif pick == 2 then
        client:get("/work?n=" .. gen.integer(1, 4))
      else
        client:post("/echo",
                    { body = { text = string.rep("x", gen.integer(1, 20)) } })
      end
    end)
  end
  assert(cq:loop(30))

  restore_clock()
  restore_random()
  execution.reset_id_prefix()
  return trace
end

local function split(list)
  local set, order = {}, {}
  for i, line in ipairs(list) do
    local id = line:match "^%a+:(%x+)"
    set[id or line] = (set[id or line] or 0) + 1
    order[i] = id or line
  end
  return set, order
end

--- Compares two runs and describes the difference in words.
function M.compare(a, b)
  local out = {}
  local function say(fmt, ...) out[#out + 1] = fmt:format(...) end

  if #a ~= #b then
    say("LENGTH DIFFERS: run 1 recorded %d lines, run 2 recorded %d", #a, #b)
  end

  local set_a, order_a = split(a)
  local set_b, order_b = split(b)

  -- Same requests, different order, or genuinely different requests?
  local missing, extra = {}, {}
  for id, n in pairs(set_a) do
    if (set_b[id] or 0) ~= n then missing[#missing + 1] = id end
  end
  for id, n in pairs(set_b) do
    if (set_a[id] or 0) ~= n then extra[#extra + 1] = id end
  end

  if #missing == 0 and #extra == 0 then
    say("SAME SET OF REQUESTS, so this is purely an ORDERING difference.")
  else
    say("DIFFERENT REQUESTS RAN, so this is NOT an ordering difference.")
    say("  only in run 1: %s", table.concat(missing, ", "))
    say("  only in run 2: %s", table.concat(extra, ", "))
  end

  local first
  for i = 1, math.min(#a, #b) do
    if a[i] ~= b[i] then first = i break end
  end
  if first then
    say("first difference at position %d of %d:", first, #a)
    say("  run 1: %s", a[first])
    say("  run 2: %s", b[first])
    -- Where did run 1's line go in run 2? A swap of neighbours reads very
    -- differently from a line that moved across the whole trace.
    for j = 1, #b do
      if b[j] == a[first] then
        say("  run 1's line is at position %d in run 2 (moved %+d)",
            j, j - first)
        break
      end
    end
  else
    say("no positional difference in the common prefix")
  end

  -- Ordering by kind, because `/work` yields and `/ping` does not: if only
  -- the yielding route moves, the scheduler is what varies.
  local moved_kinds = {}
  for i = 1, math.min(#a, #b) do
    if a[i] ~= b[i] then
      local kind = a[i]:match "^(%a+):"
      moved_kinds[kind] = (moved_kinds[kind] or 0) + 1
    end
  end
  local kinds = {}
  for kind, n in pairs(moved_kinds) do
    kinds[#kinds + 1] = ("%s x%d"):format(kind, n)
  end
  if #kinds > 0 then
    say("positions that differ, by route: %s", table.concat(kinds, ", "))
  end

  return table.concat(out, "\n")
end

--- Runs the comparison `rounds` times and prints a report. Never fails: this
--- is a diagnostic, and a diagnostic that can fail a build gets deleted.
function M.report(rounds)
  rounds = rounds or 5
  print(("determinism report on %s, %s")
    :format(tostring(portable.os_name), _VERSION))

  local first = M.trace_under(1234, 40)
  local unstable = 0
  for round = 1, rounds do
    local again = M.trace_under(1234, 40)
    local same = #first == #again
    if same then
      for i = 1, #first do
        if first[i] ~= again[i] then same = false break end
      end
    end
    if not same then
      unstable = unstable + 1
      if unstable == 1 then
        print(("round %d differs from round 0:"):format(round))
        print(M.compare(first, again))
      end
    end
  end
  print(("%d of %d rounds differed from the first"):format(unstable, rounds))
  return unstable
end

return M
