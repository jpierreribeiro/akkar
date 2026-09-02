# akkar.jobs

The semantics of a job queue with no storage in it: what a job is, what happens
when a handler fails, and what a worker loop does. Storage is a separate object
called a store, and this module wraps one.

**When you need it.** A handler has work the caller is not waiting for (an
email, a report, a resized image) and the response should go out before that
work is done.

```lua no-run
local jobs = require "akkar.jobs"
```

Three stores ship with akkar. [`akkar.jobs.memory`](#akkarjobsmemory) keeps
jobs in a Lua table, [`akkar.jobs.redis`](#akkarjobsredis) keeps them in Redis,
and `akkar.jobs.postgres` keeps them in one Postgres table -- claiming with
`select ... for update skip locked`, so a job pushed inside the transaction
that produced it exists if and only if that write does.

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`jobs.delay_for`](#jobsdelay_forattempt-backoff) | function |
| [`jobs.new`](#jobsnewstore-name-options) | function |
| [`jobs.Queue`](#queue) | table |
| [`memory.new`](#memorynewname-options) | function |
| [`memory.Store`](#memorystore-metatable) | table |
| [`memory.store`](#memorystore) | function |
| [`queue:ack`](#queueackjob) | method |
| [`queue:consume`](#queueconsumehandlers-options) | method |
| [`queue:dead_depth`](#queuedead_depth) | method |
| [`queue:dead_key`](#queuedead_key) | method |
| [`queue:dead_letters`](#queuedead_letterslimit) | method |
| [`queue:depth`](#queuedepth) | method |
| [`queue:fail`](#queuefailjob-err) | method |
| [`queue:in_flight`](#queuein_flight) | method |
| [`queue:pop`](#queuepoptimeout) | method |
| [`queue:push`](#queuepushkind-payload-options) | method |
| [`queue:reap`](#queuereapnow) | method |
| [`queue:reliable`](#queuereliable) | method |
| [`redis.new`](#redisnewcache-name-options) | function |
| [`redis.Store`](#redisstore) | table |
| [the store contract](#the-store-contract) | contract |

## The store contract

A store is any table with these three methods. `jobs.new` checks for them and
refuses anything else.

| method | meaning |
|---|---|
| `store:enqueue(key, encoded)` | append; returns the new depth |
| `store:dequeue(key, timeout)` | oldest entry, or `nil` on timeout |
| `store:depth(key)` | how many are waiting |

These are optional, and each one buys a named feature. Asking for the feature
against a store that does not implement the method is an error at the call, not
a feature that quietly does nothing.

| method | what it buys |
|---|---|
| `store:schedule(key, encoded, run_at)` | `push` with `options.delay`, and every retry |
| `store:promote(key, now)` | a delayed or retried job actually becoming due |
| `store:claim(key, id, ttl)` | `push` with `options.id` |
| `store:unclaim(key, id)` | giving that id back when the push it was taken for fails |
| `store:claim_and_enqueue(key, id, ttl, encoded, run_at)` | claim and push, in one indivisible step |
| `store:claim_pop(key, timeout)` | at-least-once delivery |
| `store:ack(key, encoded)` | at-least-once delivery |
| `store:expired(key, visibility, now, limit)` | at-least-once delivery |
| `store:in_flight(key)` | at-least-once delivery |
| `store:peek(key, limit)` | `queue:dead_letters` |
| `store:trim(key, keep)` | the dead-letter list staying under `max_dead` |

All three shipped stores implement all of them, and the same contract specs
run over each: `spec/jobs_spec.lua`, `spec/jobs_delivery_spec.lua` and
`spec/jobs_expired_order_spec.lua` take one pass per store rather than one set
of assertions per store, because matching assertions in three files drift
apart and a shared pass cannot.

**The last four come as a set.** `jobs.new` turns at-least-once delivery on
only when all four are present, because a store that leases a job without
being able to say which leases have expired holds that job for ever -- which
is a worse failure than never leasing it. A store with three of the four gets
at-most-once delivery and says so; see [`jobs.new`](#jobsnewstore-name-options).

`store:expired` returns the encoded jobs whose lease has run out, **oldest
first**, and stamps each one it returns so a second reaper arriving mid-pass
takes nothing. It does not remove them: they stay in flight until `queue:reap`
has written the next copy and acknowledged the old one, so a reaper that dies
in the middle costs a redelivery rather than the job. Its `now` is a test seam
-- left out, the store answers with its own clock, which for Redis is the
server's `TIME` and is the one clock every worker in a fleet shares.

Oldest first is part of the contract and all three stores now obey it. The Redis
one did not: `RPOPLPUSH` pushes to the head of the processing list, so the
`LRANGE` window came back newest-first and a mass reap -- a deploy, an OOM
kill, a fleet restart, which is the only time more than one lease expires at
once -- redelivered LIFO there and FIFO in memory. LIFO starves the entry at
the bottom of the list, and that entry is the one that has been redelivered
most often, so it is the one closest to `max_redeliveries`. Every spec that
existed reaped a single job, where the order cannot be seen.

## jobs.delay_for(attempt, backoff)

The backoff schedule, exposed so a caller can print or test it. `attempt` is
`1` for the first retry.

| field | type | default | meaning |
|---|---|---|---|
| `first` | number | `base` | the first window, in seconds |
| `factor` | number | `base` | what each window is multiplied by |
| `base` | number | `2` | sets both `first` and `factor` at once, giving `base ^ attempt` |
| `max` | number | `300` | the ceiling on that window |
| `jitter` | boolean | `true` | when not `false`, the answer is a uniform draw between zero and the window |

The window is `first * factor ^ (attempt - 1)`, capped at `max`. `base` is the
shorthand for the case where those two are the same number, and it is the
default, so `{}` is `2, 4, 8, 16` exactly as before.

`first` and `factor` exist because `base ^ attempt` cannot express the schedule
most retrying systems use — a fixed first delay that doubles. Delivering
webhooks to somebody else's endpoint is the usual case:

```lua no-run
{ first = 60, factor = 2, max = 4 * 60 * 60 }   --> 60, 120, 240, 480, ... 4h
```

**Resolution is sub-second**, and the fraction matters: with jitter on, the
answer is a fraction of the window, and both stores keep it. The memory store
schedules against a monotonic clock and the Redis store reads the microseconds
from the server's `TIME`.

Jitter is not decoration. A hundred jobs that failed against a database which
has just come back would otherwise all retry on the same second.

**Returns** a delay in seconds.

```lua
local jobs = require "akkar.jobs"

-- Without jitter the window itself, capped at max.
print(jobs.delay_for(1, { jitter = false }))            --> 2.0
print(jobs.delay_for(3, { jitter = false }))            --> 8.0
print(jobs.delay_for(20, { jitter = false }))           --> 300

-- With jitter, somewhere in [0, window).
local delay = jobs.delay_for(3, {})
assert(delay >= 0 and delay < 8)
```

## jobs.new(store, name, options)

Wraps a store with the queue semantics. `name` separates one queue from
another; jobs pushed under one name are only taken by workers reading that
name. It defaults to `"default"`.

| field | type | default | meaning |
|---|---|---|---|
| `retries` | number | `0` | attempts after the first. `0` means a handler that raises is buried or dropped straight away. |
| `backoff` | table | `{}` | passed to `jobs.delay_for`; see its fields above |
| `dead_letter` | boolean | `true` | keep what finally failed in a second list. Only an explicit `false` turns it off. |
| `max_dead` | number | `1000` | how many dead letters to keep, when the store can `trim` |
| `delivery` | string | inferred | `"at_least_once"` or `"at_most_once"`. Left out, it is at-least-once wherever the store can lease. |
| `visibility` | number | `300` | seconds a worker may hold a job before another may take it |
| `max_redeliveries` | number | `5` | redeliveries before a job goes to the dead letters |
| `reap_every` | number | `visibility / 10` | seconds between the automatic reaps `pop` runs |

**Returns** a `Queue`. Its `key` field is `"akkar:queue:" .. name`, which is the
Redis key when the store is Redis.

**Raises** `akkar.jobs: store does not satisfy the contract; missing :enqueue`
(or `:dequeue`, or `:depth`) when the store is not a store.

**Raises** `akkar.jobs: retries need a store that can schedule, and this one
implements neither :schedule nor :promote ...` when `retries` is above zero and
the store cannot hold a job until later. Refused at construction rather than at
the first failure.

**Raises** `akkar.jobs: delivery must be 'at_least_once' or 'at_most_once' ...`
for any other value, so a typo is not silently a downgrade.

**Raises** `akkar.jobs: at-least-once delivery needs a store that can hold a job
in flight ...` when `delivery = "at_least_once"` is asked of a store that cannot
lease. Accepting the setting and delivering at most once anyway is the one
outcome worse than not offering it.

A store that cannot lease still builds a queue. That queue reports
`delivery == "at_most_once"` rather than claiming otherwise, and
`delivery = "at_most_once"` over a store that CAN lease is how you ask for that
behaviour on purpose.

```lua
local jobs   = require "akkar.jobs"
local memory = require "akkar.jobs.memory"

local queue = jobs.new(memory.store(), "ref_jobs_email", {
  retries = 3,
  backoff = { base = 2, max = 300 },
})

print(queue.key)         --> akkar:queue:ref_jobs_email
print(queue.retries)     --> 3
print(queue.delivery)    --> at_least_once
print(queue:reliable())  --> true

-- The same store, told to be unreliable on purpose.
local careless = jobs.new(memory.store(), "ref_jobs_careless",
                          { delivery = "at_most_once" })
print(careless.delivery)  --> at_most_once

-- A store with only the three required methods cannot retry.
local bare = {
  enqueue = function() return 1 end,
  dequeue = function() return nil end,
  depth   = function() return 0 end,
}
print(pcall(jobs.new, bare, "ref_jobs_bare", { retries = 1 }))
```

## Queue

The object `jobs.new` returns. Its metatable is exported as `jobs.Queue`.

A job travelling through it is a table with these fields:

| field | meaning |
|---|---|
| `uid` | this job's identity, minted by `push` and unchanged by every retry and redelivery |
| `kind` | the string given to `push`; a worker looks it up in its handler table |
| `payload` | the second argument to `push`, after a round trip through JSON |
| `id` | the deduplication id, when one was given |
| `queued_at` | the time `push` was called |
| `attempts` | how many times a handler has failed on this job |
| `redeliveries` | how many times a worker took this job and stopped answering |
| `last_error`, `first_failed_at`, `died_at` | added by `fail`, when they apply |

**`uid` is the field to dedup on, and it is not `id`.** `id` stops a second
PUSH and is optional; `uid` is on every job and identifies one job across
however many times it runs. `attempts` and the encoded bytes both change on a
retry, so neither can be that key. Write your "already did this" marker under
`uid`, in the same transaction as the side effect, and a handler that runs
twice does its work once.

`redeliveries` is counted apart from `attempts` on purpose: `attempts` is the
handler saying no, and a worker being OOM-killed is not the handler saying
anything. Charging a redelivery to the retry budget would bury healthy work
after a deploy that restarted the fleet three times.

The payload goes through JSON, so a table comes back as a table and a number
comes back as a Lua float. Do not put a database row in a payload: put an id,
and read the row fresh when the job runs.

### queue:ack(job)

Marks a job finished so it stops being recoverable. `consume` calls it for you
after a handler returns; on the failure path [`queue:fail`](#queuefailjob-err)
does it, once the retry or the burial is written.

**Returns** `true` when the job was still checked out to you, and `false` when
it was not -- meaning the lease had already expired and somebody else has the
job, so this run was a duplicate and `visibility` is shorter than the handler's
real runtime. That is the only symptom of a visibility timeout set too low, and
`consume` counts it as `duplicated`.

**Returns** `true` under at-most-once delivery, where there was never anything
to retire.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_ack"
queue:push("ping", {})

local job = queue:pop(0)
print(queue:in_flight())   --> 1
print(queue:ack(job))      --> true
print(queue:in_flight())   --> 0
```

### queue:consume(handlers, options)

The worker loop. It pops a job, looks `job.kind` up in `handlers`, calls the
handler with `(job.payload, job)` under `pcall`, and acknowledges. It repeats
until `should_stop()` answers true.

A job whose `kind` is in no handler is not dropped. It goes through the same
failure path as a raising handler, because the usual cause is a deploy in
progress where the worker runs older code than the producer.

| field | type | default | meaning |
|---|---|---|---|
| `should_stop` | function | never stops | called before each pop; the loop ends when it returns true |
| `timeout` | number | `1` | seconds to wait for a job on each pop |
| `log` | table | none | an `akkar.log` logger. Without one, a failed job is silent. |

**Returns** `{ handled, failed, retried, buried, duplicated }`. `duplicated`
counts jobs whose handler finished after the lease had already expired, which
means they were running twice.

**Delivery is at-least-once unless the queue was told otherwise**, and
`queue.delivery` says which one you have.

**The reaper runs off the back of `pop`**, so any worker consuming from a queue
is also recovering it and there is no janitor process to forget to deploy. A
job whose worker was killed is back in the queue within
`visibility + reap_every` seconds and not before, because there is no way to
tell a dead worker from a slow one except by waiting.
[`queue:reap`](#queuereapnow) is public for anyone who wants one anyway.

A `consume` with no `should_stop` never returns. In a server process, run it
under `app:task` instead of calling it directly.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_consume"
queue:push("greet", { who = "world" })
queue:push("greet", { who = "again" })

local rounds = 0
local stats = queue:consume({
  greet = function(payload) print("hello " .. payload.who) end,
}, {
  timeout = 0,
  should_stop = function() rounds = rounds + 1 return rounds > 3 end,
})

print(stats.handled, stats.failed, stats.duplicated)   --> 2 0 0
```

### queue:dead_depth()

**Returns** how many jobs finally failed and are sitting in the dead-letter
list. A number that grows is a thing to look at.

### queue:dead_key()

**Returns** the key the dead-letter list lives under, which is
`queue.key .. ":dead"`.

```lua
local memory = require "akkar.jobs.memory"

print(memory.new("ref_jobs_keys"):dead_key())
--> akkar:queue:ref_jobs_keys:dead
```

### queue:dead_letters(limit)

Reads the dead letters without removing them, oldest first. `limit` defaults to
`100`. Bytes that would not decode are left out of the result.

**Returns** an array of jobs.

**Raises** `akkar.jobs: this store cannot list dead letters; it implements no
:peek` when the store has no `peek`.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_dead"
queue:push("boom", { order = 41 })

local job = queue:pop(0)
queue:fail(job, "the payment gateway said no")

local dead = queue:dead_letters(10)
print(#dead, dead[1].kind, dead[1].last_error)
--> 1  boom  the payment gateway said no
```

### queue:depth()

**Returns** how many jobs are waiting. It does not count jobs that are
scheduled for later, nor jobs a worker currently holds.

### queue:fail(job, err)

Puts a failed job back after its backoff, or buries it. `consume` calls this;
call it yourself only if you are writing your own loop.

It increments `job.attempts`, sets `job.last_error` and sets
`job.first_failed_at` if it was not set.

**Returns** one of:

| return | when |
|---|---|
| `"retried", delay` | `job.attempts` is still within `retries`. The job is rescheduled `delay` seconds out. |
| `"buried"` | out of retries, and `dead_letter` is on |
| `"dropped"` | out of retries, and `dead_letter` is `false` |

```lua
local jobs   = require "akkar.jobs"
local memory = require "akkar.jobs.memory"

local queue = jobs.new(memory.store(), "ref_jobs_fail", {
  retries = 1,
  backoff = { base = 2, max = 60, jitter = false },
})

queue:push("charge", { order = 41 })
local job = queue:pop(0)

print(queue:fail(job, "gateway timeout"))   --> retried  2.0
print(queue:fail(job, "gateway timeout"))   --> buried
print(queue:dead_depth())                   --> 1
```

### queue:in_flight()

**Returns** how many jobs are currently checked out by a worker, or `0` under
at-most-once delivery, where nothing is ever held.

### queue:pop(timeout)

Waits for one job, up to `timeout` seconds. `timeout` defaults to `5`, and `0`
means look without waiting.

Before it looks, it asks the store to promote anything whose delay has come
due. It takes the reliable path when the store offers one: the job moves into a
processing set as it leaves the queue, in a single step, and stays there until
it is acknowledged.

**Returns** the job, or `nil` on timeout, or `nil, "akkar.jobs: undecodable job
discarded"` when the bytes at the head of the queue are not JSON. Undecodable
bytes are acknowledged and then moved to the dead-letter list rather than
dropped.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_pop"
print(tostring(queue:pop(0)))   --> nil, the queue is empty

queue:push("resize", { image_id = 7 })
local job = queue:pop(0)
print(job.kind, job.payload.image_id, job.attempts)   --> resize 7.0 0.0
```

### queue:push(kind, payload, options)

Enqueues a job. `kind` is the string a worker looks up in its handler table.
`payload` is encoded as JSON.

| field | type | default | meaning |
|---|---|---|---|
| `delay` | number | none | hold the job for this many seconds before a worker may take it |
| `id` | string | none | refuse this push if the same id was pushed recently |
| `id_ttl` | number | `3600` | how long that id stays claimed, in seconds |

**Returns** the depth after the push, or `false, "duplicate"` when `id` was
already claimed.

**Raises** `akkar.jobs: this store cannot deduplicate -- it implements no
:claim ...` when `id` is given and the store has no `claim`.

**Raises** `akkar.jobs: this store cannot delay a job; it implements no
:schedule` when `delay` is given and the store has no `schedule`.

An `id` is deduplication at the door. It stops the same job being queued twice.
It does not stop a job that was queued once from running twice, which is what
`reap` and at-least-once delivery make possible; see
[`queue:reliable()`](#queuereliable).

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_push"

print(queue:push("welcome_email", { account_id = 13 },
                 { id = "welcome:13" }))            --> 1
print(queue:push("welcome_email", { account_id = 13 },
                 { id = "welcome:13" }))            --> false  duplicate

-- Held for an hour, so it is not waiting yet.
queue:push("digest", { account_id = 13 }, { delay = 3600 })
print(queue:depth())                                --> 1
```

### queue:reap(now)

Returns to the queue every job whose worker stopped answering, and buries the
ones that have outlived `max_redeliveries` workers.

**Returns** how many were redelivered and how many were buried, or `0, 0` under
at-most-once delivery, where nothing is ever held.

**Leave `now` out.** Then the store answers with the clock every worker shares
-- for Redis, the server's own `TIME`, read inside the script -- and that is
the whole point: a cutoff computed by one worker made every reap an assertion
about time made by a machine that might have just been stepped by NTP. A
correction forwards reclaimed jobs other workers were actively running; a
correction backwards reclaimed nothing ever again.

What decides staleness is [`visibility`](#jobsnewstore-name-options), which is
the queue's configuration rather than the caller's opinion, **and it must exceed
the longest a handler may legitimately take.** Set it too low and a slow job is
handed to a second worker while the first is still working on it.

`now` is a test seam, for a spec or an operator who cannot wait out a window:
it moves the cutoff and nothing else, so a claim time is still written from the
store's clock.

`pop` reaps for you every `reap_every` seconds, so calling this at all is
optional.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_reap"
queue:push("slow", {})

-- A worker takes the job and dies without acknowledging it.
queue:pop(0)
print(queue:depth(), queue:in_flight())   --> 0  1

-- Nothing is due yet: the lease has five minutes to run. Parenthesised
-- because `reap` answers with two numbers, redelivered and buried.
print((queue:reap()))                     --> 0

-- An instant past the visibility window, because this example cannot wait
-- five minutes. In a worker you would pass nothing and let time pass.
print((queue:reap(os.time() + 301)))      --> 1
print(queue:depth(), queue:in_flight())   --> 1  0
```

### queue:reliable()

**Returns** `true` when this queue survives a worker dying mid-job, which is
the same as `queue.delivery == "at_least_once"`.

It answers what this queue DOES rather than what its store could do, because
`delivery = "at_most_once"` makes those two different questions.

Worth asking rather than assuming. The answer decides whether a job that
matters may go through this queue at all.

## akkar.jobs.memory

In-process storage for a job queue. It implements every method in the contract,
required and optional, so retries, delays, deduplication and reaping can all be
exercised without Redis.

```lua no-run
local memory = require "akkar.jobs.memory"
```

`dequeue` does not block, whatever timeout is passed. Work can only arrive from
this same process, so sleeping while waiting for it would be a deadlock rather
than a wait.

### memory.new(name, options)

**Returns** a `Queue` over a fresh store, which is `jobs.new(memory.store(),
name, options)`. `options` is forwarded whole, so everything under
[`jobs.new`](#jobsnewstore-name-options) works here.

### memory.store()

**Returns** a bare store, for handing to `jobs.new`.

### memory.Store (metatable)

The store metatable. Its methods beyond the contract are
`store:processing_key(key)` and `store:scheduled_depth(key)`.

```lua
local jobs   = require "akkar.jobs"
local memory = require "akkar.jobs.memory"

local store = memory.store()
local queue = jobs.new(store, "ref_jobs_store", { retries = 2 })

queue:push("later", {}, { delay = 60 })
print(store:scheduled_depth(queue.key))   --> 1
print(queue:depth())                      --> 0
```

## akkar.jobs.redis

Redis storage for a job queue. Semantics stay in `akkar.jobs`; this only stores
and retrieves.

```lua no-run
local redis = require "akkar.jobs.redis"
```

A Redis list gives FIFO for free. Scheduling is a sorted set scored by the
second a job is due. Deduplication is `SET NX EX`, which is atomic across every
process talking to that Redis, which is the reason deduplication belongs in the
store and not in the worker.

### redis.new(cache, name, options)

`cache` is a connection, not a connector: `akkar.redis.connect{}` returns a
function that opens connections, so the call needs the extra `()`.

**Returns** a `Queue`. `options` is forwarded whole to
[`jobs.new`](#jobsnewstore-name-options), the same as `memory.new`.

```lua no-run
local redis = require "akkar.redis"
local jobs  = require "akkar.jobs.redis"

local queue = jobs.new(redis.connect { port = 6379 }(), "email")
```

### redis.Store

The store metatable, exposed so a queue with options can be built over it:

```lua no-run
local jobs      = require "akkar.jobs"
local redisjobs = require "akkar.jobs.redis"
local redis     = require "akkar.redis"

local store = setmetatable({ cache = redis.connect { port = 6379 }() },
                           redisjobs.Store)

local queue = jobs.new(store, "email", { retries = 3, dead_letter = true })
```

Its methods beyond the contract are `store:processing_key(key)`,
`store:claimed_key(key)`, `store:scheduled_key(key)` and
`store:scheduled_depth(key)`.

### The Redis keys a queue uses

For a queue named `email`, with `key` equal to `akkar:queue:email`:

| key | holds |
|---|---|
| `akkar:queue:email` | the list of jobs waiting |
| `akkar:queue:email:scheduled` | a sorted set of delayed and retried jobs, scored by when they are due |
| `akkar:queue:email:processing` | the list of jobs a worker currently holds |
| `akkar:queue:email:processing:at` | a sorted set scoring each held job by when it was taken; this is what `reap` reads |
| `akkar:queue:email:dead` | the list of jobs that finally failed |
| `akkar:queue:email:claim:<id>` | one key per deduplication id, with the `id_ttl` on it |

A full round trip against a live Redis:

```lua
local cqueues = require "cqueues"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"

local loop = cqueues.new()
loop:wrap(function()
  local conn  = redis.connect { host = "127.0.0.1", port = 6379 }()
  local queue = jobs.new(conn, "ref_jobs_demo")

  print(queue:reliable())                       --> true
  queue:push("welcome_email", { account_id = 13 }, { id = "ref_jobs:13" })
  print(queue:push("welcome_email", { account_id = 13 },
                   { id = "ref_jobs:13" }))     --> false  duplicate
  print(queue:depth())                          --> 1

  local job = queue:pop(0)
  print(job.kind, queue:in_flight())            --> welcome_email  1
  queue:ack(job)
  print(queue:depth(), queue:in_flight())       --> 0  0

  conn:del(queue.key, queue.key .. ":scheduled", queue.key .. ":processing",
           queue.key .. ":processing:at", queue:dead_key(),
           queue.key .. ":claim:ref_jobs:13")
  conn:release()
end)
assert(loop:loop())
```

## Not here

**No scheduler.** Nothing calls `reap` for you, and nothing runs a job on a
cron. The queue holds a job until a worker asks for it, and `options.delay` is
the only timing it knows.

**No worker command.** `queue:consume` is a Lua loop you put in your own file,
or an [`app:task`](akkar.md#apptaskname-fn) in the server process. akkar ships
no `akkar worker` binary.

**No priorities.** One name, one FIFO list. Two priorities means two queues and
two workers.

**No Postgres store.** The contract exists so one can be written; none ships.

**No automatic dedup of a redelivery.** `push` with an `id` stops a second
push; nothing stops the same job being delivered twice, because that is what
at-least-once means. Write a marker under `job.uid` inside the transaction
that does the work.

## See also

- [akkar](akkar.md) for `app:task`, which runs a consumer inside the server's
  own loop
- [akkar.redis](redis.md) for `connect`, which produces the connection
  `akkar.jobs.redis` needs
- [akkar.work](work.md) for the other answer to slow work: yielding inside the
  request instead of leaving it
- the guide's [background work page](../guide/10-background-work.md) for the
  same material taught rather than listed
- the module source, `akkar/jobs.lua`, for why the semantics and the storage
  are separate
