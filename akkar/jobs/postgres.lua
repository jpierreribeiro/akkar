--[[
akkar.jobs.postgres — Postgres persistence for a job queue.  Semantics live in
`akkar.jobs`; this only stores and retrieves.

The floor of durable execution for anyone who already has a Postgres: a job
queue whose jobs survive a worker being killed, in the database the
application already trusts with everything else. Retries, backoff, dead
letters, the reaper and the at-least-once lease are ALL `akkar/jobs.lua`'s --
nothing here decides what happens to a job, this file only answers the
questions the store contract asks, in SQL.

## One table, three states

    akkar_jobs (queue, state, body, run_at, claimed_at)

A Redis list, a sorted set and a processing list become one table whose
`state` column says which of those a row is in: `ready` is the queue,
`scheduled` is the sorted set, `held` is the processing list. The dead-letter
list is the same table under the dead key, because `akkar/jobs.lua` reaches it
through the same `enqueue`/`depth`/`peek`/`trim` it uses for the queue.

`body` is `text`, not `jsonb`, and that is deliberate. `ack` finds a job by the
EXACT bytes it was leased as -- `akkar/jobs.lua` keeps them weakly for that
reason and says why -- and `jsonb` normalises what it stores: keys reordered,
whitespace gone, so the bytes that come back are not the bytes that went in
and an acknowledgement would never match. A column nobody queries into has no
business being parsed by the database.

## The lease is `SELECT ... FOR UPDATE SKIP LOCKED`

The Graphile Worker recipe (graphile/worker, `get_job`): inside a transaction,
select the oldest ready row `FOR UPDATE SKIP LOCKED`, then mark it held. The
row lock is what makes two workers claiming at once take two different jobs:
the second worker's `SELECT` does not wait on the first's row and does not see
it either -- it SKIPS to the next unlocked one. Without those four words the
second `SELECT` returns the same row, its `UPDATE` waits for the first
transaction to commit, and then updates the row a second time. Two workers,
one job, both delivered. `spec/jobs_postgres_spec.lua` stages exactly that
with two concurrent consumers and asserts one delivery per job; the commit
that adds it records the run with the clause removed, and it is red.

`dequeue` -- the at-most-once path -- is the same select inside a `DELETE`.

## Held to the same contract as the other two, by the same specs

Nothing in this file is trusted because its own spec file says so.
`spec/jobs_spec.lua`, `spec/jobs_delivery_spec.lua` and
`spec/jobs_expired_order_spec.lua` each take one pass per store, so the queue
semantics, the at-least-once properties and the reap ordering are asserted
ONCE and run three times -- memory, Redis, Postgres. A store held only to its
own spec is a store held to its own idea of the contract, and this one has the
most room to disagree: a list, a sorted set and a processing list become three
`where` clauses over one table, and only running the shared assertions says
those clauses mean what the other two stores mean.

`spec/jobs_delivery_spec.lua` additionally records the whole delivery
lifecycle as a trace and compares this store's against the memory store's
field by field, which is how a divergence is caught rather than a divergence
in the assertions about it.

## The server owns the clock

Every time written here -- when a job is due, when a lease was taken, the
cutoff a reap compares against -- is `clock_timestamp()` on the server, never
a value this worker computed. The argument is the header of
`akkar/jobs/redis.lua` and it is not repeated in full: a fleet has several
clocks and one of them has just been stepped by NTP, and if the claim times
and the cutoff come from different machines a correction on one worker
reclaims every job the others are running. Postgres is the one clock every
worker of a Postgres-backed queue already shares.

`clock_timestamp()` rather than `now()`. `now()` is frozen at the start of the
transaction, and a job pushed inside a long transaction -- which is a
legitimate and useful thing to do, see below -- would be stamped with a time
from before the transaction began, and a claim taken inside one would look
older than it is.

The store therefore takes DURATIONS -- a delay, a visibility window -- and
turns them into instants itself, exactly as the Redis store does. The `now`
argument to `expired` is the test seam every store carries: it moves the
cutoff and nothing else, and no stamp is ever written from it.

## Waking a worker: LISTEN/NOTIFY over pgmoon, polling over the C driver

A queue whose workers sleep for a fixed interval adds that interval to every
job's latency. Postgres has `LISTEN`/`NOTIFY` for exactly this: `enqueue`
raises a notification on a channel named after the queue, and a worker with
nothing to do waits on its connection's socket for one instead of polling.
Delivered on commit, so a job pushed inside a transaction wakes nobody until
the transaction it belongs to is real.

WHETHER THAT IS POSSIBLE DEPENDS ON THE DRIVER, and this module checks rather
than assumes:

  * pgmoon -- the default driver of `akkar.db` -- parses the asynchronous
    `NotificationResponse` message and exposes `wait_for_notification`, so
    the wait is a `cqueues.poll` on the connection's own socket followed by
    one read. A push on another connection wakes the worker inside a
    millisecond or so; `spec/jobs_postgres_spec.lua` measures it.

  * `akkar.pq`, the C driver, binds no `PQnotifies` -- `src/akkar_pq.c`
    exports `send_query`, `consume`, `busy`, `get_result` and nothing that
    hands a notification to Lua -- so a `LISTEN` on that connection would be
    answered by libpq and thrown away. Over that driver this store FALLS BACK
    TO BOUNDED POLLING: it re-runs the claim every `poll_every` seconds (a
    quarter of a second by default) until the caller's timeout. The cost is
    stated rather than hidden: up to `poll_every` of added latency on an idle
    queue, and one claim query per `poll_every` per idle worker. Binding
    `PQnotifies` is about thirty lines of C and is the fix; it is not done in
    this commit because it is a driver change with its own proof to write.

The choice is made per store at construction and is readable as
`store.wakeup`, which is `"listen"` or `"poll"`.

One bounded gap on the LISTEN path, named so nobody rediscovers it: a
notification that arrives while this worker is inside its own claim query is
read by that query's reply and discarded, so a job pushed in that instant
does not wake the worker early. It is not lost -- the next claim finds it --
and the cost is at most one `timeout` of latency, once, in that interleaving.

## Pushing inside the caller's transaction

The store holds a database HANDLE and runs statements on it, so a store built
over `req.db` inside `req.db:transaction` pushes into that transaction: the
job exists if and only if the order does. That is a property no Redis-backed
queue can offer and the one most worth having from a Postgres-backed one.

    req.db:transaction(function(tx)
      tx:exec("insert into orders ...")
      jobs.new(postgres.store(tx), "email"):push("receipt", { order = id })
    end)

## The schema ships as data

`M.MIGRATIONS` is the list `akkar.migrate` takes under `files`, and
`M.migrate(db)` applies it under the same ledger and lock as the
application's own migrations. It is one file, timestamped so it sorts after
any counter an application started with, and written with `if not exists` so
a database that already carries the tables from a different ledger is left
alone rather than refused.
]]

local jobs    = require "akkar.jobs"
local cqueues = require "cqueues"

local M = {}

-- ===================================================================== schema

M.SCHEMA = [[
create table if not exists akkar_jobs (
  id         bigserial   primary key,
  queue      text        not null,
  state      text        not null check (state in ('ready', 'scheduled', 'held')),
  body       text        not null,
  run_at     timestamptz not null,
  claimed_at timestamptz,
  created_at timestamptz not null default clock_timestamp()
);

-- Partial, one per state, and each one is the exact scan a contract method
-- runs. The claim walks `ready` rows for one queue in due order and skips the
-- locked ones as it goes, so the index has to be ordered the way the claim
-- orders or SKIP LOCKED degenerates into a sort of every waiting row on every
-- pop. The other two are the promote and the reap.
create index if not exists akkar_jobs_ready
  on akkar_jobs (queue, run_at, id) where state = 'ready';
create index if not exists akkar_jobs_scheduled
  on akkar_jobs (queue, run_at) where state = 'scheduled';
create index if not exists akkar_jobs_held
  on akkar_jobs (queue, claimed_at) where state = 'held';

-- Deduplication ids. A row per id with its expiry; the primary key is what
-- makes a second push lose the race, and `expires_at` is what lets the id be
-- taken again once the ttl is over.
create table if not exists akkar_job_claims (
  queue      text        not null,
  id         text        not null,
  expires_at timestamptz not null,
  primary key (queue, id)
);
create index if not exists akkar_job_claims_expiry
  on akkar_job_claims (queue, expires_at);
]]

M.MIGRATIONS = {
  { name = "20260902120000_akkar_jobs.sql", sql = M.SCHEMA },
}

--- Applies the schema through `akkar.migrate`, so it lands in the same ledger
--- and under the same lock as the application's own migrations.
---
--- `options.table` names the ledger, as it does for `migrate.new`. Returns
--- what `runner:apply` returns: the names applied, empty on every boot after
--- the first.
function M.migrate(db, options)
  local migrate = require "akkar.migrate"
  return migrate.new(db, { files = M.MIGRATIONS,
                           table = options and options.table }):apply()
end

-- ====================================================================== store

local Store = {}
Store.__index = Store

-- How long the polling fallback sleeps between claims on an idle queue. A
-- quarter of a second: short enough that a job waits less than a blink,
-- long enough that an idle worker costs four cheap index probes a second and
-- not four hundred.
local DEFAULT_POLL_EVERY = 0.25

-- The socket read after a wake-up is bounded, because a readable socket is
-- a promise of BYTES and not of a whole message. Five seconds is far past
-- anything a notification takes to arrive in full; hitting it means the
-- connection is in trouble, and the read then reports so.
local NOTIFICATION_READ_BOUND = 5

local function count(db, sql, ...)
  local row = db:one(sql, ...)
  return row and tonumber(row.n) or 0
end

-- ------------------------------------------------------------- the required half

-- Insert, notify and count, in one statement. The count in the subquery runs
-- against the statement's snapshot, which does not include the row this same
-- statement inserted -- Postgres defines a data-modifying CTE's effect as
-- invisible to the rest of its statement -- hence the `+ 1`.
--
-- `pg_notify` is a function call rather than a `NOTIFY` statement so it can
-- take the channel as a parameter; the channel is `md5` of the key because a
-- channel is an identifier, and an identifier is at most 63 bytes while a
-- queue name is whatever the caller wrote. Hashed, every key fits and none
-- needs quoting.
local ENQUEUE = [[
with queued as (
  insert into akkar_jobs (queue, state, body, run_at)
  values ($1, 'ready', $2, clock_timestamp())
  returning id
)
select pg_notify('akkar_jobs_' || md5($1), '') as woken,
       (select count(*)::int from akkar_jobs
         where queue = $1 and state = 'ready') + 1 as n
from queued
]]

function Store:enqueue(key, encoded)
  return count(self.db, ENQUEUE, key, encoded)
end

-- The at-most-once pop: the same `FOR UPDATE SKIP LOCKED` scan the lease
-- uses, inside a `DELETE`, so the job is gone the moment it is read. One
-- statement, therefore one transaction, therefore atomic.
local DEQUEUE = [[
with next as (
  select id from akkar_jobs
   where queue = $1 and state = 'ready'
   order by run_at, id
   limit 1
   for update skip locked
)
delete from akkar_jobs j using next where j.id = next.id
returning j.body
]]

--- Waits until the socket says something arrived, or `seconds` pass.
---
--- The wait is a `cqueues.poll` on the connection's own descriptor rather
--- than a read with a timeout, and the difference matters: a poll that times
--- out has consumed NOTHING, so the connection is exactly where it was. A
--- read that timed out half-way through a message would leave the protocol at
--- an offset nobody knows, which is the shape of defect `akkar/db.lua` calls
--- "finished" and marks broken.
---
--- Only after the poll reports readable is a message read, and that read is
--- bounded too -- see `NOTIFICATION_READ_BOUND`.
local function wait_for_notification(self, key, seconds)
  local pg = self.db.pg
  local channel = self:channel(key)
  if not self.listening[channel] then
    -- Session state. It lives on this connection and dies with it, which is
    -- why the store keeps a connection rather than borrowing one per call.
    self.db:exec('listen "' .. channel .. '"')
    self.listening[channel] = true
  end

  -- Marked in flight for the duration, for the same reason `Db:query` marks
  -- a query: a coroutine abandoned mid-wait must not hand this connection to
  -- a pool with a notification half-read on its socket.
  --
  -- A TIMED-OUT POLL IS TRUTHY, and reading it as a boolean cost a broken
  -- connection on every idle wait.
  --
  -- `cqueues.poll` returns THE OBJECTS THAT ARE READY, and a number in its
  -- argument list is a timeout rather than a thing to watch -- so when the
  -- timeout is what fired, poll hands back that number. `0.3` is not `nil`,
  -- so `if not readable` never ran and every wait that found nothing went on
  -- to read a message that was not coming. The read hit its own bound and
  -- reported `failed to get type: 110` -- ETIMEDOUT -- which this function
  -- then correctly diagnosed as a connection that had died mid-message, and
  -- marked it broken. An idle queue destroyed its own connection.
  --
  -- Measured rather than reasoned about: polling a live socket with nothing
  -- to say returns `0.3` for a 0.3-second timeout, and `select('#', ...)`
  -- says one value, not zero.
  --
  -- So the pollable is built once and the answer is compared to IT. Identity,
  -- not truthiness: the only value that means "the socket has something" is
  -- the object that was asked about.
  local pollable = { pollfd = pg.sock.sock:pollfd(), events = "r" }
  self.db.in_flight = true
  local ready = cqueues.poll(pollable, seconds)
  if ready ~= pollable then
    self.db.in_flight = false
    return false
  end

  local previous = pg.sock.sock:timeout()
  pg:settimeout(NOTIFICATION_READ_BOUND * 1000)
  local note, err = pg:wait_for_notification()
  pg.sock.sock:settimeout(previous)
  self.db.in_flight = false

  if not note then
    -- Bytes were promised and a message never completed: the protocol is at
    -- an unknown offset and the connection is finished. Said so, the same
    -- way a transport failure inside a query is.
    self.db.broken = true
    error("akkar.jobs.postgres: the connection failed while waiting for a " ..
          "notification: " .. tostring(err), 0)
  end
  return true
end

--- Runs `attempt` until it answers, or until `timeout` seconds have passed,
--- waking between attempts the way the driver allows.
local function until_answered(self, key, timeout, attempt)
  local found = attempt()
  if found or not timeout or timeout <= 0 then return found end

  local deadline = cqueues.monotime() + timeout
  while true do
    local left = deadline - cqueues.monotime()
    if left <= 0 then return nil end

    if self.wakeup == "listen" then
      wait_for_notification(self, key, left)
    else
      cqueues.sleep(math.min(left, self.poll_every))
    end

    found = attempt()
    if found then return found end
  end
end

function Store:dequeue(key, timeout)
  return until_answered(self, key, timeout, function()
    local row = self.db:one(DEQUEUE, key)
    return row and row.body or nil
  end)
end

local DEPTH = "select count(*)::int as n from akkar_jobs where queue = $1 and state = $2"

function Store:depth(key)
  return count(self.db, DEPTH, key, "ready")
end

-- ------------------------------------------------------------ the optional half

local SCHEDULE = [[
with held as (
  insert into akkar_jobs (queue, state, body, run_at)
  values ($1, 'scheduled', $2, clock_timestamp() + make_interval(secs => $3))
  returning id
)
select (select count(*)::int from akkar_jobs
         where queue = $1 and state = 'scheduled') + 1 as n
from held
]]

--- Holds a job for `delay` seconds from the SERVER's now. A negative delay
--- is a job already due, which is what the specs use to stage "overdue"
--- without lying to anybody about the time.
function Store:schedule(key, encoded, delay)
  return count(self.db, SCHEDULE, key, encoded, (delay or 0) + 0.0)
end

-- Due rows become ready. Locked as they are read so two workers promoting at
-- once move disjoint sets and neither waits on the other; a row the other
-- worker is moving is simply not due for this one.
--
-- WHAT ORDER A PROMOTED JOB RUNS IN, since it differs from the other stores.
-- The memory and Redis stores push due jobs onto the back of the queue, so a
-- job due at 10:00 that a worker only noticed at 10:05 runs after a job
-- pushed at 10:03. Here a ready row is ordered by `run_at`, which for a
-- promoted row is the moment it was DUE, so that job runs first. Both are
-- FIFO among jobs pushed directly and due-order among jobs promoted together,
-- which is all the contract promises; this one additionally does not let a
-- late worker penalise the job that was waiting longest.
local PROMOTE = [[
with due as (
  select id from akkar_jobs
   where queue = $1 and state = 'scheduled' and run_at <= clock_timestamp()
   for update skip locked
), moved as (
  update akkar_jobs j set state = 'ready' from due where j.id = due.id
  returning j.id
)
select count(*)::int as n from moved
]]

function Store:promote(key)
  return count(self.db, PROMOTE, key)
end

-- Taken if the id is new, or if its previous claim has expired. `ON CONFLICT
-- DO UPDATE` locks the existing row, so two producers racing on one id are
-- serialised by Postgres and exactly one of them sees a row come back.
local CLAIM = [[
insert into akkar_job_claims (queue, id, expires_at)
values ($1, $2, clock_timestamp() + make_interval(secs => $3))
on conflict (queue, id) do update
  set expires_at = excluded.expires_at
  where akkar_job_claims.expires_at <= clock_timestamp()
returning id
]]

function Store:claim(key, id, ttl)
  return self.db:one(CLAIM, key, id, (ttl or 3600) + 0.0) ~= nil
end

local UNCLAIM = "delete from akkar_job_claims where queue = $1 and id = $2 returning id"

--- Gives a claim back. For the two-step push path only, as the other stores
--- say; `claim_and_enqueue` below rolls back instead.
function Store:unclaim(key, id)
  return self.db:one(UNCLAIM, key, id) ~= nil
end

--- Claims the id and queues the job in one transaction, so a coroutine
--- abandoned between the two -- or a push that raises -- leaves neither a
--- claim without a job nor a job without a claim.
---
--- Inside a caller's transaction this is a savepoint, which is what
--- `Db:transaction` does with nesting; the claim and the job then commit with
--- whatever the caller was doing.
function Store:claim_and_enqueue(key, id, ttl, encoded, delay)
  local duplicate = false
  local depth = self.db:transaction(function()
    if not self:claim(key, id, ttl) then
      duplicate = true
      return nil
    end
    if delay and delay > 0 then
      return self:schedule(key, encoded, delay)
    end
    return self:enqueue(key, encoded)
  end)
  if duplicate then return false, "duplicate" end
  return depth
end

-- ================================================== at-least-once delivery

-- The lease, as the Graphile Worker recipe writes it: lock the oldest ready
-- row, skipping any another worker holds, then mark it held. Two statements
-- in one transaction, and the row lock is the entire guarantee -- see the
-- module header for what happens with the clause removed, and
-- `spec/jobs_postgres_spec.lua` for the run that shows it.
local LOCK_NEXT = [[
select id, body from akkar_jobs
 where queue = $1 and state = 'ready'
 order by run_at, id
 limit 1
 for update skip locked
]]

local HOLD = [[
update akkar_jobs set state = 'held', claimed_at = clock_timestamp()
 where id = $1
]]

--- Moves one job from the queue to the held set and returns its bytes, or
--- nil when nothing became ready within `timeout` seconds.
function Store:claim_pop(key, timeout)
  return until_answered(self, key, timeout, function()
    return self.db:transaction(function(tx)
      local row = tx:one(LOCK_NEXT, key)
      if not row then return nil end
      tx:exec(HOLD, row.id)
      return row.body
    end)
  end)
end

-- One row, by the exact bytes, like `LREM key 1`. A held row is found by its
-- body because that is the only name `akkar/jobs.lua` has for it; the held
-- set is bounded by the number of workers, so the scan is short.
local ACK = [[
with mine as (
  select id from akkar_jobs
   where queue = $1 and state = 'held' and body = $2
   limit 1
)
delete from akkar_jobs j using mine where j.id = mine.id
returning j.id
]]

function Store:ack(key, encoded)
  return self.db:one(ACK, key, encoded) ~= nil
end

-- Everything whose lease ran out, oldest first, RE-LEASED to the caller.
--
-- Stamped as they are handed over, so a second reaper arriving mid-pass finds
-- fresh leases and takes nothing, and the rows stay held until `ack` -- a
-- reaper that dies between reading and writing costs a redelivery one window
-- later rather than the job. The same shape as the other two stores, in SQL.
--
-- The cutoff is the server's clock unless the test seam supplies one, and
-- the seam moves the CUTOFF alone: the stamp written here is
-- `clock_timestamp()` whatever `now` was.
--
-- `order by` on the outer select rather than trusting the CTE's order: an
-- `UPDATE ... RETURNING` makes no promise about the order of its rows.
local function expired_sql(with_now)
  local cutoff = with_now
    and "to_timestamp($3) - make_interval(secs => $2)"
    or  "clock_timestamp() - make_interval(secs => $2)"
  local limit = with_now and "$4" or "$3"
  return ([[
with stale as (
  select id, claimed_at as was from akkar_jobs
   where queue = $1 and state = 'held' and claimed_at <= %s
   order by claimed_at, id
   limit %s
   for update skip locked
), restamped as (
  update akkar_jobs j set claimed_at = clock_timestamp()
    from stale where j.id = stale.id
  returning stale.was as was, stale.id as sid, j.body as body
)
select body from restamped order by was, sid
]]):format(cutoff, limit)
end

local EXPIRED          = expired_sql(false)
local EXPIRED_AT       = expired_sql(true)
local SWEEP_CLAIMS     = "delete from akkar_job_claims where queue = $1 and expires_at <= clock_timestamp()"

function Store:expired(key, visibility, now, limit)
  -- Housekeeping rides the reaper, which is the one chore every worker
  -- already runs: dedup ids past their ttl are dropped here, so the claims
  -- table stays the size of the live ids rather than of every id ever pushed.
  self.db:exec(SWEEP_CLAIMS, key)

  local rows
  if now then
    rows = self.db:many(EXPIRED_AT, key, (visibility or 300) + 0.0, now + 0.0,
                        limit or 500)
  else
    rows = self.db:many(EXPIRED, key, (visibility or 300) + 0.0, limit or 500)
  end
  local out = {}
  for i, row in ipairs(rows) do out[i] = row.body end
  return out
end

function Store:in_flight(key)
  return count(self.db, DEPTH, key, "held")
end

local PEEK = [[
select body from akkar_jobs
 where queue = $1 and state = 'ready'
 order by run_at, id
 limit $2
]]

--- Oldest first, matching the other stores.
function Store:peek(key, limit)
  local out = {}
  for i, row in ipairs(self.db:many(PEEK, key, limit or 100)) do out[i] = row.body end
  return out
end

-- Keeps the newest `keep`, which is what the memory and Redis stores keep.
local TRIM = [[
with kept as (
  select id from akkar_jobs
   where queue = $1 and state = 'ready'
   order by run_at desc, id desc
   limit $2
), gone as (
  delete from akkar_jobs j
   where j.queue = $1 and j.state = 'ready' and j.id not in (select id from kept)
  returning j.id
)
select count(*)::int as n from gone
]]

function Store:trim(key, keep)
  return count(self.db, TRIM, key, keep)
end

function Store:scheduled_depth(key)
  return count(self.db, DEPTH, key, "scheduled")
end

--- The `LISTEN` channel for a key: `akkar_jobs_` and the md5 of the key,
--- computed by the server so it is the same md5 `enqueue` notifies on.
function Store:channel(key)
  local channel = self.channels[key]
  if not channel then
    channel = self.db:one("select 'akkar_jobs_' || md5($1) as channel", key).channel
    self.channels[key] = channel
  end
  return channel
end

-- ================================================================ constructors

-- Does this handle's driver hand notifications to Lua? pgmoon does, through
-- `wait_for_notification` on a cqueues socket this store can poll. The C
-- driver's shim has neither, and any other handle -- `akkar.db.memory`, a
-- fake -- is polled too rather than guessed at.
local function can_listen(db)
  local pg = db.pg
  if type(pg) ~= "table" or type(pg.wait_for_notification) ~= "function" then
    return false
  end
  -- The cqueues socket is a userdata, so it is asked for its `pollfd` rather
  -- than checked for a type.
  local sock = type(pg.sock) == "table" and pg.sock.sock
  return sock ~= nil and type(sock.pollfd) == "function"
end

--- Builds a bare store over a database handle, for handing to `jobs.new`.
---
--- `db` is a CONNECTION -- something with `:one`, `:many`, `:exec` and
--- `:transaction` -- and not the factory `akkar.db.connect` returns, for the
--- reason `akkar.migrate` gives about its own handle: `LISTEN` is session
--- state, and a session that goes back to a pool between calls takes its
--- subscriptions with it. Checked here so the failure names this call rather
--- than the first query.
---
--- `options.poll_every` sets the polling interval used when the driver cannot
--- listen; it is ignored when it can.
function M.store(db, options)
  if type(db) ~= "table" then
    error("akkar.jobs.postgres: expected a database handle, got " .. type(db), 2)
  end
  for _, method in ipairs { "one", "many", "exec", "transaction" } do
    if type(db[method]) ~= "function" then
      error("akkar.jobs.postgres: this is not a database handle; missing :" ..
            method .. ". A connection factory is not a connection -- call it " ..
            "first, and hand the store the connection it returns", 2)
    end
  end
  options = options or {}
  return setmetatable({
    db = db,
    wakeup = can_listen(db) and "listen" or "poll",
    poll_every = options.poll_every or DEFAULT_POLL_EVERY,
    listening = {},
    channels = {},
  }, Store)
end

--- Builds a queue on this store. `options` is forwarded whole to `jobs.new`,
--- for the reason recorded on the other two constructors: a retry policy
--- that never reaches the queue is a retry policy that configures nothing.
function M.new(db, name, options)
  return jobs.new(M.store(db, options), name, options)
end

M.Store = Store
return M
