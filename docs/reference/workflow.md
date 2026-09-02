# akkar.workflow

A long-running function whose finished steps do not run twice. It may run for a
week, sleep in the middle of itself, fail halfway and be retried, and be killed
along with its worker -- and the parts of it that already finished do not happen
again.

**When you need it.** A piece of work has several stages, each of which touches
something you cannot take back -- a row, a charge, an email -- and the whole
thing has to survive a crash between any two of them. A single job gives you
retries; it does not give you "start again but skip what already worked".

```lua no-run
local workflow = require "akkar.workflow"
```

A workflow is a job. It runs on [`akkar.jobs`](jobs.md) over
[`akkar.jobs.postgres`](jobs.md#the-store-contract), so retries with backoff,
the dead letter, the at-least-once lease and the reaper are that module's and
are not reimplemented here. What this adds is one table, `akkar_workflow_steps`,
and two methods on a context.

The shape is Inngest's, not Temporal's. Temporal re-executes a workflow against
a recorded history and needs the function sandboxed against the clock, the
random generator and every IO call so the replay takes the same branches. akkar
cannot do that honestly -- `os.time` and every socket in the process are
reachable from any handler -- so the side effects live behind memoized steps
instead and the function is free to re-run from the top.

## What exactly-once covers, and what it does not

Read this before relying on the module for anything that costs money.

**A step whose effect is a database write through the handle it is given is
exactly-once.** `fn` receives the transaction that the memo row is written in,
so the write and the record of it are one commit. There is no instant in which
one exists without the other.

```lua no-run
ctx:step("charge", function(tx)                    -- exactly once
  tx:exec("insert into ledger (order_id, cents) values ($1, $2)", id, 500)
end)
```

**A step that reaches anything else is at-least-once with a memoized result.**
A POST to a payment API, an email, a file put in S3, a write over a *different*
connection: the effect and the memo cannot share a transaction, so the process
can die in the window between them and the retry runs `fn` again.

```lua no-run
ctx:step("charge", function()                      -- AT LEAST ONCE
  return stripe:charge(card, 500)                  -- may run twice
end)
```

What the memo buys there is that the call is attempted a bounded number of
times instead of once per attempt of the whole workflow, and that its result is
stable once recorded. It does not make the effect single. For a third party,
give the remote call an idempotency key of its own derived from `ctx.run` and
the step name, and let the other side deduplicate --
[`akkar.idempotency`](idempotency.md) is that same mechanism pointed at an
inbound request.

**Nothing outside a step is protected**, and nothing needs to be. The function
re-runs from the top on every attempt, so code between steps runs once per
attempt. Put anything that must not repeat inside a step.

## Index

Every public symbol on this page, in alphabetical order. `flow` is what
`workflow.new` returns and `ctx` is what a workflow function is called with.

| symbol | kind |
|---|---|
| [`ctx.attempt`](#ctxattempt) | field |
| [`ctx.db`](#ctxdb) | field |
| [`ctx.input`](#ctxinput) | field |
| [`ctx.job`](#ctxjob) | field |
| [`ctx.run`](#ctxrun) | field |
| [`ctx:sleep`](#ctxsleepname-seconds) | method |
| [`ctx:step`](#ctxstepname-fn) | method |
| [`flow.queue`](#flowqueue) | field |
| [`flow:finished`](#flowfinishedrun) | method |
| [`flow:forget`](#flowforgetrun) | method |
| [`flow:handlers`](#flowhandlers) | method |
| [`flow:result`](#flowresultrun) | method |
| [`flow:start`](#flowstartinput-options) | method |
| [`flow:steps`](#flowstepsrun) | method |
| [`flow:work`](#flowworkoptions) | method |
| [`workflow.Ctx`](#workflowctx) | table |
| [`workflow.Flow`](#workflowflow) | table |
| [`workflow.MIGRATIONS`](#workflowmigrations) | value |
| [`workflow.migrate`](#workflowmigratedb-options) | function |
| [`workflow.new`](#workflownewdb-name-fn-options) | function |
| [`workflow.prune`](#workflowprunedb-older_than) | function |
| [`workflow.SCHEMA`](#workflowschema) | value |

Also on this page:
[What exactly-once covers, and what it does not](#what-exactly-once-covers-and-what-it-does-not),
[The table](#the-table) and [Not here](#not-here).

## workflow.new(db, name, fn, options)

Builds a workflow.

`db` is a **connection** -- something with `:one`, `:many`, `:exec` and
`:transaction` -- and not the factory [`db.connect`](db.md#dbconnectconfig)
returns. Two reasons: the queue underneath keeps a session, and the memo and the
step's writes have to be one transaction, which two handles cannot be.

`name` names the queue (`akkar:queue:workflow:<name>`), the job kind and the
prefix of every run id.

`fn` is called with a `ctx`. Its return value is recorded as the run's result.

`options` is forwarded whole to [`jobs.new`](jobs.md#jobsnewstore-name-options),
so `retries`, `backoff`, `visibility`, `dead_letter` and the rest mean what they
mean there. **`retries` defaults to zero**, as it does for every other queue, so
a workflow whose step raises is buried on the first failure unless you asked for
otherwise. Plus one of its own:

| option | default | meaning |
|---|---|---|
| `step_lock_timeout` | `5` | seconds a step waits for another worker's transaction before raising a contention error |

**Returns** a `Flow`.

**Raises**

- `akkar.workflow: expected a database handle, got <type>`
- `akkar.workflow: this is not a database handle; missing :<method>. A connection factory is not a connection -- call it first, and hand the workflow the connection it returns`
- `akkar.workflow: a workflow needs a name; it names the queue and prefixes every run id`
- `akkar.workflow: expected a function taking a ctx, got <type>`

```lua
local db       = require "akkar.db"
local workflow = require "akkar.workflow"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}

local ok, why = pcall(workflow.new, open, "signup", function() end)
print(ok, why)                    -- a factory is not a connection

local conn = open()
local flow = workflow.new(conn, "ref_workflow_shape", function(ctx)
  ctx:step("one", function() return 1 end)
end)
print(flow.queue.key, flow.queue.delivery)
conn:close()
```

## workflow.migrate(db, options)

Applies the schema through [`akkar.migrate`](migrate.md), so it lands in the
same ledger and under the same lock as the application's own migrations. The
queue's own file comes with it: a database with a step table and no queue to run
the workflow on is a half-installed feature.

`options.table` names the ledger, as it does for
[`migrate.new`](migrate.md#migratenewdb-options).

**Returns** the file names applied, in order; empty on every boot after the
first.

```lua
local db       = require "akkar.db"
local workflow = require "akkar.workflow"

local conn = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}()

conn:exec "drop table if exists ref_workflow_ledger"
print(table.concat(workflow.migrate(conn, { table = "ref_workflow_ledger" }), ", "))
print(#workflow.migrate(conn, { table = "ref_workflow_ledger" }))   -- 0, second time

conn:exec "drop table if exists ref_workflow_ledger"
conn:close()
```

## workflow.SCHEMA

The `create table` for `akkar_workflow_steps` and its index, as a string. Apply
it directly where the application does not use `akkar.migrate`.

```lua no-run
conn:exec(workflow.SCHEMA)
```

## workflow.MIGRATIONS

The one-element list `akkar.migrate` takes under `files`:
`{ { name = "20260902130000_akkar_workflow_steps.sql", sql = workflow.SCHEMA } }`.
Concatenate it with `akkar.jobs.postgres`'s own `MIGRATIONS` to build a single
list, which is what `workflow.migrate` does.

```lua no-run
local files = {}
for _, f in ipairs(postgres.MIGRATIONS) do files[#files + 1] = f end
for _, f in ipairs(workflow.MIGRATIONS) do files[#files + 1] = f end
```

## workflow.prune(db, older_than)

Deletes the memo of every run untouched for `older_than` seconds -- thirty days
by default -- and returns how many runs went.

Whole runs, by the age of their newest row. Deleting by row age alone would cut
a live run in half, dropping the steps it finished last week while it sleeps
until next week, and a workflow whose memo is gone runs those steps again.

There is no ttl on a row, because a sleeping workflow's memo has to outlive its
sleep and this module cannot know how long that is. **The retention is yours,
and it must exceed the longest sleep any workflow here takes.** A step table
nobody prunes grows for the life of the application.

**Returns** a number.

```lua no-run
local removed = workflow.prune(conn, 90 * 86400)
```

## Flow

What `new` returns.

### flow:start(input, options)

Pushes a run. `input` is handed to the function as `ctx.input`; it goes through
JSON, so it is a plain value.

`options` is [`queue:push`](jobs.md#queuepushkind-payload-options)'s: `delay`,
`id`, `id_ttl`. **The dedup id is about the push, not the run** -- a refused
duplicate returns no id at all, so an application that needs to find the
original run again has to have kept it.

**Returns** the run id and the queue's depth, or `false, "duplicate"`.

```lua no-run
local run = flow:start { email = "a@b.c" }
local again, why = flow:start({ email = "a@b.c" }, { id = "signup:a@b.c" })
```

### flow:work(options)

Consumes this workflow's queue until `options.should_stop` says otherwise.
Options are [`queue:consume`](jobs.md#queueconsumehandlers-options)'s, and the
return value is its report.

**Returns** `{ handled, failed, retried, buried, duplicated }`.

```lua
local db       = require "akkar.db"
local workflow = require "akkar.workflow"

local conn = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}()
conn:exec(require("akkar.jobs.postgres").SCHEMA)
conn:exec(workflow.SCHEMA)

-- THE WHOLE POINT, IN ONE PAGE. Three steps; the second fails the first time
-- it is reached. The function runs twice, from the top, and step one's side
-- effect happens once.
local ran, explode = { one = 0, two = 0, three = 0 }, true

local flow = workflow.new(conn, "ref_workflow_signup", function(ctx)
  ctx:step("one",   function() ran.one = ran.one + 1 return { id = 41 } end)
  ctx:step("two",   function()
    ran.two = ran.two + 1
    if explode then explode = false error("the gateway said no", 0) end
    return "charged"
  end)
  ctx:step("three", function() ran.three = ran.three + 1 return "receipt" end)
  return "shipped"
end, { retries = 3, backoff = { base = 0.01, jitter = false } })

conn:exec("delete from akkar_jobs where queue = $1", flow.queue.key)

local run = flow:start { order = 41 }
local turns = 0
flow:work {
  timeout = 0, idle = 0.01,
  should_stop = function()
    turns = turns + 1
    return turns > 200 or flow:finished(run)
  end,
}

print("one ran", ran.one, "two ran", ran.two, "three ran", ran.three)
print("result", flow:result(run))

flow:forget(run)
conn:exec("delete from akkar_jobs where queue = $1 or queue like $2",
          flow.queue.key, flow.queue.key .. ":%")
conn:close()
```

### flow:handlers()

The handler table for [`queue:consume`](jobs.md#queueconsumehandlers-options),
keyed by this workflow's job kind. Merge several to run more than one workflow
in one worker.

**Returns** a table.

```lua no-run
local handlers = {}
for _, flow in ipairs { signup, billing } do
  for kind, handler in pairs(flow:handlers()) do handlers[kind] = handler end
end
signup.queue:consume(handlers)
```

### flow:steps(run)

What a run has memoized, oldest first: a list of `{ step, kind, result }` with
the result decoded. `kind` is `"step"` or `"sleep"`. The terminal row is
included and is named `__done`.

**Returns** a list.

### flow:finished(run)

True once the function has returned for this run.

**Returns** a boolean.

### flow:result(run)

What the function returned, or `nil` when it has not returned yet -- which is
indistinguishable from a workflow that returned nil, so ask `finished` first if
the difference matters.

### flow:forget(run)

Drops a run's memo and returns how many rows went. The next execution of that
run therefore runs every step again, which is the point when a run is being
deliberately replayed and a catastrophe when it is not.

**Returns** a number.

### flow.queue

The [`akkar.jobs`](jobs.md) queue underneath, for `depth`, `dead_letters`,
`reap` and everything else that module offers. `flow.queue.key` is
`akkar:queue:workflow:<name>`.

## Ctx

What a workflow function is called with.

### ctx:step(name, fn)

Runs `fn` once per run and returns whatever it returned the first time.

`fn` is called with the transaction the memo is written in, so a database write
made through it is exactly-once with the step. Anything else `fn` touches is
at-least-once; see
[What exactly-once covers](#what-exactly-once-covers-and-what-it-does-not).

A step's result is stored as JSON and decoded on replay, so it is **one value**
and it is whatever JSON can carry: `7` comes back as `7.0`, and a function, a
userdata or a database cursor cannot be a step result at all. The first
execution sees the JSON-shaped value too, so a workflow cannot work on its first
attempt and fail on its second over an integer that became a float.

`nil` is a legitimate result. The row's existence is what says the step is done,
never the contents of `result`.

Step names are the memo's keys, so they must be unique within a workflow, and
names beginning with `__` are reserved.

**Returns** the step's result.

**Raises**

- whatever `fn` raises -- the step is left unclaimed, so a retry of the workflow runs it again
- `akkar.workflow: a step needs a name; it is the key the result is stored under, so it cannot be nil or empty`
- `akkar.workflow: '<name>' is reserved -- names beginning with '__' belong to this module`
- `akkar.workflow: step '<name>' ran twice in one execution -- step names are the memo's keys and must be unique within a workflow`
- `akkar.workflow: step '<name>' was started inside step '<other>'. ...` for a nested step
- `akkar.workflow: the result of step '<name>' cannot be encoded as JSON ...`
- `akkar.workflow: step '<name>' of run '<run>' is being run by another worker and did not finish within <n>s ...`

### ctx:sleep(name, seconds)

Suspends the workflow and resumes it on a fresh worker once `seconds` have
passed. It records a due time and pushes the workflow back onto its own queue
with that delay, in one transaction, and then unwinds the function -- so nothing
holds a coroutine, a connection or a process for the duration. The worker
acknowledges the job and moves on.

**It does not return on the execution that reaches it first.** Anything after
the call belongs to the continuation. On a later execution, once the due time
has passed, it returns normally and the function carries on.

The due time is why a sleep is not simply recorded as "done". A workflow that
suspended and was then redelivered -- its worker died between the commit and the
acknowledgement, which is exactly what at-least-once means -- runs from the top
and reaches the sleep again; a row that only said "this happened" would let it
sail through and run tomorrow's work today, beside a continuation that is still
queued. The clock compared against is the server's, for the reason
`akkar.jobs.postgres` gives at length about `clock_timestamp()`.

Unwinding is an `error` carrying a private sentinel, so **do not wrap
`ctx:sleep` in `pcall`**: catching it makes the function carry on as though the
time had passed, and there is no way for this module to tell that `pcall` from
any other.

**Raises**

- the suspension sentinel, always, on the execution that schedules the continuation
- `akkar.workflow: step '<name>' tried to sleep. ...` for a sleep inside a step
- the same name errors `ctx:step` raises

### ctx.run

The run id: `<name>:<24 hex characters>`, stable across every retry, every
redelivery and every continuation of this run. It is the key every memo row is
written under, and it is the right thing to derive an outbound idempotency key
from.

It is minted by `flow:start` rather than taken from `job.uid`, and the
difference matters. `uid` is stable across every retry and redelivery of **one
job**, which is all a plain job needs; but `ctx:sleep` pushes a *new* job to
resume with, and a new push mints a new uid. A memo keyed on `uid` would be lost
at the first sleep, and every step before it would run a second time.

### ctx.input

Whatever `flow:start` was given, after a JSON round trip.

### ctx.job

The job this execution came from -- `uid`, `attempts`, `kind` and the rest of
[what `queue:pop` returns](jobs.md#queuepoptimeout) -- or `nil` when the
workflow was invoked directly.

### ctx.attempt

Which attempt this is, counting from 1.

### ctx.db

The connection the workflow was built on. Use it for reads that do not need to
be memoized; a write belongs in a step, through the handle the step is given.

## workflow.Flow

The metatable of what `new` returns.

## workflow.Ctx

The metatable of the context a workflow function is called with.

## The table

One table, and a row in it is a finished step.

```sql
akkar_workflow_steps (run, step, kind, result, due_at, created_at)
primary key (run, step)
```

There is no lease column, no token and no expiry, and that is not a
simplification. The claim and the completion are the same transaction:

```sql
begin
  insert into akkar_workflow_steps (run, step)   -- the claim
  ... the step's own writes ...
  update ... set result = ...                    -- the memo
commit
```

A second worker's `insert ... on conflict do nothing` on that key waits for the
first transaction to resolve and then either finds the row, and replays its
result, or inserts its own because the first rolled back. **A row that exists is
always a finished step**: a worker killed mid-step leaves nothing behind,
because its insert died with it.

That wait is bounded by `step_lock_timeout`. Past it the step raises a
contention error rather than holding a pooled connection for the length of
somebody else's step, and the queue's retry policy brings the run back -- by
which time the step is done and replays.

## Not here

**A run table, a status column, a list of running workflows.** The queue holds a
run's liveness and the step table holds its history; a third record of the same
fact is a third thing that can disagree. The cost is stated: a run that has not
yet finished a step is visible only as a job in `akkar_jobs`, and `flow:steps`
answers about a run whose id you already have.

**Parallel steps, fan-out, `Promise.all`.** Steps run in the order the function
calls them. A workflow that wants two things at once pushes two jobs.

**Cancellation, signals, waiting for an external event.** A run stops when its
function returns or when the queue buries it.

**Deterministic replay, a sandboxed VM, a hosted orchestrator.** See the top of
this page.

**Any store but Postgres.** The memo and the step's writes have to be one
transaction, which is a property of a database and not of a queue.

## See also

- [akkar.jobs](jobs.md) -- the queue this runs on, and everything it already guarantees
- [akkar.idempotency](idempotency.md) -- the same claim/replay pattern, for an inbound request
- [akkar.db](db.md) -- `db:transaction` and its savepoints
- [akkar.migrate](migrate.md) -- how the schema is applied
