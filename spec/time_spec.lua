--[[
akkar.time — the clock the framework reads.

`clock` had been in the capability set since the beginning and the framework
read none of it: the deadline, the watchdog, the shutdown grace, the metrics
uptime, the queue's due times and every log line called `cqueues.monotime()`
or `os.time()` directly. So the only way to make time pass in a test was to
wait, and `spec/abandoned_spec.lua` waits 2.2 seconds in one place because
there was no alternative.

What is pinned here is the seam itself and the one thing it buys that nothing
else could: a scheduled job coming due without anybody sleeping.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar  = require "akkar"
local time   = require "akkar.time"
local memory = require "akkar.jobs.memory"

describe("the clock seam", function()
  local restore

  after_each(function()
    if restore then restore() end
    restore = nil
  end)

  it("answers the real clock until told otherwise", function()
    local before = time.now()
    assert.is_number(before)
    assert.is_true(math.abs(before - os.time()) <= 1)
    assert.is_number(time.monotime())
  end)

  it("moves only when a manual clock is told to move", function()
    local clock = time.manual { now = 1755000000, monotime = 100 }
    restore = time.set(clock)

    assert.equal(1755000000, time.now())
    assert.equal(100, time.monotime())

    clock:advance(3600)
    assert.equal(1755003600, time.now())
    assert.equal(3700, time.monotime())
  end)

  it("puts the previous clock back", function()
    local clock = time.manual { now = 1 }
    local put_back = time.set(clock)
    assert.equal(1, time.now())
    put_back()
    assert.is_true(time.now() > 1000000, "the real clock did not come back")
  end)

  it("nests, so one restore does not undo another", function()
    local outer = time.manual { now = 100 }
    local restore_outer = time.set(outer)
    local inner = time.manual { now = 200 }
    local restore_inner = time.set(inner)

    assert.equal(200, time.now())
    restore_inner()
    assert.equal(100, time.now(), "restoring the inner clock skipped the outer")
    restore_outer()
  end)
end)

describe("what the seam makes testable", function()
  local restore
  after_each(function() if restore then restore() end restore = nil end)

  it("brings a delayed job due without waiting for it", function()
    -- Before the seam this could only be tested by pushing a job with a
    -- one-second delay and then sleeping for a second, which is why
    -- `spec/jobs_retry_spec.lua` says it tests "the due check, not the clock".
    -- Now the clock is the thing under test.
    local clock = time.manual { now = 1755000000 }
    restore = time.set(clock)

    local queue = memory.new "spec-clock"
    queue:push("send_email", { to = "ada@example.com" }, { delay = 300 })

    assert.equal(0, queue:depth(), "a delayed job must not be poppable yet")
    assert.is_nil(queue:pop(0))

    clock:advance(299)
    assert.is_nil(queue:pop(0), "one second early is still early")

    clock:advance(2)
    local job = queue:pop(0)
    assert.is_truthy(job, "the job never came due")
    assert.equal("send_email", job.kind)
  end)

  it("expires a deduplication claim without waiting for it", function()
    local clock = time.manual { now = 1755000000 }
    restore = time.set(clock)

    local queue = memory.new "spec-clock-claim"
    assert.equal(1, queue:push("charge", {}, { id = "inv-1", id_ttl = 60 }))

    local ok = queue:push("charge", {}, { id = "inv-1", id_ttl = 60 })
    assert.is_false(ok, "the id was not held at all")

    clock:advance(61)
    assert.is_truthy(queue:push("charge", {}, { id = "inv-1", id_ttl = 60 }),
      "the claim never expired")
  end)

  it("ages the process without running for that long", function()
    local clock = time.manual { now = 1755000000 }
    restore = time.set(clock)

    local registry = akkar.metrics.new()
    clock:advance(86400)

    assert.is_truthy(registry:render():match "akkar_uptime_seconds 86400",
      "uptime is not read through the seam")
  end)
end)
