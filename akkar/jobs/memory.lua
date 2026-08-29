--[[
akkar.jobs.memory — in-process persistence for a job queue.

Same argument as the other `_memory` adapters: a shared, tested implementation
of the store contract beats a fake per test file.

Delivery is **at least once**, the same as the Redis store, and that is not
decoration here either. Losing the process loses this queue anyway -- so the
crash it has to survive is not a dead process but a dead COROUTINE: a handler
that raised past its worker, a cqueues deadline that abandoned the loop
mid-job, a `should_stop` that returned true while a job was in hand. Those
lose the job on a store that pops and hands over in one step, and they are the
same shape as the crash that matters on Redis.

It matters more than "it is only a fake" suggests: this store is what the
semantic tests run against, so a fake with a weaker safety property than the
real thing is how a test proves the wrong thing. `lease`, `ack`, `expired`
and `in_flight_depth` are here so that both backends answer the same
questions the same way, and `spec/jobs_delivery_spec.lua` asserts exactly
that against both.

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

-- ====================================================== holding one in flight
-- Modelled on what the Redis store can express, not on what a table makes
-- easy.  There the in-flight record is a list entry and the deadline is a
-- sorted-set score, and an entry claimed by a reaper has lost its score but
-- not its list entry -- so here an entry is `{ deadline = n }` and a claimed
-- one is `{ deadline = false }`, still counted by `in_flight_depth`, still
-- waiting for an `ack` that will now say "no, this was taken from you".
--
-- The alternative -- deleting on reap -- would have made this store answer
-- `ack` differently from Redis on the one path the whole feature exists for.

local function held(self, key)
  local entries = self.inflight[key]
  if not entries then entries = {} self.inflight[key] = entries end
  return entries
end

--- Takes a job and holds it, in one step.  No `timeout`: nothing here can
--- arrive while this coroutine is inside the call, so blocking would be a
--- deadlock rather than a wait.
function Store:lease(key, _timeout, visibility)
  local encoded = self:dequeue(key)
  if not encoded then return nil end
  held(self, key)[encoded] = { deadline = os.time() + (visibility or 300) }
  return encoded
end

--- Retires an in-flight record.  1 when it was still ours, 0 when a reaper
--- had already claimed it -- which tells the caller its handler outran the
--- visibility timeout and the job is being run somewhere else too.
function Store:ack(key, encoded)
  local entries = self.inflight[key]
  local entry = entries and entries[encoded]
  if not entry then return 0 end
  entries[encoded] = nil
  return entry.deadline and 1 or 0
end

--- Claims what ran out of time, oldest deadline first, and returns it.
---
--- Claiming and RELEASING are deliberately separate: the entry stays in
--- flight until the caller has written its next copy somewhere, so a crash in
--- between costs a redelivery instead of the job.
function Store:expired(key, now, _visibility, limit)
  local entries = self.inflight[key]
  if not entries then return {} end

  local due = {}
  for encoded, entry in pairs(entries) do
    if entry.deadline and entry.deadline <= now then
      due[#due + 1] = { encoded = encoded, deadline = entry.deadline }
    end
  end
  table.sort(due, function(a, b)
    if a.deadline ~= b.deadline then return a.deadline < b.deadline end
    return a.encoded < b.encoded            -- `pairs` order is not an order
  end)

  local out = {}
  for i = 1, math.min(#due, limit or 500) do
    entries[due[i].encoded].deadline = false               -- claimed, not gone
    out[#out + 1] = due[i].encoded
  end
  return out
end

function Store:in_flight_depth(key)
  local entries = self.inflight[key]
  if not entries then return 0 end
  local n = 0
  for _ in pairs(entries) do n = n + 1 end
  return n
end

-- ============================================================ the optional half

--- Holds a job until `run_at`.  A list scanned on promote, not a heap: a
--- process-local queue with enough scheduled jobs for that to matter has
--- outgrown a process-local queue.
function Store:schedule(key, encoded, run_at)
  local pending = self.scheduled[key]
  if not pending then pending = {} self.scheduled[key] = pending end
  pending[#pending + 1] = { run_at = run_at, encoded = encoded }
  return #pending
end

--- Moves everything due into the queue proper, oldest first, and returns how
--- many moved.  Ordering by `run_at` matters: two jobs that came due while
--- nobody was looking should run in the order they were meant to.
function Store:promote(key, now)
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

  local now = os.time()
  local held = seen[id]
  if held and held > now then return false end
  seen[id] = now + (ttl or 3600)
  return true
end

--- Gives a claim back when the job it was taken for never got queued, so a
--- failed enqueue does not leave the id answering "duplicate" for an hour
--- about a job that does not exist. The Redis store does the same, because a
--- fake whose behaviour differs from the real one is how a test proves the
--- wrong thing.
function Store:unclaim(key, id)
  local seen = self.claims[key]
  if not seen or seen[id] == nil then return 0 end
  seen[id] = nil
  return 1
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
  return setmetatable({ lists = {}, scheduled = {}, claims = {}, inflight = {} },
                      Store)
end

--- `options` goes straight to `akkar.jobs.new`, matching `akkar.jobs.redis`:
--- a fake that cannot be configured the way the real store can is a fake the
--- tests cannot ask the same questions of.
function M.new(name, options)
  return jobs.new(M.store(), name, options)
end

M.Store = Store
return M
