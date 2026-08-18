--[[
A run repeats: same seed, same trace, in a separate process.

WHAT THIS MEASURED, AND WHAT IT SAVED. `docs/PLAN.md`'s L1 lists three missing
pieces for deterministic simulation -- a seeded PRNG, deterministic
scheduling, and a simulator loop with replay. The second was the expensive
one: controlling the order in which cqueues resumes coroutines is days of
work and a second scheduler.

It is not needed for the case that matters, and this file is the measurement
that says so. With the seams akkar already has -- every I/O through an adapter,
`akkar.time` for the clock, the memory adapters, and now `akkar.random` --
forty CONCURRENT requests through three routes produce a byte-identical trace
across separate processes.

The one thing that differed on the first run was the execution id prefix,
which was drawn at module load and so before any generator could be installed.
That is fixed in `akkar/execution.lua` rather than tolerated here, and the
absence of a workaround in this file is the evidence.

WHAT THIS DOES NOT SAY. Nothing here touches a socket. Real I/O readiness is
ordered by the kernel and is not reproducible by any of this; a spec that
speaks a protocol to a real server keeps its real non-determinism. What is
established is narrower and is exactly what a simulator needs: **akkar's own
scheduling of concurrent work over in-memory adapters is already
deterministic.**
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local random  = require "akkar.random"
local time    = require "akkar.time"
local execution = require "akkar.execution"
local cqueues = require "cqueues"

--- Runs a fixed workload under a seed and returns the trace it produced.
local function trace_under(seed, n)
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
      cqueues.sleep(0)                 -- yields, so the scheduler can interleave
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

  -- CONCURRENT, not serial. Anything repeats in series; what is being pinned
  -- is that the ORDER in which coroutines finish is stable.
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
  return table.concat(trace, "\n")
end

describe("a seeded run", function()
  it("produces the same trace twice, ids included", function()
    local a = trace_under(1234, 40)
    local b = trace_under(1234, 40)
    assert.equal(a, b)
    -- Guards against the trace being empty or trivial, which would make the
    -- equality above true and meaningless.
    assert.is_true(#a > 400, "the trace is too short to mean anything")
    assert.equal(40, select(2, a:gsub("\n", "")) + 1)
  end)

  it("produces a different trace for a different seed", function()
    assert.are_not.equal(trace_under(1234, 40), trace_under(5678, 40))
  end)

  it("interleaves rather than running each request to completion", function()
    -- If every coroutine ran start to finish before the next began, the trace
    -- would be deterministic for a reason that proves nothing about
    -- scheduling. `/work` yields between steps, so a run that interleaves has
    -- its `work` lines spread through the trace rather than in arrival order.
    local trace = trace_under(1234, 40)

    -- ANCHORED, and the first version was not. `[^\n]*:(%x+)` is greedy, so
    -- on `echo:9e8c9247000002:3` it captured `3` -- the payload length -- and
    -- the test compared a mixture of ids and small integers. It passed, and
    -- it passed for a reason that had nothing to do with scheduling.
    local ids = {}
    for id in trace:gmatch "\n?%a+:(%x+)" do ids[#ids + 1] = id end
    assert.equal(40, #ids, "the ids were not extracted; the pattern is wrong")

    local ordered = true
    for i = 2, #ids do
      if ids[i] <= ids[i - 1] then ordered = false break end
    end
    assert.is_false(ordered,
      "every request finished in the order it started; nothing interleaved")
  end)
end)
