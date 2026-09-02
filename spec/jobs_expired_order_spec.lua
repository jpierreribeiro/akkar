--[[
The two job stores hand back an expired lease in the same order.

## The divergence this pins

`akkar/jobs/memory.lua:expired` documents "oldest first, so a job abandoned
twice does not overtake one abandoned once", and does it: `held` is appended
to in claim order and walked forwards.

`akkar/jobs/redis.lua` said the same thing in a comment and did the opposite.
`claim_pop` uses `RPOPLPUSH`, which pushes to the HEAD, so the processing list
runs newest-first and `LRANGE processing -limit -1` hands back its slice in
that order -- `held[1]` is the newest lease in the window and `held[#held]`
the oldest. The script walked it forwards.

So after a mass reap -- a deploy, an OOM kill, a fleet restart, which is
exactly when more than one lease expires at once -- Redis redelivered LIFO and
memory redelivered FIFO. Every existing spec reaps a single job, where the
order cannot be seen, so ~2,170 green tests said nothing about it.

## Which order is correct

Oldest first, and not merely because the memory store got there first.

* It is what the rest of the queue already promises. `promote` moves due
  work "oldest first", `peek` reads oldest first, and `dequeue` is FIFO. A
  redelivery path that ran newest-first would make the queue's ordering
  depend on whether a worker had died, which is not a property anybody can
  reason about.
* LIFO STARVES THE OLDEST ENTRY. Under a reap that keeps finding more than
  `limit` stale leases, a newest-first window never reaches the bottom of the
  list -- and the entry at the bottom is the one that has been redelivered
  most often, so it is the one closest to `max_redeliveries` and to whatever
  deadline put it in the queue. The failure mode of getting this wrong is
  that the sickest job is the last one looked at.

## How it is asserted

One scenario, driven over both stores, the shape `spec/capacity_spec.lua`
uses. The memory half never skips.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local jobs_memory = require "akkar.jobs.memory"
local jobs_redis  = require "akkar.jobs.redis"
local redis       = require "akkar.redis"
local cqueues     = require "cqueues"
local time        = require "akkar.time"

local JOBS = { "first", "second", "third", "fourth", "fifth" }

local function reachable()
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if not ok then return false end
  local alive = pcall(function() return conn:ping() end)
  conn:close()
  return alive
end

--- `drive(body)` gives `body` a store, a key, and the instant to ask about.
---
--- `asked` is the `now` seam both stores carry: it moves the CUTOFF and
--- nothing else, so a lease can be made stale without waiting out a
--- visibility window. Each store reads its own clock to build it, because a
--- claim time is written by the store and comparing it against somebody
--- else's clock is the defect `akkar/jobs/redis.lua`'s header is about.
local function with_memory(body)
  local store = jobs_memory.store()
  local key   = "spec:reap:memory"
  for _, encoded in ipairs(JOBS) do store:enqueue(key, encoded) end
  return body(store, key, time.now() + 10000)
end

local function with_redis(body)
  local failure, result
  local cq = cqueues.new()
  cq:wrap(function()
    local conn  = redis.connect { pool_size = 0 }()
    local store = setmetatable({ cache = conn }, jobs_redis.Store)
    local key   = ("spec:reap:%d"):format(math.random(1, 1e9))
    local ok, res = pcall(function()
      for _, encoded in ipairs(JOBS) do store:enqueue(key, encoded) end
      local server = conn:command "TIME"
      return body(store, key, tonumber(server[1]) + 10000)
    end)
    pcall(function()
      conn:del(key); conn:del(store:processing_key(key)); conn:del(store:claimed_key(key))
    end)
    conn:close()
    if ok then result = res else failure = res end
  end)
  assert(cq:loop(30))
  if failure then error(failure, 0) end
  return result
end

local stores = { { name = "akkar.jobs.memory", drive = with_memory } }
if reachable() then
  stores[#stores + 1] = { name = "akkar.jobs.redis", drive = with_redis }
else
  describe("akkar.jobs.redis (reap order)", function()
    pending "Redis is not reachable on 127.0.0.1:6379; skipping the server half"
  end)
end

for _, store in ipairs(stores) do
  describe(store.name .. " reaps oldest first", function()
    it("hands back every stale lease in the order it was claimed", function()
      store.drive(function(s, key, asked)
        -- Five jobs claimed and none acknowledged: five workers that died
        -- holding them, which is what a fleet restart looks like to the
        -- store.
        for _ = 1, #JOBS do assert.is_string(s:claim_pop(key)) end
        assert.equal(#JOBS, s:in_flight(key))

        assert.same(JOBS, s:expired(key, 300, asked, 500))
      end)
    end)

    it("takes the OLDEST when the batch is smaller than the backlog", function()
      -- The case that decides whether an old lease can starve. A window of
      -- two must be the two at the bottom of the list, in that order --
      -- newest-first would return the two most recently claimed and never
      -- come back for the rest.
      store.drive(function(s, key, asked)
        for _ = 1, #JOBS do assert.is_string(s:claim_pop(key)) end

        assert.same({ JOBS[1], JOBS[2] }, s:expired(key, 300, asked, 2))
      end)
    end)

    it("returns nothing while the leases are inside their window", function()
      -- The seam moves the cutoff and nothing else, so asking about NOW must
      -- find leases that were taken a moment ago perfectly healthy.
      store.drive(function(s, key)
        for _ = 1, #JOBS do assert.is_string(s:claim_pop(key)) end
        assert.same({}, s:expired(key, 300, nil, 500))
      end)
    end)
  end)
end
