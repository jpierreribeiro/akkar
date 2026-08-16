--[[
akkar.jobs.redis — Redis persistence for a job queue.  Semantics live in
`akkar.jobs`; this only stores and retrieves.

A Redis list gives FIFO for free: `LPUSH` to the head, `BRPOP` from the tail.
`BRPOP` blocks server-side rather than polling, and blocking there costs
nothing here because the Redis adapter yields while it waits.

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

  -- The connection carries a read timeout, and this is the one command that
  -- is legitimately slower than it: `BRPOP` waits IN THE SERVER for up to
  -- `timeout` seconds, so leaving the socket bound at its default would abort
  -- a wait that is doing exactly what it was asked to do. Raised for this
  -- call and put back afterwards, on every path -- the slack is what
  -- separates "the server is thinking" from "the server is gone".
  local restore = self.cache.settimeout and function(seconds)
    self.cache:settimeout(seconds)
  end

  if restore then self.cache:settimeout(timeout + 5) end
  local ok, reply = pcall(self.cache.command, self.cache, "BRPOP", key, timeout)
  if restore then self.cache:settimeout(nil) end

  if not ok then error(reply, 0) end
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

-- Read, remove and push, in one script.
--
-- This used to be a range read followed by a `ZREM` and an `LPUSH` per entry,
-- three round trips deep, and its docstring reasoned only about two workers
-- racing. The case it did not consider is one worker being ABANDONED -- a
-- request deadline firing between the remove and the push -- and that does not
-- run a job twice. It DESTROYS the job: gone from the schedule, never in the
-- queue, and nothing anywhere records that it existed.
--
-- A script removes the window rather than narrowing it, and costs one round
-- trip instead of 2N+1.
local PROMOTE_SCRIPT = [[
local zkey  = KEYS[1]
local lkey  = KEYS[2]
local now   = tonumber(ARGV[1])

local due = redis.call('ZRANGEBYSCORE', zkey, '-inf', now)
local moved = 0
for i = 1, #due do
  if redis.call('ZREM', zkey, due[i]) == 1 then
    redis.call('LPUSH', lkey, due[i])
    moved = moved + 1
  end
end
return moved
]]

-- Take the id and push the job, in one script.
--
-- Two calls meant a coroutine abandoned between them left the id claimed for
-- the full TTL -- an hour by default -- with no job anywhere. The retry that
-- deduplication exists to make safe is then answered `false, "duplicate"`
-- for an hour, about a job that was never queued. Worse than a double push,
-- because a double push is visible and this is not.
local CLAIM_AND_PUSH_SCRIPT = [[
local claim_key = KEYS[1]
local lkey      = KEYS[2]
local zkey      = KEYS[3]
local encoded   = ARGV[1]
local ttl       = tonumber(ARGV[2])
local run_at    = tonumber(ARGV[3])

if not redis.call('SET', claim_key, '1', 'NX', 'EX', ttl) then
  return -1
end

if run_at > 0 then
  return redis.call('ZADD', zkey, run_at, encoded)
end
return redis.call('LPUSH', lkey, encoded)
]]

-- Sent as `EVAL` rather than cached as `EVALSHA`. `akkar.limit` caches,
-- because it runs on every request and a kilobyte on the wire against a
-- decision measured in microseconds is a bad trade. A job push is not that:
-- it happens once per job, and the second round trip a cache miss costs is
-- invisible beside the work the job represents. Correctness first, and no
-- third copy of a SHA cache to keep in step with the other two.
local function eval(cache, script, keys, args)
  local argv = { #keys }
  for _, k in ipairs(keys) do argv[#argv + 1] = k end
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  return cache:command("EVAL", script, table.unpack(argv))
end

--- Moves everything due into the list, oldest due first, atomically.
---
--- Two workers can still both read the same entry as due; `ZREM` is the
--- arbiter, and only the one whose remove returns 1 pushes it. That race
--- costs a wasted read and never a duplicate job -- and now it cannot lose
--- one either.
function Store:promote(key, now)
  local moved = eval(self.cache, PROMOTE_SCRIPT,
                     { self:scheduled_key(key), key }, { now })
  return tonumber(moved) or 0
end

--- Claims the id and enqueues the job in one round trip.
---
--- Returns the depth after the push, or `false, "duplicate"`.
function Store:claim_and_enqueue(key, id, ttl, encoded, run_at)
  local reply = eval(self.cache, CLAIM_AND_PUSH_SCRIPT,
                     { key .. ":claim:" .. id, key, self:scheduled_key(key) },
                     { encoded, ttl or 3600, run_at or 0 })
  local n = tonumber(reply)
  if n == -1 then return false, "duplicate" end
  return n
end

-- ================================================== at-least-once delivery
--
-- `BLMOVE` takes the job off the queue and puts it in the processing list in
-- ONE server-side step, so there is no window where the job exists only in a
-- worker's memory. That window is exactly what made `Queue:consume`
-- at-most-once: a worker killed between `BRPOP` and the handler finishing
-- lost the job with nothing anywhere recording that it existed.
--
-- The list is what `BLMOVE` needs; the sorted set beside it is what makes
-- reaping possible, because a list cannot say how old its entries are.
--
-- ONE PAIR CANNOT BE A SCRIPT, and this comment used to claim they all were:
-- "kept in step by scripts, never by two round trips". Redis refuses blocking
-- commands inside a script, so the WAITING claim is `BLMOVE` and then `ZADD`,
-- two round trips with a gap between them. Everything else here is a script,
-- including the non-blocking claim, which was two round trips only because
-- nobody had noticed it did not have to be.
--
-- What that surviving gap costs is bounded on purpose: an entry in the list
-- with no score is a claim in flight, so `reap` STAMPS it rather than
-- reclaiming it, and only the ordinary staleness rule can take a job away
-- from a worker. See `REAP_SCRIPT`.

function Store:processing_key(key) return key .. ":processing" end
function Store:claimed_key(key)    return key .. ":processing:at" end

local ACK_SCRIPT = [[
redis.call('LREM', KEYS[1], 1, ARGV[1])
return redis.call('ZREM', KEYS[2], ARGV[1])
]]

-- Everything claimed before the cutoff goes back, oldest first.
--
-- Entries in the list with NO score are reaped too: that is a worker killed
-- between the `BLMOVE` and the `ZADD` below, and leaving them would make a
-- job invisible for ever -- the precise failure this whole mechanism exists
-- to remove.
local REAP_SCRIPT = [[
local processing = KEYS[1]
local claimed    = KEYS[2]
local queue      = KEYS[3]
local cutoff     = tonumber(ARGV[1])
local now        = tonumber(ARGV[2]) or cutoff

local moved = 0
local stale = redis.call('ZRANGEBYSCORE', claimed, '-inf', cutoff)
for i = 1, #stale do
  if redis.call('LREM', processing, 1, stale[i]) > 0 then
    redis.call('LPUSH', queue, stale[i])
    moved = moved + 1
  end
  redis.call('ZREM', claimed, stale[i])
end

local held = redis.call('LRANGE', processing, 0, -1)
for i = 1, #held do
  if not redis.call('ZSCORE', claimed, held[i]) then
    -- STAMPED, NOT SNATCHED. This branch used to move an unscored entry
    -- straight back to the queue, and the only way to be unscored is to be
    -- inside the window between `BLMOVE` and `ZADD` in `claim_pop` -- which
    -- a LIVE worker passes through on every single job. A reap landing in
    -- that window handed a running job to somebody else, and at-least-once
    -- quietly became at-least-twice under nothing worse than ordinary
    -- timing.
    --
    -- So it adopts instead: give it a timestamp now, and let the ordinary
    -- stale path reclaim it one window later if nobody acknowledges it. A
    -- worker that really died between the two commands loses `cutoff`
    -- seconds, once. A worker that is alive loses nothing.
    redis.call('ZADD', claimed, now, held[i])
  end
end

return moved
]]

-- The non-blocking claim, as one step.
--
-- `LMOVE` then `ZADD` from the client is two round trips with a gap, and the
-- gap is what made `reap` capable of stealing a live worker's job. The
-- comment at the top of this file claims these pairs are "kept in step by
-- scripts, never by two round trips"; for this one pair it was not true.
local CLAIM_POP_SCRIPT = [[
local job = redis.call('RPOPLPUSH', KEYS[1], KEYS[2])
if not job then return false end
redis.call('ZADD', KEYS[3], tonumber(ARGV[1]), job)
return job
]]

--- Moves one job from the queue to the processing list and returns it.
function Store:claim_pop(key, timeout, now)
  local processing = self:processing_key(key)
  local encoded

  if not timeout or timeout <= 0 then
    -- One script, so the move and the timestamp cannot be separated. The
    -- blocking branch below cannot do this -- Redis refuses blocking commands
    -- inside a script -- which is why `reap` had to learn to adopt an
    -- unscored entry rather than reclaim it.
    encoded = eval(self.cache, CLAIM_POP_SCRIPT,
                   { key, processing, self:claimed_key(key) },
                   { tostring(now or 0) })
    if type(encoded) ~= "string" then return nil end
    return encoded
  else
    -- The connection's read bound has to outlive a command that blocks in
    -- the server, for the same reason `dequeue` raises it around `BRPOP`.
    local bounded = self.cache.settimeout ~= nil
    if bounded then self.cache:settimeout(timeout + 5) end
    local ok, reply = pcall(self.cache.command, self.cache,
                            "BLMOVE", key, processing, "RIGHT", "LEFT", timeout)
    if bounded then self.cache:settimeout(nil) end
    if not ok then error(reply, 0) end
    encoded = reply
  end

  if type(encoded) ~= "string" then return nil end

  -- Timestamped after the move, and `reap` treats an entry with no timestamp
  -- as stale precisely because a worker can die in between.
  self.cache:command("ZADD", self:claimed_key(key), now or 0, encoded)
  return encoded
end

function Store:ack(key, encoded)
  local removed = eval(self.cache, ACK_SCRIPT,
                       { self:processing_key(key), self:claimed_key(key) },
                       { encoded })
  return tonumber(removed) == 1
end

function Store:reap(key, cutoff, now)
  local moved = eval(self.cache, REAP_SCRIPT,
                     { self:processing_key(key), self:claimed_key(key), key },
                     { cutoff, now or cutoff })
  return tonumber(moved) or 0
end

function Store:in_flight(key)
  return tonumber(self.cache:command("LLEN", self:processing_key(key))) or 0
end

--- `SET NX EX` -- atomic across every process, which is the whole point.
function Store:claim(key, id, ttl)
  local reply = self.cache:command("SET", key .. ":claim:" .. id, "1",
                                   "NX", "EX", tostring(ttl or 3600))
  return reply == "OK"
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
function M.new(cache, name, options)
  return jobs.new(setmetatable({ cache = cache }, Store), name, options)
end

M.Store = Store
return M
