--[[
The Postgres job store, against a real Postgres.

The queue semantics run against this store in `spec/jobs_spec.lua`,
`spec/jobs_delivery_spec.lua` and `spec/jobs_expired_order_spec.lua`, in the
same passes the memory and Redis stores take. What can only be tested here is
whether Postgres behaves the way the store assumes: whether `FOR UPDATE SKIP
LOCKED` really gives two workers two different jobs, whether `ON CONFLICT`
really refuses the second claim, whether a `LISTEN` really wakes a worker
before its timeout, and whether the C driver -- which cannot listen -- is
honestly polled instead. A fake proves none of that.

Skipped, not failed, when Postgres is unreachable:

  docker run -d --name akkar-pg -e POSTGRES_PASSWORD=akkar \
    -e POSTGRES_DB=akkar -p 55432:5432 postgres:16-alpine

THE SAME CONTRACT, RUN AGAINST EVERY DRIVER, in the shape `spec/db_spec.lua`
uses: pgmoon always, the C driver when it is built and can reach the server,
and a named `pending` -- not silence -- for each reason it might not run.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

local support  = require "spec.support.jobs_postgres"
local db       = require "akkar.db"
local jobs     = require "akkar.jobs"
local postgres = require "akkar.jobs.postgres"
local memory   = require "akkar.jobs.memory"
local cjson    = require "akkar.json"
local cqueues  = require "cqueues"

if not support.reachable "pgmoon" then
  describe("akkar.jobs.postgres (integration)", function()
    pending "Postgres is not reachable on 127.0.0.1:55432; skipping"
  end)
  return
end

local DRIVERS = { "pgmoon" }
local pq_built = pcall(require, "akkar.pq_native")
if pq_built and support.reachable "pq" then
  DRIVERS[#DRIVERS + 1] = "pq"
elseif not pq_built then
  describe("akkar.jobs.postgres over driver pq", function()
    pending("akkar/pq_native.so is not built, so the store ran against pgmoon " ..
            "only; build it with `bash src/build.sh`")
  end)
else
  describe("akkar.jobs.postgres over driver pq", function()
    pending("akkar/pq_native.so is built but `driver = \"pq\"` could not reach " ..
            "Postgres on 127.0.0.1:55432; the store ran against pgmoon only")
  end)
end

local function fresh_name(prefix)
  return prefix .. ":" .. math.random(1, 1e9)
end

-- ================================================================ the schema

describe("akkar.jobs.postgres schema", function()
  local conn
  before_each(function() conn = support.open "pgmoon" end)
  after_each(function()
    pcall(function() conn:exec "drop table if exists akkar_jobs_spec_ledger" end)
    conn:close()
  end)

  it("ships as migrations akkar.migrate applies once", function()
    -- The tables already exist from `support.open`, so what this proves is
    -- the ledger: one file, recorded, and nothing to do the second time.
    local applied = postgres.migrate(conn, { table = "akkar_jobs_spec_ledger" })
    assert.same({ "20260902120000_akkar_jobs.sql" }, applied)
    assert.same({}, postgres.migrate(conn, { table = "akkar_jobs_spec_ledger" }))
  end)

  it("gives the claim an index it can walk in due order", function()
    -- `SKIP LOCKED` walks rows in the order the plan produces them, so the
    -- plan has to produce them in due order from an index rather than sort
    -- every waiting row on every pop. A partial index on the ready rows is
    -- what makes that true, and the plan is where it shows.
    local key = "akkar:queue:" .. fresh_name "spec:plan"
    local q = postgres.new(conn, key:sub(#"akkar:queue:" + 1))
    for _ = 1, 50 do q:push("n", {}) end
    conn:exec "analyze akkar_jobs"
    local rows = conn:many(
      "explain (costs off) select id, body from akkar_jobs where queue = $1 " ..
      "and state = 'ready' order by run_at, id limit 1 for update skip locked", key)
    local plan = {}
    for _, r in ipairs(rows) do plan[#plan + 1] = r["QUERY PLAN"] end
    plan = table.concat(plan, "\n")
    assert.is_truthy(plan:find("akkar_jobs_ready", 1, true),
      "the claim does not use the ready index:\n" .. plan)
    assert.is_nil(plan:find("Sort", 1, true),
      "the claim sorts instead of walking the index:\n" .. plan)
    support.clean(conn, key)
  end)

  it("refuses a factory where it needs a connection", function()
    local ok, err = pcall(postgres.store, db.connect(support.config "pgmoon"))
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "expected a database handle")
  end)
end)

-- ==================================================== per driver, the store

for _, DRIVER in ipairs(DRIVERS) do
describe("akkar.jobs.postgres over driver " .. DRIVER, function()
  local conn, key

  before_each(function()
    conn = support.open(DRIVER)
    key = nil
  end)

  after_each(function()
    if key then pcall(support.clean, conn, key) end
    conn:close()
  end)

  local function queue(options)
    local name = fresh_name "spec:pg"
    local q = postgres.new(conn, name, options)
    key = q.key
    return q
  end

  it("names how it wakes up, and it is what the driver allows", function()
    -- pgmoon parses the asynchronous notification message; the C driver binds
    -- no `PQnotifies`, so over it the store polls and says so. Neither is
    -- inferred by a caller from the driver's name.
    local q = queue()
    assert.equal(DRIVER == "pgmoon" and "listen" or "poll", q.store.wakeup)
  end)

  it("accepts at-least-once delivery, because it can lease", function()
    local q = queue { delivery = "at_least_once" }
    assert.equal("at_least_once", q.delivery)
    assert.is_true(q:reliable())
  end)

  -- ------------------------------------------------------------ the lease

  it("hands one job to one of two workers claiming at once", function()
    -- THE PROPERTY THE WHOLE STORE RESTS ON, staged for real: two consumers
    -- on two connections, each taking everything it can, at the same time.
    -- `FOR UPDATE SKIP LOCKED` is what makes their takes disjoint; with the
    -- clause removed the second worker's select returns the row the first
    -- has already locked, its update waits for the first commit, then marks
    -- the same row held a second time -- and both return the same job. The
    -- commit that added this test recorded that run, and it is red.
    local q = queue()
    local N = 20
    for i = 1, N do q:push("n", { i = i }) end

    local cq = cqueues.new()
    local delivered = {}
    local failure
    for worker = 1, 2 do
      cq:wrap(function()
        local ok, err = pcall(function()
          local mine = support.open(DRIVER)
          local store = postgres.store(mine)
          while true do
            local encoded = store:claim_pop(q.key, 0)
            if not encoded then break end
            delivered[#delivered + 1] = { worker = worker, uid = cjson.decode(encoded).uid }
          end
          mine:close()
        end)
        if not ok then failure = err end
      end)
    end
    assert(cq:loop(30))
    if failure then error(failure, 0) end

    local seen, twice = {}, {}
    for _, d in ipairs(delivered) do
      if seen[d.uid] then twice[#twice + 1] = d.uid end
      seen[d.uid] = true
    end
    assert.equal(0, #twice, #twice .. " job(s) were delivered to both workers")
    assert.equal(N, #delivered, "every job is delivered exactly once")
    assert.equal(N, q:in_flight())

    -- And both workers actually took part, or the race was never run.
    local by_worker = {}
    for _, d in ipairs(delivered) do by_worker[d.worker] = (by_worker[d.worker] or 0) + 1 end
    assert.is_truthy(by_worker[1] and by_worker[2],
      "one worker took everything, so nothing raced: " ..
      tostring(by_worker[1]) .. " / " .. tostring(by_worker[2]))
  end)

  it("gives the at-most-once pop the same atomicity", function()
    local q = queue { delivery = "at_most_once" }
    local N = 20
    for i = 1, N do q:push("n", { i = i }) end

    local cq = cqueues.new()
    local delivered = {}
    for _ = 1, 2 do
      cq:wrap(function()
        local mine = support.open(DRIVER)
        local store = postgres.store(mine)
        while true do
          local encoded = store:dequeue(q.key, 0)
          if not encoded then break end
          delivered[#delivered + 1] = cjson.decode(encoded).uid
        end
        mine:close()
      end)
    end
    assert(cq:loop(30))

    table.sort(delivered)
    for i = 2, #delivered do
      assert.are_not.equal(delivered[i - 1], delivered[i], "a job was dequeued twice")
    end
    assert.equal(N, #delivered)
    assert.equal(0, q:depth())
  end)

  -- ------------------------------------------------- the server's clock

  it("holds a delayed job until the server says it is due", function()
    -- THE SERVER OWNS THE CLOCK, so there is no clock here to drive: what
    -- moves is Postgres's own `clock_timestamp()`, and the wait is kept to a
    -- third of a second. The delay is a duration handed to the store, never
    -- an instant computed by this process.
    local q = queue()
    q:push("later", {}, { delay = 0.3 })
    assert.equal(0, q:depth())
    assert.equal(1, q.store:scheduled_depth(q.key))
    assert.is_nil(q:pop(0), "a job due in 300ms was delivered immediately")

    cqueues.sleep(0.35)
    local job = q:pop(0)
    assert.is_table(job, "a job past its due time was not delivered")
    assert.equal("later", job.kind)
    assert.equal(0, q.store:scheduled_depth(q.key))
  end)

  it("promotes what is due in due order, and leaves the rest", function()
    local q = queue()
    q.store:schedule(q.key, cjson.encode { kind = "second", payload = {} }, -20)
    q.store:schedule(q.key, cjson.encode { kind = "first",  payload = {} }, -30)
    q.store:schedule(q.key, cjson.encode { kind = "future", payload = {} }, 60)
    assert.equal(2, q.store:promote(q.key))
    assert.equal("first", q:pop(0).kind)
    assert.equal("second", q:pop(0).kind)
    assert.equal(1, q.store:scheduled_depth(q.key), "the future job was promoted too")
  end)

  it("expires a lease by the server's clock, not by a value it was handed", function()
    -- `visibility` in fractions of a second, so the real clock can be waited
    -- out instead of faked. Reaping before the window must find nothing and
    -- reaping after it must find the job, with nobody passing a `now`.
    local q = queue { visibility = 0.3, reap_every = 3600 }
    q:push("charge", { order = 41 })
    assert.is_table(q:pop(0))
    assert.equal(0, (q:reap()), "a lease taken a moment ago was reclaimed")

    cqueues.sleep(0.35)
    local redelivered = q:reap()
    assert.equal(1, redelivered, "an expired lease was not reclaimed")
    assert.equal(1, q:pop(0).redeliveries)
  end)

  it("ignores the caller's clock entirely", function()
    -- The fleet defect from `spec/clock_spec.lua`, over this store: step
    -- THIS worker's clock an hour forward and a live lease must stay live,
    -- because the stamp and the cutoff both come from Postgres.
    local time = require "akkar.time"
    local at = 1755000000
    local restore = time.set {
      now = function() return at end, monotime = function() return at end,
      sleep = function() end,
    }
    finally(function() restore() end)

    local q = queue()
    q:push("charge", {})
    assert.is_table(q:pop(0))
    at = at + 3600
    assert.equal(0, (q:reap()), "the store read the caller's clock")
    assert.equal(1, q:in_flight())
  end)

  -- ------------------------------------------------------- deduplication

  it("refuses a duplicate id through ON CONFLICT, until its ttl is over", function()
    local q = queue()
    local id = "order:" .. math.random(1, 1e9)
    assert.equal(1, q:push("charge", {}, { id = id, id_ttl = 0.3 }))
    local ok, why = q:push("charge", {}, { id = id, id_ttl = 0.3 })
    assert.is_false(ok)
    assert.equal("duplicate", why)
    assert.equal(1, q:depth())

    cqueues.sleep(0.35)
    assert.equal(2, q:push("charge", {}, { id = id, id_ttl = 0.3 }),
      "an id whose claim expired was still refused")
  end)

  it("gives a claim back through unclaim", function()
    local q = queue()
    local store = q.store
    assert.is_true(store:claim(q.key, "order:41", 60))
    assert.is_false(store:claim(q.key, "order:41", 60))
    assert.is_true(store:unclaim(q.key, "order:41"))
    assert.is_true(store:claim(q.key, "order:41", 60), "the claim was never released")
  end)

  it("takes the id and the job in one transaction", function()
    -- A push that raises after the claim must leave no claim behind. Staged
    -- by making the insert fail: a body Postgres refuses is a null byte,
    -- which pgmoon rejects before sending and libpq rejects on the wire.
    local q = queue()
    local id = "order:" .. math.random(1, 1e9)
    local ok = pcall(function()
      return q.store:claim_and_enqueue(q.key, id, 60, "{\"kind\":\"x\0\"}", 0)
    end)
    assert.is_false(ok)
    assert.equal(1, q:push("charge", {}, { id = id }),
      "the id stayed claimed for a job that never existed")
  end)

  it("pushes inside the caller's transaction, and rolls back with it", function()
    -- The property no Redis-backed queue can offer: a job that exists if and
    -- only if the write it belongs to does.
    local q = queue()
    local ok = pcall(function()
      conn:transaction(function(tx)
        q:push("receipt", { order = 41 })
        q:push("receipt", { order = 42 }, { id = "order:" .. math.random(1, 1e9) })
        assert.equal(2, q:depth())
        error("the order failed to save", 0)
      end)
    end)
    assert.is_false(ok)
    assert.equal(0, q:depth(), "a job survived the rollback of the write it belongs to")
  end)

  -- ------------------------------------------------------------- wake-up

  if DRIVER == "pgmoon" then
    it("wakes a blocked worker on a push from another connection", function()
      -- The wait is a LISTEN, so a push wakes the worker in milliseconds. To
      -- tell that apart from polling, the polling interval is set far above
      -- the bound asserted: a poller would not look again for two seconds.
      local q = queue()
      local waiter = postgres.store(conn, { poll_every = 2 })
      assert.equal("listen", waiter.wakeup)

      local cq = cqueues.new()
      local woke_after, got
      cq:wrap(function()
        local pusher = support.open "pgmoon"
        cqueues.sleep(0.2)
        postgres.new(pusher, q.key:sub(#"akkar:queue:" + 1)):push("wake", {})
        pusher:close()
      end)
      cq:wrap(function()
        local started = cqueues.monotime()
        got = waiter:claim_pop(q.key, 5)
        woke_after = cqueues.monotime() - started
      end)
      assert(cq:loop(20))

      assert.is_string(got, "the worker never received the job")
      assert.is_true(woke_after >= 0.2, "woke before the push: " .. woke_after)
      assert.is_true(woke_after < 0.6,
        ("woke %.3fs after starting -- that is polling, not LISTEN"):format(woke_after))
      assert.is_true(conn.in_flight == false or conn.in_flight == nil,
        "the connection was left marked in flight")
    end)

    it("returns nil on timeout without touching the connection", function()
      -- A poll that times out consumes nothing, so the connection is exactly
      -- where it was and the next query on it is an ordinary query.
      local q = queue()
      local started = cqueues.monotime()
      assert.is_nil(q.store:claim_pop(q.key, 0.3))
      local waited = cqueues.monotime() - started
      assert.is_true(waited >= 0.3 and waited < 0.6, "waited " .. waited)
      assert.equal(1, conn:one("select 1 as n").n)
      assert.is_nil(conn.broken)
    end)
  else
    it("polls, bounded, because this driver cannot listen", function()
      local q = queue()
      local waiter = postgres.store(conn, { poll_every = 0.1 })
      assert.equal("poll", waiter.wakeup)

      local cq = cqueues.new()
      local woke_after, got
      cq:wrap(function()
        local pusher = support.open(DRIVER)
        cqueues.sleep(0.2)
        postgres.new(pusher, q.key:sub(#"akkar:queue:" + 1)):push("wake", {})
        pusher:close()
      end)
      cq:wrap(function()
        local started = cqueues.monotime()
        got = waiter:claim_pop(q.key, 5)
        woke_after = cqueues.monotime() - started
      end)
      assert(cq:loop(20))

      assert.is_string(got, "the worker never received the job")
      -- Within one polling interval of the push, which is the latency the
      -- fallback costs and the module header states.
      assert.is_true(woke_after >= 0.2 and woke_after < 0.2 + 0.1 + 0.2,
        ("woke %.3fs after starting"):format(woke_after))
    end)
  end
end)
end

-- ============================================ the drivers answer identically

--- The same lifecycle `spec/jobs_delivery_spec.lua` traces across stores,
--- traced here across DRIVERS: the C driver and pgmoon must produce the same
--- observable queue, or the adapter boundary is not the boundary
--- `akkar/db.lua` claims.
local function trace(q)
  local out = {}
  local function note(...) out[#out + 1] = { ... } end
  note("delivery", q.delivery)
  q:push("charge", { order = 41 })
  q:push("charge", { order = 42 })
  note("queued", q:depth(), q:in_flight())
  local acked = q:pop(0)
  note("leased", acked.payload.order, q:depth(), q:in_flight())
  note("acked", q:ack(acked), q:depth(), q:in_flight())
  local lost = q:pop(0)
  note("leased", lost.payload.order, q:depth(), q:in_flight())
  note("too early", q:reap(os.time()), q:in_flight())
  local redelivered, buried = q:reap(os.time() + 301)
  note("reaped", redelivered, buried, q:depth(), q:in_flight())
  note("stale ack", q:ack(lost))
  local back = q:pop(0)
  note("back", back.kind, back.payload.order, back.redeliveries, back.uid == lost.uid)
  note("failed", q:fail(back, "smtp down"))
  note("settled", q:depth(), q:in_flight(), q:dead_depth())
  return out
end

describe("the memory store and every Postgres driver", function()
  it("answer the same lifecycle identically", function()
    local from_memory = trace(jobs.new(memory.store(), fresh_name "spec:trace"))
    for _, driver in ipairs(DRIVERS) do
      local conn = support.open(driver)
      local q = postgres.new(conn, fresh_name "spec:trace")
      local ok, from_pg = pcall(trace, q)
      pcall(support.clean, conn, q.key)
      conn:close()
      if not ok then error(from_pg, 0) end
      assert.same(from_memory, from_pg, "driver " .. driver .. " diverged")
    end
    assert.is_truthy(#from_memory > 8)
  end)
end)
