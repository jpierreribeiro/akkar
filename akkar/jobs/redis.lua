--[[
akkar.jobs.redis — Redis persistence for a job queue.  Semantics live in
`akkar.jobs`; this only stores and retrieves.

A Redis list gives FIFO for free: `LPUSH` to the head, `BRPOP` from the tail.
`BRPOP` blocks server-side rather than polling, and blocking there costs
nothing here because the Redis adapter yields while it waits.

## The delivery guarantee, and the two keys that make it

**At least once.** `BRPOP` and `RPOP` used to remove the job and hand it over
in one step, so a worker that died between the pop and the end of the handler
took the job with it -- nothing redelivered it and nothing anywhere recorded
that it had existed. `BRPOPLPUSH` moves it instead: out of the ready list and
into an in-flight list, in one atomic server-side step, so at no instant is
the job in neither place.

Two keys hold a job in flight, and which one is authoritative is the whole
argument:

    <key>:inflight             a LIST -- the durable record.  Nothing is ever
                               removed from it except by an ack or by a reap
                               that has already written the job elsewhere.
    <key>:inflight:deadlines   a ZSET, member = the encoded job, score = the
                               second its lease runs out.  Only a SCHEDULE.

An entry can therefore be in the list with no deadline -- `BRPOPLPUSH` and
the `ZADD` behind it are two round trips, and a worker can die between them --
and that is not a lost job, it is an ORPHAN. `expired` walks the list, not
the sorted set, and adopts anything with no deadline by giving it one. The
invariant is short enough to check by reading: an entry leaves the list only
after its next copy exists. Every crash window therefore costs a duplicate
delivery, never the job, which is exactly the guarantee named above.

Being the ZSET member also makes the encoded job the identity of the in-flight
record, for `ZREM` and for `LREM`. That works only because `akkar.jobs` gives
every job a `uid`: without it two identical payloads would be one member, and
acking one would ack both. The uniqueness that was added to stop two receipt
emails collapsing into one is load-bearing here too.

### Why not the per-worker processing list

The classic shape is `RPOPLPUSH ready -> processing:<worker id>`, so a worker
that restarts can reclaim its own list. It is not what this does, for two
reasons that are the same reason. A list entry carries no timestamp, so a
reaper still cannot tell an entry two seconds old from one two hours old and
the deadline sorted set has to exist anyway; and once it does, the per-worker
split buys only the restart case, at the price of the reaper having to
DISCOVER worker ids -- which over Redis means `SCAN` on a keyspace pattern,
against the one instance every other akkar module shares. A worker that dies
and never comes back under the same id would also leave a list nobody scans
for. One list per queue is reaped by reading one key.

Scheduling uses a sorted set scored by the wall-clock second a job is due,
which is what a ZSET is for. Claims use `SET NX EX`, which is atomic across
every process talking to this Redis -- the property a process-local table
cannot have, and the reason deduplication belongs in the store rather than in
the worker.
]]

local jobs = require "akkar.jobs"

local Store = {}
Store.__index = Store

local M = {}

function Store:enqueue(key, encoded)
  return self.cache:command("LPUSH", key, encoded)
end

function Store:dequeue(key, timeout)
  -- `BRPOP key 0` blocks FOREVER in Redis, which is the opposite of what a
  -- caller passing zero means.  Zero here is "look, do not wait", so it maps
  -- to the non-blocking pop and nothing else does.
  if not timeout or timeout <= 0 then
    return self.cache:command("RPOP", key)
  end
  local reply = self.cache:command("BRPOP", key, timeout)
  if type(reply) ~= "table" then return nil end
  return reply[2]
end

function Store:depth(key)
  return self.cache:command("LLEN", key)
end

-- ====================================================== holding one in flight

function Store:inflight_key(key) return key .. ":inflight" end
function Store:deadline_key(key) return key .. ":inflight:deadlines" end

--- Takes a job and holds it, atomically, then schedules its lease.
---
--- The two commands are in this order and not the other because only this one
--- is safe to be interrupted: the job is in the in-flight list before it has
--- a deadline, so a crash in between leaves an orphan for `expired` to adopt.
--- Reversed, there would be nothing to adopt.
function Store:lease(key, timeout, visibility)
  local inflight = self:inflight_key(key)
  local encoded
  -- Zero means "look, do not wait" here, as it does for `dequeue`.  Passed
  -- through, Redis reads it as "block forever", which is its opposite.
  if not timeout or timeout <= 0 then
    encoded = self.cache:command("RPOPLPUSH", key, inflight)
  else
    encoded = self.cache:command("BRPOPLPUSH", key, inflight, timeout)
  end
  if type(encoded) ~= "string" then return nil end

  self.cache:command("ZADD", self:deadline_key(key),
                     os.time() + (visibility or 300), encoded)
  return encoded
end

--- Retires an in-flight record.  1 when the lease was still ours.
---
--- The `ZREM` first, and its result is the answer: a reaper claims an entry
--- by removing its deadline, so a missing deadline means this job was handed
--- to somebody else while the handler was still running. The `LREM` runs
--- either way -- the record has to leave the list -- but it is not what
--- decides. Reversed, an ack interrupted after the `LREM` would leave a
--- deadline for an entry that no longer exists, and `expired` reads the list,
--- so that member would sit in the sorted set forever.
function Store:ack(key, encoded)
  local ours = tonumber(self.cache:command("ZREM", self:deadline_key(key), encoded))
  local gone = tonumber(self.cache:command("LREM", self:inflight_key(key), -1, encoded))
  if ours == 1 and gone == 1 then return 1 end
  return 0
end

--- Claims every in-flight entry whose lease has run out, oldest first.
---
--- Claiming is a `ZREM`, and the entry stays in the list: the caller writes
--- the job's next copy and then calls `ack`.  `ZREM` is also the arbiter, the
--- same way it is in `promote` -- only the reaper whose remove returns 1 gets
--- the entry, so two reapers racing costs a wasted read rather than two
--- copies of the job.
function Store:expired(key, now, visibility, limit)
  local inflight = self.cache:command("LRANGE", self:inflight_key(key), 0,
                                      (limit or 500) - 1)
  if type(inflight) ~= "table" or #inflight == 0 then return {} end

  local zkey = self:deadline_key(key)
  local flat = self.cache:command("ZRANGE", zkey, 0, -1, "WITHSCORES")
  local deadline = {}
  if type(flat) == "table" then
    for i = 1, #flat - 1, 2 do deadline[flat[i]] = tonumber(flat[i + 1]) end
  end

  local due = {}
  for _, encoded in ipairs(inflight) do
    local at = deadline[encoded]
    if not at then
      -- An orphan: in flight, with no deadline, because a worker died between
      -- the move and the ZADD. Adopted rather than reaped on the spot -- it
      -- may be a lease taken microseconds ago by a worker that is perfectly
      -- alive, and reaping that would redeliver a job nobody lost.
      self.cache:command("ZADD", zkey, now + (visibility or 300), encoded)
    elseif at <= now
       and tonumber(self.cache:command("ZREM", zkey, encoded)) == 1 then
      due[#due + 1] = { encoded = encoded, deadline = at }
    end
  end

  table.sort(due, function(a, b)
    if a.deadline ~= b.deadline then return a.deadline < b.deadline end
    return a.encoded < b.encoded
  end)
  local out = {}
  for _, entry in ipairs(due) do out[#out + 1] = entry.encoded end
  return out
end

function Store:in_flight_depth(key)
  return self.cache:command("LLEN", self:inflight_key(key))
end

-- ============================================================ the optional half

function Store:scheduled_key(key) return key .. ":scheduled" end

function Store:schedule(key, encoded, run_at)
  return self.cache:command("ZADD", self:scheduled_key(key), run_at, encoded)
end

--- Moves everything due into the list, oldest due first.
---
--- Not atomic: another worker can take the same entry between the range read
--- and the remove, which would run a job twice. `ZREM` is the arbiter -- only
--- the worker whose remove returns 1 enqueues it -- so a race costs a wasted
--- read rather than a duplicate job.
function Store:promote(key, now)
  local zkey = self:scheduled_key(key)
  local due = self.cache:command("ZRANGEBYSCORE", zkey, "-inf", now)
  if type(due) ~= "table" then return 0 end

  local moved = 0
  for _, encoded in ipairs(due) do
    if tonumber(self.cache:command("ZREM", zkey, encoded)) == 1 then
      self:enqueue(key, encoded)
      moved = moved + 1
    end
  end
  return moved
end

function Store:claim_key(key, id) return key .. ":claim:" .. id end

--- `SET NX EX` -- atomic across every process, which is the whole point.
function Store:claim(key, id, ttl)
  local reply = self.cache:command("SET", self:claim_key(key, id), "1",
                                   "NX", "EX", tostring(ttl or 3600))
  return reply == "OK"
end

--- Gives a claim back when the job it was taken for never got queued.
---
--- The claim has to be taken before the enqueue -- that is the only order
--- that closes the race between two producers -- so the enqueue failing must
--- undo it. Without this the id sat there for its whole TTL answering
--- "duplicate" about a job that does not exist.
function Store:unclaim(key, id)
  return self.cache:command("DEL", self:claim_key(key, id))
end

--- Oldest first, matching the memory store, so a reader sees the same order
--- whichever backend is behind it.
function Store:peek(key, limit)
  local reply = self.cache:command("LRANGE", key, -(limit or 100), -1)
  if type(reply) ~= "table" then return {} end
  local out = {}
  for i = #reply, 1, -1 do out[#out + 1] = reply[i] end
  return out
end

--- Keeps the newest `keep` entries; the head of the list is the newest.
function Store:trim(key, keep)
  return self.cache:command("LTRIM", key, 0, keep - 1)
end

function Store:scheduled_depth(key)
  return self.cache:command("ZCARD", self:scheduled_key(key))
end

--- Returns a ready-to-use queue, which is what a caller almost always wants.
---
--- `options` goes straight to `akkar.jobs.new`, so `visibility`, `retries`
--- and the rest are reachable without assembling the store by hand -- which
--- is what anyone needing a visibility other than the default had to do.
function M.new(cache, name, options)
  return jobs.new(setmetatable({ cache = cache }, Store), name, options)
end

M.Store = Store
return M
