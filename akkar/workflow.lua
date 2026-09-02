--[[
akkar.workflow — a long-running function whose finished steps do not run twice.

A workflow is an ordinary Lua function taking a `ctx`. It may run for a week,
sleep in the middle of itself, fail halfway and be retried, and be killed with
its worker -- and the parts of it that already finished do not happen again.

    local flow = workflow.new(db, "signup", function(ctx)
      local user = ctx:step("create", function(tx)
        return tx:one("insert into users (email) values ($1) returning id",
                      ctx.input.email)
      end)
      ctx:sleep("settle", 86400)
      ctx:step("welcome", function()
        return mailer:send(ctx.input.email, "how is it going?")
      end)
      return user.id
    end, { retries = 5 })

    flow:start { email = "a@b.c" }        -- returns a run id
    flow:work { should_stop = stopping }  -- a worker, in another process

## The shape is Inngest's, not Temporal's, and the difference is the point

Temporal replays a workflow deterministically: the function is re-executed from
the top against a recorded history, and every source of non-determinism -- the
clock, the random generator, every IO call -- must be intercepted so the replay
takes the same branches. That needs the function sandboxed against the whole
language, which is a large, brittle project and one akkar has no way to do
honestly: Lua's `os.time`, `math.random` and every socket in the process are
reachable from any handler.

So the side effects live behind memoized steps instead, and the function is
free to re-run from the top as often as it likes. `ctx:step(name, fn)` looks
`(run, name)` up in `akkar_workflow_steps`; a stored result comes back WITHOUT
`fn` running, and otherwise `fn` runs and its result is written in the SAME
transaction that records the step. Nothing outside a step is protected, and
nothing needs to be: re-running it is expected.

There is no dashboard, no orchestrator process, and no scheduler service. A
workflow is a job on `akkar.jobs` over `akkar.jobs.postgres`, so retries with
backoff, the dead letter, the at-least-once lease and the reaper are the ones
already there and already proved.

## WHAT EXACTLY-ONCE COVERS HERE, AND WHAT IT DOES NOT

This is the sentence people skip, so it is the loudest one on the page.

**A step whose effect is a database write through the handle it is given is
exactly-once.** `fn` receives the transaction, its writes and the memo row are
one commit, and there is no instant in which one exists without the other. A
crash before the commit undoes the write and leaves the step unclaimed; a crash
after it finds the step done and skips `fn`.

    ctx:step("charge", function(tx)                    -- exactly once
      tx:exec("insert into ledger (order_id, cents) values ($1, $2)", id, 500)
    end)

**A step that reaches anything else is at-least-once with a memoized result.**
A POST to a payment API, an email, a file written to S3, a write through a
DIFFERENT connection: the effect and the memo cannot share a transaction, so
the process can die in the window between them, and the retry runs `fn` again.

    ctx:step("charge", function()                      -- AT LEAST ONCE
      return stripe:charge(card, 500)                  -- may run twice
    end)

What the memo buys there is that the effect is attempted a bounded number of
times instead of once per attempt of the whole workflow, and that its RESULT is
stable once recorded. It does not make the effect single. For a third party the
answer is the same as it has always been: give the remote call an idempotency
key of its own, derived from `ctx.run` and the step name, and let the other
side deduplicate. `akkar.idempotency` is that mechanism pointed at an inbound
request; this is the outbound half, and akkar cannot do it for you because only
the remote API knows what its key means.

The window is real and it is small, and it is stated rather than left for
somebody to find in an invoice.

## A step's result goes through JSON

It is stored as text and decoded on replay, so a step returns ONE value and
that value is whatever JSON can carry. `7` comes back as `7.0`, a table with
both array and hash keys comes back as one or the other, and a function, a
userdata or a database cursor cannot be a step result at all -- attempting it
raises, and rolls the step back rather than recording something that will not
decode. Return an id, not a connection.

`nil` is a legitimate result: the row's EXISTENCE is what says the step is
done, never the contents of `result`, so a step returning nothing replays as a
step returning nothing and does not run twice.

## A step is claimed by an uncommitted insert, which is the whole lock

There is no lease column, no token, and no expiry, and that is not a
simplification -- it is what makes the table impossible to leave in a bad
state. The claim and the completion are the same transaction:

    begin
      insert into akkar_workflow_steps (run, step)   -- the claim
      ... fn(tx) ...                                 -- the effect
      update ... set result = ...                    -- the memo
    commit

A second worker's `insert ... on conflict do nothing` on that key WAITS for the
first transaction to resolve, and then either finds the row (and replays the
result) or inserts its own (because the first rolled back). A row that exists
and is visible is therefore always a finished step: a worker killed mid-step
leaves nothing behind, because its insert died with it.

This is `akkar.idempotency`'s claim/replay/refuse in the one place where it
does not need a token. That module claims across REQUESTS, which cannot share a
transaction, so it needs a lock ttl and a compare-and-set to survive a claim
expiring under a handler that is still running. Here the claim IS the
transaction, so it cannot expire under anybody.

The wait is bounded by `step_lock_timeout` (five seconds by default), set with
`SET LOCAL` on the step's own transaction. Past it the step raises a contention
error rather than holding a pooled connection open for the length of somebody
else's step -- ten duplicate workflows blocking on ten long steps is a frozen
pool, and a frozen pool is worse than a retried run. The queue's retry policy
then brings the workflow back, and by then the step is done and replays.

## `ctx:sleep` is a scheduled continuation, not a wait

    ctx:sleep("settle", 86400)

records a due time and pushes the workflow back onto its own queue with that
delay, in one transaction, and then unwinds the function. The worker acks the
job and moves on; nothing holds a coroutine, a connection or a process for the
day. When the continuation runs, the function starts again from the top, every
finished step replays out of storage, and the sleep -- now past its due time --
returns instead of suspending.

THE DUE TIME IS WHY THE SLEEP ROW IS NOT MERELY "DONE". A workflow that
suspended and was then redelivered (its worker died between the commit and the
ack, which is exactly what at-least-once means) re-runs from the top and
reaches the sleep again. If the row only said "this sleep happened" the
redelivery would sail through it and run the rest of the workflow a day early,
beside a continuation that is still queued. Reading `due_at <= clock_timestamp()`
makes the redelivery suspend again, and the clock it compares against is the
SERVER's -- the same argument `akkar/jobs/postgres.lua` makes at length about
`clock_timestamp()`, and for the same reason: a fleet has several clocks and
one of them has just been stepped by NTP.

Unwinding is an `error` with a private sentinel, so a `pcall` wrapped around a
`ctx:sleep` swallows the suspension and the function carries on as though the
day had passed. Do not do that; there is no way for this module to tell that
`pcall` from any other.

## What is NOT here

**A run table, a status column, a list of running workflows.** The queue holds a
run's liveness and the step table holds its history, and a third record of the
same fact is a third thing that can disagree. The cost is stated: a run that
has not yet finished a step is visible only as a job in `akkar_jobs`, and
`flow:steps(run)` answers about a run whose id you already have. `flow:finished`
and `flow:result` read the terminal row.

**Parallel steps, fan-out, `Promise.all`.** Steps run in the order the function
calls them. A workflow that wants two things at once can push two jobs.

**Cancellation, signals, waiting for an event.** A run stops when its function
returns or when the queue buries it.

**Anything but Postgres.** The memo and the step's writes have to be one
transaction, which is a property of a database and not of a queue, so the store
is `akkar.jobs.postgres` and the handle is a connection.

## The schema ships as data

`M.MIGRATIONS` is the list `akkar.migrate` takes under `files`, and
`M.migrate(db)` applies it under the same ledger and lock as the application's
own migrations -- the shape `akkar/jobs/postgres.lua` uses, for the reason it
gives there.
]]

local postgres = require "akkar.jobs.postgres"
local cjson    = require "akkar.json"
local crypto   = require "akkar.crypto"

local M = {}

-- ===================================================================== schema

M.SCHEMA = [[
create table if not exists akkar_workflow_steps (
  run        text        not null,
  step       text        not null,
  kind       text        not null check (kind in ('step', 'sleep')),
  -- JSON, and null only for a sleep. A step that returned nothing stores the
  -- JSON literal `null`, because the ROW is what says the step is done and a
  -- column is not allowed to carry that meaning as well.
  result     text,
  -- Sleeps only: when the continuation becomes due, on the server's clock.
  due_at     timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  primary key (run, step)
);

-- Pruning walks runs by age, and the primary key cannot answer that.
create index if not exists akkar_workflow_steps_age
  on akkar_workflow_steps (created_at);
]]

M.MIGRATIONS = {
  { name = "20260902130000_akkar_workflow_steps.sql", sql = M.SCHEMA },
}

--- Applies the schema through `akkar.migrate`, so it lands in the same ledger
--- and under the same lock as the application's own migrations.
---
--- The job tables come too: a workflow is a job, and a database with the step
--- table and no queue to run it on is a half-installed feature.
function M.migrate(db, options)
  local migrate = require "akkar.migrate"
  local files = {}
  for _, file in ipairs(postgres.MIGRATIONS) do files[#files + 1] = file end
  for _, file in ipairs(M.MIGRATIONS)        do files[#files + 1] = file end
  return migrate.new(db, { files = files,
                           table = options and options.table }):apply()
end

-- ==================================================================== queries

-- The claim. `on conflict do nothing` rather than `do update`: a row that
-- exists is a finished step, and there is nothing to update it to. A row that
-- exists but is not yet COMMITTED belongs to another worker's live
-- transaction, and this statement waits for it -- see the module header.
local CLAIM = [[
insert into akkar_workflow_steps (run, step, kind, due_at)
values ($1, $2, $3,
        case when $3 = 'sleep'
             then clock_timestamp() + make_interval(secs => $4)
             else null end)
on conflict (run, step) do nothing
returning step
]]

-- `due` is null for a step row and a boolean for a sleep, so one read answers
-- both "is this memoized" and "is the wait over".
local READ = [[
select kind, result, due_at <= clock_timestamp() as due
  from akkar_workflow_steps
 where run = $1 and step = $2
]]

local RECORD = "update akkar_workflow_steps set result = $3 where run = $1 and step = $2"

local STEPS = [[
select step, kind, result from akkar_workflow_steps
 where run = $1 order by created_at, step
]]

local FORGET = "delete from akkar_workflow_steps where run = $1 returning step"

-- Whole runs, by the age of their NEWEST row. Deleting by `created_at` alone
-- would cut a live run in half -- dropping the steps it finished last week
-- while it sleeps until next week -- and a workflow whose memo is gone runs
-- those steps again. Only a run that has been quiet for the whole window goes.
local PRUNE = [[
with stale as (
  select run from akkar_workflow_steps
   group by run
  having max(created_at) <= clock_timestamp() - make_interval(secs => $1)
), gone as (
  delete from akkar_workflow_steps s using stale
   where s.run = stale.run
  returning s.run
)
select count(distinct run)::int as n from gone
]]

-- ==================================================================== helpers

-- The terminal row. Reserved, like every name beginning with `__`, so a step
-- called "done" by an application cannot collide with the run's own record.
local DONE = "__done"

-- How long a step waits for another worker's transaction before giving up.
-- Five seconds: long enough that the ordinary case -- a duplicate delivery
-- arriving beside a short step -- resolves by waiting and replaying, short
-- enough that a pooled connection is never held for the length of somebody
-- else's minute-long step.
local DEFAULT_LOCK_TIMEOUT = 5

-- Raised by `ctx:sleep` to unwind the function. A private table, so it cannot
-- be confused with any error an application raises, and never exported: a
-- caller who could catch it could also fabricate it.
local SUSPEND = setmetatable({}, { __tostring = function()
  return "akkar.workflow: suspended until a scheduled continuation"
end })

local function encode_result(value, name)
  if value == nil then return cjson.encode(cjson.null) end
  local ok, encoded = pcall(cjson.encode, value)
  if not ok then
    error("akkar.workflow: the result of step '" .. tostring(name) ..
          "' cannot be encoded as JSON, so it could not be replayed -- a step " ..
          "returns one JSON value, not a connection, a cursor or a function (" ..
          tostring(encoded) .. ")", 0)
  end
  return encoded
end

local function decode_result(text, name)
  if text == nil then return nil end
  local ok, value = pcall(cjson.decode, text)
  if not ok then
    error("akkar.workflow: the stored result of step '" .. tostring(name) ..
          "' is not decodable JSON; the row was written by something other " ..
          "than this module", 0)
  end
  if value == cjson.null then return nil end
  return value
end

-- Postgres reports a lock_timeout as a plain error, and the difference between
-- "somebody else is running this step" and "the step itself failed" decides
-- what a caller should do about it -- so it is named rather than passed on as
-- a database error.
local function is_contention(err)
  return tostring(err):lower():find("lock timeout", 1, true) ~= nil
end

--- Bounds how long this transaction waits on another transaction's row.
---
--- Interpolated rather than bound, because `SET` takes no parameters -- and
--- floored to an integer number of milliseconds first, so the only thing that
--- can reach the statement text is a number.
local function bound_waiting(tx, seconds)
  tx:exec(("set local lock_timeout = %d"):format(
    math.max(1, math.floor(seconds * 1000))))
end

-- ======================================================================== ctx

local Ctx = {}
Ctx.__index = Ctx

local function check_name(self, name)
  if type(name) ~= "string" or name == "" then
    error("akkar.workflow: a step needs a name; it is the key the result is " ..
          "stored under, so it cannot be nil or empty", 3)
  end
  if name:sub(1, 2) == "__" then
    error("akkar.workflow: '" .. name .. "' is reserved -- names beginning " ..
          "with '__' belong to this module", 3)
  end
  -- WITHIN ONE EXECUTION, because across executions a repeat is the whole
  -- point. Two steps sharing a name in the same function is not memoization,
  -- it is the second one silently replaying the first one's result, and that
  -- is a typo with the shape of a feature.
  if self._seen[name] then
    error("akkar.workflow: step '" .. name .. "' ran twice in one execution " ..
          "-- step names are the memo's keys and must be unique within a " ..
          "workflow", 3)
  end
  self._seen[name] = true
end

--- Runs `fn` once per run, and returns whatever it returned the first time.
---
--- `fn` is called with the transaction the memo is written in, so a database
--- write made through it is exactly-once with the step. Anything else `fn`
--- touches is at-least-once; see the module header, which says so at length.
---
--- Returns the step's result, JSON-round-tripped.
---
--- Raises whatever `fn` raises -- the step is left unclaimed, so a retry of
--- the workflow runs it again -- or a contention error when another worker
--- held the step for longer than `step_lock_timeout`.
function Ctx:step(name, fn)
  check_name(self, name)
  if type(fn) ~= "function" then
    error("akkar.workflow: step '" .. name .. "' needs a function", 2)
  end
  if self._in_step then
    error("akkar.workflow: step '" .. name .. "' was started inside step '" ..
          tostring(self._in_step) .. "'. Nested steps would share one " ..
          "transaction and one memo row, so the inner one could not be " ..
          "replayed without the outer one", 2)
  end

  -- The replay path is one read and no transaction. It is also the common
  -- path: a workflow of ten steps that is retried on its last one reads nine
  -- rows and takes no locks at all.
  local stored = self.db:one(READ, self.run, name)
  if stored then
    if stored.kind ~= "step" then
      error("akkar.workflow: '" .. name .. "' is a sleep in this run and a " ..
            "step in this code; a name means one thing per workflow", 2)
    end
    return decode_result(stored.result, name)
  end

  local ok, outcome = pcall(function()
    return self.db:transaction(function(tx)
      bound_waiting(tx, self.lock_timeout)
      if not tx:one(CLAIM, self.run, name, "step", 0) then
        -- Either it was already there, or it committed while we waited.
        local row = tx:one(READ, self.run, name)
        return { replayed = true, result = row and row.result }
      end
      self._in_step = name
      local value = fn(tx)
      self._in_step = nil
      tx:exec(RECORD, self.run, name, encode_result(value, name))
      return { replayed = false, value = value }
    end)
  end)

  self._in_step = nil
  if not ok then
    if is_contention(outcome) then
      error("akkar.workflow: step '" .. name .. "' of run '" .. self.run ..
            "' is being run by another worker and did not finish within " ..
            self.lock_timeout .. "s. This run is a duplicate delivery; it " ..
            "will replay the step once the other worker commits", 0)
    end
    error(outcome, 0)
  end

  if outcome.replayed then return decode_result(outcome.result, name) end
  -- Deliberately NOT `outcome.value`: the caller must see the same value on
  -- the first run as on every replay, and the replay's value has been through
  -- JSON. Returning the live one here would make a workflow that works on its
  -- first attempt fail on its second, over an integer that became a float.
  return decode_result(encode_result(outcome.value, name), name)
end

--- Suspends the workflow for `seconds` and resumes it on a fresh worker.
---
--- Does not return on the execution that reaches it first: it raises a private
--- sentinel that `Flow:_run` catches, so anything after the call belongs to
--- the continuation. On a later execution, once the due time has passed, it
--- returns normally and the function carries on.
---
--- Do not wrap it in `pcall`.
function Ctx:sleep(name, seconds)
  check_name(self, name)
  seconds = tonumber(seconds) or 0
  if self._in_step then
    error("akkar.workflow: step '" .. tostring(self._in_step) .. "' tried to " ..
          "sleep. A step is one transaction and a sleep ends the execution, " ..
          "so the step's memo would be rolled back and its effect repeated", 2)
  end

  local stored = self.db:one(READ, self.run, name)
  if stored then
    if stored.kind ~= "sleep" then
      error("akkar.workflow: '" .. name .. "' is a step in this run and a " ..
            "sleep in this code; a name means one thing per workflow", 2)
    end
    -- Due: the wait is over and the function carries on from here.
    if stored.due then return end
    -- Not due, and the continuation is already queued -- this execution is a
    -- redelivery of the one that scheduled it. Stop again rather than run the
    -- rest of the workflow early, beside a continuation that is still coming.
    error(SUSPEND, 0)
  end

  self.db:transaction(function(tx)
    bound_waiting(tx, self.lock_timeout)
    -- The due time and the continuation are one commit, so there is no state
    -- in which the workflow is asleep with nothing scheduled to wake it, and
    -- none in which two workers each queued a continuation.
    if not tx:one(CLAIM, self.run, name, "sleep", seconds + 0.0) then return end
    self.flow:_continue(self.run, self.input, seconds)
  end)
  error(SUSPEND, 0)
end

-- ======================================================================= flow

local Flow = {}
Flow.__index = Flow

--- Starts a run. Returns its id, or `false, "duplicate"` when `options.id`
--- names a push this queue has already accepted.
---
--- `options` is `akkar.jobs`'s: `delay`, `id`, `id_ttl`. THE DEDUP ID IS ABOUT
--- THE PUSH, not the run -- a refused duplicate returns no id at all, so an
--- application that needs to find the original run again has to have kept it.
function Flow:start(input, options)
  -- Minted here rather than taken from `job.uid`, and the reason is
  -- continuations. `uid` is stable across every retry and redelivery of ONE
  -- job, which is what `akkar/jobs.lua` promises and all a plain job needs;
  -- but `ctx:sleep` pushes a NEW job to resume with, and a new push mints a
  -- new uid. A memo keyed on `uid` would therefore be lost at the first sleep
  -- -- every step before it would run a second time. So the run carries its
  -- own identity in the envelope, and it plays exactly the role `uid` plays
  -- for a job: the one name that is stable across every re-execution.
  --
  -- Through `akkar.crypto` for the reason `akkar/jobs.lua` gives about `uid`:
  -- `akkar.random` is seedable on purpose, and two workers replaying a seed
  -- would mint one id for two runs.
  local run = self.name .. ":" .. crypto.token(12)
  local depth, err = self.queue:push(self.kind, { run = run, input = input },
                                     options)
  if depth == false then return false, err end
  return run, depth
end

-- The continuation, pushed inside the sleep's transaction. Same envelope, same
-- run id, delayed by the sleep -- so the store computes the due time from its
-- own clock, as it does for every other delayed job.
function Flow:_continue(run, input, seconds)
  return self.queue:push(self.kind, { run = run, input = input },
                         { delay = seconds })
end

function Flow:_run(envelope, job)
  envelope = envelope or {}
  if type(envelope.run) ~= "string" then
    error("akkar.workflow: this job carries no run id, so its steps cannot " ..
          "be memoized; it was not pushed by " .. self.name .. ":start", 0)
  end

  -- A run whose function already returned. Reached by a redelivery of the last
  -- job -- the worker died between the terminal write and the ack -- and the
  -- answer is the recorded result rather than another pass over the function.
  local finished = self.db:one(READ, envelope.run, DONE)
  if finished then return decode_result(finished.result, DONE) end

  local ctx = setmetatable({
    run = envelope.run,
    input = envelope.input,
    db = self.db,
    job = job,
    attempt = (job and job.attempts or 0) + 1,
    flow = self,
    lock_timeout = self.lock_timeout,
    _seen = {},
  }, Ctx)

  local ok, result = pcall(self.fn, ctx)
  if not ok then
    -- The function asked to be resumed later. The continuation is committed,
    -- so returning here lets `akkar.jobs` ack this delivery -- the run is not
    -- finished and it is not failed, it is elsewhere.
    if result == SUSPEND then return nil end
    error(result, 0)
  end

  -- Terminal, and written the same way a step is: `on conflict do nothing`, so
  -- two executions that both reached the end record one ending.
  self.db:transaction(function(tx)
    bound_waiting(tx, self.lock_timeout)
    if tx:one(CLAIM, envelope.run, DONE, "step", 0) then
      tx:exec(RECORD, envelope.run, DONE, encode_result(result, DONE))
    end
  end)
  return result
end

--- The handler table for `queue:consume`, so a worker is
--- `flow.queue:consume(flow:handlers())` and a process running several
--- workflows can merge them.
function Flow:handlers()
  return { [self.kind] = function(payload, job) return self:_run(payload, job) end }
end

--- Consumes this workflow's queue until `options.should_stop` says otherwise.
--- Options are `queue:consume`'s.
function Flow:work(options)
  return self.queue:consume(self:handlers(), options)
end

--- What a run has memoized, oldest first: `{ step, kind, result }`, with the
--- result decoded. The terminal row is included and named `__done`.
function Flow:steps(run)
  local out = {}
  for _, row in ipairs(self.db:many(STEPS, run)) do
    out[#out + 1] = {
      step = row.step, kind = row.kind,
      result = decode_result(row.result, row.step),
    }
  end
  return out
end

--- True once the function has returned for this run.
function Flow:finished(run)
  return self.db:one(READ, run, DONE) ~= nil
end

--- What the function returned, or nil when it has not returned yet -- which is
--- indistinguishable from a workflow that returned nil, so ask `finished`
--- first if the difference matters.
function Flow:result(run)
  local row = self.db:one(READ, run, DONE)
  if not row then return nil end
  return decode_result(row.result, DONE)
end

--- Drops a run's memo. The next execution of that run therefore runs every
--- step again, which is the point when a run is being deliberately replayed
--- and a catastrophe when it is not.
function Flow:forget(run)
  return #self.db:many(FORGET, run)
end

--- Deletes the memo of every run untouched for `older_than` seconds, and
--- returns how many runs went.
---
--- A step table nobody prunes grows for the life of the application. There is
--- no ttl on a row because a sleeping workflow's memo has to outlive its
--- sleep, and this module cannot know how long that is -- so the retention is
--- the operator's number, and it must exceed the longest sleep any workflow
--- here takes.
function M.prune(db, older_than)
  local row = db:one(PRUNE, (older_than or 30 * 86400) + 0.0)
  return row and tonumber(row.n) or 0
end

-- ================================================================ constructor

--- Builds a workflow over a database CONNECTION -- something with `:one`,
--- `:many`, `:exec` and `:transaction`, not the factory `akkar.db.connect`
--- returns. The reason is `akkar.jobs.postgres`'s: the queue underneath keeps
--- a session, and a session that goes back to a pool between calls takes its
--- subscriptions with it. Here there is a second reason: the memo and the
--- step's writes are one transaction, and two handles are two transactions.
---
--- `options` is forwarded whole to `akkar.jobs`, so `retries`, `backoff`,
--- `visibility`, `dead_letter` and the rest mean what they mean there.
--- `retries` DEFAULTS TO ZERO, as it does for every other queue: a workflow
--- whose step raises is buried on the first failure unless you asked for
--- otherwise. That is `akkar.jobs`'s opinion -- "a retry policy nobody chose
--- is worse than none" -- and it is not overridden here, but a workflow is the
--- shape of job that usually wants one.
---
--- `options.step_lock_timeout` bounds how long a step waits for another
--- worker's transaction, in seconds.
function M.new(db, name, fn, options)
  if type(db) ~= "table" then
    error("akkar.workflow: expected a database handle, got " .. type(db), 2)
  end
  for _, method in ipairs { "one", "many", "exec", "transaction" } do
    if type(db[method]) ~= "function" then
      error("akkar.workflow: this is not a database handle; missing :" ..
            method .. ". A connection factory is not a connection -- call it " ..
            "first, and hand the workflow the connection it returns", 2)
    end
  end
  if type(name) ~= "string" or name == "" then
    error("akkar.workflow: a workflow needs a name; it names the queue and " ..
          "prefixes every run id", 2)
  end
  if type(fn) ~= "function" then
    error("akkar.workflow: expected a function taking a ctx, got " .. type(fn), 2)
  end

  options = options or {}
  return setmetatable({
    db = db,
    name = name,
    fn = fn,
    -- One queue per workflow, named after it, so a worker consuming one
    -- workflow is not woken by another's jobs.
    queue = postgres.new(db, "workflow:" .. name, options),
    kind = "workflow:" .. name,
    lock_timeout = options.step_lock_timeout or DEFAULT_LOCK_TIMEOUT,
  }, Flow)
end

M.Flow = Flow
M.Ctx = Ctx
return M
