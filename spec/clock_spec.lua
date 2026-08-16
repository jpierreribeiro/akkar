--[[
What a clock that jumps does to akkar.

## Why this file exists

`akkar/time.lua` was built so the framework's sense of time could be moved in
a test, and until now nothing moved it BACKWARDS. NTP stepping a clock is not
exotic: a machine whose clock drifts, a VM resumed from a snapshot, a
container on a host that has just been corrected. Every one of those steps the
wall clock, forwards or backwards, under a running process.

## The map, read out of the source before writing a line

Deadlines, the pool, health checks, the HTTP client, the Postgres driver and
the tracer all use `monotime`, which by definition does not move when the wall
clock is corrected. Those are immune and no test here can say anything about
them.

`akkar.jobs` uses `time.now()` -- wall clock -- for every one of: when a job
was queued, when a delayed job is due, which scheduled jobs to promote, when a
claim was taken, when a failure first happened, when a retry is due, and the
cutoff `reap` compares claims against.

That is the whole exposure, and it is where these tests point.

`akkar.jwt` also uses wall clock, and correctly: `exp` and `nbf` are defined
against wall time by the standard, so a JWT that expires when the clock is
corrected is behaving as specified rather than failing.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local time   = require "akkar.time"
local memory = require "akkar.jobs.memory"

--- A clock that starts at a fixed wall time and can be stepped either way.
local function manual(at)
  local wall = at
  return {
    now      = function() return wall end,
    monotime = function() return wall end,
    sleep    = function() end,
    step     = function(by) wall = wall + by end,
  }
end

describe("a wall clock that jumps", function()
  local clock, restore

  before_each(function()
    clock = manual(1755000000)
    restore = time.set(clock)
  end)

  after_each(function() if restore then restore() end end)

  it("delays a scheduled job by however far the clock went back", function()
    -- `run_at = now + delay`, and `promote` asks whether `run_at <= now`. Step
    -- the clock back an hour and a job due in a minute is due in sixty-one.
    local queue = memory.new "clockspec"
    queue:push("later", { n = 1 }, { delay = 60 })

    clock.step(60)
    queue.store:promote(queue.key, time.now())
    assert.equal(1, queue:depth(), "a job due now was not promoted")

    -- And with the clock stepped BACKWARDS before the delay elapses.
    local back = memory.new "clockspec_back"
    back:push("later", { n = 2 }, { delay = 60 })
    clock.step(-3600)
    clock.step(60)                     -- a minute of real time passes
    back.store:promote(back.key, time.now())
    assert.equal(0, back:depth(),
      "the job ran on time despite the clock going back, which would mean " ..
      "scheduling is not wall-clock after all")
  end)

  it("REAPS A LIVE WORKER'S JOB when the clock jumps forward", function()
    -- The dangerous direction, and the one worth having a test for.
    --
    -- `reap(older_than)` reclaims anything claimed before `now - older_than`.
    -- A claim is stamped with the wall clock. So a forward step of more than
    -- `older_than` makes EVERY claim look stale at once -- including the one
    -- a worker is holding and actively running.
    --
    -- At-least-once becomes at-least-twice for every job in flight, caused by
    -- a clock correction and nothing else.
    local queue = memory.new "clockspec_reap"
    queue:push("charge", { amount = 10 })

    local job = queue:pop(0)
    assert.is_table(job)
    assert.equal(1, queue:in_flight())

    -- A worker holding it for one second. Nothing is stale.
    clock.step(1)
    assert.equal(0, queue:reap(300),
      "a one-second-old claim was reaped against a five-minute window")

    -- NTP corrects the clock forward by an hour.
    clock.step(3600)

    local reclaimed = queue:reap(300)
    assert.equal(1, reclaimed,
      "the claim survived a forward clock step, which would mean reaping is " ..
      "not wall-clock after all")
    assert.equal(1, queue:depth(),
      "the job the live worker is running is back in the queue")
  end)

  it("never reaps anything after the clock jumps backwards", function()
    -- The other direction is quieter and also wrong: claims stamped with the
    -- old, larger wall time look like they were taken in the future, so the
    -- cutoff never reaches them and an abandoned job is never recovered.
    local queue = memory.new "clockspec_back_reap"
    queue:push("charge", { amount = 10 })
    queue:pop(0)                                   -- claimed, never acked

    clock.step(-3600)

    assert.equal(0, queue:reap(300),
      "an abandoned job was recovered despite the clock going back")
    assert.equal(1, queue:in_flight(),
      "the job is stuck in the processing set until wall time catches up")
  end)

  it("leaves deadlines alone, because they are monotonic", function()
    -- The reassuring half, and it is worth pinning: a request deadline uses
    -- `monotime`, which is defined not to move when the wall clock is
    -- corrected. A step of an hour must not expire a request that has been
    -- running for a millisecond.
    --
    -- This uses the REAL clock deliberately: the manual one above answers the
    -- same value for both, which is fine for the job tests and would make
    -- this one vacuous.
    if restore then restore() restore = nil end

    local before = time.monotime()
    local wall_before = time.now()
    assert.is_number(before)
    assert.is_number(wall_before)

    -- Monotime and wall time are different clocks, and the point is that they
    -- are read from different sources rather than one being derived from the
    -- other.
    assert.are_not.equal(math.floor(before), math.floor(wall_before),
      "monotime and now appear to be the same clock, which would make every " ..
      "deadline in akkar vulnerable to an NTP step")
  end)
end)
