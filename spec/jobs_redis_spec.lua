--[[
The Redis job store, against a real Redis.

The semantics are tested against the memory store in `jobs_retry_spec.lua`.
What can only be tested here is whether Redis actually behaves the way the
store assumes: whether `SET NX EX` really refuses the second claim, whether a
sorted set gives back what is due in the right order, and whether the RESP
replies parse into what the code expects. A fake proves none of that.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local redis      = require "akkar.redis"
local jobs       = require "akkar.jobs"
local jobs_redis = require "akkar.jobs.redis"
local cqueues    = require "cqueues"

local function reachable()
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if ok then conn:close() end
  return ok
end

if not reachable() then
  describe("akkar.jobs.redis (integration)", function()
    pending("Redis is not reachable on 127.0.0.1:6379; skipping")
  end)
  return
end

--- Everything here runs inside a cqueues controller, because the Redis
--- adapter yields while it waits.
local function in_redis(fn)
  local cq = cqueues.new()
  local result, failure
  cq:wrap(function()
    local conn = redis.connect { pool_size = 0 }()
    local store = setmetatable({ cache = conn }, jobs_redis.Store)
    local q = jobs.new(store, "spec:" .. math.random(1, 1e9), {
      retries = 2, backoff = { base = 0, jitter = false },
    })
    local ok, res = pcall(fn, q, conn)
    -- Leave nothing behind: another run of this suite must not inherit it.
    pcall(function()
      conn:del(q.key); conn:del(q:dead_key()); conn:del(q.key .. ":scheduled")
    end)
    conn:close()
    if ok then result = res else failure = res end
  end)
  assert(cq:loop(20))
  if failure then error(failure, 0) end
  return result
end

describe("akkar.jobs.redis", function()
  it("round-trips a job through a list", function()
    in_redis(function(q)
      q:push("send", { to = "ada" })
      assert.equal(1, tonumber(q:depth()))
      local job = q:pop(1)
      assert.equal("send", job.kind)
      assert.equal("ada", job.payload.to)
    end)
  end)

  it("holds a scheduled job until it is due, then promotes it", function()
    in_redis(function(q)
      q:push("later", {}, { delay = 60 })
      assert.equal(0, tonumber(q:depth()))
      assert.equal(1, tonumber(q.store:scheduled_depth(q.key)))

      assert.equal(0, q.store:promote(q.key, os.time()))          -- not yet
      assert.equal(1, q.store:promote(q.key, os.time() + 61))     -- now
      assert.equal(1, tonumber(q:depth()))
    end)
  end)

  it("promotes what is due oldest first", function()
    in_redis(function(q)
      q:push("second", {}, { delay = 20 })
      q:push("first", {}, { delay = 10 })
      q.store:promote(q.key, os.time() + 30)
      assert.equal("first", q:pop(1).kind)
      assert.equal("second", q:pop(1).kind)
    end)
  end)

  it("refuses a duplicate id, atomically, via SET NX EX", function()
    -- This is the property a process-local table cannot have, and the reason
    -- deduplication lives in the store rather than in the worker.
    in_redis(function(q, conn)
      assert.is_truthy(q:push("charge", { order = 41 }, { id = "order:41" }))
      local ok, why = q:push("charge", { order = 41 }, { id = "order:41" })
      assert.is_false(ok)
      assert.equal("duplicate", why)
      assert.equal(1, tonumber(q:depth()))
      conn:del(q.key .. ":claim:order:41")
    end)
  end)

  it("buries a job that runs out of retries, and lists it", function()
    in_redis(function(q)
      q:push("send", { to = "ada" })
      local left = 5
      q:consume({ send = function() error "smtp down" end },
                { timeout = 0, should_stop = function()
                    left = left - 1; return left < 0
                  end })

      assert.equal(1, tonumber(q:dead_depth()))
      local dead = q:dead_letters()[1]
      assert.equal("send", dead.kind)
      assert.equal(3, dead.attempts)
      assert.is_truthy(dead.last_error:find("smtp down", 1, true))
    end)
  end)

  it("caps the dead-letter list", function()
    in_redis(function(q)
      for i = 1, 5 do
        q.store:enqueue(q:dead_key(), '{"kind":"send","i":' .. i .. '}')
      end
      q.store:trim(q:dead_key(), 2)
      assert.equal(2, tonumber(q:dead_depth()))
    end)
  end)

  it("peeks oldest first, the same way the memory store does", function()
    -- A reader must see the same order whichever backend is behind it.
    in_redis(function(q)
      for i = 1, 3 do
        q.store:enqueue(q:dead_key(), '{"kind":"send","n":' .. i .. '}')
      end
      local seen = q:dead_letters()
      assert.equal(3, #seen)
      assert.equal(1, seen[1].n)
      assert.equal(3, seen[3].n)
    end)
  end)
end)
