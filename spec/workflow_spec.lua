--[[
akkar.workflow, against a real Postgres.

What is being proved here cannot be proved against a fake, because every
guarantee this module offers is a property of a transaction: that a step's
memo and a step's writes commit together, that a second worker's insert waits
on the first worker's uncommitted one, and that a crash leaves nothing behind.
An in-memory double would say yes to all three by construction.

Skipped, not failed, when Postgres is unreachable:

  docker run -d --name akkar-pg -e POSTGRES_PASSWORD=akkar \
    -e POSTGRES_DB=akkar -p 55432:5432 postgres:16-alpine

TIME IS MOVED BY MOVING THE ROWS, not by waiting. The server owns the clock
here -- every due time is `clock_timestamp()` on Postgres -- so `akkar.time`'s
manual clock cannot reach it, and the only honest way to make a deadline pass
without waiting for it is to put the deadline in the past. That is what
`store:schedule` already does with a negative delay, and what
`spec/jobs_postgres_spec.lua` uses to stage an overdue job.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

local support  = require "spec.support.jobs_postgres"
local db       = require "akkar.db"
local workflow = require "akkar.workflow"
local cqueues  = require "cqueues"

if not support.reachable "pgmoon" then
  describe("akkar.workflow (integration)", function()
    pending "Postgres is not reachable on 127.0.0.1:55432; skipping"
  end)
  return
end

-- ONE CONNECTION FOR THE FILE, for the reason `spec/support/jobs_postgres.lua`
-- gives: the queue underneath keeps a session, and Postgres's default
-- `max_connections` is 100. The concurrency case opens its own second
-- connection, because two transactions need two of them.
local conn = support.open "pgmoon"
conn:exec(workflow.SCHEMA)

local function fresh(prefix)
  return prefix .. ":" .. math.random(1, 1e9)
end

--- A workflow with nothing left over: the queue's rows and the memo of every
--- run this name has ever had.
local function flow_for(name, fn, options)
  local flow = workflow.new(conn, name, fn, options)
  support.clean(conn, flow.queue.key)
  conn:exec("delete from akkar_workflow_steps where run like $1", name .. ":%")
  return flow
end

--- Runs the worker until `done` says so, or until it has taken `limit` turns.
---
--- `timeout = 0` so an empty queue does not block, and `idle` short so a retry
--- scheduled a hundredth of a second out is picked up on the next pass rather
--- than a second later. This is `Flow:work`, which is `queue:consume`, so what
--- the proofs below drive is the production loop and not a reimplementation
--- of it.
local function work_until(flow, done, limit)
  local turns = 0
  return flow:work {
    timeout = 0, idle = 0.01,
    should_stop = function()
      turns = turns + 1
      if turns > (limit or 400) then return true end
      return done()
    end,
  }
end

local function until_finished(flow, run, limit)
  return work_until(flow, function() return flow:finished(run) end, limit)
end

--- Puts every due time this run is waiting on into the past: the sleep's own
--- deadline and the queued continuation's. The server's clock is the only
--- clock in play, so this is how time passes in this file.
local function rewind(flow, run)
  conn:exec("update akkar_workflow_steps set due_at = clock_timestamp() - " ..
            "interval '1 second' where run = $1 and kind = 'sleep'", run)
  conn:exec("update akkar_jobs set run_at = clock_timestamp() - " ..
            "interval '1 second' where queue = $1 and state = 'scheduled'",
            flow.queue.key)
end

-- =================================================================== schema

describe("akkar.workflow schema", function()
  it("ships as migrations akkar.migrate applies once, jobs included", function()
    pcall(function() conn:exec "drop table if exists akkar_workflow_spec_ledger" end)
    local applied = workflow.migrate(conn, { table = "akkar_workflow_spec_ledger" })
    -- The queue's file comes with it: a database with a step table and no
    -- queue to run the workflow on is a half-installed feature.
    assert.same({ "20260902120000_akkar_jobs.sql",
                  "20260902130000_akkar_workflow_steps.sql" }, applied)
    assert.same({}, workflow.migrate(conn, { table = "akkar_workflow_spec_ledger" }))
    conn:exec "drop table if exists akkar_workflow_spec_ledger"
  end)

  it("refuses a factory where it needs a connection", function()
    local ok, err = pcall(workflow.new, db.connect(support.config "pgmoon"),
                          "x", function() end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "expected a database handle")
  end)

  it("refuses a workflow that is not a function", function()
    local ok, err = pcall(workflow.new, conn, "x", { not_a = "function" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "expected a function taking a ctx")
  end)
end)

-- ============================================ THE HEADLINE: a step runs once

describe("akkar.workflow step memoization", function()
  it("does not re-run a finished step when a later one fails", function()
    -- THE PROOF THIS MODULE EXISTS FOR.
    --
    -- Three steps. The second raises the first time it is reached and
    -- succeeds afterwards. The workflow function therefore runs twice, from
    -- the top, in full -- and step one's side effect must have happened
    -- exactly once across both runs.
    --
    -- The counter is a Lua upvalue rather than a row on purpose: a row would
    -- be inside the step's own transaction and would roll back with it, which
    -- would make the assertion pass for a reason other than memoization. An
    -- upvalue survives everything and counts what actually executed.
    local ran = { one = 0, two = 0, three = 0 }
    local explode = true

    local flow = flow_for(fresh "spec:headline", function(ctx)
      ctx:step("one", function()
        ran.one = ran.one + 1
        return { id = 41 }
      end)
      ctx:step("two", function()
        ran.two = ran.two + 1
        if explode then
          explode = false
          error("the payment gateway said no", 0)
        end
        return "charged"
      end)
      ctx:step("three", function()
        ran.three = ran.three + 1
        return "receipt sent"
      end)
    end, {
      retries = 3,
      -- A hundredth of a second, and no jitter, so the retry is due on the
      -- next pass of the loop rather than in two seconds' time. The policy is
      -- `akkar.jobs`'s, unchanged; only its numbers are small.
      backoff = { base = 0.01, jitter = false },
    })

    local run = flow:start { order = 41 }
    local report = until_finished(flow, run)

    assert.is_true(flow:finished(run))
    assert.equal(1, ran.one,
      "step one ran " .. ran.one .. " times; a finished step must not run again")
    assert.equal(2, ran.two, "step two must have run once per attempt")
    assert.equal(1, ran.three)
    assert.equal(1, report.failed)
    assert.equal(1, report.retried)

    -- And the memo is what did it: three rows plus the terminal one, with the
    -- first step's result as the first execution left it.
    local steps = {}
    for _, s in ipairs(flow:steps(run)) do steps[s.step] = s end
    assert.same({ id = 41 }, steps.one.result)
    assert.equal("charged", steps.two.result)
    assert.equal("receipt sent", steps.three.result)
    assert.is_truthy(steps.__done)
  end)

  it("gives a replayed step the same value as the first run", function()
    -- A step's result goes through JSON on replay, so the first execution has
    -- to see the JSON-shaped value too. Returning the live one would make a
    -- workflow work on its first attempt and fail on its second, over an
    -- integer that had become a float.
    local seen = {}
    local flow = flow_for(fresh "spec:shape", function(ctx)
      local n = ctx:step("count", function() return 7 end)
      seen[#seen + 1] = n
      ctx:step("fail_once", function()
        if #seen == 1 then error("not yet", 0) end
      end)
    end, { retries = 2, backoff = { base = 0.01, jitter = false } })

    local run = flow:start {}
    until_finished(flow, run)
    assert.equal(2, #seen)
    assert.equal(seen[1], seen[2])
  end)
end)

-- ================================================== a nil result, and a raise

describe("akkar.workflow step results", function()
  it("memoizes a step that returns nil without running it again", function()
    -- The ROW is what says a step is done, never the contents of `result`.
    -- A step returning nothing is indistinguishable from one that never ran
    -- if the module looks at the value instead of the row.
    local ran, saw = 0, {}
    local flow = flow_for(fresh "spec:nil", function(ctx)
      local value = ctx:step("quiet", function() ran = ran + 1 end)
      saw[#saw + 1] = { value == nil }
      ctx:step("fail_once", function()
        if #saw == 1 then error("go round again", 0) end
      end)
    end, { retries = 2, backoff = { base = 0.01, jitter = false } })

    local run = flow:start {}
    until_finished(flow, run)

    assert.equal(1, ran, "a step returning nil ran " .. ran .. " times")
    assert.same({ { true }, { true } }, saw)
    -- Stored as the JSON literal `null`, so the column is not carrying the
    -- "is it done" question as well.
    local row = conn:one("select result from akkar_workflow_steps " ..
                         "where run = $1 and step = 'quiet'", run)
    assert.equal("null", row.result)
  end)

  it("leaves a raising step unclaimed, so a retry runs it again", function()
    local flow = flow_for(fresh "spec:raise", function(ctx)
      ctx:step("boom", function() error("no", 0) end)
    end)

    local run = flow:start {}
    local ok, err = pcall(flow._run, flow, { run = run }, nil)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "no")

    -- Nothing recorded: the claim was the transaction, and the transaction
    -- rolled back with the step.
    assert.same({}, flow:steps(run))
    assert.is_false(flow:finished(run))
  end)

  it("rolls a step's writes back with its memo when it raises", function()
    -- The exactly-once boundary, stated as a test: a write made through the
    -- handle the step is given is undone when the step fails, so a retry does
    -- not find half of it.
    conn:exec "drop table if exists akkar_workflow_spec_effect"
    conn:exec "create table akkar_workflow_spec_effect (n int)"

    -- The row carries WHICH ATTEMPT wrote it, and that is what makes this
    -- test load-bearing. Counting rows alone passes for the wrong reason: a
    -- design that commits the claim, runs the step and saves the result as
    -- three separate statements also ends with one row -- the FAILED
    -- attempt's, left behind and never replaced, because the claim it also
    -- committed makes the retry skip the step.
    local blow_up = true
    local flow = flow_for(fresh "spec:atomic", function(ctx)
      ctx:step("write", function(tx)
        tx:exec("insert into akkar_workflow_spec_effect (n) values ($1)",
                ctx.attempt)
        if blow_up then
          blow_up = false
          error("after the insert, before the commit", 0)
        end
      end)
    end, { retries = 2, backoff = { base = 0.01, jitter = false } })

    local run = flow:start {}
    until_finished(flow, run)

    local rows = conn:many "select n from akkar_workflow_spec_effect order by n"
    assert.equal(1, #rows,
      "the failed attempt's insert survived beside the successful one; the " ..
      "memo and the write are not one transaction")
    assert.equal(2, tonumber(rows[1].n),
      "the surviving row is the FAILED attempt's; its write outlived the " ..
      "step that raised")
    conn:exec "drop table if exists akkar_workflow_spec_effect"
  end)

  it("refuses two steps with one name, and a reserved name", function()
    local flow = flow_for(fresh "spec:names", function(ctx)
      ctx:step("same", function() end)
      ctx:step("same", function() end)
    end)
    local ok, err = pcall(flow._run, flow, { run = flow.name .. ":x" }, nil)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "ran twice in one execution")

    local reserved = flow_for(fresh "spec:reserved", function(ctx)
      ctx:step("__done", function() end)
    end)
    local ok2, err2 = pcall(reserved._run, reserved, { run = reserved.name .. ":x" }, nil)
    assert.is_false(ok2)
    assert.is_truthy(tostring(err2):match "reserved")
  end)
end)

-- ======================================================= ctx:sleep resumes

describe("akkar.workflow ctx:sleep", function()
  it("suspends, schedules a continuation and resumes once it is due", function()
    local ran = { before = 0, after = 0 }
    local flow = flow_for(fresh "spec:sleep", function(ctx)
      ctx:step("before", function() ran.before = ran.before + 1 end)
      ctx:sleep("settle", 86400)
      ctx:step("after", function() ran.after = ran.after + 1 end)
    end)

    local run = flow:start {}

    -- One delivery: the function reaches the sleep and stops there.
    work_until(flow, function() return ran.before > 0 end, 20)
    assert.equal(1, ran.before)
    assert.equal(0, ran.after, "the workflow ran past a sleep that is not due")
    assert.is_false(flow:finished(run))

    -- The continuation is queued and held, not ready.
    assert.equal(1, flow.queue.store:scheduled_depth(flow.queue.key))
    assert.equal(0, flow.queue:depth())
    assert.equal(0, flow.queue:in_flight(),
      "the suspended delivery was not acknowledged")

    -- A REDELIVERY BEFORE THE DUE TIME MUST NOT SAIL THROUGH THE SLEEP.
    -- This is the case the due time exists for: the worker that scheduled the
    -- continuation died between the commit and the ack, so the same job comes
    -- back and the function runs from the top again. It must stop at the
    -- sleep a second time rather than run tomorrow's work today.
    flow:_run({ run = run }, nil)
    assert.equal(1, ran.before, "the replay re-ran a finished step")
    assert.equal(0, ran.after,
      "a redelivery ran past a sleep whose due time had not arrived")
    assert.equal(1, flow.queue.store:scheduled_depth(flow.queue.key),
      "the redelivery queued a second continuation")

    -- Time passes: the sleep's deadline and the continuation's due time go
    -- into the past, which is the only clock this store has.
    rewind(flow, run)

    until_finished(flow, run, 60)
    assert.equal(1, ran.before)
    assert.equal(1, ran.after, "the continuation did not resume the workflow")
    assert.is_true(flow:finished(run))
  end)

  it("refuses a sleep inside a step", function()
    local flow = flow_for(fresh "spec:nested", function(ctx)
      ctx:step("outer", function() ctx:sleep("inner", 1) end)
    end)
    local ok, err = pcall(flow._run, flow, { run = flow.name .. ":x" }, nil)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "tried to")
  end)
end)

-- ============================================== two workers, one step, once

describe("akkar.workflow under a duplicate delivery", function()
  it("does not let two workers run the same step", function()
    -- THE RACE, STAGED. At-least-once delivery means a slow handler can be
    -- redelivered while it is still running -- `akkar/jobs.lua` says so in
    -- its own header and logs it when it happens -- so two workers holding
    -- the same run is not exotic, it is the documented failure mode of a
    -- `visibility` set below a step's real runtime.
    --
    -- Two connections, because two transactions need two of them. The step
    -- sleeps inside its transaction so the overlap is certain rather than
    -- hoped for.
    local second = support.open "pgmoon"
    local ran = 0

    local function body(ctx)
      ctx:step("slow", function(tx)
        tx:exec "select pg_sleep(0.4)"
        ran = ran + 1
        return "once"
      end)
    end

    local a = flow_for(fresh "spec:race", body)
    local b = workflow.new(second, a.name, body)
    local run = a.name .. ":" .. "staged"

    local got = {}
    local cq = cqueues.new()
    cq:wrap(function() got.a = { pcall(a._run, a, { run = run }, nil) } end)
    cq:wrap(function()
      -- Far enough in that the first transaction is certainly holding its
      -- uncommitted insert, well inside the five-second lock bound.
      cqueues.sleep(0.1)
      got.b = { pcall(b._run, b, { run = run }, nil) }
    end)
    assert(cq:loop(20))

    assert.is_true(got.a[1], tostring(got.a[2]))
    assert.is_true(got.b[1], tostring(got.b[2]))
    assert.equal(1, ran,
      "the step ran " .. ran .. " times; the claim is not excluding the " ..
      "second worker")

    -- One row for the step, once, whichever worker wrote it.
    local rows = conn:one("select count(*)::int as n from akkar_workflow_steps " ..
                          "where run = $1 and step = 'slow'", run)
    assert.equal(1, rows.n)
    local steps = {}
    for _, s in ipairs(a:steps(run)) do steps[s.step] = s end
    assert.equal("once", steps.slow.result)

    conn:exec("delete from akkar_workflow_steps where run = $1", run)
    second:close()
  end)

  it("names contention rather than reporting a database error", function()
    -- Past the bound the loser stops instead of holding a pooled connection
    -- for the length of somebody else's step. The queue's retry policy brings
    -- the run back, and by then the step replays.
    local second = support.open "pgmoon"
    local function body(ctx)
      ctx:step("slow", function(tx) tx:exec "select pg_sleep(0.6)" end)
    end

    local a = flow_for(fresh "spec:contend", body)
    local b = workflow.new(second, a.name, body, { step_lock_timeout = 0.05 })
    local run = a.name .. ":staged"

    local got = {}
    local cq = cqueues.new()
    cq:wrap(function() got.a = { pcall(a._run, a, { run = run }, nil) } end)
    cq:wrap(function()
      cqueues.sleep(0.1)
      got.b = { pcall(b._run, b, { run = run }, nil) }
    end)
    assert(cq:loop(20))

    assert.is_true(got.a[1], tostring(got.a[2]))
    assert.is_false(got.b[1])
    assert.is_truthy(tostring(got.b[2]):match "is being run by another worker")

    conn:exec("delete from akkar_workflow_steps where run = $1", run)
    second:close()
  end)
end)

-- =================================================== the run's own lifecycle

describe("akkar.workflow runs", function()
  it("records a terminal result and does not re-run a finished run", function()
    local ran = 0
    local flow = flow_for(fresh "spec:done", function(ctx)
      ran = ran + 1
      ctx:step("only", function() return "ok" end)
      return { status = "shipped" }
    end)

    local run = flow:start {}
    until_finished(flow, run)
    assert.equal(1, ran)
    assert.same({ status = "shipped" }, flow:result(run))

    -- A redelivery of the last job, which is what a worker dying between the
    -- terminal write and the ack leaves behind. The function must not run.
    assert.same({ status = "shipped" }, flow:_run({ run = run }, nil))
    assert.equal(1, ran, "a finished run executed its function again")
  end)

  it("refuses a job that carries no run id", function()
    local flow = flow_for(fresh "spec:norun", function() end)
    local ok, err = pcall(flow._run, flow, { input = {} }, nil)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "carries no run id")
  end)

  it("deduplicates a start by id, the way a push is deduplicated", function()
    local flow = flow_for(fresh "spec:dedup", function() end)
    local run, depth = flow:start({}, { id = "order:1", id_ttl = 60 })
    assert.is_string(run)
    assert.equal(1, depth)
    local again, why = flow:start({}, { id = "order:1", id_ttl = 60 })
    assert.is_false(again)
    assert.equal("duplicate", why)
  end)

  it("prunes runs that have been quiet, and keeps the ones that have not", function()
    local flow = flow_for(fresh "spec:prune", function(ctx)
      ctx:step("only", function() return 1 end)
    end)
    local old = flow:start {}
    until_finished(flow, old)
    local fresh_run = flow:start {}
    until_finished(flow, fresh_run)

    conn:exec("update akkar_workflow_steps set created_at = clock_timestamp() " ..
              "- interval '40 days' where run = $1", old)
    assert.equal(1, workflow.prune(conn, 30 * 86400))
    assert.same({}, flow:steps(old))
    assert.is_true(flow:finished(fresh_run))
  end)

  it("forgets a run on request", function()
    local flow = flow_for(fresh "spec:forget", function(ctx)
      ctx:step("only", function() return 1 end)
    end)
    local run = flow:start {}
    until_finished(flow, run)
    assert.equal(2, flow:forget(run))       -- the step and the terminal row
    assert.same({}, flow:steps(run))
  end)
end)
