--[[
`cache:remember` coalesces a stampede into one computation.

The property, measured before the module existed and asserted here: N concurrent
requests for the same uncached key run `produce` ONCE, not N times. On a
single cooperative thread every one of them yields inside the database
round-trip that fills the cache, so every one of them misses before any writes
-- which is exactly the thundering herd, and exactly what this removes.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local remember = require "akkar.cache_remember"
local memory = require "akkar.cache.memory"

describe("cache:remember", function()
  it("computes a cold key once and caches the result", function()
    local cache = remember.wrap(memory.new())
    local runs = 0
    local cq = cqueues.new()
    local seen
    cq:wrap(function()
      seen = cache:remember("k", 60, function() runs = runs + 1; return "v" end)
    end)
    assert(cq:loop(5))
    assert.equal("v", seen)
    assert.equal(1, runs)
    -- Second call is a hit, so produce does not run again.
    cq = cqueues.new()
    cq:wrap(function()
      cache:remember("k", 60, function() runs = runs + 1; return "x" end)
    end)
    assert(cq:loop(5))
    assert.equal(1, runs)
  end)

  it("collapses a concurrent stampede to ONE computation", function()
    local cache = remember.wrap(memory.new())
    local runs, answers = 0, {}
    local cq = cqueues.new()
    for i = 1, 100 do
      cq:wrap(function()
        answers[i] = cache:remember("hot", 60, function()
          runs = runs + 1
          cqueues.sleep(0.02)          -- yields, so the others pile up on the miss
          return "the-value"
        end)
      end)
    end
    assert(cq:loop(5))

    assert.equal(1, runs, ("100 requests ran produce %d times"):format(runs))
    -- And every one of them got the value, not nil.
    for i = 1, 100 do
      assert.equal("the-value", answers[i],
        ("request %d did not receive the coalesced value"):format(i))
    end
  end)

  it("does not hang the waiters when produce raises", function()
    -- A failed producer must wake the waiters, or they wait for ever. One of
    -- them then becomes the next producer. This asserts the run TERMINATES and
    -- that a later success still fills the cache.
    local cache = remember.wrap(memory.new())
    local attempts = 0
    local raised, recovered = 0, nil
    local cq = cqueues.new()
    for _ = 1, 5 do
      cq:wrap(function()
        local ok, v = pcall(function()
          return cache:remember("k", 60, function()
            attempts = attempts + 1
            if attempts <= 3 then error("boom") end   -- first three fail
            cqueues.sleep(0.01)
            return "eventually"
          end)
        end)
        if not ok then raised = raised + 1 else recovered = v end
      end)
    end
    assert(cq:loop(5), "the waiters hung after a failed producer")
    assert.equal("eventually", recovered)
    assert.is_true(raised >= 1, "a failing producer should have surfaced its error")
  end)

  it("fills a shared key once PER decorator, which is once per process", function()
    -- Two decorators over two caches are two processes' worth of state. Each
    -- fills the key once; the flight table does not and must not span them.
    local a = remember.wrap(memory.new())
    local b = remember.wrap(memory.new())
    local runs = 0
    local function fill(c)
      return c:remember("k", 60, function() runs = runs + 1; return "v" end)
    end
    local cq = cqueues.new()
    cq:wrap(function() fill(a) end)
    cq:wrap(function() fill(b) end)
    assert(cq:loop(5))
    assert.equal(2, runs)
  end)
end)
