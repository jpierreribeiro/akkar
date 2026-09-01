--[[
akkar.jobs — two jobs that look alike are still two jobs.

The Redis store schedules with `ZADD <key> <run_at> <encoded job>`, so the
encoded job WAS the sorted-set member: two byte-identical jobs due in the same
second collapsed into one. A customer double-clicking "email me the receipt"
got one email; a hundred jobs failing against a database that had just come
back merged into a single retry. The memory store appends to a list and did
not collapse them, so the two backends disagreed about how many jobs existed.

Also here: the failure path must survive a store that cannot answer, and a
dedup id must not outlive the enqueue it was taken for.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local jobs        = require "akkar.jobs"
local jobs_memory = require "akkar.jobs.memory"
local jobs_redis  = require "akkar.jobs.redis"
local redis       = require "akkar.redis"
local cqueues     = require "cqueues"

describe("two identical jobs", function()
  it("stay two in the memory store", function()
    local queue = jobs_memory.new("identity:" .. math.random(1, 1e9))
    queue:push("receipt", { order = 41 })
    queue:push("receipt", { order = 41 })
    assert.equal(2, queue:depth())
  end)

  it("stay two when they are scheduled for the same second", function()
    -- The delayed path is the one that goes through the sorted set.
    local store = jobs_memory.store()
    local queue = jobs.new(store, "identity:" .. math.random(1, 1e9))
    queue:push("receipt", { order = 41 }, { delay = 1 })
    queue:push("receipt", { order = 41 }, { delay = 1 })
    assert.equal(2, store:scheduled_depth(queue.key))
  end)

  it("stay two after both fail into the same retry second", function()
    local store = jobs_memory.store()
    local queue = jobs.new(store, "identity:" .. math.random(1, 1e9),
                           { retries = 3, backoff = { base = 0, jitter = false } })
    queue:push("receipt", { order = 41 })
    queue:push("receipt", { order = 41 })

    local first, second = queue:pop(0), queue:pop(0)
    queue:fail(first, "the database was away")
    queue:fail(second, "the database was away")
    assert.equal(2, store:scheduled_depth(queue.key),
      "a hundred identical failures would have merged into one retry")
  end)
end)

describe("a dedup id", function()
  it("is given back when the enqueue it was taken for fails", function()
    -- Claimed before the push, which is the only order that closes the race
    -- between two producers -- so a failed push has to undo it. Held, the id
    -- answered "duplicate" for an hour about a job that never existed.
    local store = jobs_memory.store()
    local queue = jobs.new(store, "identity:" .. math.random(1, 1e9))
    local real_enqueue = store.enqueue
    store.enqueue = function() error("connection reset by peer", 0) end

    assert.is_false((pcall(queue.push, queue, "charge", {}, { id = "order:41" })))

    store.enqueue = real_enqueue
    local depth = queue:push("charge", {}, { id = "order:41" })
    assert.equal(1, depth, "the id was still held for a job that never existed")
  end)

  it("still refuses a genuine duplicate", function()
    local queue = jobs_memory.new("identity:" .. math.random(1, 1e9))
    assert.is_truthy(queue:push("charge", {}, { id = "order:42" }))
    local ok, why = queue:push("charge", {}, { id = "order:42" })
    assert.is_false(ok)
    assert.equal("duplicate", why)
  end)
end)

describe("a store that fails on the failure path", function()
  it("costs one job rather than the whole worker", function()
    -- `fail` writes to the store, and the store is a network. Called bare, a
    -- blip there unwound the consume loop carrying the job in hand.
    local store = jobs_memory.store()
    local queue = jobs.new(store, "identity:" .. math.random(1, 1e9))
    queue:push("send", { to = "a" })
    queue:push("send", { to = "b" })
    store.enqueue = function(self, key)
      if key:find("dead", 1, true) then error("connection reset by peer", 0) end
      return 0
    end

    local rounds = 0
    local stats
    local ok, err = pcall(function()
      stats = queue:consume({ send = function() error "smtp down" end }, {
        timeout = 0,
        should_stop = function() rounds = rounds + 1; return rounds > 4 end,
      })
    end)

    assert.is_true(ok, "the consume loop unwound: " .. tostring(err))
    assert.equal(2, stats.failed, "both jobs were seen")
  end)
end)

local function redis_reachable()
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if ok then conn:close() end
  return ok
end

if not redis_reachable() then
  describe("the Redis store's sorted set (integration)", function()
    pending("Redis is not reachable on 127.0.0.1:6379; skipping")
  end)
  return
end

describe("the Redis store's sorted set", function()
  it("holds two identical jobs as two members", function()
    local cq = cqueues.new()
    local failure
    cq:wrap(function()
      local ok, err = pcall(function()
        local conn = redis.connect { pool_size = 0 }()
        local store = setmetatable({ cache = conn }, jobs_redis.Store)
        local queue = jobs.new(store, "spec:identity:" .. math.random(1, 1e9))
        queue:push("receipt", { order = 41 }, { delay = 60 })
        queue:push("receipt", { order = 41 }, { delay = 60 })
        assert.equal(2, tonumber(store:scheduled_depth(queue.key)),
          "the encoded job was the ZSET member, so both were one")
        conn:command("DEL", store:scheduled_key(queue.key))
        conn:close()
      end)
      if not ok then failure = err end
    end)
    assert(cq:loop(20))
    if failure then error(failure, 0) end
  end)

  it("gives a claim back through the store the same way", function()
    local cq = cqueues.new()
    local failure
    cq:wrap(function()
      local ok, err = pcall(function()
        local conn = redis.connect { pool_size = 0 }()
        local store = setmetatable({ cache = conn }, jobs_redis.Store)
        local key = "akkar:spec:claim:" .. math.random(1, 1e9)
        assert.is_true(store:claim(key, "order:41", 60))
        assert.is_false(store:claim(key, "order:41", 60))
        store:unclaim(key, "order:41")
        assert.is_true(store:claim(key, "order:41", 60),
          "the claim was never released")
        conn:command("DEL", store:claim_key(key, "order:41"))
        conn:close()
      end)
      if not ok then failure = err end
    end)
    assert(cq:loop(20))
    if failure then error(failure, 0) end
  end)
end)
