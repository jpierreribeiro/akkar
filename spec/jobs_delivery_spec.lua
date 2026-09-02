--[[
At-least-once delivery: the tests that have to be crashes.

Both shipped stores used to pop a job and hand it over in one step, so a
worker killed mid-handler took the job with it -- nothing redelivered it and
nothing anywhere recorded that it had existed. What follows is the evidence
that this is no longer true, and the standard it is held to is that calling
the API in the documented order proves nothing about a worker dying: a
sequence of `push`, `pop`, `ack` passes just as happily on a store that loses
every unacked job. So each crash here is a real one -- a coroutine abandoned
with the job in hand, a process sent SIGKILL while it holds the lease -- and
the assertion is that the job comes back.

The properties run against BOTH stores, and one test records the same script
against each and compares the two traces field by field. The reason is written
in `akkar/db/memory.lua`: a fake whose safety property differs from the real
one is how a test proves the wrong thing, and this module has already been
bitten by exactly that -- Redis collapsed two identical jobs into one, memory
did not, and the suite was green.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local jobs        = require "akkar.jobs"
local jobs_memory = require "akkar.jobs.memory"
local jobs_redis  = require "akkar.jobs.redis"
local redis       = require "akkar.redis"
local cqueues     = require "cqueues"

-- Long enough that nothing expires by accident while a test is running, and
-- every reap below is driven by an explicit `now` instead of a sleep: what is
-- under test is the due check, not the clock.
local VISIBILITY = 30
local LATER      = VISIBILITY + 1

local function options(extra)
  local out = { visibility = VISIBILITY, reap_every = 3600 }
  for k, v in pairs(extra or {}) do out[k] = v end
  return out
end

local function over_memory(extra, fn)
  fn(jobs.new(jobs_memory.store(), "delivery:" .. math.random(1, 1e9),
              options(extra)))
end

local function redis_reachable()
  -- PING, not merely connect: `cqueues.socket.connect` builds the socket
  -- lazily, so `pcall(redis.connect{...})` returns true with nothing
  -- listening. The connect-only form is decorative -- the same defect fixed
  -- in `jobs_redis_spec` and the two guards on `ci-green`, and the one CI's
  -- no-services job caught. And it is worse than a false skip here: a
  -- connect that FAILS is what fires the cqueues fd-cancel path, so a whole
  -- spec file connecting to a dead port at load time is the arm64 segfault's
  -- own trigger.
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if not ok then return false end
  local alive = pcall(function() return conn:ping() end)
  conn:close()
  return alive
end

-- The Postgres half. No controller around it, and that difference is real
-- rather than an oversight: the Redis adapter yields while it waits, so its
-- half has to run inside one, and the Postgres store's waits are a
-- `cqueues.poll` that blocks perfectly well standalone. Every property below
-- passes `timeout = 0` anyway, so nothing here waits at all.
local pg_support = require "spec.support.jobs_postgres"

local function over_postgres(extra, fn)
  fn(pg_support.queue("spec:delivery", options(extra)))
end

--- Runs `fn` against a Redis-backed queue inside a cqueues controller, since
--- the Redis adapter yields while it waits, and leaves no keys behind.
local function over_redis(extra, fn)
  local cq = cqueues.new()
  local failure
  cq:wrap(function()
    local conn  = redis.connect { pool_size = 0 }()
    local store = setmetatable({ cache = conn }, jobs_redis.Store)
    local q = jobs.new(store, "spec:delivery:" .. math.random(1, 1e9),
                       options(extra))
    local ok, err = pcall(fn, q)
    pcall(function()
      conn:del(q.key, q:dead_key(), q.key .. ":scheduled",
               store:processing_key(q.key), store:claimed_key(q.key))
    end)
    conn:close()
    if not ok then failure = err end
  end)
  assert(cq:loop(60))
  if failure then error(failure, 0) end
end

-- ================================================== what the queue promises

describe("the guarantee a queue reports", function()
  it("is at-least-once wherever the store can hold a job", function()
    assert.equal("at_least_once", jobs_memory.new("delivery:promise").delivery)
  end)

  it("is at-most-once on a store that cannot, and says so rather than lying",
  function()
    local bare = {
      enqueue = function() return 1 end,
      dequeue = function() return nil end,
      depth = function() return 0 end,
    }
    assert.equal("at_most_once", jobs.new(bare, "delivery:bare").delivery)
  end)

  it("refuses to claim at-least-once over a store that cannot do it", function()
    -- The failure this replaces: accepting the setting and delivering at most
    -- once anyway, which is the one outcome worse than not offering it.
    local bare = {
      enqueue = function() return 1 end,
      dequeue = function() return nil end,
      depth = function() return 0 end,
    }
    local ok, err = pcall(jobs.new, bare, "delivery:bare",
                          { delivery = "at_least_once" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "at%-least%-once delivery needs a store")
  end)

  it("gives the old behaviour back when it is asked for by name", function()
    local q = jobs_memory.new("delivery:opt-out", { delivery = "at_most_once" })
    assert.equal("at_most_once", q.delivery)
    q:push("send", {})
    q:pop(0)
    assert.equal(0, q:in_flight())              -- nothing is held; it is gone
    assert.equal(0, (q:reap(os.time() + LATER)))
  end)

  it("refuses a delivery setting that is a typo", function()
    local ok, err = pcall(jobs_memory.new, "delivery:typo",
                          { delivery = "atmost_once" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "delivery must be")
  end)
end)

-- ============================================ the properties, over every store

local function delivers_at_least_once(label, run)
  describe("at-least-once delivery over " .. label, function()
    it("holds a job in flight instead of handing it over", function()
      run({}, function(q)
        q:push("charge", { order = 41 })
        local job = q:pop(0)

        assert.equal("charge", job.kind)
        assert.equal(0, tonumber(q:depth()))    -- not runnable by anyone else
        assert.equal(1, q:in_flight())          -- but not gone, either
      end)
    end)

    it("retires it on ack, and then there is nothing to bring back", function()
      run({}, function(q)
        q:push("charge", { order = 41 })
        assert.is_true(q:ack(q:pop(0)))
        assert.equal(0, q:in_flight())
        assert.equal(0, (q:reap(os.time() + LATER)))
        assert.equal(0, tonumber(q:depth()))
      end)
    end)

    it("brings back a job whose worker stopped answering", function()
      -- The crash, simulated the bluntest way there is: the job is leased and
      -- then simply dropped on the floor, which is what a SIGKILL between the
      -- pop and the ack leaves behind.
      run({}, function(q)
        q:push("charge", { order = 41 })
        local job = q:pop(0)
        assert.equal(41, job.payload.order)
        job = nil                                          -- the worker died

        assert.equal(0, (q:reap(os.time())))               -- not before its time
        assert.equal(1, q:in_flight())

        local redelivered, buried = q:reap(os.time() + LATER)
        assert.equal(1, redelivered)
        assert.equal(0, buried)
        assert.equal(1, tonumber(q:depth()))
        assert.equal(0, q:in_flight())

        local again = q:pop(0)
        assert.equal("charge", again.kind)
        assert.equal(41, again.payload.order)
        assert.equal(1, again.redeliveries)
      end)
    end)

    it("keeps the uid across the redelivery, so a handler can dedup on it",
    function()
      -- The uid is the whole answer this module has for "your handler will
      -- run twice"; it is worth nothing if a redelivery changes it.
      run({}, function(q)
        q:push("charge", { order = 41 })
        local first = q:pop(0)
        first = { uid = first.uid }                        -- the worker died
        q:reap(os.time() + LATER)
        assert.equal(first.uid, q:pop(0).uid)
      end)
    end)

    it("tells a worker its lease was taken away", function()
      -- The one symptom of a visibility timeout set below the handler's real
      -- runtime, and otherwise completely invisible.
      run({}, function(q)
        q:push("charge", {})
        local job = q:pop(0)
        q:reap(os.time() + LATER)                          -- somebody else has it now
        assert.is_false(q:ack(job))
      end)
    end)

    it("buries a job that outlives too many workers", function()
      -- A job that kills every worker that touches it would otherwise be
      -- redelivered forever, taking the fleet down one process at a time.
      run({ max_redeliveries = 2 }, function(q)
        q:push("poison", { order = 41 })
        for _ = 1, 3 do
          q:pop(0)                                         -- taken, and lost
          q:reap(os.time() + LATER)
        end

        assert.equal(0, tonumber(q:depth()))
        assert.equal(0, q:in_flight())
        assert.equal(1, tonumber(q:dead_depth()))

        local dead = q:dead_letters()[1]
        assert.equal("poison", dead.kind)
        assert.equal(3, dead.redeliveries)
        assert.is_truthy(dead.last_error:find("stopped answering", 1, true))
        -- Counted apart from the retry budget: nothing here was the handler
        -- saying no, and `attempts` is what the handler says.
        assert.equal(0, dead.attempts)
      end)
    end)

    it("releases the lease when a job is retried, so it is not also reaped",
    function()
      -- Both at once is the bug this ordering exists to prevent: a retry
      -- scheduled AND an in-flight record left behind is two copies of one
      -- job, delivered a backoff apart.
      run({ retries = 1, backoff = { base = 0, jitter = false } }, function(q)
        q:push("send", {})
        q:fail(q:pop(0), "smtp down")

        assert.equal(1, tonumber(q.store:scheduled_depth(q.key)))
        assert.equal(0, q:in_flight())
        assert.equal(0, (q:reap(os.time() + LATER)))
      end)
    end)

    it("releases the lease when a job is buried", function()
      run({}, function(q)
        q:push("send", {})
        q:fail(q:pop(0), "smtp down")

        assert.equal(1, tonumber(q:dead_depth()))
        assert.equal(0, q:in_flight())
        assert.equal(0, (q:reap(os.time() + LATER)))
      end)
    end)

    it("acks a job it consumed, without being asked to", function()
      run({}, function(q)
        q:push("send", { to = "ada" })
        local seen
        local left = 2
        local stats = q:consume({ send = function(payload) seen = payload.to end }, {
          timeout = 0,
          should_stop = function() left = left - 1 return left < 0 end,
        })

        assert.equal("ada", seen)
        assert.equal(1, stats.handled)
        assert.equal(0, stats.duplicated)
        assert.equal(0, q:in_flight())
        assert.equal(0, (q:reap(os.time() + LATER)))
      end)
    end)

    it("reaps from pop, so a worker recovers a queue just by consuming it",
    function()
      -- There is no janitor process to forget to deploy: any worker popping
      -- from this queue is also the reaper for it.
      run({ visibility = 0, reap_every = 0 }, function(q)
        q:push("charge", { order = 41 })
        assert.equal("charge", q:pop(0).kind)               -- taken, and lost

        local again = q:pop(0)
        assert.is_table(again, "the lost job never came back on its own")
        assert.equal(1, again.redeliveries)
      end)
    end)

    it("keeps an undecodable job instead of eating it", function()
      -- Under leasing, dropping it is not even an option: an unacked lease
      -- comes back, and the reaper cannot tell a poison pill from a crashed
      -- worker, so it would circulate forever.
      run({}, function(q)
        q.store:enqueue(q.key, "{not json")
        local job, err = q:pop(0)
        assert.is_nil(job)
        assert.is_truthy(tostring(err):match "undecodable")
        assert.equal(0, q:in_flight())
        assert.equal(1, tonumber(q:dead_depth()))
      end)
    end)
  end)
end

delivers_at_least_once("memory", over_memory)

if redis_reachable() then
  delivers_at_least_once("redis", over_redis)
else
  describe("at-least-once delivery over redis", function()
    pending "Redis is not reachable on 127.0.0.1:6379; skipping"
  end)
end

if pg_support.reachable "pgmoon" then
  delivers_at_least_once("postgres", over_postgres)
else
  describe("at-least-once delivery over postgres", function()
    pending "Postgres is not reachable on 127.0.0.1:55432; skipping"
  end)
end

-- ==================================================== the two stores agree

--- Drives one queue through the whole delivery lifecycle and writes down
--- everything observable about it.  Compared between backends rather than
--- asserted per backend: matching assertions in two files drift apart, a
--- recorded trace cannot.
local function trace(q)
  local out = {}
  local function note(...) out[#out + 1] = { ... } end

  note("delivery", q.delivery)
  q:push("charge", { order = 41 })
  q:push("charge", { order = 42 })
  note("queued", tonumber(q:depth()), q:in_flight())

  local acked = q:pop(0)
  note("leased", acked.payload.order, tonumber(q:depth()), q:in_flight())
  note("acked", q:ack(acked), tonumber(q:depth()), q:in_flight())

  local lost = q:pop(0)
  note("leased", lost.payload.order, tonumber(q:depth()), q:in_flight())
  note("too early", q:reap(os.time()), q:in_flight())

  local redelivered, buried = q:reap(os.time() + LATER)
  note("reaped", redelivered, buried, tonumber(q:depth()), q:in_flight())
  note("stale ack", q:ack(lost))

  local back = q:pop(0)
  note("back", back.kind, back.payload.order, back.redeliveries, back.uid == lost.uid)
  note("failed", q:fail(back, "smtp down"))
  note("settled", tonumber(q:depth()), q:in_flight(), tonumber(q:dead_depth()))
  return out
end

-- Memory is the reference the others are read against, because it is the one
-- that never skips. Each server-backed store is compared to it by name, so a
-- divergence says WHICH store diverged rather than that two traces differ.
local others = {}
if redis_reachable() then
  others[#others + 1] = { name = "the Redis store", run = over_redis }
else
  describe("the memory store and the Redis store", function()
    pending "Redis is not reachable on 127.0.0.1:6379; skipping"
  end)
end
if pg_support.reachable "pgmoon" then
  others[#others + 1] = { name = "the Postgres store", run = over_postgres }
else
  describe("the memory store and the Postgres store", function()
    pending "Postgres is not reachable on 127.0.0.1:55432; skipping"
  end)
end

for _, other in ipairs(others) do
  describe("the memory store and " .. other.name, function()
    it("answer the same lifecycle identically", function()
      local from_memory, from_other
      over_memory({}, function(q) from_memory = trace(q) end)
      other.run({}, function(q) from_other = trace(q) end)

      assert.same(from_memory, from_other)
      -- And the trace is worth comparing only if it actually observed the
      -- crash: a pair of empty traces would match too.
      assert.is_truthy(#from_memory > 8)
    end)
  end)
end

-- ===================================================== crashes, for real

describe("a worker whose coroutine is abandoned", function()
  it("loses its job to the next worker rather than for good", function()
    -- The crash boundary that matters for an in-process queue, and the one
    -- `akkar.jobs.memory` names: not a dead process but a dead coroutine --
    -- a cqueues deadline landing mid-handler, a handler that raised past its
    -- worker. The job is in hand when the coroutine stops, and nothing ever
    -- resumes it.
    local q = jobs_memory.new("delivery:abandoned:" .. math.random(1, 1e9),
                              options())
    q:push("charge", { order = 41 })

    local worker = coroutine.create(function()
      local job = q:pop(0)
      coroutine.yield(job.payload.order)
      q:ack(job)                                  -- never reached
    end)

    local ok, order = coroutine.resume(worker)
    assert.is_true(ok)
    assert.equal(41, order)

    worker = nil                                  -- abandoned, mid-job
    collectgarbage() collectgarbage()

    assert.equal(0, q:depth())
    assert.equal(1, q:in_flight(), "the job was not being held at all")

    assert.equal(1, (q:reap(os.time() + LATER)))
    local again = q:pop(0)
    assert.equal("charge", again.kind)
    assert.equal(41, again.payload.order)
  end)
end)

-- ------------------------------------------------------------ SIGKILL, on Redis

--- The interpreter to run a child worker under.  Probed rather than assumed:
--- `lua` on PATH is not necessarily the one busted is running on, and a child
--- that cannot `require "cqueues"` would fail this test for a reason that has
--- nothing to do with job delivery.
local function child_interpreter()
  for _, candidate in ipairs { "lua", "lua5.4", "lua5.3", "luajit" } do
    local probe = io.popen(candidate ..
      " -e 'require(\"cqueues\") require(\"akkar.jobs.redis\")' 2>&1")
    if probe then
      local output = probe:read "a"
      probe:close()
      if output == "" then return candidate end
    end
  end
end

local interpreter = redis_reachable() and child_interpreter()

if not interpreter then
  describe("a worker killed with SIGKILL", function()
    pending "no Redis, or no interpreter that can run a child worker; skipping"
  end)
  return
end

describe("a worker killed with SIGKILL", function()
  it("loses its job to the next worker rather than for good", function()
    -- The one that cannot be faked. A separate OS process leases a job from
    -- the real Redis, says so, and then holds it while the parent sends it
    -- signal 9 -- no unwinding, no ack, no chance to put anything back. What
    -- the old store did here was lose the job silently and forever.
    local name = "spec:delivery:kill:" .. math.random(1, 1e9)
    local base = os.tmpname()
    local script, out, pidfile = base .. ".lua", base .. ".out", base .. ".pid"

    local child = assert(io.open(script, "w"))
    child:write(([[
      package.path = "./?.lua;./?/init.lua;" .. package.path
      local cqueues    = require "cqueues"
      local redis      = require "akkar.redis"
      local jobs_redis = require "akkar.jobs.redis"
      local cq = cqueues.new()
      cq:wrap(function()
        local conn = redis.connect { pool_size = 0 }()
        local q = jobs_redis.new(conn, %q, { visibility = %d, reap_every = 3600 })
        local job = q:pop(5)
        if not job then io.stderr:write "no job\n" os.exit(3) end
        io.stdout:write("leased " .. job.kind .. "\n")
        io.stdout:flush()
        cqueues.sleep(120)          -- holding the lease, waiting to be killed
      end)
      cq:loop()
    ]]):format(name, VISIBILITY))
    child:close()

    local killed = false
    local ok, failure = pcall(over_redis, {}, function(q)
      -- The child talks to the same queue by name, not to this store object.
      q.key = "akkar:queue:" .. name
      q:push("charge", { order = 41 })

      assert(os.execute(("sh -c '%s %s >%s 2>&1 & echo $! > %s'")
                        :format(interpreter, script, out, pidfile)))

      -- Wait for the child to actually hold the lease. Killing it before it
      -- has one would prove nothing at all.
      local deadline = os.time() + 20
      while q:in_flight() ~= 1 and os.time() < deadline do
        cqueues.sleep(0.1)
      end

      local report = assert(io.open(out)):read "a"
      assert.equal(1, q:in_flight(),
        "the child never took the job; it said: " .. report)
      assert.is_truthy(report:find("leased charge", 1, true),
        "the child did not report leasing the job; it said: " .. report)
      assert.equal(0, tonumber(q:depth()))

      local pid = assert(io.open(pidfile)):read "a"
      assert(os.execute("kill -9 " .. pid:gsub("%s+$", "")))
      killed = true

      -- The worker is gone. Nothing it held was written back, nothing was
      -- unwound: the job exists only as a record in Redis now.
      local redelivered = q:reap(os.time() + LATER)
      assert.equal(1, redelivered, "the killed worker's job did not come back")
      assert.equal(1, tonumber(q:depth()))

      local again = q:pop(0)
      assert.equal("charge", again.kind)
      assert.equal(41, again.payload.order)
      assert.equal(1, again.redeliveries)
    end)

    -- Cleaned up even when an assertion above failed, so a failing run does
    -- not leave a process holding a lease for two minutes.
    if not killed then os.execute("pkill -9 -f " .. script .. " 2>/dev/null") end
    os.remove(script) os.remove(out) os.remove(pidfile) os.remove(base)
    if not ok then error(failure, 0) end
  end)
end)
