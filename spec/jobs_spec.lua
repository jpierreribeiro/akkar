--[[
The jobs/store split.

The property that justifies the split is that the SAME semantics run against
different storage.  So the semantic tests run twice -- once over memory, once
over Redis -- and the Redis half skips when none is reachable.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar     = require "akkar"
local jobs      = require "akkar.jobs"
local memory    = require "akkar.jobs.memory"
local jobs_redis= require "akkar.jobs.redis"
local redis     = require "akkar.redis"

describe("the store contract", function()
  it("refuses a store that does not answer it", function()
    local ok, err = pcall(function()
      return jobs.new({ enqueue = function() end }, "x")
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "missing :dequeue")
  end)
end)

-- The semantics, run against every store.
local function behaves_like_a_queue(label, make)
  describe("queue semantics over " .. label, function()
    local queue
    before_each(function() queue = make() end)

    it("round-trips a job with its kind and payload", function()
      queue:push("send_email", { to = "ada@example.com" })
      local job = queue:pop(1)
      assert.equal("send_email", job.kind)
      assert.equal("ada@example.com", job.payload.to)
      assert.is_number(job.queued_at)
    end)

    it("is FIFO", function()
      for i = 1, 3 do queue:push("n", { i = i }) end
      local seen = {}
      for _ = 1, 3 do seen[#seen + 1] = queue:pop(1).payload.i end
      assert.same({ 1, 2, 3 }, seen)
    end)

    it("reports depth", function()
      assert.equal(0, queue:depth())
      queue:push("a", {})
      queue:push("b", {})
      assert.equal(2, queue:depth())
    end)

    it("returns nil when empty rather than hanging", function()
      assert.is_nil(queue:pop(1))
    end)

    it("keeps working after a handler fails", function()
      queue:push("boom", {})
      queue:push("ok", { value = 7 })

      local got, errors = nil, 0
      local remaining = 3
      local result = queue:consume({
        boom = function() error "handler exploded" end,
        ok   = function(payload) got = payload.value end,
      }, {
        timeout = 1,
        log = { warn = function() end, error = function() errors = errors + 1 end },
        should_stop = function() remaining = remaining - 1 return remaining < 0 end,
      })

      -- One failing job must not take the worker down with it.
      assert.equal(7, got)
      assert.equal(1, errors)
      assert.equal(1, result.handled)
      assert.equal(1, result.failed)
    end)

    it("takes the id and queues the job as one step", function()
      -- As two calls, a coroutine abandoned between the claim and the push
      -- left the id held for the full ttl with no job anywhere, and every
      -- retry for the next hour was refused as a duplicate of a job that had
      -- never been queued. Both stores answer the single-step contract now,
      -- so the semantics can be stated once and checked against each.
      assert.is_function(queue.store.claim_and_enqueue,
        "this store cannot claim and enqueue in one step")

      -- A fresh id per run. A claim outlives the suite -- an hour by default
      -- -- so a fixed id would make the second run of the day fail on the
      -- first run's success.
      local id = "inv-" .. math.random(1, 1e9)

      assert.equal(1, queue:push("charge", { amount = 10 }, { id = id }))
      assert.equal(1, queue:depth())

      local ok, why = queue:push("charge", { amount = 10 }, { id = id })
      assert.is_false(ok)
      assert.equal("duplicate", why)
      assert.equal(1, queue:depth(), "the refused push still queued a job")

      -- A different id is a different job.
      queue:push("charge", { amount = 20 }, { id = id .. "-b" })
      assert.equal(2, queue:depth())
    end)

    it("takes the id and schedules a delayed job as one step", function()
      -- The delayed branch goes to the sorted set instead of the list, and it
      -- is the branch a retry most often takes.
      local id = "inv-" .. math.random(1, 1e9)

      queue:push("charge", { amount = 10 }, { id = id, delay = 60 })
      assert.equal(0, queue:depth(), "a delayed job must not be immediately poppable")
      assert.equal(1, queue.store:scheduled_depth(queue.key))

      local ok, why = queue:push("charge", { amount = 10 }, { id = id, delay = 60 })
      assert.is_false(ok)
      assert.equal("duplicate", why)
      assert.equal(1, queue.store:scheduled_depth(queue.key),
        "the refused push still scheduled a job")
    end)

    it("does not lose a job when the worker dies holding it", function()
      -- The property `Queue:consume` did not have, and said so in its own
      -- docstring: `pop` is destructive, so between it and the handler
      -- finishing, the job existed only in the worker's memory. An ordinary
      -- deploy lost it, silently, and the retry policy did not cover that --
      -- retries are for a handler that RAISED, and a worker that died raised
      -- nothing.
      --
      -- A worker dying cannot be staged in-process, so this stages what is
      -- observationally identical: take the job and never acknowledge it.
      assert.is_true(queue:reliable(),
        "this store cannot survive a worker dying, and the queue says so")

      queue:push("charge", { amount = 10 })
      local job = queue:pop(0)
      assert.equal("charge", job.kind)

      assert.equal(0, queue:depth(), "the job should be out of the queue")
      assert.equal(1, queue:in_flight(), "and accounted for as checked out")

      -- `reap(n)` returns what was claimed more than n seconds ago, so a
      -- generous window must reclaim nothing and a negative one -- everything
      -- claimed before a moment in the future -- must reclaim this.
      assert.equal(0, queue:reap(60), "a fresh claim must not be reclaimed")
      assert.equal(1, queue:reap(-1), "the abandoned job was not returned")
      assert.equal(1, queue:depth())
      assert.equal(0, queue:in_flight())

      local again = queue:pop(0)
      assert.equal("charge", again.kind)
      assert.equal(10, again.payload.amount)
    end)

    it("stops being recoverable once it is acknowledged", function()
      -- The other half. A job that finished must not come back, or every
      -- reap would replay the day.
      queue:push("charge", { amount = 10 })
      local job = queue:pop(0)
      assert.is_true(queue:ack(job))

      assert.equal(0, queue:in_flight())
      assert.equal(0, queue:reap(-1), "an acknowledged job was reaped anyway")
      assert.equal(0, queue:depth())
    end)

    it("acknowledges through consume, on success and on failure alike", function()
      -- Both paths end with the job dealt with: handled, or failed and then
      -- retried or buried. Leaving either checked out would make the next
      -- reap run it again.
      queue:push("ok", {})
      queue:push("boom", {})

      local remaining = 4
      queue:consume({
        ok   = function() end,
        boom = function() error "handler exploded" end,
      }, {
        timeout = 0,
        log = { warn = function() end, error = function() end },
        should_stop = function() remaining = remaining - 1 return remaining < 0 end,
      })

      assert.equal(0, queue:in_flight(),
        "consume left a job checked out after dealing with it")
    end)

    it("warns about a job kind nobody handles", function()
      queue:push("unknown_kind", {})
      local warned = 0
      local remaining = 2
      queue:consume({}, {
        timeout = 1,
        log = { warn = function() warned = warned + 1 end, error = function() end },
        should_stop = function() remaining = remaining - 1 return remaining < 0 end,
      })
      assert.equal(1, warned)
    end)
  end)
end

behaves_like_a_queue("memory", function() return memory.new("spec") end)

local function redis_reachable()
  -- PING, not merely connect. `cqueues.socket.connect` builds the socket
  -- lazily and touches the network on first use, so `pcall` around the
  -- factory returns TRUE with nothing listening -- every Redis skip guard in
  -- this suite was decorative, and only looked correct because a developer's
  -- machine always had Redis running. CI's no-services job found it on its
  -- first run.
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if not ok then return false end
  local alive = pcall(function() return conn:ping() end)
  conn:close()
  return alive
end

if redis_reachable() then
  behaves_like_a_queue("redis", function()
    local cache = redis.connect { pool_size = 0 }()
    -- The scheduled set as well as the list. Redis outlives the suite, so a
    -- delayed job left by an earlier run is state the next run inherits --
    -- and a test that reads a depth would then be measuring history.
    cache:del "akkar:queue:spec-redis"
    cache:del "akkar:queue:spec-redis:scheduled"
    -- And the processing set, for the same reason as the scheduled one: a
    -- job left checked out by an earlier run is state the next run inherits,
    -- and a test that counts in-flight jobs would be counting history.
    cache:del "akkar:queue:spec-redis:processing"
    cache:del "akkar:queue:spec-redis:processing:at"
    return jobs_redis.new(cache, "spec-redis")
  end)
else
  describe("queue semantics over redis", function()
    pending "Redis is not reachable; skipping"
  end)
end

describe("offloading from a handler", function()
  it("answers immediately and leaves the work queued", function()
    local queue = memory.new "reports"
    local app = akkar.new()
    app:post("/reports", function()
      queue:push("build_report", { user = 1 })
      return akkar.response(202, { status = "queued" })
    end)

    local res = app:test():post("/reports", { body = {} })
    assert.equal(202, res.status)
    assert.equal(1, queue:depth())
  end)
end)
