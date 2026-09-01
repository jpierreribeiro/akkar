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

    store:schedule(key, encoded, delay)   -- hold for this many seconds
    store:promote(key, now)               -- move what is due into the queue
    store:claim(key, id, ttl)             -- false if this id was seen already
    store:unclaim(key, id)                -- give a claim back
    store:peek(key, limit)                -- read without removing
    store:trim(key, keep)                 -- cap a list's length

    store:claim_pop(key, timeout)         -- take a job AND hold it in flight
    store:ack(key, encoded)               -- done with it; false if it was not ours
    store:expired(key, visibility, now, limit)  -- what ran out of time
    store:in_flight(key)                  -- how many are held

Optional, because a store that cannot hold a job until Tuesday is still a
useful store. But they are not optional *silently*: asking for retries with
backoff, or for a delay, or for an idempotency key against a store that
cannot do it is an error at the call rather than a feature that quietly does
nothing.

The last four are the delivery guarantee, and they come as a set: a store that
leases without expiring holds jobs for ever, which is worse than not leasing
at all.

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
moves to a processing list, `ack` retires it, and anything still in flight
after `visibility` seconds is put back for another worker. So a worker that is
SIGKILLed, OOM-killed or unplugged mid-handler costs a redelivery instead of
the job -- but a worker that is merely SLOW, still working past its visibility
timeout, also costs a redelivery, and then the same job is running twice at
once. Set `visibility` above your slowest handler; the default is five minutes
for that reason and not because five minutes is precise.

    local queue = jobs.new(store, "email", {
      visibility = 300,        -- seconds a worker may hold a job
      max_redeliveries = 5,    -- then the dead letters
      reap_every = 30,         -- how often a worker looks for lost jobs
    })

**And the guarantee is named rather than inferred.** Leasing used to be on
wherever the store could do it and silently off where it could not, so a
caller could end up at AT-MOST-ONCE by accident -- and at-most-once is not a
configuration anybody picks on purpose. It means a worker killed mid-handler
loses paid work with nothing anywhere recording that the job existed. So:

  * `delivery = "at_least_once"` over a store that cannot lease is REFUSED at
    construction. Accepting the setting and delivering at most once anyway is
    the one outcome worse than not offering it.
  * `delivery = "at_most_once"` buys the old behaviour back, out loud.
  * A store that cannot lease still builds a queue, and that queue says
    `delivery == "at_most_once"` rather than claiming otherwise.

### How the two halves compose, because they are not the same tool

The dedup id above stops a second PUSH. It does nothing about a redelivery,
because a redelivery never goes through `push` -- it is the same job, with the
same id, coming back around. The two solve different problems and a caller
generally needs both:

    push id   -- two producers, one job      (this module handles it)
    job.uid   -- one job, two runs           (the handler has to handle it)

Every job carries `uid`, and it is stable across every retry and every
redelivery of that job. It is therefore the key to write an "already did this"
marker under -- a unique index, a row in a `processed` table, an
`akkar.idempotency` record -- inside the same transaction as the side effect.
That is what makes a handler safe to run twice; nothing else does, and until
`uid` existed this module documented the hazard without offering the key.
]]

local cjson = require "akkar.json"

local Queue = {}
Queue.__index = Queue

local time   = require "akkar.time"
local random = require "akkar.random"
local crypto = require "akkar.crypto"

local M = {}

-- THE ONE NAME A HANDLER CAN DEDUP ON, and it is not decoration.
--
-- This module's whole answer to "your handler will sometimes run twice" is
-- "write an already-did-this marker and check it". That answer needs a key,
-- and until now there was none to offer. `job.id` is optional and supplied by
-- the CALLER, so most jobs have none; `job.attempts` changes on every retry;
-- the encoded bytes change the moment anything is written into the job. A
-- guarantee of at-least-once delivery with no stable identity is a guarantee
-- the caller cannot act on.
--
-- `uid` is minted once, in `push`, and carried through every re-encode: a
-- retry, a redelivery, a burial. It is therefore the key to write that marker
-- under -- a unique index, a row in a `processed` table, an
-- `akkar.idempotency` record -- inside the same transaction as the side
-- effect.
--
-- Through `akkar.crypto` rather than `akkar.random`, and the two are not
-- interchangeable here. `akkar.random` exists to be REPLAYABLE: seed it and
-- it draws the same sequence twice, which is right for the backoff jitter
-- below and catastrophic for an identity, because two workers replaying the
-- same seed would mint the same uid for different jobs. `akkar/random.lua`
-- says so itself: "if being able to GUESS the value matters, this is the
-- wrong module".
local function unique_id()
  return crypto.token(12)
end

-- Exponential backoff with full jitter.  The jitter is not decoration: a
-- hundred jobs that failed against a database which has just come back will
-- otherwise all retry on the same second and knock it over again.  "Full"
-- jitter -- a uniform draw across the whole interval rather than a wobble
-- around its end -- is the variant that measured best among the simple
-- strategies, and it costs one line.
-- THE SHAPE, and why there are three names for two numbers.
--
-- This used to compute `base ^ attempt`, which cannot express the schedule
-- almost every retrying system actually uses: a FIRST delay, doubling. Porting
-- a webhook dispatcher whose original is "one minute, doubling, capped at four
-- hours" left two choices, and both were wrong -- `base = 2` retries a
-- customer's dead endpoint after two seconds, and `base = 60` goes 60s, then
-- an hour, then two and a half days.
--
-- The general form is `first * factor ^ (attempt - 1)`, and `base` still means
-- exactly what it meant: defaulting both `first` and `factor` to it reproduces
-- `base ^ attempt` for every value, so no existing configuration moves by a
-- microsecond.
--
--     {}                        -> 2, 4, 8, 16      (unchanged)
--     { base = 3 }              -> 3, 9, 27         (unchanged)
--     { first = 60, factor = 2 } -> 60, 120, 240    (the one that was missing)
local function delay_for(attempt, backoff)
  local base   = backoff.base or 2
  local first  = backoff.first or base
  local factor = backoff.factor or base
  local max    = backoff.max or 300
  local window = math.min(max, first * factor ^ (attempt - 1))
  if backoff.jitter == false then return window end
  -- Through `akkar.random` rather than `math.random`, so a seeded run picks
  -- the same jitter twice. Jitter is exactly what this module is for: it has
  -- to be SPREAD OUT so a thundering herd of retries does not land together,
  -- and it does not have to be unguessable.
  return random.float() * window
end

local function supports(store, method)
  return type(store[method]) == "function"
end

-- A store that can hold a job while a handler runs it. ALL FOUR OR NONE: a
-- lease with no reaper behind it is a job that disappears permanently instead
-- of temporarily, which is a worse failure than the one leasing was meant to
-- fix. This used to ask for `claim_pop` and `ack` alone, which is the half of
-- the set that takes a job out of circulation without the half that puts it
-- back.
local function can_lease(store)
  for _, method in ipairs { "claim_pop", "ack", "expired", "in_flight" } do
    if not supports(store, method) then return false end
  end
  return true
end

-- Five minutes, matching the backoff cap, and chosen from what this library
-- says jobs are FOR: `akkar.work` gives "a report, an image, an email" as the
-- motivating examples, and building a report takes minutes. A visibility
-- shorter than the handler redelivers work that is still running.
local DEFAULT_VISIBILITY = 300

-- How many in-flight entries one reaper pass handles. A pass is repeatable, so
-- the only thing this bounds is how long a single pass can block the worker
-- that ran it; an in-flight list longer than this means a great many workers
-- died at once, and recovering them 500 at a time is fine.
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

  -- THE GUARANTEE IS NAMED, and it used to be inferred and never said.
  --
  -- Leasing was on wherever the store could do it and silently off where it
  -- could not, which reads like a sensible default and is the wrong shape: it
  -- makes AT-MOST-ONCE something a caller can end up with by accident. Nobody
  -- picks at-most-once on purpose -- it means a worker killed mid-handler
  -- loses paid work with nothing anywhere recording that the job existed -- so
  -- it has to be asked for by name, and asking for at-least-once over a store
  -- that cannot do it has to be refused rather than quietly downgraded.
  local delivery = options.delivery
  if delivery and delivery ~= "at_least_once" and delivery ~= "at_most_once" then
    error("akkar.jobs: delivery must be 'at_least_once' or 'at_most_once', " ..
          "not '" .. tostring(delivery) .. "'", 2)
  end
  if delivery == "at_least_once" and not can_lease(store) then
    error("akkar.jobs: at-least-once delivery needs a store that can hold a " ..
          "job in flight, and this one implements no :claim_pop -- accepting " ..
          "the setting and delivering at most once anyway is the silent " ..
          "degradation this module exists to avoid", 2)
  end
  local leasing = can_lease(store) and delivery ~= "at_most_once"

  local visibility = options.visibility or DEFAULT_VISIBILITY

  return setmetatable({
    store = store,
    key = "akkar:queue:" .. (name or "default"),
    -- The EXACT bytes each in-flight job was stored as, keyed on the decoded
    -- job and held weakly. Acknowledging re-encodes otherwise, and a table
    -- does not promise to serialise the same way twice -- so a job could be
    -- acknowledged with a string that does not match the one in the
    -- processing set, silently leaving it to be reaped and run again. Weak
    -- keys because a job the caller drops -- which is precisely the case this
    -- module is about -- must not pin its encoded form for the life of the
    -- process.
    _claimed = setmetatable({}, { __mode = "k" }),
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
    -- that touches it would be redelivered for ever, taking the fleet down one
    -- process at a time. Five means a poison pill is out of circulation after
    -- five casualties, and a rolling restart that catches the same job twice
    -- does not bury healthy work.
    max_redeliveries = options.max_redeliveries or 5,
    -- The automatic reap inside `pop` costs a read. Unthrottled, a
    -- `timeout = 0` consume loop pays it on every iteration for a job that
    -- cannot come due more than once per visibility window anyway.
    reap_every = options.reap_every or math.max(1, math.floor(visibility / 10)),
    -- Now, not zero: the first automatic reap is `reap_every` seconds into
    -- this queue's life rather than on its first `pop`. A process that pops
    -- once and exits -- a one-shot script, a test -- is not a worker, and
    -- making it recover the whole fleet's abandoned jobs before it has done
    -- any of its own is work nobody asked that process to do.
    last_reap = time.now(),
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

  if options.id and not supports(self.store, "claim") then
    error("akkar.jobs: this store cannot deduplicate -- it implements no " ..
          ":claim, and taking the id while ignoring it would be worse than " ..
          "refusing it", 2)
  end

  local delayed = options.delay and options.delay > 0
  if delayed and not supports(self.store, "schedule") then
    error("akkar.jobs: this store cannot delay a job; it implements no " ..
          ":schedule", 2)
  end

  local encoded = cjson.encode {
    id = options.id,
    -- Minted here and never again. See `unique_id` at the top of this file:
    -- it is the only field of a job that is both present on every job and
    -- unchanged by every retry and redelivery, which is what makes it the
    -- key a handler can dedup on.
    --
    -- It also, incidentally, ends a defect in the Redis store: `ZADD` makes
    -- the ENCODED JOB the sorted-set member, so two byte-identical jobs due
    -- in the same second were one member -- a customer double-clicking
    -- "email me the receipt" got one email, and a hundred jobs failing
    -- against a database that had just come back merged into a single retry.
    -- The memory store appends to a list and did not collapse them, so the
    -- two backends disagreed about how many jobs existed. Fixed here rather
    -- than in the store, because uniqueness is a property of a job and a fix
    -- in one store would have left the other still disagreeing.
    uid = unique_id(),
    kind = kind,
    payload = payload,
    queued_at = time.now(),
    attempts = 0,
  }

  -- A DELAY, NOT A DEADLINE. The store computes the absolute time from its
  -- own clock, because a timestamp computed here is this worker's opinion and
  -- a fleet has several. See the header of `akkar/jobs/redis.lua`.
  local delay = delayed and options.delay or 0

  -- CLAIMING AND PUSHING ARE ONE STEP where the store can do it.
  --
  -- As two calls, a coroutine abandoned between them -- a request deadline
  -- firing, which is ordinary -- left the id claimed for the full ttl with no
  -- job anywhere. Every retry for the next hour is then refused as a
  -- duplicate, about a job that was never queued. The mechanism that exists
  -- to make a retry safe was the thing that made it useless.
  if options.id and supports(self.store, "claim_and_enqueue") then
    return self.store:claim_and_enqueue(self.key, options.id,
                                        options.id_ttl or 3600, encoded, delay)
  end

  -- The two-step path, kept for a store that implements `claim` and not
  -- `claim_and_enqueue`. The window above is open here, and it is open in
  -- the direction of losing the job rather than running it twice.
  --
  -- AND THE FAILURE PATH HAS TO GIVE THE ID BACK. The claim is taken BEFORE
  -- the job exists, which is the only order that closes the race between two
  -- producers -- so an enqueue that raises leaves an id held for the full ttl
  -- about a job that was never queued, and every retry for the next hour is
  -- answered "duplicate". The mechanism that exists to make a retry safe was
  -- the thing that made it useless.
  --
  -- Only on this path. The atomic path above needs nothing of the sort and
  -- must not have it: there the claim and the push are one step, so either
  -- both happened or neither did, and releasing after a lost REPLY would give
  -- away an id whose job is sitting in the queue.
  local function release()
    if options.id and supports(self.store, "unclaim") then
      pcall(function() return self.store:unclaim(self.key, options.id) end)
    end
  end

  if options.id then
    if not self.store:claim(self.key, options.id, options.id_ttl or 3600) then
      return false, "duplicate"
    end
  end

  local ok, result = pcall(function()
    if delayed then
      return self.store:schedule(self.key, encoded, delay)
    end
    return self.store:enqueue(self.key, encoded)
  end)
  if not ok then release() error(result, 0) end
  return result
end

--- Waits for one job, up to `timeout` seconds.  Returns nil on timeout.
---
--- Takes the RELIABLE path when the store offers one: the job moves to a
--- processing set as it leaves the queue, in one step, and stays there until
--- it is acknowledged. A worker that dies holding it leaves it recoverable
--- rather than gone. See `Queue:consume` and `Queue:reap`.
function Queue:pop(timeout)
  -- Anything whose time has come joins the queue before we look at it.
  if supports(self.store, "promote") then
    self.store:promote(self.key)
  end
  self:_maybe_reap()

  local encoded
  if self.leasing then
    encoded = self.store:claim_pop(self.key, timeout or 5)
  else
    encoded = self.store:dequeue(self.key, timeout or 5)
  end
  if not encoded then return nil end
  local ok, job = pcall(cjson.decode, encoded)
  if not ok then
    -- DISCARDED MEANS DISCARDED, and for one commit it did not.
    --
    -- On the reliable path `claim_pop` has already moved these bytes into the
    -- processing set, so returning here without removing them left the entry
    -- checked out with nobody holding it: `ack` needs a decoded job to find
    -- the bytes, and `reap` pushes stale entries BACK to the queue. The result
    -- was a poison cycle -- queue, processing, reap, queue -- with a log line
    -- claiming the thing had been discarded.
    --
    -- Worse than the old behaviour, which at least lost it once. A message
    -- that describes what the code used to do is how a defect hides.
    -- Kept rather than dropped: bytes nobody can decode are exactly what
    -- somebody will need to look at, and a dead-letter queue is where this
    -- module already puts work it cannot finish. Written BEFORE the lease is
    -- given back, for the same reason every other path writes the next copy
    -- first.
    if self.dead_letter then
      pcall(function() return self.store:enqueue(self:dead_key(), encoded) end)
    end
    if self.leasing then
      pcall(function() return self.store:ack(self.key, encoded) end)
    end
    return nil, "akkar.jobs: undecodable job discarded"
  end
  if self.leasing then self._claimed[job] = encoded end
  return job
end

function Queue:depth()
  return self.store:depth(self.key)
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

-- The one dead-letter path. Both callers -- a handler that ran out of retries
-- and a job that outlived too many workers -- come through here, so there is
-- one place where "finally failed" is written down and one place that has to
-- be capped.
local function bury(queue, encoded)
  if not queue.dead_letter then return "dropped" end
  queue.store:enqueue(queue:dead_key(), encoded)

  -- An unbounded dead-letter queue is a memory leak with a respectable name.
  if supports(queue.store, "trim") then
    queue.store:trim(queue:dead_key(), queue.max_dead)
  end
  return "buried"
end

-- Gives the in-flight record back. Always called AFTER the job's next copy
-- exists somewhere else -- scheduled, buried, dead-lettered -- and never
-- before: a crash in that window then costs a REDELIVERY, which is what this
-- queue promises, rather than the JOB, which is what it promises not to.
function Queue:_release(job)
  if not self.leasing then return end
  local encoded = self._claimed[job]
  if not encoded then return end
  self._claimed[job] = nil
  return self.store:ack(self.key, encoded)
end

--- Puts a failed job back after its backoff, or buries it.
--- Returns "retried", "buried" or "dropped", plus the delay when retried.
---
--- Releases the lease as its last act, so a failed job is never both
--- scheduled and in flight -- that pair is two copies of one job, delivered a
--- backoff apart.
function Queue:fail(job, err)
  job.attempts = (job.attempts or 0) + 1
  job.last_error = tostring(err)
  job.first_failed_at = job.first_failed_at or time.now()

  if job.attempts <= self.retries then
    local delay = delay_for(job.attempts, self.backoff)
    self.store:schedule(self.key, cjson.encode(job), delay)
    self:_release(job)
    return "retried", delay
  end

  job.died_at = time.now()
  local outcome = bury(self, cjson.encode(job))
  self:_release(job)
  return outcome
end


--- True when this queue can survive a worker dying mid-job.
---
--- Worth asking rather than assuming: the answer decides whether a job that
--- matters may go through here at all. It now answers what this queue DOES
--- rather than what its store could do, because `delivery = "at_most_once"`
--- makes those two different questions.
function Queue:reliable()
  return self.delivery == "at_least_once"
end

--- Marks a job finished, so it stops being recoverable.
---
--- Called by `consume` after the handler returns. Returns false when the lease
--- had already expired and the job was handed to somebody else -- meaning this
--- run was a duplicate, and `visibility` is shorter than the handler's real
--- runtime. True under at-most-once delivery, where there was never anything
--- to retire.
function Queue:ack(job)
  if not self.leasing then return true end
  local encoded = self._claimed[job]
  -- No record means no lease: either this job never came from `pop`, or it has
  -- already been released. Re-encoding to guess at the bytes is worse than
  -- saying so -- a table does not promise to serialise the same way twice, so
  -- the guess would sometimes name somebody else's entry.
  if not encoded then return false end
  self._claimed[job] = nil
  return self.store:ack(self.key, encoded)
end

--- Returns to the queue every job whose worker stopped answering, and buries
--- the ones that have outlived too many workers.
---
--- Returns how many were redelivered and how many were buried.
---
--- `now` IS A TEST SEAM, NOT THE PRODUCTION PATH. Leave it out and the store
--- answers with the clock every worker shares -- the Redis server's own
--- `TIME`, read inside the script. That is the whole clock fix and it must
--- stay the default: a cutoff computed by ONE worker made every reap an
--- assertion about time made by a machine that might have just been stepped by
--- NTP, so a correction forwards reclaimed jobs other workers were actively
--- running, and a correction backwards reclaimed nothing ever again.
--- `spec/clock_spec.lua` holds both directions.
---
--- Pass `now` only where waiting out a `visibility` window is not an option --
--- a spec, an operator draining a queue by hand. What decides staleness is
--- `visibility`, which is the queue's configuration rather than the caller's
--- opinion, and it must exceed the longest a handler may legitimately take:
--- set it too low and a slow job is run twice while the first attempt is still
--- going.
function Queue:reap(now)
  if not self.leasing then return 0, 0 end
  self.last_reap = time.now()

  local redelivered, buried = 0, 0
  local expired = self.store:expired(self.key, self.visibility, now, REAP_BATCH)

  for _, encoded in ipairs(expired) do
    local ok, job = pcall(cjson.decode, encoded)
    if not ok then
      -- Bytes nobody can decode, holding a lease that keeps coming back. The
      -- dead letters are where everything else this module cannot finish goes.
      pcall(function() return bury(self, encoded) end)
      pcall(function() return self.store:ack(self.key, encoded) end)
    else
      job.redeliveries = (job.redeliveries or 0) + 1

      -- COUNTED APART FROM `attempts`, on purpose. `attempts` is the handler
      -- saying no; a worker being OOM-killed is not the handler saying
      -- anything, and charging a redelivery to the retry budget would bury
      -- healthy work after a deploy that restarted the fleet three times.
      if job.redeliveries > self.max_redeliveries then
        job.last_error = "the worker holding this job stopped answering, " ..
                         job.redeliveries .. " times in a row"
        job.died_at = time.now()
        bury(self, cjson.encode(job))
        buried = buried + 1
      else
        self.store:enqueue(self.key, cjson.encode(job))
        redelivered = redelivered + 1
      end
      -- Only now, with the next copy already written.
      self.store:ack(self.key, encoded)
    end
  end

  return redelivered, buried
end

-- The reaper runs off the back of `pop` rather than from a thread of its own:
-- a queue that needs a separate janitor process to be correct is a queue that
-- is incorrect on every deployment that forgot to run one. Any worker
-- consuming from a queue is also recovering it.
--
-- Wrapped, because the store is a network and a blip in a chore must not
-- unwind the worker loop that called it.
function Queue:_maybe_reap()
  if not self.leasing then return end
  local now = time.now()
  if now - self.last_reap < self.reap_every then return end
  self.last_reap = now
  pcall(self.reap, self)
end

--- How many jobs are currently checked out by a worker. Zero under
--- at-most-once delivery, where nothing is ever held.
function Queue:in_flight()
  if not self.leasing then return 0 end
  return tonumber(self.store:in_flight(self.key)) or 0
end

-- `fail` writes to the store, and the store is a network. Called bare, a blip
-- there unwound the whole consume loop -- carrying the job in hand with it --
-- so one flaky moment stopped the worker entirely rather than costing one job.
-- Reported and survived instead.
local function settle(queue, job, err, log)
  local ok, outcome, delay = pcall(queue.fail, queue, job, err)
  if ok then return outcome, delay end
  if log then
    -- Under leasing the lease is still held, so this job comes back when it
    -- expires instead of vanishing. That is the difference the in-flight list
    -- buys on the one path where the store is already misbehaving.
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
---
--- **AT LEAST ONCE unless this queue was told otherwise, and `queue.delivery`
--- says which one you have.**
---
--- Under at-least-once delivery a job moves to a processing set as it leaves
--- the queue, in one step, and is acknowledged only after the handler has
--- finished or its failure has been retried or buried. A worker killed in
--- between leaves the job recoverable: it goes back to the queue once its
--- `visibility` window runs out and some worker reaps it.
---
--- The reaper runs off the back of `pop`, so any worker consuming from a queue
--- is also recovering it and there is no janitor process to forget to deploy.
--- A job whose worker was killed is therefore back within
--- `visibility + reap_every` seconds and not before, because there is no way
--- to tell a dead worker from a slow one except by waiting.
---
--- Under `delivery = "at_most_once"` -- which has to be asked for by name --
--- `pop` is destructive, so between it and the handler finishing the job
--- exists only in this worker's memory, and an ordinary deploy loses it
--- silently. The retry policy does not cover that: retries are for a handler
--- that RAISED, and a worker that died raised nothing.
---
--- At-least-once means a handler can run twice. That is the trade, and it is
--- the right way round: a job run twice is visible and fixable with a marker
--- written under `job.uid`, and a job silently lost is neither.
function Queue:consume(handlers, options)
  options = options or {}
  local log = options.log
  local should_stop = options.should_stop or function() return false end
  local handled, failed, retried, buried, duplicated = 0, 0, 0, 0, 0

  -- AN EMPTY POLL THAT DID NOT WAIT MUST WAIT HERE, or this loop is a spin.
  --
  -- `timeout = 0` tells the STORE not to block. Against Redis that never
  -- mattered: `BRPOP` waits server-side and yields the coroutine while it
  -- does, so the loop was paced by the store. Against the in-memory store
  -- `pop(0)` returns immediately, and the loop had nothing to yield to --
  -- 99.9% of a core, and the server it shares a process with stops answering
  -- entirely.
  --
  -- Measured: a probe designed to finish in one second did not finish in
  -- sixty, because the spinning consumer starved even the controller's own
  -- timeout.
  --
  -- Found by an agent writing a recipe for an in-process worker, and it is
  -- the exact shape `App:task`'s docstring suggests -- so the framework was
  -- recommending it. `spec/task_spec.lua` used it too and passed, because a
  -- test that exits as soon as its job is consumed never notices a spin.
  --
  -- The wait belongs here rather than in the store: a store honouring
  -- `timeout = 0` is behaving correctly, and the caller who asked for it
  -- wants a poll loop, not a busy loop. `idle` is how long an empty turn
  -- costs, and only an EMPTY turn pays it -- a queue with work in it runs
  -- flat out.
  local idle = options.idle or 0.05
  local store_waits = (options.timeout or 1) > 0

  while not should_stop() do
    local job, decode_error = self:pop(options.timeout or 1)

    if not job and not decode_error and not store_waits and not should_stop() then
      time.sleep(idle)
    end
    if decode_error and log then
      log:warn("jobs: discarded an undecodable job")
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
          -- AFTER the handler, never before. The whole point is that a worker
          -- dying between the two leaves the job recoverable.
          --
          -- A failed ack is not an error: the handler did its work. It means
          -- the lease had already expired and this job is running somewhere
          -- else too -- the one symptom of a `visibility` set below the
          -- handler's real runtime, and otherwise completely invisible.
          if not self:ack(job) then
            duplicated = duplicated + 1
            if log then
              log:warn("jobs: finished a job whose lease had already expired; " ..
                       "it is being run twice", {
                kind = job.kind, uid = job.uid, visibility_s = self.visibility,
              })
            end
          end
        else
          failed = failed + 1
          -- `fail` releases the lease itself, once the retry or the burial is
          -- written: this attempt is finished even though the work is not.
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
