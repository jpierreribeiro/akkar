--[[
akkar.jobs.memory — in-process persistence for a job queue.

Same argument as the other `_memory` adapters: a shared, tested implementation
of the store contract beats a fake per test file.

`dequeue` does not block. Nothing here should sleep waiting for work that can
only arrive from the same process -- if the queue is empty it will stay empty
until this coroutine yields, so blocking would be a deadlock rather than a
wait.

It implements the optional half of the contract too -- scheduling, claiming,
peeking, trimming -- so that retries, delays and idempotency can be tested
without Redis. A fake that supports less than the real store means the tests
prove less than they appear to.
]]

local jobs = require "akkar.jobs"

local Store = {}
Store.__index = Store

local time = require "akkar.time"

local M = {}

function Store:enqueue(key, encoded)
  local list = self.lists[key]
  if not list then list = {} self.lists[key] = list end
  table.insert(list, 1, encoded)
  return #list
end

function Store:dequeue(key)
  local list = self.lists[key]
  if not list or #list == 0 then return nil end
  return table.remove(list)      -- from the tail: FIFO
end

function Store:depth(key)
  local list = self.lists[key]
  return list and #list or 0
end

-- ============================================================ the optional half

--- Holds a job until `run_at`.  A list scanned on promote, not a heap: a
--- process-local queue with enough scheduled jobs for that to matter has
--- outgrown a process-local queue.
--- Schedules a job `delay` seconds from now, by this process's clock.
---
--- The Redis store reads the SERVER's clock so that a fleet agrees; here
--- there is only one process, so its own clock IS the shared one. A step of
--- this process's clock moves everything in it together, which is the
--- consistent -- if not always convenient -- answer.
-- `monotime`, not `now`, and for two reasons that arrived a day apart.
--
-- RESOLUTION: `time.now()` is `os.time`, which counts whole seconds, so a
-- sub-second delay became "the next second boundary" and the fractional jitter
-- `jobs.delay_for` computes was discarded. A retry schedule whose first window
-- is two seconds spread its jobs across two values.
--
-- AND THE SAME ARGUMENT DEADLINES ALREADY WON: a wall clock stepped by NTP
-- moves scheduled work with it. Everything in this process schedules and
-- promotes against one monotonic clock, so a step moves nothing.
function Store:schedule(key, encoded, delay)
  local run_at = time.monotime() + (delay or 0)
  local pending = self.scheduled[key]
  if not pending then pending = {} self.scheduled[key] = pending end
  pending[#pending + 1] = { run_at = run_at, encoded = encoded }
  return #pending
end

--- Moves everything due into the queue proper, oldest first, and returns how
--- many moved.  Ordering by `run_at` matters: two jobs that came due while
--- nobody was looking should run in the order they were meant to.
function Store:promote(key)
  local now = time.monotime()
  local pending = self.scheduled[key]
  if not pending or #pending == 0 then return 0 end

  local due = {}
  local waiting = {}
  for _, entry in ipairs(pending) do
    if entry.run_at <= now then due[#due + 1] = entry else waiting[#waiting + 1] = entry end
  end
  table.sort(due, function(a, b) return a.run_at < b.run_at end)
  for _, entry in ipairs(due) do self:enqueue(key, entry.encoded) end

  self.scheduled[key] = waiting
  return #due
end

--- True the first time an id is seen, false afterwards, until the ttl expires.
function Store:claim(key, id, ttl)
  local seen = self.claims[key]
  if not seen then seen = {} self.claims[key] = seen end

  local now = time.now()
  local held = seen[id]
  if held and held > now then return false end
  seen[id] = now + (ttl or 3600)
  return true
end

--- Gives a claim back, so the id can be taken again.
---
--- The claim is taken before the job exists -- the only order that closes the
--- race between two producers -- so something has to undo it when the job
--- then fails to exist. Held, the id answers "duplicate" for an hour about a
--- job that was never queued.
function Store:unclaim(key, id)
  local seen = self.claims[key]
  if not seen then return false end
  local held = seen[id] ~= nil
  seen[id] = nil
  return held
end

--- Claims the id and enqueues the job as one indivisible step.
---
--- In one process with one coroutine at a time this is atomic by
--- construction: nothing here yields, so nothing can be scheduled between the
--- claim and the push. The method exists anyway, rather than letting
--- `Queue:push` fall back to two calls, because the two stores must answer
--- the same contract -- a fake whose safety property differs from the real
--- one is how a test proves the wrong thing.
--- INDIVISIBLE MEANS INDIVISIBLE, AND A RAISE IS THE OTHER WAY TO DIVIDE IT.
--- Nothing here yields, so no other coroutine can land between the claim and
--- the push -- but the push can still fail, and a claim left behind by a job
--- that does not exist is the exact defect this method exists to prevent, one
--- cause further along. The Redis version cannot have this problem because a
--- script either runs or does not; this one has to unwind by hand to answer
--- the same contract.
function Store:claim_and_enqueue(key, id, ttl, encoded, run_at)
  if not self:claim(key, id, ttl) then return false, "duplicate" end
  local ok, result = pcall(function()
    if run_at and run_at > 0 then
      return self:schedule(key, encoded, run_at)
    end
    return self:enqueue(key, encoded)
  end)
  if not ok then
    self:unclaim(key, id)
    error(result, 0)
  end
  return result
end

-- ================================================== at-least-once delivery
--
-- A job leaves the queue and enters the PROCESSING set in one step, and stays
-- there until it is acknowledged. A worker that dies holding it leaves it
-- recoverable rather than gone, which is the difference between at-most-once
-- and at-least-once -- and `Queue:consume` was at-most-once, loudly
-- documented, until this existed.
--
-- In one process the "worker died" case can only be simulated, and that is
-- exactly what the specs do: pop without acknowledging, then reap.

function Store:processing_key(key) return key .. ":processing" end

--- Moves the oldest job into the processing set and returns it.
function Store:claim_pop(key, _timeout)
  local now = time.now()
  local encoded = self:dequeue(key)
  if not encoded then return nil end

  local held = self.processing[key]
  if not held then held = {} self.processing[key] = held end
  held[#held + 1] = { encoded = encoded, at = now or time.now() }
  return encoded
end

--- Drops a job from the processing set. Returns whether it was there.
function Store:ack(key, encoded)
  local held = self.processing[key]
  if not held then return false end
  for i, entry in ipairs(held) do
    if entry.encoded == encoded then
      table.remove(held, i)
      return true
    end
  end
  return false
end

--- Everything whose lease ran out, oldest first.
---
--- Oldest first, so a job abandoned twice does not overtake one abandoned
--- once -- the same ordering promise `promote` makes. `held` is appended to in
--- claim order, so it is already in that order.
---
--- RE-LEASED, NOT HANDED OVER. Each entry returned is stamped `now` before it
--- leaves, which gives the caller a fresh `visibility` window to write the
--- job's next copy in and stops a second reaper arriving in the middle from
--- collecting the same entry. The entry stays in flight until the caller
--- `ack`s it, so a reaper that dies mid-pass costs a redelivery -- which is
--- what this queue promises -- rather than the job, which is what it promises
--- not to.
---
--- `now` is a test seam: leave it out and this store reads its own clock. See
--- `Queue:reap`, and the header of `akkar/jobs/redis.lua` for why the store
--- rather than the caller owns that reading.
function Store:expired(key, visibility, now, limit)
  -- The seam moves the CUTOFF and nothing else: a stamp is a claim time, and
  -- it is always this store's own clock. Same rule as the Redis store, where
  -- writing a claim time from the caller's clock is the defect its header is
  -- about.
  local cutoff = (now or time.now()) - (visibility or 300)
  local held = self.processing[key]
  if not held or #held == 0 then return {} end

  local out = {}
  for _, entry in ipairs(held) do
    if entry.at <= cutoff then
      entry.at = time.now()
      out[#out + 1] = entry.encoded
      if #out >= (limit or 500) then break end
    end
  end
  return out
end

function Store:in_flight(key)
  local held = self.processing[key]
  return held and #held or 0
end

--- Reads without removing, oldest first, to match what a reader expects.
function Store:peek(key, limit)
  local list = self.lists[key]
  if not list then return {} end
  local out = {}
  for i = #list, math.max(1, #list - (limit or 100) + 1), -1 do
    out[#out + 1] = list[i]
  end
  return out
end

--- Keeps the newest `keep` entries.  An unbounded dead-letter list is a
--- memory leak with a respectable name.
function Store:trim(key, keep)
  local list = self.lists[key]
  if not list then return 0 end
  local removed = 0
  while #list > keep do
    table.remove(list)          -- the tail is the oldest
    removed = removed + 1
  end
  return removed
end

function Store:scheduled_depth(key)
  local pending = self.scheduled[key]
  return pending and #pending or 0
end

function M.store()
  return setmetatable({ lists = {}, scheduled = {}, claims = {},
                        processing = {} }, Store)
end

--- Builds a queue on this store.
---
--- OPTIONS ARE FORWARDED, AND FOR A WHILE THEY WERE NOT.
---
--- `jobs.new(store, name, options)` has always accepted a retry policy, a
--- backoff and a dead-letter setting -- and this constructor took only the
--- name, so every one of them was dropped on the floor between the caller and
--- the queue. `memory.new("emails", { retries = 3 })` produced a queue with
--- `retries = 0` and said nothing.
---
--- The irony is the part worth recording: `akkar/jobs.lua` REFUSES a retry
--- policy it cannot honour, and calls that refusal "the silent degradation
--- this module exists to avoid". The policy never reached the check.
---
--- Found by an agent writing the reference documentation, who read the
--- signature rather than the docstring -- and it had already been taught in
--- `docs/guide/10-background-work.md`, whose retries section was configuring
--- nothing at all.
function M.new(name, options)
  return jobs.new(M.store(), name, options)
end

M.Store = Store
return M
