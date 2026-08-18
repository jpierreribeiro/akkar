--[[
The invariants, checked by machine, under faults a seed chose.

## What this is

L1. `docs/PLAN.md` calls deterministic simulation the largest lever in the
programme, on the argument that it turns akkar's invariants from things the
README declares into things a machine verifies -- and that akkar is unusually
close to being able to do it, because it already is a cooperative scheduler on
one thread with every I/O behind an adapter.

Three of the four pieces it listed were already here. `spec/determinism_spec.lua`
measured the fourth and found it unnecessary: a seeded run of forty concurrent
requests already reproduces byte for byte, so no second scheduler is needed.
This file is what that was for.

## The defect class it aims at

Not "a query failed". From `spec/fault_injection_spec.lua`, which built the
seam this uses: **a capability was acquired, the coroutine was abandoned
mid-yield, and the release never ran.** Seven of those were found by hand in
one audit, and every one lived where something yielded and never came back.

By hand is the problem. A schedule somebody imagined is a schedule somebody
imagined; this generates them, injects the faults that stage abandonment --
`:hang` and `:drop`, which `:fail` cannot express because it returns
immediately -- and checks after every run that the pool is whole.

## Reading a failure

The seed is in the message. A counterexample here is a command to re-run, not
a story about a Tuesday.

## Proof that it bites

`akkar/execution.lua`'s `M.release` was emptied and this file re-run. It did
not fail -- **it hung**, and that is the strongest form the demonstration
takes: with no release the pool is exhausted, every later request waits for a
slot that will never come back, and the run never drains. Which is exactly the
outage `akkar/pool.lua` records from the study box, "224.7 ok/s, then 0.0 ok/s
from t=10s, for ever".

A test that merely goes red when a guarantee breaks is a good test. One that
reproduces the outage is the guarantee.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar     = require "akkar"
local random    = require "akkar.random"
local execution = require "akkar.execution"
local memory    = require "akkar.db.memory"
local Pool      = require "akkar.pool"
local cqueues   = require "cqueues"

local POOL_SIZE = 4

--- One run: a seed picks the workload, the faults and the deadlines.
---
--- Returns the pool's stats after everything has drained, plus what each
--- request answered, so the caller can assert on both.
local function simulate(seed, steps)
  local restore = random.set(random.seeded(seed))
  execution.reset_id_prefix()

  local gen = random.seeded(seed * 31 + 7)

  -- A pool over memory adapters, because the memory adapter alone has no
  -- pool and the pool is where this defect class lives.
  local pool
  pool = Pool.new(function()
    local conn = memory.new()
    -- The contract `akkar/execution.lua:181` checks: a capability whose value
    -- is a table with `release` is registered for guaranteed release.
    conn.release = function(self) pool:put(self) end
    conn.close = function() end
    return conn
  end, POOL_SIZE)

  local app = akkar.new()
  app:get("/q", function(req)
    local rows = req.db:many "select * from things"
    return { n = #rows }
  end)

  local answered, raised = {}, {}

  local cq = cqueues.new()
  cq:wrap(function()
    for i = 1, steps do
      cq:wrap(function()
        -- The faults are chosen per request, from the seed. `hang` is what
        -- stages abandonment: the query yields and the deadline arrives while
        -- it is yielding, which is the only shape that reproduces the class.
        local client = app:test {
          db = function()
            local conn = pool:get()
            local fault = gen.integer(1, 6)
            if fault == 1 then
              conn:fail("things", "the backend said no")
            elseif fault == 2 then
              -- Long enough to outlive the 0.02 s budget by a wide margin --
              -- which is all that staging abandonment needs -- and short
              -- enough that the controller drains. It was five seconds
              -- first, and the file took 114 seconds to run for no extra
              -- coverage: the request is abandoned at 0.02 either way, and
              -- the remaining 4.98 were spent holding the loop open.
              conn:hang("things", 0.3)
            elseif fault == 3 then
              conn:drop "things"
            else
              conn:on("things", { { id = 1 }, { id = 2 } })
            end
            return conn
          end,
          log = akkar.log.new { level = "error", sink = function() end },
        }

        -- A budget short enough that a hung query is abandoned mid-yield.
        local ok, res = pcall(function()
          return client:get("/q", { timeout = 0.02 })
        end)
        if ok then
          answered[#answered + 1] = res.status
        else
          raised[#raised + 1] = tostring(res)
        end
      end)
      if i % 4 == 0 then cqueues.sleep(0) end
    end
  end)
  assert(cq:loop(30))

  -- Everything that could still be in flight has had its chance; `reap` is
  -- what turns an abandoned coroutine's reservation back into a free slot,
  -- and it is deliberately called rather than waited for.
  pool:reap()

  restore()
  execution.reset_id_prefix()

  return pool:stats(), answered, raised
end

describe("the invariants, under faults a seed chose", function()
  it("never leaks a pool slot, across many seeds", function()
    -- THE ASSERTION THE AUDIT MADE BY HAND. After everything drains, every
    -- resource the pool created is back in it: nothing is held by a request
    -- that went away, and no reservation outlived the coroutine that made it.
    for seed = 1, 25 do
      local stats, answered, raised = simulate(seed, 12)

      assert.is_true(stats.live >= 0,
        ("seed %d: live went negative (%d)"):format(seed, stats.live))

      assert.equal(0, stats.reserved,
        ("seed %d: %d reservation(s) outlived their coroutine"):format(
          seed, stats.reserved))

      assert.equal(stats.live, stats.idle,
        ("seed %d: %d of %d resources never came back"):format(
          seed, stats.live - stats.idle, stats.live))

      assert.is_true(stats.live <= POOL_SIZE,
        ("seed %d: the pool grew past its size (%d > %d)"):format(
          seed, stats.live, POOL_SIZE))

      -- And the run has to have done something: a simulation where every
      -- request raised before touching the pool would satisfy every
      -- assertion above and prove nothing.
      assert.is_true(#answered + #raised == 12,
        ("seed %d: %d of 12 requests are unaccounted for"):format(
          seed, 12 - #answered - #raised))
    end
  end)

  it("answers every request, whatever the fault was", function()
    -- No request may vanish. A 500 or a 503 is an answer; nothing is not.
    for seed = 100, 110 do
      local _, answered, raised = simulate(seed, 8)
      assert.equal(0, #raised,
        ("seed %d: a request escaped as an error: %s"):format(
          seed, raised[1] or ""))
      assert.equal(8, #answered,
        ("seed %d: only %d of 8 requests answered"):format(seed, #answered))
      for _, status in ipairs(answered) do
        assert.is_true(status >= 200 and status < 600,
          ("seed %d: a request answered %s"):format(seed, tostring(status)))
      end
    end
  end)

  it("reproduces: the same seed gives the same answers", function()
    -- Without this the two above are property tests over a random walk. With
    -- it, a failure above is a command: run this seed again.
    local _, first = simulate(4242, 10)
    local _, again = simulate(4242, 10)
    assert.same(first, again)
  end)
end)
