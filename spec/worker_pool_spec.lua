--[[
`with_deadline` runs the handler on a POOLED coroutine, not a fresh one.

Measured through a real server on a real socket, three samples, the no-wrap
arm byte-identical in all three:

    a fresh coroutine per request   11,404 B/request
    a pooled worker                  9,151 B/request
    the machinery now costs            115 B/request   (1.3%, was 20.8%)

The deadline still covers everything it covered: a handler parked OUTSIDE a
capability -- the one case `spec/abandoned_defence_spec.lua` cannot reach
through the budget -- is still answered TIMEOUT at 0.30 s against a 0.30 s
budget, because the arbitration did not change. Only who runs the handler did.

This file pins the properties that make that safe, because the pool degrades
silently otherwise: reuse can stop happening and only the allocation ceiling
would notice, and a worker could be handed to a second request while the first
is still inside it, which nothing else in the suite would see.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues   = require "cqueues"
local execution = require "akkar.execution"

describe("the worker pool", function()
  it("runs consecutive work on the same coroutine", function()
    local seen = {}
    local cq = cqueues.new()
    cq:wrap(function()
      for i = 1, 5 do
        execution.with_deadline(5, function()
          seen[i] = coroutine.running()
        end)
      end
    end)
    assert(cq:loop(20))

    assert.equal(5, #seen)
    for i = 2, 5 do
      assert.equal(seen[1], seen[i],
        ("request %d ran on a different coroutine: the pool is not reusing")
          :format(i))
    end
  end)

  it("does not run work on the coroutine that is calling it", function()
    -- The arbitration depends on the handler being somewhere else: the caller
    -- has to stay free to `poll` the deadline. If this ever became the same
    -- coroutine the timeout could not fire at all, and every test above would
    -- still pass.
    local caller, worker
    local cq = cqueues.new()
    cq:wrap(function()
      caller = coroutine.running()
      execution.with_deadline(5, function() worker = coroutine.running() end)
    end)
    assert(cq:loop(20))
    assert.is_truthy(worker)
    assert.are_not.equal(caller, worker)
  end)

  it("never hands out a worker that is still running a handler", function()
    -- THE PROPERTY THAT MATTERS, and it is not the one this test asserted
    -- first. The original asserted that an abandoned handler's worker is
    -- retired for good, and failed -- because since F2 removed the nested
    -- controller an abandoned handler is no longer inert. It wakes, finishes,
    -- and rejoins the pool, which is correct: by then its stack has unwound.
    --
    -- What must never happen is the OVERLAP -- a worker handed to a second
    -- request while the first is still inside it. So the second request here
    -- runs while the abandoned handler is provably still parked.
    local abandoned_on, next_on, still_parked
    local cq = cqueues.new()
    cq:wrap(function()
      local winner = execution.with_deadline(0.1, function()
        abandoned_on = coroutine.running()
        cqueues.sleep(2)                    -- outlives the budget
        still_parked = false
      end)
      assert.equal("TIMEOUT", winner)
      still_parked = true

      -- Immediately, while the first handler is demonstrably still inside
      -- its sleep.
      execution.with_deadline(5, function() next_on = coroutine.running() end)
      assert.is_true(still_parked, "the abandoned handler had already finished")
    end)
    assert(cq:loop(30))

    assert.is_truthy(abandoned_on)
    assert.is_truthy(next_on)
    assert.are_not.equal(abandoned_on, next_on,
      "a worker was handed out while it was still running a handler")
  end)

  it("keeps a controller's workers to itself", function()
    -- Workers are `cq:wrap`ped onto one controller and cannot run on another,
    -- so the pool is keyed by controller. A worker leaking across would park
    -- on a condition its own controller never steps.
    local first, second

    local cq1 = cqueues.new()
    cq1:wrap(function()
      execution.with_deadline(5, function() first = coroutine.running() end)
    end)
    assert(cq1:loop(20))

    local cq2 = cqueues.new()
    cq2:wrap(function()
      execution.with_deadline(5, function() second = coroutine.running() end)
    end)
    assert(cq2:loop(20))

    assert.is_truthy(first)
    assert.is_truthy(second)
    assert.are_not.equal(first, second)
  end)
end)
