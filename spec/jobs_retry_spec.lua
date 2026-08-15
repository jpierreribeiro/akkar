--[[
Retries, backoff, dead letters and idempotency — readiness item 5.

This module used to drop a failing job on purpose, and the comment defending
it was right about the danger: a retry policy nobody chose hides the failure
and repeats side effects. What follows makes the choice explicit instead of
removing the capability, so the first thing tested is that nothing changed for
anyone who does not ask.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local jobs   = require "akkar.jobs"
local memory = require "akkar.jobs.memory"

local function queue(options)
  return jobs.new(memory.store(), "spec", options)
end

--- Runs the consumer for a fixed number of pops, then stops.
---
--- Counted in pops rather than sized from `q:depth()`, because a job waiting
--- on its backoff is scheduled and not queued -- depth is zero and a helper
--- that trusted it would stop before the retry it was written to observe.
local function drain(q, handlers, rounds)
  local left = rounds or 1
  return q:consume(handlers, { timeout = 0, should_stop = function()
    left = left - 1
    return left < 0
  end })
end

describe("the default is still to drop", function()
  it("does not retry unless retries were asked for", function()
    local q = queue()
    q:push("send", { to = "ada" })

    local runs = 0
    local stats = drain(q, { send = function() runs = runs + 1; error "smtp down" end })

    assert.equal(1, runs)
    assert.equal(1, stats.failed)
    assert.equal(0, stats.retried)
    assert.equal(0, q:depth())
  end)

  it("keeps what it dropped, so nothing is lost silently", function()
    -- The dead-letter queue is on by default even at zero retries: the old
    -- behaviour lost the job entirely, and there was never a reason to.
    local q = queue()
    q:push("send", { to = "ada" })
    drain(q, { send = function() error "smtp down" end })

    assert.equal(1, q:dead_depth())
    local dead = q:dead_letters()[1]
    assert.equal("send", dead.kind)
    assert.equal("ada", dead.payload.to)
    assert.is_truthy(dead.last_error:find("smtp down", 1, true))
    assert.is_number(dead.died_at)
  end)

  it("can be told to drop outright", function()
    local q = queue { dead_letter = false }
    q:push("send", {})
    drain(q, { send = function() error "no" end })
    assert.equal(0, q:dead_depth())
  end)
end)

describe("retrying", function()
  it("schedules a failed job instead of losing it", function()
    local q = queue { retries = 2, backoff = { base = 2, jitter = false } }
    q:push("send", { to = "ada" })

    local stats = drain(q, { send = function() error "smtp down" end })
    assert.equal(1, stats.retried)
    assert.equal(0, q:depth())                          -- not runnable yet
    assert.equal(1, q.store:scheduled_depth(q.key))     -- waiting on its backoff
    assert.equal(0, q:dead_depth())
  end)

  it("gives up after the configured number and buries the job", function()
    -- Backoff of zero so the whole lifecycle runs without waiting.
    local q = queue { retries = 2, backoff = { base = 0, jitter = false } }
    q:push("send", { to = "ada" })

    local attempts = 0
    drain(q, { send = function() attempts = attempts + 1; error "smtp down" end }, 5)

    assert.equal(3, attempts, "one first attempt plus two retries")
    assert.equal(1, q:dead_depth())
    assert.equal(3, q:dead_letters()[1].attempts)
  end)

  it("carries the failure history into the dead letter", function()
    local q = queue { retries = 1, backoff = { base = 0, jitter = false } }
    q:push("send", {})
    drain(q, { send = function() error "first" end })
    drain(q, { send = function() error "second" end }, 2)

    local dead = q:dead_letters()[1]
    assert.equal(2, dead.attempts)
    assert.is_truthy(dead.last_error:find("second", 1, true))
    assert.is_number(dead.first_failed_at)
  end)

  it("refuses a retry policy the store cannot honour", function()
    -- The failure mode this replaces: accepting the policy and quietly not
    -- retrying.  A store with only the three required methods says so now.
    local bare = {
      enqueue = function() return 1 end,
      dequeue = function() return nil end,
      depth = function() return 0 end,
    }
    local ok, err = pcall(jobs.new, bare, "spec", { retries = 3 })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "retries need a store that can schedule")
  end)

  it("treats a missing handler as a failure, not as nothing", function()
    -- Usually a deploy in progress: the worker is older than the producer.
    -- Dropping the job loses work that finishing the deploy would have run.
    local q = queue()
    q:push("kind_from_the_future", {})
    drain(q, { other = function() end })
    assert.equal(1, q:dead_depth())
  end)
end)

describe("backoff", function()
  it("grows exponentially and stops at the cap", function()
    local plain = { base = 2, max = 300, jitter = false }
    assert.equal(2, jobs.delay_for(1, plain))
    assert.equal(4, jobs.delay_for(2, plain))
    assert.equal(8, jobs.delay_for(3, plain))
    assert.equal(300, jobs.delay_for(20, plain))       -- capped, not astronomical
  end)

  it("spreads retries across the window by default", function()
    -- Without jitter, a hundred jobs that failed against a database which has
    -- just come back all retry on the same second and knock it over again.
    local seen = {}
    for _ = 1, 200 do
      local d = jobs.delay_for(4, { base = 2, max = 300 })
      assert.is_true(d >= 0 and d <= 16, "outside the window: " .. d)
      seen[math.floor(d)] = true
    end
    local buckets = 0
    for _ in pairs(seen) do buckets = buckets + 1 end
    assert.is_true(buckets > 5, "delays are not spread out: " .. buckets .. " buckets")
  end)
end)

describe("scheduling", function()
  it("holds a delayed job until it is due", function()
    local q = queue()
    q:push("later", {}, { delay = 60 })
    assert.equal(0, q:depth())
    assert.is_nil(q:pop(0))

    -- Reach into the store rather than sleeping a minute: what is being
    -- tested is the due check, not the clock.
    q.store:promote(q.key, os.time() + 61)
    assert.equal(1, q:depth())
    assert.equal("later", q:pop(0).kind)
  end)

  it("runs what came due in the order it was meant to", function()
    local q = queue()
    q:push("second", {}, { delay = 20 })
    q:push("first", {}, { delay = 10 })
    q.store:promote(q.key, os.time() + 30)

    assert.equal("first", q:pop(0).kind)
    assert.equal("second", q:pop(0).kind)
  end)
end)

describe("idempotency", function()
  it("refuses a second push with the same id", function()
    local q = queue()
    assert.is_number(q:push("charge", { order = 41 }, { id = "charge:order:41" }))

    local ok, why = q:push("charge", { order = 41 }, { id = "charge:order:41" })
    assert.is_false(ok)
    assert.equal("duplicate", why)
    assert.equal(1, q:depth())
  end)

  it("lets a different id through", function()
    local q = queue()
    q:push("charge", {}, { id = "a" })
    q:push("charge", {}, { id = "b" })
    assert.equal(2, q:depth())
  end)

  it("refuses an id the store cannot honour", function()
    local bare = {
      enqueue = function() return 1 end,
      dequeue = function() return nil end,
      depth = function() return 0 end,
    }
    local q = jobs.new(bare, "spec")
    local ok, err = pcall(function() q:push("x", {}, { id = "k" }) end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "cannot deduplicate")
  end)
end)

describe("the dead-letter queue", function()
  it("is capped, because an unbounded one is a leak with a good name", function()
    local q = queue { max_dead = 3 }
    for i = 1, 6 do q:push("send", { i = i }) end
    drain(q, { send = function() error "no" end }, 6)

    assert.equal(3, q:dead_depth())
    -- The newest are the ones kept: the oldest failure is the least useful.
    local kept = q:dead_letters()
    assert.equal(3, #kept)
  end)
end)
