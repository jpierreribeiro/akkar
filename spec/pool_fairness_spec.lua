--[[
The pool serves waiters in the order they arrived.

WHY THIS FILE EXISTS AND `spec/pool_spec.lua`'s coverage did not catch it: the
pool had a condition, waiters parked on it, and every functional test passed.
What it did not have was a QUEUE. `put` appended the resource to `idle` and
broadcast; every waiter then raced back to `table.remove(self.idle)`, and a
coroutine that was already running -- a request just read off a socket -- got
there before any woken waiter was resumed.

The consequence is invisible in a functional test and enormous in a tail. On
the benchmark box, `/users/42` at 100 connections:

    p99 5.42 s  ->  17 ms      and throughput went UP, 7165 -> 7409 req/s

Measured without HTTP and without Postgres -- the shape below -- twelve
waiters sharing one resource over 400 rounds served TEN OF THE TWELVE not once.

This spec is the deterministic half of that. It fails hard on the old code:
starvation there is total, not marginal, so the assertions do not need a
tight bound to have teeth and do not depend on timing.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local Pool    = require "akkar.pool"

describe("pool fairness", function()
  -- WHAT IS NOT IN THIS FILE, and why, because the absence is a finding.
  --
  -- Two attempts were made to reproduce the STARVATION itself in-process --
  -- twelve waiters looping on a pool of one, then parked callers against a
  -- stream of 200 fresh arrivals. **Both passed on the old code.** With every
  -- competitor inside one controller and no real I/O, a broadcast plus the
  -- scheduler's own round robin distributes the resource well enough that
  -- nobody is starved, whatever the pool does.
  --
  -- So they were deleted rather than kept as reassurance. A test that passes
  -- before and after the fix is not a regression test; it is a claim of
  -- coverage that does not exist, which is the thing this project has spent
  -- the week finding in its own instruments.
  --
  -- The starvation is real and is measured where it happens -- under load, on
  -- the benchmark box, with the numbers in `akkar/pool.lua`'s comment. What
  -- IS testable in-process is the ordering property that causes it, and that
  -- is below: it fails on the old code and passes on the new.

  it("hands a returned resource to the oldest waiter, not to a new arrival", function()
    local pool = Pool.new(function() return { id = 1 } end, 1)
    local arrived, served = {}, {}

    -- ARRIVAL IS RECORDED, NOT ASSUMED. The first version of this test
    -- asserted the two waiters would be served in `cq:wrap` order and failed
    -- -- because `thread_add` puts a new coroutine at the HEAD, so the
    -- second wrapped runs first and therefore queues first. The pool had
    -- served them in arrival order all along; the test had encoded a guess
    -- about the scheduler. What is being pinned is arrived-order equals
    -- served-order, whatever order the scheduler produces.
    local cq = cqueues.new()
    local held = pool:get()          -- the pool is now empty

    for i = 1, 2 do
      cq:wrap(function()
        arrived[#arrived + 1] = i
        local r = pool:get()
        served[#served + 1] = i
        pool:put(r)
      end)
    end

    cq:wrap(function()
      -- Let both reach `get` and park before anything is returned.
      cqueues.sleep(0)
      cqueues.sleep(0)

      -- A LATE ARRIVAL, started after both are parked and running when the
      -- resource comes back. This is the barger: under the old code it took
      -- from `idle` before either parked waiter was resumed.
      cq:wrap(function()
        arrived[#arrived + 1] = "late"
        local r = pool:get()
        served[#served + 1] = "late"
        pool:put(r)
      end)

      pool:put(held)
    end)

    assert(cq:loop(30))
    assert.equal(3, #served)
    assert.same(arrived, served)
    -- Stated separately so a failure says which property broke: the whole
    -- point is that arriving late does not jump the queue.
    assert.equal("late", served[3])
  end)
end)
