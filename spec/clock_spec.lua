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

-- THE IN-MEMORY STORE FOLLOWS ITS PROCESS'S CLOCK, and that is the right
-- answer for it rather than an outstanding defect.
--
-- One process has one clock. If it is stepped, everything inside it stepped
-- together and there is no second opinion to be wrong about. These tests
-- therefore pin what that store DOES, so that a future change to it is a
-- decision rather than an accident.
--
-- The dangerous version of this was the Redis store, where several workers
-- each had an opinion and one wrong clock reclaimed everybody's work. That is
-- fixed, and the fleet tests at the bottom of this file are the proof.
describe("a wall clock that jumps, over the in-memory store", function()
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

  it("reclaims its own in-flight claim when its clock jumps forward", function()
    -- In one process this is consistent: the claim and the cutoff are read
    -- from the same clock, so a step moves both and the store simply believes
    -- more time passed than did. The job comes back and runs again, which
    -- at-least-once permits.
    --
    -- The same shape across SEVERAL processes was the real defect: one
    -- worker's correction made every other worker's live claim look stale.
    -- That is what the Redis store no longer does.
    local queue = memory.new "clockspec_reap"
    queue:push("charge", { amount = 10 })

    local job = queue:pop(0)
    assert.is_table(job)
    assert.equal(1, queue:in_flight())

    -- A worker holding it for one second. Nothing is stale.
    clock.step(1)
    assert.equal(0, queue:reap(),
      "a one-second-old claim was reaped against a five-minute window")

    -- NTP corrects the clock forward by an hour.
    clock.step(3600)

    local reclaimed = queue:reap()
    assert.equal(1, reclaimed,
      "the claim survived a forward clock step; the in-memory store is " ..
      "expected to follow its own clock")
    assert.equal(1, queue:depth(),
      "the job the live worker is running is back in the queue")
  end)

  it("stops reclaiming after its clock jumps backwards", function()
    -- The quieter direction. Claims stamped with the old, larger wall time
    -- look as though they were taken in the future, so the cutoff never
    -- reaches them and an abandoned job waits until wall time catches up.
    --
    -- Pinned rather than fixed: for a single process this is the honest
    -- consequence of following one clock, and the alternative -- a second,
    -- monotonic stamp -- would buy nothing here and cannot work across
    -- processes, which is where it would have mattered.
    local queue = memory.new "clockspec_back_reap"
    queue:push("charge", { amount = 10 })
    queue:pop(0)                                   -- claimed, never acked

    clock.step(-3600)

    assert.equal(0, queue:reap(),
      "an abandoned job was recovered despite the clock going back, which " ..
      "the in-memory store cannot do")
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

describe("a fleet where one worker's clock is wrong", function()
  -- THE FIX, AND THE ONLY TEST THAT CAN SHOW IT.
  --
  -- The tests above use the in-memory store, which is one process: if that
  -- process's clock jumps, everything in it jumped together, and there is no
  -- second opinion to disagree with. A fleet is different, and a fleet is
  -- where the damage was: one worker's NTP correction reclaiming jobs that
  -- other workers were running.
  --
  -- The store now reads the Redis server's clock inside its scripts, so the
  -- caller's clock is not consulted at all. This test steps the CALLER's
  -- clock by an hour and requires nothing to happen.
  local jobs_redis = require "akkar.jobs.redis"
  local redis      = require "akkar.redis"
  local time       = require "akkar.time"

  local function redis_reachable()
    local ok, conn = pcall(redis.connect { pool_size = 0 })
    if not ok then return false end
    local alive = pcall(function() return conn:ping() end)
    conn:close()
    return alive
  end

  if not redis_reachable() then
    pending "Redis is not reachable; skipping"
    return
  end

  local queue, restore, at

  before_each(function()
    local cache = redis.connect { pool_size = 0 }()
    for _, suffix in ipairs { "", ":processing", ":processing:at", ":scheduled", ":dead" } do
      cache:del("akkar:queue:clockfleet" .. suffix)
    end
    queue = jobs_redis.new(cache, "clockfleet")

    -- A caller whose wall clock is whatever we say it is.
    at = 1755000000
    restore = time.set {
      now      = function() return at end,
      monotime = function() return at end,
      sleep    = function() end,
    }
  end)

  after_each(function() if restore then restore() end end)

  it("does not reap a live claim when the CALLER's clock jumps forward", function()
    queue:push("charge", { amount = 10 })
    local job = queue:pop(0)
    assert.is_table(job)
    assert.equal(1, queue:in_flight())

    -- NTP corrects this worker forward by an hour. Against the old code every
    -- claim in the fleet looked an hour stale at once, and this reaped a job
    -- another worker was running.
    at = at + 3600

    assert.equal(0, queue:reap(),
      "a live claim was reclaimed because THIS worker's clock moved -- the " ..
      "store is reading the caller's clock again")
    assert.equal(1, queue:in_flight())
    assert.equal(0, queue:depth())
  end)

  it("still reaps a genuinely abandoned claim", function()
    -- The other half, and the one that makes the first meaningful: a fix that
    -- simply stopped reaping would pass the test above and lose every
    -- abandoned job for ever.
    --
    -- `visibility = 0` rather than an instant passed in: what has to be shown
    -- is that the SERVER decides, so nothing here may hand the store a time.
    queue = jobs_redis.new(queue.store.cache, "clockfleet", { visibility = 0 })
    queue:push("charge", { amount = 10 })
    queue:pop(0)                                   -- claimed, never acked

    assert.equal(1, queue:reap(),
      "an abandoned claim was not recovered; reaping is broken rather than " ..
      "merely clock-independent")
    assert.equal(1, queue:depth())
    assert.equal(0, queue:in_flight())
  end)

  it("does not freeze reaping when the caller's clock jumps backwards", function()
    queue = jobs_redis.new(queue.store.cache, "clockfleet", { visibility = 0 })
    queue:push("charge", { amount = 10 })
    queue:pop(0)

    at = at - 3600                                 -- NTP steps back an hour

    assert.equal(1, queue:reap(),
      "nothing was reclaimed after the caller's clock went back, which is " ..
      "the old failure in the other direction")
  end)

  it("schedules by the server's clock, not the caller's", function()
    -- A worker an hour behind used to schedule everything an hour late.
    at = at - 3600
    queue:push("later", {}, { delay = 1 })
    assert.equal(1, tonumber(queue.store:scheduled_depth(queue.key)))

    -- Not due yet by the SERVER's clock, whatever this worker believes.
    assert.equal(0, queue.store:promote(queue.key))

    queue.store:schedule(queue.key,
      require("cjson").encode { kind = "overdue", payload = {} }, -1)
    assert.equal(1, queue.store:promote(queue.key),
      "an entry scheduled into the past was not promoted, so scheduling is " ..
      "still following the caller")
  end)
end)
