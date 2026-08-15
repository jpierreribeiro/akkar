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

  local now = time.now()
  local held = seen[id]
  if held and held > now then return false end
  seen[id] = now + (ttl or 3600)
  return true
end

--- Claims the id and enqueues the job as one indivisible step.
---
--- In one process with one coroutine at a time this is atomic by
--- construction: nothing here yields, so nothing can be scheduled between the
--- claim and the push. The method exists anyway, rather than letting
--- `Queue:push` fall back to two calls, because the two stores must answer
--- the same contract -- a fake whose safety property differs from the real
--- one is how a test proves the wrong thing.
function Store:claim_and_enqueue(key, id, ttl, encoded, run_at)
  if not self:claim(key, id, ttl) then return false, "duplicate" end
  if run_at and run_at > 0 then
    return self:schedule(key, encoded, run_at)
  end
  return self:enqueue(key, encoded)
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
  return setmetatable({ lists = {}, scheduled = {}, claims = {} }, Store)
end

function M.new(name)
  return jobs.new(M.store(), name)
end

M.Store = Store
return M
