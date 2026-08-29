--[[
akkar.jobs — the semantics of a job queue, with no storage in it.

The split follows `druse-crystals`, where `jobs` holds the logic and
`jobs_postgres` holds only persistence. Reading that code, the shape is
explicit: "a store reads it, hands it to `settle`, and writes back what it
gets."

`akkar.work.queue` had the two fused. The semantics of a job -- what one is,
what happens when a handler fails, what a worker loop does -- are logic, and
Redis was only where they happened to live. Fused, a Postgres-backed queue
could not exist without reimplementing the semantics alongside it, and the two
would then be free to disagree.

## What a store must provide

    store:enqueue(key, encoded)   -- append; returns the new depth
    store:dequeue(key, timeout)   -- oldest entry, or nil on timeout
    store:depth(key)              -- how many are waiting

Three methods, and everything a job queue needs beyond that is semantics and
belongs here.

## What a store MAY provide, and what it buys

    store:schedule(key, encoded, run_at)  -- hold until a wall-clock time
    store:promote(key, now)               -- move what is due into the queue
    store:claim(key, id, ttl)             -- false if this id was seen already
    store:unclaim(key, id)                -- give a claim back
    store:peek(key, limit)                -- read without removing
    store:trim(key, keep)                 -- cap a list's length

    store:lease(key, timeout, visibility) -- take a job AND hold it in flight
    store:ack(key, encoded)               -- done with it; 1 if it was still ours
    store:expired(key, now, visibility, limit)  -- claim what ran out of time
    store:in_flight_depth(key)            -- how many are held

Optional, because a store that cannot hold a job until Tuesday is still a
useful store. But they are not optional *silently*: asking for retries with
backoff, or for a delay, or for an idempotency key against a store that
cannot do it is an error at the call rather than a feature that quietly does
nothing.

The last four are the delivery guarantee, and they come as a set: a store
that leases without expiring holds jobs forever, which is worse than not
leasing at all.

## Retries, and why they were absent for so long

This module used to log a failing job and drop it, with a comment defending
the choice: "a retry policy nobody chose is worse than none -- it hides the
failure and repeats whatever side effects already happened."

That was right about the danger and wrong about the conclusion. The danger is
a policy nobody chose, so the fix is to make the choice explicit rather than
to remove the capability. Retries are **off unless asked for**:

    local queue = jobs.new(store, "email", {
      retries = 3,                       -- attempts after the first
      backoff = { base = 2, max = 300 }, -- 2s, 4s, 8s ... capped at five minutes
      dead_letter = true,                -- keep what finally failed
    })

`retries = 0` is the old behaviour and it is still the default. Nothing
changes for anyone who does not ask.

## Repeating side effects

A retry re-runs a handler that may already have charged a card. akkar cannot
know which half of a handler is safe to repeat, so it offers the one thing it
can: an id the store refuses to accept twice.

    queue:push("charge", { order = 41 }, { id = "charge:order:41" })

The second push returns `false, "duplicate"`. That is deduplication at the
door, which is a different thing from an idempotent handler and does not
pretend to replace one.

## What a delivery is worth, said before it is relied on

**At least once, and that means AT LEAST.** A handler here will sometimes run
twice for one job, and a caller who cannot survive that has a bug this module
cannot fix for them.

`pop` does not take a job off the queue; it takes a LEASE on one. The job
moves to an in-flight list, `ack` retires it, and anything still in flight
after `visibility` seconds is put back for another worker. So a worker that is
SIGKILLed, OOM-killed or unplugged mid-handler costs a redelivery instead of
the job -- but a worker that is merely SLOW, still working past its visibility
timeout, also costs a redelivery, and then the same job is running twice at
once. Set `visibility` above your slowest handler; the default is five
minutes for that reason and not because five minutes is precise.

This is the trade every at-least-once queue makes, stated here rather than
discovered in production: it prefers running a job twice to running it never.
`delivery = "at_most_once"` buys the old behaviour back, explicitly.

    local queue = jobs.new(store, "email", {
      visibility = 300,        -- seconds a worker may hold a job
      max_redeliveries = 5,    -- then the dead letters; see below
      reap_every = 30,         -- how often a worker looks for lost jobs
    })

A job whose worker was killed is therefore back in the queue within
`visibility + reap_every` seconds -- five and a half minutes on the defaults --
and not before, because there is no way to tell a dead worker from a slow one
except by waiting.

The reaper runs off the back of `pop`, so any worker consuming from a queue is
also recovering it. There is no janitor process to forget to deploy. `reap`
is public for anyone who wants one anyway.

Kept being reaped is a job that kills every worker that touches it, and the
answer is the one already here: after `max_redeliveries` it goes to the dead
letters, with `last_error` saying so. Counted separately from `attempts`,
because a worker being OOM-killed is not the handler saying no -- charging it
to the retry budget would bury healthy work after a deploy that restarted the
fleet three times.

### How the two halves compose, because they are not the same tool

The dedup id above stops a second PUSH. It does nothing about a redelivery,
because a redelivery never goes through `push` -- it is the same job, with the
same id, coming back around. The two solve different problems and a caller
generally needs both:

    push id   -- two producers, one job      (this module handles it)
    job.uid   -- one job, two runs           (the handler has to handle it)

Every job carries `uid`, and it is stable across every retry and every
redelivery of that job. It is therefore the key to write an "already did
this" marker under -- a unique index, a row in a `processed` table, an
`akkar.idempotency` record -- inside the same transaction as the side effect.
That is what makes a handler safe to run twice; nothing else does.
]]

local cjson = require "cjson"
local rand  = require "openssl.rand"

-- Every job carries one of these, and it is not decoration.
--
-- The Redis store schedules with `ZADD <key> <run_at> <encoded job>`, so the
-- ENCODED JOB is the sorted-set member and two byte-identical jobs due in the
-- same second are one member: a customer double-clicking "email me the
-- receipt" got one email, and a hundred jobs failing against a database that
-- had just come back merged into a single retry. The memory store, which
-- appends to a list, did not collapse them -- so the two backends silently
-- disagreed about how many jobs existed.
--
-- Fixed here rather than in the store, because uniqueness is a property of a
-- job, and a fix in one store would have left the other still disagreeing.
local function unique_id()
  return (rand.bytes(12):gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

local Queue = {}
Queue.__index = Queue

local M = {}

-- Exponential backoff with full jitter.  The jitter is not decoration: a
-- hundred jobs that failed against a database which has just come back will
-- otherwise all retry on the same second and knock it over again.  "Full"
-- jitter -- a uniform draw across the whole interval rather than a wobble
-- around its end -- is the variant that measured best among the simple
-- strategies, and it costs one line.
local function delay_for(attempt, backoff)
  local base = backoff.base or 2
  local max  = backoff.max or 300
  local window = math.min(max, base ^ attempt)
  if backoff.jitter == false then return window end
  return math.random() * window
end

local function supports(store, method)
  return type(store[method]) == "function"
end

-- A store that can hold a job while a handler runs it.  All four or none: a
-- lease with no reaper behind it is a job that disappears permanently instead
-- of temporarily, which is a worse failure than the one it was meant to fix.
local function can_lease(store)
  for _, method in ipairs { "lease", "ack", "expired", "in_flight_depth" } do
    if not supports(store, method) then return false end
  end
  return true
end

-- Five minutes, matching the backoff cap above, and chosen from what this
-- library says jobs are FOR: `akkar.work` gives "a report, an image, an
-- email" as the motivating examples, and building a report takes minutes.
-- A visibility shorter than the handler redelivers work that is still
-- running -- the same defeat-your-own-example bug the idempotency module had
-- when its 30 s claim expired under its own 31 s handler.
local DEFAULT_VISIBILITY = 300

-- How many in-flight entries one reaper pass handles.  A pass is repeatable,
-- so the only thing this bounds is how long a single pass can block the
-- worker that ran it; an in-flight list longer than this means a great many
-- workers died at once, and recovering them 500 at a time is fine.
local REAP_BATCH = 500

--- Wraps a store with the queue semantics.
function M.new(store, name, options)
  for _, method in ipairs { "enqueue", "dequeue", "depth" } do
    if type(store[method]) ~= "function" then
      error("akkar.jobs: store does not satisfy the contract; missing :" ..
            method, 2)
    end
  end

  options = options or {}
  local retries = options.retries or 0

  -- Refused at construction rather than at the first failure.  A queue that
  -- accepts a retry policy it cannot honour is the silent degradation this
  -- module exists to avoid.
  if retries > 0 and not (supports(store, "schedule") and supports(store, "promote")) then
    error("akkar.jobs: retries need a store that can schedule, and this one " ..
          "implements neither :schedule nor :promote -- a retry could only " ..
          "run immediately, which hammers whatever just failed", 2)
  end

  -- Leasing is on wherever the store can do it, and off is the thing you have
  -- to ask for.  The opposite default would have been consistent with
  -- `retries`, and wrong for the same reason the tenant namespace being
  -- opt-in was wrong: the unsafe configuration is the one nobody picks on
  -- purpose, and here it silently loses paid work when a worker is killed.
  local delivery = options.delivery
  if delivery and delivery ~= "at_least_once" and delivery ~= "at_most_once" then
    error("akkar.jobs: delivery must be 'at_least_once' or 'at_most_once', " ..
          "not '" .. tostring(delivery) .. "'", 2)
  end
  if delivery == "at_least_once" and not can_lease(store) then
    error("akkar.jobs: at-least-once delivery needs a store that can hold a " ..
          "job in flight, and this one implements no :lease -- accepting the " ..
          "setting and delivering at most once anyway is the silent " ..
          "degradation this module exists to avoid", 2)
  end
  local leasing = can_lease(store) and delivery ~= "at_most_once"

  local visibility = options.visibility or DEFAULT_VISIBILITY

  return setmetatable({
    store = store,
    key = "akkar:queue:" .. (name or "default"),
    retries = retries,
    backoff = options.backoff or {},
    dead_letter = options.dead_letter ~= false,
    max_dead = options.max_dead or 1000,

    leasing = leasing,
    -- Readable, because "what does this queue actually guarantee" is a
    -- question a caller should be able to answer without reading the store.
    delivery = leasing and "at_least_once" or "at_most_once",
    visibility = visibility,
    -- A job whose worker dies is redelivered; a job that kills every worker
    -- that touches it would be redelivered forever, taking the fleet down one
    -- process at a time.  Five means a poison pill is out of circulation after
    -- five casualties, and a rolling restart that catches the same job twice
    -- does not bury healthy work.
    max_redeliveries = options.max_redeliveries or 5,
    -- The automatic reap inside `pop` costs two reads.  Unthrottled, a
    -- `timeout = 0` consume loop pays them on every iteration for a job that
    -- cannot come due more than once per second anyway.
    reap_every = options.reap_every or math.max(1, math.floor(visibility / 10)),
    -- Now, not zero: the first automatic reap is `reap_every` seconds into
    -- this queue's life rather than on its first `pop`. The reaper is a
    -- worker's background chore, and a process that pops once and exits --
    -- a one-shot script, a test -- is not a worker; making it recover the
    -- whole fleet's abandoned jobs before it has done any of its own is
    -- surprising, and it is work nobody asked that process to do.
    last_reap = os.time(),
    -- Weak keys: a job abandoned without ack or fail -- which is precisely
    -- the case this module is about -- must not pin its encoded form here
    -- for the life of the process.
    leases = setmetatable({}, { __mode = "k" }),
  }, Queue)
end

function Queue:dead_key() return self.key .. ":dead" end

--- Enqueues a job.
---
--- `options.delay` holds it for that many seconds; `options.id` refuses it if
--- the same id was pushed within `options.id_ttl` (an hour by default).
---
--- Returns the depth after the push, or `false, "duplicate"`.
function Queue:push(kind, payload, options)
  options = options or {}

  if options.id then
    if not supports(self.store, "claim") then
      error("akkar.jobs: this store cannot deduplicate -- it implements no " ..
            ":claim, and taking the id while ignoring it would be worse than " ..
            "refusing it", 2)
    end
    if not self.store:claim(self.key, options.id, options.id_ttl or 3600) then
      return false, "duplicate"
    end
  end

  local encoded = cjson.encode {
    id = options.id,
    uid = unique_id(),
    kind = kind,
    payload = payload,
    queued_at = os.time(),
    attempts = 0,
  }

  -- The claim above is taken BEFORE the job exists, which is the only order
  -- that closes the race between two producers. So the failure path has to
  -- give it back: held through a failed enqueue, the id reported "duplicate"
  -- for the next hour about a job that was never queued.
  local function release()
    if options.id and supports(self.store, "unclaim") then
      pcall(function() self.store:unclaim(self.key, options.id) end)
    end
  end

  if options.delay and options.delay > 0 then
    if not supports(self.store, "schedule") then
      release()
      error("akkar.jobs: this store cannot delay a job; it implements no " ..
            ":schedule", 2)
    end
    local ok, result = pcall(function()
      return self.store:schedule(self.key, encoded, os.time() + options.delay)
    end)
    if not ok then release() ; error(result, 0) end
    return result
  end

  local ok, result = pcall(function()
    return self.store:enqueue(self.key, encoded)
  end)
  if not ok then release() ; error(result, 0) end
  return result
end

--- Waits for one job, up to `timeout` seconds.  Returns nil on timeout.
---
--- Under at-least-once delivery this takes a LEASE, not the job: it is yours
--- for `visibility` seconds and comes back to the queue if you do not `ack`
--- or `fail` it in that time.  `consume` does both for you.
function Queue:pop(timeout)
  -- Anything whose time has come joins the queue before we look at it.
  if supports(self.store, "promote") then
    self.store:promote(self.key, os.time())
  end
  self:_maybe_reap()

  local encoded
  if self.leasing then
    encoded = self.store:lease(self.key, timeout or 5, self.visibility)
  else
    encoded = self.store:dequeue(self.key, timeout or 5)
  end
  if not encoded then return nil end

  local ok, job = pcall(cjson.decode, encoded)
  if not ok then
    -- A job that cannot be decoded cannot be handled or retried, and leaving
    -- it at the head of the queue would stall every worker behind it forever.
    -- It used to be dropped here; under leasing dropping it is not even an
    -- option, because an unacked lease comes back and the reaper cannot tell
    -- a poison pill from a crashed worker -- it would circulate forever.
    -- So it goes where everything else that finally failed goes.
    self:_discard(encoded)
    return nil, "akkar.jobs: undecodable job moved to the dead letters"
  end

  if self.leasing then self.leases[job] = encoded end
  return job
end

function Queue:depth()
  return self.store:depth(self.key)
end

--- How many jobs are out with a worker right now.  Zero under at-most-once
--- delivery, where nothing is held.
function Queue:in_flight()
  if not self.leasing then return 0 end
  return tonumber(self.store:in_flight_depth(self.key)) or 0
end

--- Retires a job a handler finished.
---
--- Returns false when the lease had already expired and the job was handed to
--- somebody else -- meaning this run was a duplicate, and the `visibility` is
--- shorter than the handler.  True under at-most-once delivery, where there
--- was never anything to retire.
function Queue:ack(job)
  if not self.leasing then return true end
  local encoded = self.leases[job]
  if not encoded then return false end
  self.leases[job] = nil
  return tonumber(self.store:ack(self.key, encoded)) == 1
end

--- How many jobs finally failed.  A dead-letter queue nobody can measure is a
--- dead-letter queue nobody looks at.
function Queue:dead_depth()
  return self.store:depth(self:dead_key())
end

--- Reads the dead letters without removing them, when the store can.
function Queue:dead_letters(limit)
  if not supports(self.store, "peek") then
    error("akkar.jobs: this store cannot list dead letters; it implements " ..
          "no :peek", 2)
  end
  local out = {}
  for _, encoded in ipairs(self.store:peek(self:dead_key(), limit or 100)) do
    local ok, job = pcall(cjson.decode, encoded)
    if ok then out[#out + 1] = job end
  end
  return out
end

-- The one dead-letter path.  Both callers -- a handler that ran out of
-- retries and a job that outlived too many workers -- come through here, so
-- there is one place where "finally failed" is written down and one place
-- that has to be capped.
local function bury(queue, encoded)
  if not queue.dead_letter then return "dropped" end
  queue.store:enqueue(queue:dead_key(), encoded)

  -- An unbounded dead-letter queue is a memory leak with a respectable name.
  if supports(queue.store, "trim") then
    queue.store:trim(queue:dead_key(), queue.max_dead)
  end
  return "buried"
end

-- Gives back the in-flight record.  Always called AFTER the job's next copy
-- exists somewhere else -- scheduled, buried, dead-lettered -- never before:
-- a crash in that window then costs a redelivery, which is what this queue
-- promises, rather than the job, which is what it promises not to.
function Queue:_release(job)
  if not self.leasing then return end
  local encoded = self.leases[job]
  if not encoded then return end
  self.leases[job] = nil
  self.store:ack(self.key, encoded)
end

-- Bytes that are not a job: kept rather than dropped, because a queue that
-- silently eats what it cannot parse tells nobody what it ate.
function Queue:_discard(encoded)
  pcall(function() bury(self, encoded) end)
  if self.leasing then pcall(function() self.store:ack(self.key, encoded) end) end
end

--- Puts a failed job back after its backoff, or buries it.
--- Returns "retried", "buried" or "dropped", plus the delay when retried.
function Queue:fail(job, err)
  job.attempts = (job.attempts or 0) + 1
  job.last_error = tostring(err)
  job.first_failed_at = job.first_failed_at or os.time()

  if job.attempts <= self.retries then
    local delay = delay_for(job.attempts, self.backoff)
    self.store:schedule(self.key, cjson.encode(job), os.time() + delay)
    self:_release(job)
    return "retried", delay
  end

  job.died_at = os.time()
  local outcome = bury(self, cjson.encode(job))
  self:_release(job)
  return outcome
end

--- Returns to the queue every job whose worker stopped answering.
---
--- `now` is a parameter so this can be tested without waiting out a
--- visibility timeout.  Returns how many were redelivered and how many were
--- finally buried -- or dropped, when the queue was told to keep no dead
--- letters.
function Queue:reap(now)
  if not self.leasing then return 0, 0 end
  now = now or os.time()
  self.last_reap = os.time()

  local redelivered, buried = 0, 0
  local expired = self.store:expired(self.key, now, self.visibility, REAP_BATCH)

  for _, encoded in ipairs(expired) do
    local ok, job = pcall(cjson.decode, encoded)
    if not ok then
      self:_discard(encoded)
    else
      job.redeliveries = (job.redeliveries or 0) + 1

      -- Counted apart from `attempts` on purpose.  `attempts` is the handler
      -- saying no, and a worker being OOM-killed is not the handler saying
      -- anything; charging a redelivery to the retry budget would bury
      -- healthy work after a deploy that restarted the fleet three times.
      if job.redeliveries > self.max_redeliveries then
        job.last_error = "the worker holding this job stopped answering, " ..
                         job.redeliveries .. " times in a row"
        job.died_at = os.time()
        bury(self, cjson.encode(job))
        buried = buried + 1
      else
        self.store:enqueue(self.key, cjson.encode(job))
        redelivered = redelivered + 1
      end
      -- Only now, with the new copy already written.
      self.store:ack(self.key, encoded)
    end
  end

  return redelivered, buried
end

-- The reaper runs off the back of `pop` rather than from a thread of its own:
-- a queue that needs a separate janitor process to be correct is a queue that
-- is incorrect on every deployment that forgot to run one.
--
-- Wrapped, for the same reason `settle` is: the store is a network, and a
-- blip in the reaper must not unwind the worker loop that called it.
function Queue:_maybe_reap()
  if not self.leasing then return end
  if os.time() - self.last_reap < self.reap_every then return end
  pcall(self.reap, self, os.time())
end

-- `fail` writes to the store, and the store is a network. Called bare, a
-- Redis blip on the failure path unwound the whole consume loop -- carrying
-- the job in hand with it -- so one flaky moment stopped the worker entirely
-- rather than costing one job. Reported and survived instead.
local function settle(queue, job, err, log)
  local ok, outcome, delay = pcall(queue.fail, queue, job, err)
  if ok then return outcome, delay end
  if log then
    -- Under leasing the lease is still held, so this job comes back when it
    -- expires instead of vanishing.  That is the difference the in-flight
    -- list buys on the one path where the store is already misbehaving.
    log:error(queue.leasing
                and "jobs: the store could not record a failed job; it stays " ..
                    "in flight and will be redelivered"
                or  "jobs: the store could not record a failed job; it is lost", {
      kind = job.kind, detail = tostring(outcome),
    })
  end
  return nil
end

--- Consumes until `should_stop()` returns true.
function Queue:consume(handlers, options)
  options = options or {}
  local log = options.log
  local should_stop = options.should_stop or function() return false end
  local handled, failed, retried, buried, duplicated = 0, 0, 0, 0, 0

  while not should_stop() do
    local job, decode_error = self:pop(options.timeout or 1)
    if decode_error and log then
      log:warn("jobs: an undecodable job went to the dead letters")
    elseif job then
      local handler = handlers[job.kind]
      if not handler then
        -- A job with no handler is usually a deployment in progress -- a
        -- worker running older code than the producer -- so it goes through
        -- the same failure path rather than being dropped.  Dropping it
        -- loses work that finishing the deploy would have run.
        if log then log:warn("jobs: no handler", { kind = job.kind }) end
        settle(self, job,
               "no handler registered for kind '" .. tostring(job.kind) .. "'", log)
      else
        local ok, err = pcall(handler, job.payload, job)
        if ok then
          handled = handled + 1
          -- A failed ack is not an error: the handler did its work. It means
          -- the lease had already expired and this job is running somewhere
          -- else too -- the one symptom of a `visibility` set below the
          -- handler's real runtime, and otherwise invisible.
          if not self:ack(job) then
            duplicated = duplicated + 1
            if log then
              log:warn("jobs: finished a job whose lease had already expired; " ..
                       "it is being run twice", {
                kind = job.kind, visibility_s = self.visibility,
              })
            end
          end
        else
          failed = failed + 1
          local outcome, delay = settle(self, job, err, log)
          if outcome == "retried" then retried = retried + 1
          elseif outcome then buried = buried + 1 end
          if log and outcome then
            log:error("jobs: job failed", {
              kind = job.kind, attempt = job.attempts, outcome = outcome,
              retry_in_s = delay and math.floor(delay * 10) / 10 or nil,
              detail = tostring(err),
            })
          end
        end
      end
    end
  end

  return {
    handled = handled, failed = failed, retried = retried, buried = buried,
    duplicated = duplicated,
  }
end

M.Queue = Queue
M.delay_for = delay_for
return M
