--[[
The abandonment sweep — the audit's question, asked automatically.

An audit asked one question of every place that acquires something: who
releases it, on which paths, and what happens when a coroutine is abandoned
mid-operation. It found seven defects, by hand, in an afternoon. Seven more
were found the next day, the same way. The lesson is not that the code was bad
-- it is that ASKING BY HAND IS NOT A STRATEGY, because the eighth pass never
happens.

So the question is asked here by a loop.

## The axis is time, not yield count

An earlier design counted yields and abandoned at the n-th. This sweeps the
DEADLINE instead, in small steps across the whole span of a request, and it is
better on two counts: it needs no instrumentation inside the adapters, and it
is what production actually does. A deadline does not fire at a yield ordinal;
it fires at a moment, and every moment in the request gets its turn here.

## The invariants, checked after every single one

A request abandoned anywhere must leave the process able to answer the next
one. Concretely:

  * no resource is in the idle set twice -- two requests on one connection is
    the worst thing this framework can produce;
  * nothing in the idle set is still marked in-flight or in a transaction;
  * live + reserved never exceeds the pool's size;
  * acquisitions and releases balance, or the difference is recoverable;
  * and the pool can still serve, which is the only test that matters.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local Pool    = require "akkar.pool"
local cqueues = require "cqueues"

--- A capability backed by a real `akkar.pool`, so the sweep exercises the
--- code that actually holds resources rather than a table pretending to.
local function pooled_capability(size, open_delay)
  local opened, released = 0, 0

  local pool
  pool = Pool.new(function()
    if open_delay and open_delay > 0 then cqueues.sleep(open_delay) end
    opened = opened + 1
    return {
      in_flight = false,
      release = function(self) if self.pool then self.pool:put(self) end end,
      close = function() end,
    }
  end, size, function(conn) return not conn.in_flight end)

  local factory = function()
    local conn = pool:get()
    local original = conn.release
    conn.release = function(self)
      released = released + 1
      return original(self)
    end
    return conn
  end

  return factory, pool, function() return opened, released end
end

local function idle_has_duplicates(pool)
  local seen = {}
  for _, resource in ipairs(pool.idle) do
    if seen[resource] then return true end
    seen[resource] = true
  end
  return false
end

local function check_invariants(pool, where)
  local stats = pool:stats()
  assert.is_false(idle_has_duplicates(pool),
    where .. ": the same resource is in the idle set twice")
  assert.is_true(stats.live + stats.reserved <= stats.size,
    ("%s: live=%d reserved=%d exceeds size=%d")
      :format(where, stats.live, stats.reserved, stats.size))
  assert.is_true(stats.idle <= stats.live,
    where .. ": more idle resources than live ones")
  for _, resource in ipairs(pool.idle) do
    assert.is_false(resource.in_flight,
      where .. ": an in-flight resource went back to the idle set")
  end
end

describe("a request abandoned at every moment of its life", function()
  it("never leaves the pool in a state the next request cannot use", function()
    -- The handler takes a connection and then yields several times, so the
    -- deadline has somewhere to land at every step: before the acquisition,
    -- inside it, between the yields, and after the handler returned.
    local factory, pool = pooled_capability(2, 0.004)

    local app = akkar.new()
    app:get("/work", function(req)
      local conn = req.db
      conn.in_flight = true
      cqueues.sleep(0.006)
      conn.in_flight = false
      cqueues.sleep(0.006)
      return { ok = true }
    end)

    local outcomes = { [200] = 0, [503] = 0, other = 0 }

    local cq = cqueues.new()
    cq:wrap(function()
      -- 0.002 to 0.040 in 0.002 steps: twenty abandonment points across a
      -- request whose own work takes about 0.016.
      for step = 1, 20 do
        local budget = step * 0.002
        local client = app:test { db = factory, timeout = budget }
        local ok, res = pcall(function() return client:get "/work" end)

        if ok then
          outcomes[res.status] = (outcomes[res.status] or 0) + 1
          if res.status ~= 200 and res.status ~= 503 then
            outcomes.other = outcomes.other + 1
          end
        else
          outcomes.other = outcomes.other + 1
        end

        check_invariants(pool, ("deadline %.3fs"):format(budget))
      end
    end)
    assert(cq:loop(60))

    -- Every abandonment produced either an answer or a deadline, never a
    -- crash and never a 500.
    assert.equal(0, outcomes.other,
      "an abandoned request produced something other than a response")
    assert.is_true(outcomes[503] > 0,
      "no deadline ever fired; the sweep did not exercise abandonment")
    assert.is_true(outcomes[200] > 0,
      "no request ever completed; the budgets were all too small")
  end)

  it("can still serve after the whole sweep", function()
    -- The only invariant that ultimately matters. A pool of two that has been
    -- abandoned twenty times must still hand out a connection.
    local factory, pool = pooled_capability(2, 0.004)

    local app = akkar.new()
    app:get("/work", function(req)
      local conn = req.db
      conn.in_flight = true
      cqueues.sleep(0.006)
      conn.in_flight = false
      return { ok = true }
    end)

    local served
    local cq = cqueues.new()
    cq:wrap(function()
      for step = 1, 20 do
        local client = app:test { db = factory, timeout = step * 0.002 }
        pcall(function() return client:get "/work" end)
      end
      pool:reap()

      local client = app:test { db = factory, timeout = 10 }
      served = client:get("/work").status
    end)
    assert(cq:loop(60))

    assert.equal(200, served,
      "the pool never recovered from the sweep and could not serve")
    check_invariants(pool, "after the sweep")
  end)

  it("balances acquisitions against releases", function()
    -- Not an equality: a connection abandoned mid-query is deliberately NOT
    -- released -- it is judged unfit and closed, which is the whole point of
    -- the `in_flight` flag. What must hold is that the difference is bounded
    -- by the number of abandonments rather than growing with every request.
    local factory, pool, counts = pooled_capability(2, 0)

    local app = akkar.new()
    app:get("/work", function(req)
      local _ = req.db
      cqueues.sleep(0.004)
      return { ok = true }
    end)

    local timeouts = 0
    local cq = cqueues.new()
    cq:wrap(function()
      for step = 1, 30 do
        local client = app:test { db = factory, timeout = 0.001 + (step % 5) * 0.002 }
        local ok, res = pcall(function() return client:get "/work" end)
        if ok and res.status == 503 then timeouts = timeouts + 1 end
      end
    end)
    assert(cq:loop(60))

    local opened, released = counts()
    assert.is_true(opened - released <= timeouts + pool:stats().size,
      ("opened %d, released %d, with only %d abandonments to account for it")
        :format(opened, released, timeouts))
  end)
end)
