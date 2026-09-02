--[[
The in-server timeout path must abandon NO controller.

`akkar/health.lua`'s `with_timeout` used to allocate a fresh `cqueues.new()`
per probe purely to arbitrate the timeout, and on timeout it DROPPED that
controller with the probe still running inside.  An abandoned pollset, linked
into the live loop, is what `cstack_cancelfd` walked into a SIGSEGV in
`fileno_cmp` on arm64 -- `docs/substrate/SEGFAULT.md`.  The no-services CI job
crashes because its probes time out continuously, and timeout was the one path
that abandoned a controller.

The fix runs the probe as a worker on the controller it is already inside, the
way `akkar/execution.lua` (F2) runs a request handler.  These tests pin the two
properties that has to hold:

  1. STRUCTURAL: N timed-out probes inside a server controller create ZERO new
     controllers.  Proven by counting `cqueues.new` over the window -- this is
     RED against the old code (one `cqueues.new` per probe) and GREEN now.

  2. The abandoned probe WAKES and finishes on the shared loop rather than
     going inert inside a dropped controller -- proven by a check that records
     completion AFTER its timeout, and asserting every one of them recorded it.

  3. BEHAVIOUR PRESERVED, in-server: a probe that never returns still makes the
     caller see "timed out" promptly, without hanging.  (The out-of-controller
     twin of this is `spec/health_spec.lua`'s "fails a check that does not
     return".)
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local health  = require "akkar.health"
local cqueues = require "cqueues"

describe("the in-server timeout path abandons no controller", function()
  it("creates zero controllers across N timed-out probes, and each one wakes", function()
    local N = 8
    local finished = 0        -- checks that ran to completion on the shared loop

    local probe = health.new {
      -- Sleeps past its own timeout, then records completion. Every probe
      -- times out (reported to the caller), and the abandoned worker must
      -- still wake on the shared loop and reach the increment.
      checks = { slow = function()
        cqueues.sleep(0.05)
        finished = finished + 1
        return true
      end },
      timeout = 0.02,
      cache   = 0,            -- no cache: every ready() actually runs the check
    }

    local cq = cqueues.new()

    -- Spy on controller creation for the duration of the wrapped work only.
    local real_new = cqueues.new
    local created = 0
    cqueues.new = function(...) created = created + 1; return real_new(...) end

    local timed_out = 0
    cq:wrap(function()
      for _ = 1, N do
        local result = probe:ready()
        if result.checks.slow.timed_out then timed_out = timed_out + 1 end
      end
    end)
    assert(cq:loop(5))        -- bounded so a regression cannot hang the suite
    cqueues.new = real_new

    assert.equal(0, created,
      ("the in-server path created %d controller(s) across %d probes; on " ..
       "timeout each is DROPPED with the probe still inside it, and that " ..
       "abandoned pollset is the arm64 segfault"):format(created, N))

    assert.equal(N, timed_out,
      "every probe was supposed to time out; the test proves nothing if they did not")

    assert.equal(N, finished,
      ("only %d of %d abandoned probes woke and finished on the shared loop; " ..
       "the fix depends on the abandoned worker resuming, not going inert")
      :format(finished, N))
  end)

  it("still times out a probe that never returns, in-server, without hanging", function()
    local probe = health.new {
      checks = { wedged = function() cqueues.sleep(30); return true end },
      timeout = 0.05,
      cache   = 0,
    }

    local cq = cqueues.new()
    local result, elapsed
    cq:wrap(function()
      local began = cqueues.monotime()
      result  = probe:ready()
      elapsed = cqueues.monotime() - began
    end)
    -- The driver coroutine finishes at ~0.05s; the wedged worker parks on the
    -- shared loop for 30s, so the loop is bounded rather than run to empty.
    assert(cq:loop(2))

    assert.is_not_nil(result, "the probe never returned to its caller -- it hung")
    assert.equal("fail", result.checks.wedged.status)
    assert.is_true(result.checks.wedged.timed_out)
    assert.is_truthy(result.checks.wedged.reason:find("timed out", 1, true))
    assert.is_true(elapsed < 1,
      ("the caller waited %.2fs for a check with a 0.05s timeout"):format(elapsed or -1))
  end)
end)
