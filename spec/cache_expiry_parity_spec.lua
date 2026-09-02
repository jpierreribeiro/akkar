--[[
The memory cache expires without being read, because Redis does.

## The divergence this pins

`akkar/cache/memory.lua` removed an expired entry when something next read it,
and by nothing else. The audit measured the consequence: 5,000 keys whose TTL
had passed an hour earlier, and `size()` still 5,000. A real server answers
`DBSIZE` 0 there -- verified on redis 7.4.7, where 5,000 keys given `PX 300`
read back as zero after three seconds with nothing having touched them.

It is not only a fidelity gap. `akkar.limit` keys a bucket on (limiter,
tenant, caller), so a process that has served N callers held N hashes for
ever, each one long dead. That is unbounded growth in a long-running process:
the kind of defect that appears only in the deployment nobody restarts, and
that no test could see while the fake behaved this way.

## What is asserted, and against what

Two different questions, and they are separated on purpose.

* WHAT THE STORE REPORTS is asked of both adapters, from one scenario. The
  mechanism for passing time differs -- the fake has an injectable clock, the
  server has a real one and its own expire cycle -- so each adapter answers
  in its own way, exactly as `spec/capacity_spec.lua` gives each one its own
  `issue`. The ANSWER is what has to agree.

* WHAT THE STORE STILL HOLDS can only be asked of the fake, because the
  server's table is not in this process. It is the leak itself rather than
  the report of it, so it is asked without calling `size()` or `:sweep()` --
  anything that reclaims on the way would prove the wrong thing.

The Redis half skips when there is no server. The memory half never skips:
this file must fail on a machine with nothing installed if the fix is
reverted, or it is not testing the fake.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local memory  = require "akkar.cache.memory"
local redis   = require "akkar.redis"
local cqueues = require "cqueues"

local KEYS_EXPECTED = 500
local TTL           = 1        -- whole seconds: `EX` takes nothing smaller

-- ------------------------------------------------------------------ the fake

--- The memory adapter, with the clock in the test's hand.
---
--- `poke` is one ordinary round trip that touches none of the keys under
--- test, because the whole question is whether reclamation happens WITHOUT
--- anybody reading them.
local function with_memory(body)
  local at = 1755000000
  local cache = memory.new { now = function() return at end }
  return body {
    set     = function(key) cache:set(key, "v", TTL) end,
    forever = function(key) cache:set(key, "v") end,
    pass    = function() at = at + TTL + 1 end,   -- `settled` is the server's problem
    poke    = function() cache:command "PING" end,
    reports = function() return cache:size() end,
    -- Not part of the contract; it is the leak rather than the report of it.
    holds   = function()
      local n = 0
      for _ in pairs(cache.store) do n = n + 1 end
      return n
    end,
  }
end

-- ----------------------------------------------------------------- the server

local function reachable()
  -- PING, not merely connect: `cqueues.socket.connect` builds the socket
  -- lazily, so `pcall` around the factory returns true with nothing
  -- listening. The same guard `spec/jobs_redis_spec.lua` carries, and for the
  -- same reason -- every Redis skip in this suite was once decorative.
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if not ok then return false end
  local alive = pcall(function() return conn:ping() end)
  conn:close()
  return alive
end

local COUNT_PREFIX = "return #redis.call('KEYS', ARGV[1])"

--- The same scenario against a real server, in a namespace of its own.
---
--- Counted by prefix rather than with `DBSIZE`, because this container is
--- shared: `DBSIZE` would be answering about somebody else's keys as well as
--- these.
local function with_redis(body)
  local failure, result
  local cq = cqueues.new()
  cq:wrap(function()
    local conn   = redis.connect { pool_size = 0 }()
    local prefix = ("spec:expiry:%d:"):format(math.random(1, 1e9))
    local ok, res = pcall(body, {
      set     = function(key) conn:set(prefix .. key, "v", TTL) end,
      forever = function(key) conn:set(prefix .. key, "v") end,
      -- The server expires on its own time, so this waits for it rather than
      -- moving a clock. Polled, not slept blind: the active cycle runs at
      -- `hz` and the point is that it runs at all, not how fast.
      pass    = function(settled)
        local deadline = cqueues.monotime() + 15
        repeat
          cqueues.sleep(0.1)
          local left = tonumber(conn:command("EVAL", COUNT_PREFIX, 0, prefix .. "*"))
        until left == (settled or 0) or cqueues.monotime() > deadline
      end,
      poke    = function() conn:ping() end,
      reports = function()
        return tonumber(conn:command("EVAL", COUNT_PREFIX, 0, prefix .. "*"))
      end,
    })
    -- Leave nothing behind: another run must not inherit it.
    pcall(function()
      conn:command("EVAL",
        "local n = redis.call('KEYS', ARGV[1]) " ..
        "for i = 1, #n do redis.call('DEL', n[i]) end return #n", 0, prefix .. "*")
    end)
    conn:close()
    if ok then result = res else failure = res end
  end)
  assert(cq:loop(60))
  if failure then error(failure, 0) end
  return result
end

local stores = { { name = "akkar.cache.memory", drive = with_memory } }
if reachable() then
  stores[#stores + 1] = { name = "akkar.redis", drive = with_redis }
else
  describe("akkar.redis (expiry parity)", function()
    pending "Redis is not reachable on 127.0.0.1:6379; skipping the server half"
  end)
end

for _, store in ipairs(stores) do
  describe(store.name .. " expires without being read", function()
    it("reports nothing left once the TTL has passed", function()
      store.drive(function(it_)
        for i = 1, KEYS_EXPECTED do it_.set("k" .. i) end
        assert.equal(KEYS_EXPECTED, it_.reports())

        it_.pass()

        -- NOTHING HAS READ THEM. That is the whole assertion: expiry that
        -- needs a reader is expiry that never happens for a key nobody
        -- returns to, which is every rate-limit bucket of every caller who
        -- went away.
        assert.equal(0, it_.reports(),
          "expired keys are still counted; the store is waiting to be asked")
      end)
    end)

    it("leaves a key with no TTL alone", function()
      -- The other half of the same promise. A store that reclaimed eagerly
      -- and got this wrong would be worse than the one that reclaimed never.
      store.drive(function(it_)
        it_.forever "permanent"
        it_.set "temporary"
        it_.pass(1)
        assert.equal(1, it_.reports())
      end)
    end)
  end)
end

describe("akkar.cache.memory stops holding what it has expired", function()
  it("reclaims across ordinary round trips, with no reader and no sweep", function()
    -- THE LEAK ITSELF, not the report of it. `size()` and `:sweep()` both
    -- reclaim on the way through, so neither is allowed here: what is
    -- inspected is the store's own table, after nothing but PINGs.
    with_memory(function(it_)
      for i = 1, KEYS_EXPECTED do it_.set("k" .. i) end
      assert.equal(KEYS_EXPECTED, it_.holds())

      it_.pass()
      for _ = 1, 50 do it_.poke() end

      assert.equal(0, it_.holds(),
        ("%d entries survived fifty round trips after expiring"):format(it_.holds()))
    end)
  end)

  it("costs a bounded amount of work when nothing is expiring", function()
    -- The reason the cycle is amortised over commands rather than run whole:
    -- a store full of live keys must not pay for a full scan on every
    -- command. Sampling twenty at a time with a rotating cursor is what makes
    -- that true, and a cursor that never advanced would show up here as keys
    -- beyond the first sample never being reached.
    local at = 1755000000
    local cache = memory.new { now = function() return at end }
    for i = 1, 200 do cache:set("live" .. i, "v", 3600) end
    cache:set("doomed", "v", 10)

    at = at + 20
    -- Enough round trips for the cursor to have walked the whole table once
    -- over, and not one more than that.
    for _ = 1, 20 do cache:command "PING" end

    local held = 0
    for _ in pairs(cache.store) do held = held + 1 end
    assert.equal(200, held, "the cursor never reached the expired key")
  end)
end)
