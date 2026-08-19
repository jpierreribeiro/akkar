--[[
The budget travels with the call.

`akkar/http.lua` opens every outbound request with `timeout = 10`. So a request
that has 200 ms of its own deadline left used to call the service below it with
ten seconds: the caller gives up, drops the connection, and the callee keeps
working on an answer nobody will ever read.

That is the cascading-failure pattern the Google SRE book names, and it was the
default here. gRPC's answer is deadline propagation, and this is akkar's: the
execution's remaining budget bounds every capability inside it.

These tests exercise `akkar.execution` directly rather than through a socket,
because the property is arithmetic and a socket would only add flakiness to it.
`spec/http_spec.lua` covers the wire.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues   = require "cqueues"
local execution = require "akkar.execution"
local akkar     = require "akkar"

--- Runs `fn` inside a coroutine, because the budget is keyed by one.
local function in_execution(fn)
  local result
  local cq = cqueues.new()
  cq:wrap(function() result = fn() end)
  assert(cq:loop(5))
  return result
end

describe("the execution budget", function()
  it("is nil when nothing set one", function()
    assert.is_nil(in_execution(function()
      return execution.remaining()
    end))
  end)

  it("counts down from what began it", function()
    local left = in_execution(function()
      execution.begin(5)
      return execution.remaining()
    end)
    -- THE SAME CLOCK TOLERANCE AS `bounded` BELOW, and this one was found by
    -- sweeping for the shape rather than by waiting for CI to hit it.
    -- `remaining` computes `(t + 5) - t'`, so `left <= 5` is a claim about
    -- doubles and not about the deadline; the sibling assertion returned
    -- 0.20000000000005 against a 0.2 budget on macOS. A nanosecond is far
    -- below any clock here and far above the error, so `left > 4.9` still
    -- carries the real content: time is counting DOWN.
    local EPSILON = 1e-9
    assert.is_true(left > 4.9 and left <= 5 + EPSILON,
      ("remaining was %s, expected just under 5"):format(tostring(left)))
  end)

  it("goes negative rather than nil once it has passed", function()
    -- The distinction matters: nil means "no limit" and a capability would
    -- fall back to its own generous default. Negative means "already too
    -- late", and handing a negative timeout to an I/O call is how you hang.
    local left = in_execution(function()
      execution.begin(0.01)
      cqueues.sleep(0.05)
      return execution.remaining()
    end)
    assert.is_true(left < 0, ("remaining was %s, expected negative"):format(tostring(left)))
  end)

  it("clears when the execution finishes", function()
    assert.is_nil(in_execution(function()
      execution.begin(5)
      execution.finish()
      return execution.remaining()
    end))
  end)

  it("does not leak between coroutines", function()
    -- One execution's budget must never be visible to another. This is the
    -- aliasing defect that ruled out putting the deadline on the shared http
    -- client, so it is asserted rather than assumed.
    local seen
    local cq = cqueues.new()
    cq:wrap(function() execution.begin(5) end)
    cq:wrap(function() seen = execution.remaining() end)
    assert(cq:loop(5))
    assert.is_nil(seen)
  end)
end)

describe("bounded", function()
  it("returns what was asked for when there is no budget", function()
    assert.equal(10, in_execution(function() return execution.bounded(10) end))
  end)

  it("returns the budget when the budget is smaller", function()
    local got = in_execution(function()
      execution.begin(0.2)
      return execution.bounded(10)
    end)

    -- THE TOLERANCE IS THE CLOCK'S, NOT A CONCESSION. `begin` stores
    -- `monotime() + 0.2` and `remaining` returns `deadline - monotime()`, so
    -- what this compares is `(t + 0.2) - t'` in doubles. That is exactly 0.2
    -- only when the two reads and the addition all land on representable
    -- values; on macOS CI it returned **0.20000000000005**, which is fifty
    -- femtoseconds of overshoot and a property of binary floating point
    -- rather than of `bounded`.
    --
    -- A nanosecond is nine orders of magnitude below the observed error and
    -- far below any clock this runs on, so it separates the arithmetic from
    -- the guarantee: a budget that leaked a millisecond would still fail.
    local EPSILON = 1e-9
    assert.is_true(got <= 0.2 + EPSILON,
      ("bounded returned %s, which is more than the 0.2 budget by more than "
       .. "the clock's own precision"):format(tostring(got)))
  end)

  it("returns what was asked for when the ask is smaller", function()
    -- A caller asking for less than the budget gets less. The budget is a
    -- ceiling, not a floor: nobody gets more time by asking.
    local got = in_execution(function()
      execution.begin(30)
      return execution.bounded(0.5)
    end)
    assert.equal(0.5, got)
  end)

  it("returns the budget when nothing was asked for", function()
    local got = in_execution(function()
      execution.begin(3)
      return execution.bounded(nil)
    end)
    assert.is_true(got > 2.9 and got <= 3)
  end)
end)

describe("a request", function()
  it("publishes its deadline to the capabilities inside it", function()
    -- THE END TO END SHAPE, through a real app and a real handler: whatever
    -- `app:run { timeout = ... }` says is what a capability inside the handler
    -- reads. Before this, a handler could not find out how long it had.
    local app = akkar.new()
    app:get("/budget", function()
      return { left = execution.remaining() or -1 }
    end)

    local client = app:test { timeout = 4 }
    local res = client:get "/budget"
    assert.equal(200, res.status)
    assert.is_true(res.body.left > 3.5 and res.body.left <= 4,
      ("the handler saw %s seconds of a 4 second budget"):format(tostring(res.body.left)))
  end)

  it("leaves no budget behind for a request that declares none", function()
    local app = akkar.new()
    app:get("/none", function()
      return { left = execution.remaining() }
    end)

    -- `timeout = 0` is "no deadline", and `0` being truthy in Lua is exactly
    -- how this framework once answered 408 to every request. So it is tested.
    local client = app:test { timeout = 0 }
    local res = client:get "/none"
    assert.equal(200, res.status)
    assert.is_nil(res.body.left)
  end)
end)
