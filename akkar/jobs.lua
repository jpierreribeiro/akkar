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

local cjson = require "cjson"

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
    queued_at = os.time(),
    attempts = 0,
  }

  local run_at = delayed and (os.time() + options.delay) or 0

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
function Queue:pop(timeout)
  -- Anything whose time has come joins the queue before we look at it.
  if supports(self.store, "promote") then
    self.store:promote(self.key, os.time())
  end

  local encoded = self.store:dequeue(self.key, timeout or 5)
  if not encoded then return nil end
  local ok, job = pcall(cjson.decode, encoded)
  -- A job that cannot be decoded cannot be handled or retried, and leaving it
  -- at the head of the queue would stall every worker behind it forever.
  if not ok then return nil, "akkar.jobs: undecodable job discarded" end
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
  job.first_failed_at = job.first_failed_at or os.time()

  if job.attempts <= self.retries then
    local delay = delay_for(job.attempts, self.backoff)
    self.store:schedule(self.key, cjson.encode(job), os.time() + delay)
    return "retried", delay
  end

  if not self.dead_letter then return "dropped" end

  job.died_at = os.time()
  self.store:enqueue(self:dead_key(), cjson.encode(job))

  -- An unbounded dead-letter queue is a memory leak with a respectable name.
  if supports(self.store, "trim") then
    self.store:trim(self:dead_key(), self.max_dead)
  end
  return "buried"
end

--- Consumes until `should_stop()` returns true.
---
--- **AT MOST ONCE. Read this before putting anything that matters through it.**
---
--- `pop` is destructive: `BRPOP` removes the job from Redis and returns it,
--- and from that moment until the handler finishes the job exists only in
--- this worker's local variable. A process killed there -- an ordinary deploy,
--- an OOM kill, a machine going away -- loses it, silently and with nothing
--- anywhere recording that it existed. The retry policy does not cover this:
--- retries are for a handler that RAISED, and a worker that died raised
--- nothing.
---
--- That is a real property of this design and not a bug to be reported. It is
--- written here because nobody discovers it from the API, and because the
--- obvious assumption -- that a queue with retries, backoff and a dead-letter
--- queue also survives a worker dying -- is the opposite of the truth.
---
--- Use it for work that can be lost: cache warming, non-critical mail,
--- analytics. Do not use it for anything a customer paid for. At-least-once
--- delivery needs a claim on pop and an acknowledgement after the handler,
--- which changes this API and is not built.
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
      if not handler then
        -- A job with no handler is usually a deployment in progress -- a
        -- worker running older code than the producer -- so it goes through
        -- the same failure path rather than being dropped.  Dropping it
        -- loses work that finishing the deploy would have run.
        if log then log:warn("jobs: no handler", { kind = job.kind }) end
        self:fail(job, "no handler registered for kind '" .. tostring(job.kind) .. "'")
      else
        local ok, err = pcall(handler, job.payload, job)
        if ok then
          handled = handled + 1
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
        end
      end
    end
  end

  return { handled = handled, failed = failed, retried = retried, buried = buried }
end

M.Queue = Queue
M.delay_for = delay_for
return M
