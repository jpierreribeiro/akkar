--[[
akkar.jobs.redis — Redis persistence for a job queue.  Semantics live in
`akkar.jobs`; this only stores and retrieves.

A Redis list gives FIFO for free: `LPUSH` to the head, `BRPOP` from the tail.
`BRPOP` blocks server-side rather than polling, and blocking there costs
nothing here because the Redis adapter yields while it waits.

## The delivery guarantee, stated because it was not

**At most once, at the crash boundary.** `BRPOP` and `RPOP` remove the job
from the list and hand it over in one step. There is no processing list, no
visibility timeout and no acknowledgement, so a worker that dies between the
pop and the end of the handler takes that job with it: nothing will ever
redeliver it, and nothing anywhere records that it existed. A job that must
survive a worker being killed -- a SIGKILL, an OOM, a machine going away --
needs a store that can hold it in flight, which this one does not.

`RPOPLPUSH` into a per-worker processing list, with a reaper for entries
older than a visibility timeout, is the shape that would fix it. It is not
here, and the alternative to saying so is a queue whose users believe
something about it that is not true.

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
function M.new(cache, name)
  return jobs.new(setmetatable({ cache = cache }, Store), name)
end

M.Store = Store
return M
