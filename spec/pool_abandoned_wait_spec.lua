--[[
A handler abandoned WHILE WAITING FOR A POOL SLOT.

Found on the study box, not here, and it is the defect F2 introduced.

Removing the per-request controller made an abandoned handler wake instead of
staying inert. What was supposed to protect the next request is the budget: an
abandoned handler carries a negative `execution.remaining()`, and `db.lua` and
`redis.lua` both refuse on it.

**That covers the QUERY and not the ACQUISITION.** A handler parked in
`Pool:get`'s `waiters:wait()` when its deadline fires is not inside a query
yet. It wakes after the 503 has gone out, is handed the next free slot, and
nothing ever returns that slot -- the request's release ran at the 503, when
the handler did not yet hold anything.

Measured on the box, pool of 2, four fast clients and one slow, 120 seconds:

    head    t=0s   224.7 ok/s     t=10s onward   0.0 ok/s   forever
    base    t=0s  3195.4 ok/s     t=110s        3291.7 ok/s

and afterwards, with no load at all running, `live=2 idle=0 reserved=0` and
every probe answering 503. A permanent, unrecoverable outage.

It is a cliff rather than a drift because it is self-reinforcing: each leaked
slot lengthens the wait, and a longer wait abandons more handlers inside it.
With slack in the pool it never starts -- pool of 10 ran 935,510 requests with
zero leaks and a `waited_max` of 16 ms.

These cases reproduce it without a database, because the mechanism is the
pool's and not Postgres's.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues   = require "cqueues"
local Pool      = require "akkar.pool"
local execution = require "akkar.execution"
local log       = require "akkar.log"

execution.default_log(log.new { level = "error", sink = function() end })

--- A pool of `size` trivial resources.
local function pool_of(size)
  local opened = 0
  return Pool.new(function()
    opened = opened + 1
    return { id = opened }
  end, size)
end

describe("a handler abandoned while waiting for a pool slot", function()
  it("does not take the slot it can no longer give back", function()
    -- THE DEFECT, reproduced. One holder occupies the only slot; a second
    -- handler parks in `waiters:wait()` with a budget too short to survive
    -- the wait. When the holder finally returns the slot, the abandoned
    -- handler must NOT be the one to receive it.
    local pool = pool_of(1)
    local cq = cqueues.new()
    local waiter_got

    cq:wrap(function()
      -- The holder: takes the only slot and gives it back after the waiter's
      -- deadline has already passed.
      local held = pool:get()
      cqueues.sleep(0.30)
      pool:put(held)
    end)

    cq:wrap(function()
      cqueues.sleep(0.02)             -- let the holder take the slot first
      execution.with_deadline(0.10, function()
        local ok, got = pcall(function() return pool:get() end)
        waiter_got = ok and got or false
      end)
      -- Long enough for the abandoned handler to wake and be handed the slot.
      cqueues.sleep(0.40)
    end)

    assert(cq:loop(5))

    assert.is_false(waiter_got ~= false and waiter_got ~= nil,
      "an abandoned handler was given a pool slot; nothing will return it, " ..
      "and the pool wedges one slot per occurrence")
  end)

  it("leaves the pool able to serve the next request", function()
    -- The consequence, stated as the property that actually matters: after
    -- an abandonment inside the wait, a fresh caller must still be served.
    -- On the box this was the difference between 3,291 ok/s and zero.
    local pool = pool_of(1)
    local cq = cqueues.new()
    local later

    cq:wrap(function()
      local held = pool:get()
      cqueues.sleep(0.30)
      pool:put(held)
    end)
    cq:wrap(function()
      cqueues.sleep(0.02)
      execution.with_deadline(0.10, function() pcall(pool.get, pool) end)
      cqueues.sleep(0.40)
    end)
    cq:wrap(function()
      -- Arrives after everything above has finished, with no budget of its
      -- own, exactly like the next request on a quiet server.
      cqueues.sleep(0.90)
      local ok, got = pcall(pool.get, pool)
      later = ok and got or nil
      if later then pool:put(later) end
    end)

    assert(cq:loop(5))
    assert.is_not_nil(later,
      "the pool could not serve a later request: the slot was taken by a " ..
      "handler that had already been abandoned and never returns it")
  end)

  it("says why, rather than handing back nil", function()
    -- The refusal has to be legible. A pool that returns nil here would put
    -- an "attempt to index a nil value" in a handler that did nothing wrong.
    local pool = pool_of(1)
    local cq = cqueues.new()
    local why

    cq:wrap(function()
      local held = pool:get()
      cqueues.sleep(0.30)
      pool:put(held)
    end)
    cq:wrap(function()
      cqueues.sleep(0.02)
      execution.with_deadline(0.10, function()
        local ok, err = pcall(pool.get, pool)
        if not ok then why = tostring(err) end
      end)
      cqueues.sleep(0.40)
    end)
    assert(cq:loop(5))

    assert.is_string(why, "the abandoned waiter was not refused at all")
    assert.is_truthy(why:find("deadline", 1, true),
      "the refusal did not name the deadline: " .. tostring(why))
  end)

  it("does not refuse a waiter whose execution has no deadline", function()
    -- Jobs, workers and `app:test` run with no budget. `remaining()` is nil
    -- there, and nil must read as "no limit" rather than as "already over" --
    -- the same trap `with_deadline` documents about `timeout = 0`.
    local pool = pool_of(1)
    local cq = cqueues.new()
    local got

    cq:wrap(function()
      local held = pool:get()
      cqueues.sleep(0.15)
      pool:put(held)
    end)
    cq:wrap(function()
      cqueues.sleep(0.02)
      got = pool:get()                -- no with_deadline anywhere
    end)

    assert(cq:loop(5))
    assert.is_not_nil(got, "a waiter with no budget was refused a slot")
  end)

  it("does not keep a connection whose deadline passed while it opened", function()
    -- THE HOLE THE FIRST FIX MISSED, and the study box found it: the guard was
    -- right and the frame was wrong.
    --
    -- `open` YIELDS -- it connects a socket, and on Postgres it authenticates
    -- and sets `statement_timeout`. The budget can be positive when the loop
    -- iteration begins and negative by the time the connection exists, so the
    -- check at the top of the loop cannot see it. Measured on the box: 26
    -- refusals fired on the wait path and ZERO at the entry, while every
    -- leaked resource was tagged `budget=-0.0035` and handed out from this
    -- branch.
    local opened = 0
    local pool = Pool.new(function()
      opened = opened + 1
      cqueues.sleep(0.20)          -- `open` takes longer than the budget
      return { id = opened }
    end, 4)

    local cq = cqueues.new()
    local got, why
    cq:wrap(function()
      execution.with_deadline(0.05, function()
        local ok, res = pcall(pool.get, pool)
        if ok then got = res else why = tostring(res) end
      end)
      cqueues.sleep(0.40)
    end)
    assert(cq:loop(5))

    assert.is_nil(got,
      "a connection opened past the deadline was handed to a handler that " ..
      "had already answered 503; nothing will return it")
    assert.is_truthy(why and why:find("deadline", 1, true),
      "the refusal did not name the deadline: " .. tostring(why))
    assert.equal(1, #pool.idle,
      "the fresh connection was thrown away instead of parked; a contended " ..
      "pool would reconnect on every abandonment")
  end)
end)
