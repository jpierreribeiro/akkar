--[[
THE GATE ON THE TWO LARGEST OPTIMISATIONS IN `docs/PERFORMANCE-PLAN.md`.

Both of them -- deleting the per-request controller (B1) and reusing a
coroutine instead of creating one (A2) -- are worth about 2,300 bytes a
request each, and both are blocked on the same property, which nothing in this
suite pinned down until now.

The property: **a handler abandoned by its deadline never runs again.**

Today it holds by construction rather than by design. `with_deadline` runs the
handler inside a controller of its own; when the deadline fires, that
controller is dropped and nothing ever steps it, so the suspended coroutine is
inert. `with_deadline`'s own comment says exactly this, and says what would
happen otherwise: "Move it to the outer controller and it keeps running, wakes
after the 503, and touches a connection that has already gone back to the
pool -- trading a descriptor leak for a data bug."

Both optimisations do precisely that. A shared controller steps the abandoned
handler; a reused worker coroutine is by definition still being resumed. So
whoever attempts either will need a defence that does not exist yet, and these
tests are how they find out -- the first goes red the moment inertness stops
holding.

The second test is the uncomfortable half, and it is the reason the first one
is not enough on its own. It asserts what is TRUE today rather than what ought
to be: after release, the object the handler is still holding **works**. There
is no poisoning, no generation check, nothing. Inertness is the only thing
standing between an abandoned handler and somebody else's connection.

If you are here because you added that defence: this second test should now
fail, and the right response is to rewrite it to assert the new guarantee.
That is a test doing its job, not a test being wrong.
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
  it("never runs again after the deadline fires", function()
    -- THE PROPERTY BOTH OPTIMISATIONS MUST PRESERVE.
    --
    -- The handler sleeps past its budget and then, if it ever woke, would
    -- write into a table this test can see. It must never appear there.
    local resource = recorder()
    local outcome
    local cq = cqueues.new()

    cq:wrap(function()
      outcome = execution.with_deadline(0.05, function()
        cqueues.sleep(0.4)
        -- Everything below is what an abandoned handler would do if it woke.
        resource:touch "after the deadline"
        return "finished"
      end)
    end)

    -- The loop runs well past the handler's own sleep, so "it did not wake"
    -- cannot be confused with "there was no time for it to wake".
    assert(cq:loop(3))

    assert.equal("TIMEOUT", outcome)
    assert.same({}, resource.used,
      "the abandoned handler ran after its deadline: " ..
      table.concat(resource.used, ", "))
  end)

  it("is inert even while the controller it lives in is stepped", function()
    -- The sharper version. The previous case could pass because nothing ran
    -- at all; this one keeps the OUTER controller busy for the whole of the
    -- handler's sleep, so the scheduler has every opportunity to resume it and
    -- the only reason it does not is that the handler is in a controller
    -- nobody steps.
    local resource = recorder()
    local ticks = 0
    local cq = cqueues.new()

    cq:wrap(function()
      execution.with_deadline(0.05, function()
        cqueues.sleep(0.4)
        resource:touch "woke inside a busy loop"
      end)
    end)
    cq:wrap(function()
      for _ = 1, 40 do
        cqueues.sleep(0.01)
        ticks = ticks + 1
      end
    end)

    assert(cq:loop(3))
    assert.is_true(ticks >= 30,
      ("the outer controller only ran %d times; it was not busy"):format(ticks))
    assert.same({}, resource.used,
      "a busy outer controller resumed the abandoned handler")
  end)

  it("has had its capabilities released while it was still suspended", function()
    -- And this is why inertness matters rather than being a curiosity. By the
    -- time the deadline has fired, the framework has already handed the
    -- handler's connection back. The handler is suspended holding a reference
    -- to something that now belongs to whoever borrows it next.
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
        local _ = carrier.db          -- acquired, and now held by the handler
        cqueues.sleep(0.4)
        carrier.db:touch "would corrupt somebody else's connection"
      end)
      -- What `handle` does on every exit path, including this one.
      execution.release(record)
    end)
    assert(cq:loop(3))

    assert.equal(1, resource.released, "the capability was not released")
    assert.same({}, resource.used,
      "the abandoned handler touched a capability that had been released")
  end)
end)

describe("what stands between an abandoned handler and a recycled connection", function()
  it("is ONLY inertness -- a released capability still works", function()
    -- THE UNCOMFORTABLE ASSERTION, and it is deliberate.
    --
    -- This states what is true rather than what ought to be. `release` calls
    -- `resource:release()` and drops the framework's own reference; it does
    -- not poison the object, and it cannot cheaply -- the object may BE the
    -- pooled connection, so poisoning it would break the next request that
    -- borrows it. Any real defence needs a per-execution handle or a
    -- generation check, and neither exists.
    --
    -- So the safety of every request in this runtime rests on one thing: the
    -- abandoned handler is in a controller nobody steps. Remove that and this
    -- is what is left.
    --
    -- IF YOU ADDED THE DEFENCE, THIS TEST SHOULD NOW FAIL. Rewrite it to
    -- assert the new guarantee. That is the test doing its job.
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

    held:touch "after release"
    assert.same({ "after release" }, resource.used,
      "a released capability refused to work -- if that is deliberate, this " ..
      "test is out of date and the plan's B1 and A2 are unblocked")
  end)

  it("does not survive release for a handler that reads the carrier again", function()
    -- The narrower case, and the only one currently defended: a handler that
    -- reads `req.db` FRESH after release gets a new acquisition rather than
    -- the released one, because `release` clears the list and `acquire`
    -- caches on the carrier. It is not a defence against a captured local,
    -- which is what handlers actually write.
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

    -- Still cached on the carrier: the same object comes back, released.
    local again = carrier.db
    assert.equal(1, opened,
      "reading the carrier after release opened a SECOND capability, which " ..
      "would leak one per abandoned request")
    assert.is_not_nil(again)
  end)
end)
