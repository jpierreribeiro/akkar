--[[
WHAT PROTECTS A REQUEST FROM A HANDLER ITS DEADLINE ABANDONED.

This file was written as a GATE: `with_deadline` used to run every handler in
a nested controller of its own, so an abandoned handler was inert -- nothing
ever stepped it and it never woke. Two optimisations worth about 2,300 bytes a
request each would have removed that, and these tests existed to fail the
moment one of them was attempted.

**One of them was attempted, and these tests failed exactly as designed.** The
controller is gone: `with_deadline` runs the handler on the controller it is
already in and uses a bare number in `cqueues.poll` as the deadline. Descriptors
per in-flight request went 3.00 -> 1.00, and the concurrency ceiling on the
usual `ulimit -n 1024` went 225 -> 675.

So an abandoned handler DOES wake now, and this file records the two defences
that replaced inertness.

**The budget protects built-in I/O.** A handler abandoned by its deadline
carries a NEGATIVE remaining budget: `M.begin` set the deadline inside the
handler's own coroutine and `M.finish` never ran, because the handler never
resumed. Database and Redis consult it before I/O.

**A lease protects every per-execution resource.** A custom capability need
not know akkar's budget. The handler receives a proxy tied to the execution
record, while release keeps the real object. Once the record is over, the
proxy refuses fields and methods without poisoning the object that may already
belong to another request. `spec/abandoned_spec.lua` tells the protocol half
of this story against real servers, because a fake cannot have the problem it
is about.
]]
package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues   = require "cqueues"
local execution = require "akkar.execution"
local log       = require "akkar.log"

execution.default_log(log.new { level = "error", sink = function() end })

--- A capability that records everything done to it, and can be released.
---
--- Deliberately not a database. What is being tested is the FRAMEWORK's
--- guarantee about lifetime, and a real connection would add a second story
--- -- the protocol's -- on top of the one under test. `spec/abandoned_spec.lua`
--- tells that second story, against real servers, because it has to.
local function recorder()
  local it = { used = {}, released = 0 }
  function it:touch(what) self.used[#self.used + 1] = what end
  function it:release() self.released = self.released + 1 end
  return it
end

describe("a handler abandoned by its deadline", function()
  it("reports TIMEOUT to the caller whatever the handler goes on to do", function()
    -- The guarantee the CLIENT gets, and it did not change when the
    -- controller went away: the deadline decides the outcome, and a handler
    -- that finishes later cannot overturn it.
    local outcome
    local cq = cqueues.new()
    cq:wrap(function()
      outcome = execution.with_deadline(0.05, function()
        cqueues.sleep(0.4)
        return "finished, but far too late"
      end)
    end)
    assert(cq:loop(3))
    assert.equal("TIMEOUT", outcome)
  end)

  it("does wake, now that the controller is gone -- and that is the point", function()
    -- STATED RATHER THAN HIDDEN. This used to assert the opposite, and the
    -- assertion is inverted rather than deleted so that the change is legible
    -- to whoever reads the file next.
    --
    -- The handler resumes on the connection's own controller after the 503
    -- has gone out. What it may then DO is the subject of every case below.
    local resource = recorder()
    local cq = cqueues.new()
    cq:wrap(function()
      execution.with_deadline(0.05, function()
        cqueues.sleep(0.2)
        resource:touch "woke after the deadline"
      end)
      -- Keep the controller alive long enough for the handler to resume.
      cqueues.sleep(0.4)
    end)
    assert(cq:loop(3))
    assert.same({ "woke after the deadline" }, resource.used,
      "the handler did not wake; if a controller came back, the descriptor " ..
      "count in spec/concurrency_spec.lua will have gone 1.00 -> 3.00 too")
  end)

  it("is told by its budget that it is over", function()
    -- WHAT REPLACED INERTNESS, and the whole safety argument rests on it.
    local left
    local cq = cqueues.new()
    cq:wrap(function()
      execution.with_deadline(0.05, function()
        cqueues.sleep(0.2)
        left = execution.remaining()
      end)
      cqueues.sleep(0.4)
    end)
    assert(cq:loop(3))

    assert.is_not_nil(left, "the abandoned handler had no budget at all")
    assert.is_true(left < 0,
      ("a resumed handler saw %.3f s left; every capability that refuses on " ..
       "the budget -- db and redis -- would have served it"):format(left))
  end)

  it("has had its capabilities released while it was still suspended", function()
    -- Unchanged, and still true: by the time the deadline has fired the
    -- framework has handed the handler's connection back. That is why the
    -- budget check matters rather than being a nicety.
    local resource = recorder()
    local record  = { capabilities = { db = function() return resource end } }
    local carrier = setmetatable({ id = "abandoned-1" }, {
      __index = function(self, key)
        return execution.acquire(self, record, key)
      end,
    })

    local cq = cqueues.new()
    cq:wrap(function()
      execution.with_deadline(0.05, function()
        local _ = carrier.db
        cqueues.sleep(0.4)
      end)
      execution.release(record)
      cqueues.sleep(0.3)
    end)
    assert(cq:loop(3))
    assert.equal(1, resource.released, "the capability was not released")
  end)
end)

describe("what stands between an abandoned handler and a recycled connection", function()
  it("is the BUDGET, for a capability that reads it", function()
    -- One defence, which already existed for the built-in network adapters.
    --
    -- An abandoned handler carries a NEGATIVE remaining budget: `begin` set
    -- the deadline inside the handler's own coroutine and `finish` never ran,
    -- because the handler never resumed. So a capability that asks how much
    -- time is left gets a negative answer and can refuse -- which is exactly
    -- what `bound_by_execution` does in `akkar/db.lua` and, since the gate
    -- was written, in `akkar/redis.lua` too.
    --
    -- This is a stronger position than inertness, because it survives the two
    -- optimisations that would remove inertness.
    local refused
    local cq = cqueues.new()
    cq:wrap(function()
      local co
      local inner = cqueues.new()
      inner:wrap(function()
        co = coroutine.running()
        execution.begin(0.05)
        cqueues.sleep(0.3)
        -- The handler wakes, and asks what a budget-aware capability asks.
        local left = execution.remaining()
        refused = left ~= nil and left <= 0
      end)
      inner:step(0)
      cqueues.sleep(0.2)      -- the budget passes while nothing steps it
      inner:step(0)           -- and now it IS stepped: the handler wakes
      cqueues.sleep(0.3)
      inner:step(0)
    end)
    assert(cq:loop(5))

    assert.is_true(refused,
      "a resumed handler did not see a passed budget; every capability that " ..
      "refuses on the budget -- db and redis -- would have served it")
  end)

  it("revokes a captured capability even when it ignores the budget", function()
    -- The resource itself cannot be poisoned: release may already have put it
    -- back in a pool for another request. The value held by THIS execution is
    -- a lease, though, and the lease must stop dispatching as soon as release
    -- marks its execution over.
    local resource = recorder()
    local record  = { capabilities = { db = function() return resource end } }
    local carrier = setmetatable({ id = "held-1" }, {
      __index = function(self, key)
        return execution.acquire(self, record, key)
      end,
    })

    local held = carrier.db                 -- what a handler captures in a local
    execution.release(record)
    assert.equal(1, resource.released)

    local ok, err = pcall(function() held:touch "after release" end)
    assert.is_false(ok, "a captured capability remained usable after release")
    assert.is_truthy(tostring(err):find("execution ended", 1, true), tostring(err))
    assert.same({}, resource.used,
      "the revoked lease dispatched a call to the recycled resource")
  end)

  it("also revokes a fresh read of the cached carrier value", function()
    local opened = 0
    local record = { capabilities = { db = function()
      opened = opened + 1
      return recorder()
    end } }
    local carrier = setmetatable({ id = "held-2" }, {
      __index = function(self, key)
        return execution.acquire(self, record, key)
      end,
    })

    local _ = carrier.db
    execution.release(record)
    assert.equal(1, opened, "the capability was opened more than once")

    -- Still cached on the carrier: no second acquisition, but the cached
    -- lease is dead too.
    local again = carrier.db
    assert.equal(1, opened,
      "reading the carrier after release opened a SECOND capability, which " ..
      "would leak one per abandoned request")
    assert.is_not_nil(again)
    local ok = pcall(function() again:touch "after release" end)
    assert.is_false(ok, "the carrier returned a usable released capability")
  end)
end)
