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
    store:peek(key, limit)                -- read without removing
    store:trim(key, keep)                 -- cap a list's length

Optional, because a store that cannot hold a job until Tuesday is still a
useful store. But they are not optional *silently*: asking for retries with
backoff, or for a delay, or for an idempotency key against a store that
cannot do it is an error at the call rather than a feature that quietly does
nothing.

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
]]

local cjson = require "akkar.json"

local Queue = {}
Queue.__index = Queue

local time = require "akkar.time"

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

  return setmetatable({
    store = store,
    key = "akkar:queue:" .. (name or "default"),
    -- The EXACT bytes each in-flight job was stored as, keyed on the decoded
    -- job and held weakly. Acknowledging re-encodes otherwise, and a table
    -- does not promise to serialise the same way twice -- so a job could be
    -- acknowledged with a string that does not match the one in the
    -- processing set, silently leaving it to be reaped and run again. Weak
    -- keys because a job the caller drops is not our business.
    _claimed = setmetatable({}, { __mode = "k" }),
    retries = retries,
    backoff = options.backoff or {},
    dead_letter = options.dead_letter ~= false,
    max_dead = options.max_dead or 1000,
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
    kind = kind,
    payload = payload,
    queued_at = time.now(),
    attempts = 0,
  }

  local run_at = delayed and (time.now() + options.delay) or 0

  -- CLAIMING AND PUSHING ARE ONE STEP where the store can do it.
  --
  -- As two calls, a coroutine abandoned between them -- a request deadline
  -- firing, which is ordinary -- left the id claimed for the full ttl with no
  -- job anywhere. Every retry for the next hour is then refused as a
  -- duplicate, about a job that was never queued. The mechanism that exists
  -- to make a retry safe was the thing that made it useless.
  if options.id and supports(self.store, "claim_and_enqueue") then
    return self.store:claim_and_enqueue(self.key, options.id,
                                        options.id_ttl or 3600, encoded, run_at)
  end

  -- The two-step path, kept for a store that implements `claim` and not
  -- `claim_and_enqueue`. The window above is open here, and it is open in
  -- the direction of losing the job rather than running it twice.
  if options.id then
    if not self.store:claim(self.key, options.id, options.id_ttl or 3600) then
      return false, "duplicate"
    end
  end

  if delayed then
    return self.store:schedule(self.key, encoded, run_at)
  end

  return self.store:enqueue(self.key, encoded)
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
    self.store:promote(self.key, time.now())
  end

  local encoded
  if supports(self.store, "claim_pop") then
    encoded = self.store:claim_pop(self.key, timeout or 5, time.now())
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
    if supports(self.store, "ack") then
      pcall(function() return self.store:ack(self.key, encoded) end)
    end
    if self.dead_letter then
      -- Kept rather than dropped: bytes nobody can decode are exactly what
      -- somebody will need to look at, and a dead-letter queue is where this
      -- module already puts work it cannot finish.
      pcall(function() return self.store:enqueue(self:dead_key(), encoded) end)
    end
    return nil, "akkar.jobs: undecodable job discarded"
  end
  self._claimed[job] = encoded
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

--- Puts a failed job back after its backoff, or buries it.
--- Returns "retried", "buried" or "dropped", plus the delay when retried.
function Queue:fail(job, err)
  job.attempts = (job.attempts or 0) + 1
  job.last_error = tostring(err)
  job.first_failed_at = job.first_failed_at or time.now()

  if job.attempts <= self.retries then
    local delay = delay_for(job.attempts, self.backoff)
    self.store:schedule(self.key, cjson.encode(job), time.now() + delay)
    return "retried", delay
  end

  if not self.dead_letter then return "dropped" end

  job.died_at = time.now()
  self.store:enqueue(self:dead_key(), cjson.encode(job))

  -- An unbounded dead-letter queue is a memory leak with a respectable name.
  if supports(self.store, "trim") then
    self.store:trim(self:dead_key(), self.max_dead)
  end
  return "buried"
end


--- True when this queue can survive a worker dying mid-job.
---
--- Worth asking rather than assuming: the answer decides whether a job that
--- matters may go through here at all, and it depends on the store, not on
--- the queue.
function Queue:reliable()
  return supports(self.store, "claim_pop") and supports(self.store, "ack")
end

--- Marks a job finished, so it stops being recoverable.
---
--- Called by `consume` after the handler returns AND after a failure has been
--- retried or buried -- in both cases the job has been dealt with, and
--- leaving it in the processing set would make `reap` run it again.
function Queue:ack(job)
  if not supports(self.store, "ack") then return false end
  local encoded = self._claimed[job] or cjson.encode(job)
  self._claimed[job] = nil
  return self.store:ack(self.key, encoded)
end

--- Returns jobs abandoned by a worker that never came back.
---
--- `older_than` is in seconds and must exceed the longest a handler may
--- legitimately take. Set it too low and a slow job is run twice while the
--- first attempt is still going; that is the trade this method makes and it
--- cannot be made safe from here, because only the application knows how long
--- its work takes.
---
--- Returns how many were returned to the queue.
function Queue:reap(older_than)
  if not supports(self.store, "reap") then return 0 end
  local now = time.now()
  -- `now` as well as the cutoff: a store that keeps claim times separately
  -- from the jobs themselves needs to be able to stamp an entry it finds
  -- unstamped, rather than assume nobody holds it.
  return self.store:reap(self.key, now - (older_than or 300), now)
end

--- How many jobs are currently checked out by a worker.
function Queue:in_flight()
  if not supports(self.store, "in_flight") then return 0 end
  return self.store:in_flight(self.key)
end

--- Consumes until `should_stop()` returns true.
---
--- **AT LEAST ONCE where the store can do it, at most once where it cannot,
--- and `Queue:reliable()` says which one you have.**
---
--- With a store that offers `claim_pop` and `ack` -- Redis and the in-memory
--- one both do -- a job moves to a processing set as it leaves the queue, in
--- one step, and is acknowledged only after the handler has finished or its
--- failure has been retried or buried. A worker killed in between leaves the
--- job recoverable: `Queue:reap(older_than)` puts it back.
---
--- Nothing reaps automatically. A timer that returned jobs on its own would
--- have to guess how long a handler may legitimately take, and guessing that
--- runs live jobs twice. Call `reap` from wherever your deployment knows the
--- answer -- a periodic task, a startup hook, an operator command.
---
--- With a store that offers neither, this is AT MOST ONCE and the loss is
--- silent: `pop` is destructive, so between it and the handler finishing the
--- job exists only in this worker's memory, and an ordinary deploy loses it.
--- The retry policy does not cover that -- retries are for a handler that
--- RAISED, and a worker that died raised nothing.
---
--- At-least-once means a handler can run twice. That is the trade, and it is
--- the right way round: a job run twice is visible and fixable with an
--- idempotency key, and a job silently lost is neither.
function Queue:consume(handlers, options)
  options = options or {}
  local log = options.log
  local should_stop = options.should_stop or function() return false end
  local handled, failed, retried, buried = 0, 0, 0, 0

  while not should_stop() do
    local job, decode_error = self:pop(options.timeout or 1)
    if decode_error and log then
      log:warn("jobs: discarded an undecodable job")
    elseif job then
      local handler = handlers[job.kind]
      local function done() self:ack(job) end

      if not handler then
        -- A job with no handler is usually a deployment in progress -- a
        -- worker running older code than the producer -- so it goes through
        -- the same failure path rather than being dropped.  Dropping it
        -- loses work that finishing the deploy would have run.
        if log then log:warn("jobs: no handler", { kind = job.kind }) end
        self:fail(job, "no handler registered for kind '" .. tostring(job.kind) .. "'")
        done()
      else
        local ok, err = pcall(handler, job.payload, job)
        if ok then
          handled = handled + 1
          -- AFTER the handler, never before. The whole point is that a worker
          -- dying between the two leaves the job recoverable.
          done()
        else
          failed = failed + 1
          local outcome, delay = self:fail(job, err)
          if outcome == "retried" then retried = retried + 1 else buried = buried + 1 end
          if log then
            log:error("jobs: job failed", {
              kind = job.kind, attempt = job.attempts, outcome = outcome,
              retry_in_s = delay and math.floor(delay * 10) / 10 or nil,
              detail = tostring(err),
            })
          end
          -- The failure has been retried or buried, so this attempt is
          -- finished even though the work is not.
          done()
        end
      end
    end
  end

  return { handled = handled, failed = failed, retried = retried, buried = buried }
end

M.Queue = Queue
M.delay_for = delay_for
return M
