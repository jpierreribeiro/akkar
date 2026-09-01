--[[
akkar.cache.memory — an in-memory cache adapter.

The same argument as `akkar.db.memory`: a shared, tested implementation of the
contract beats a fake reinvented per test file.

Unlike the database one, this is a **real implementation, not a stand-in**. A
cache is a table with expiry, and that is a thing you can honestly build in
memory. So it obeys the whole contract for real: `set` with a TTL expires,
`incr` counts, `ttl` reports what is left.

That makes it useful beyond tests. A single-process deployment that wants
caching without running Redis can use this one and mean it — with the
limitation that follows from the shape rather than from the code: it is
per-process. Two processes have two caches, and akkar's answer to more CPU is
more processes. Say that out loud, because a cache that silently disagrees
between workers is a bug that takes a long time to see.

Expiry is lazy: an entry is removed when it is next read, not by a timer.
Nothing here should own a background task, and a cache that only cleans on
access will hold expired keys until then. `:sweep()` exists for a caller who
wants to reclaim eagerly.

## Faults, and why a real implementation still needs them

`akkar/db/memory.lua` can make a query `:fail()`, `:hang()` or `:drop()`, and
this adapter could make nothing go wrong at all. So every test written against
it tested a cache that always answers — which is not the cache anybody runs.

The surface is ported here, with the arguments that separate the three kept
intact and re-derived against `akkar/redis.lua`, because the standard this
project holds a fake to is that its failures are failures the REAL adapter can
produce. Two defects already came from breaking that rule: `redis.pcall` was
the same function as `redis.call` here and nowhere else, and the database fake
reported a clean rollback where Postgres had silently autocommitted.

So the three are named after what `akkar/redis.lua` actually does:

* `:fail()` is an ERROR REPLY. `WRONGTYPE`, `NOSCRIPT`, `READONLY`, `OOM
  command not allowed when used memory > 'maxmemory'`, `NOAUTH`. The server
  answered normally with bad news; `read_reply` tags it `"reply"` and
  `Redis:command` deliberately does NOT set `broken`, because the RESP stream
  is perfectly in step afterwards. Measured, in that module's own header: two
  WRONGTYPE replies used to take the pool from `live=1 idle=1` to `live=0
  idle=0`. A failed command leaves a HEALTHY connection.

* `:hang()` is a command that was sent and never answered. The socket's own
  timeout is what eventually ends it, and a timed-out read leaves the stream
  out of step — so this one sets `broken`, where `:fail` must not. It waits in
  REAL seconds for the same reason `db/memory.lua:hang` does: `akkar.time` can
  move a budget without waiting but deliberately does not move the event loop,
  and staging a coroutine abandoned mid-command needs a genuine yield.

* `:drop()` is the transport gone: a write that failed, a truncated bulk
  reply, a header that did not parse. Everything after it fails, because a
  closed socket does not answer because the next caller asked nicely.

The difference between `:fail` and `:drop` is SHARPER on a cache than on a
database, and that is the reason this is not a copy-paste of the other file.
RESP has no request ids: replies are matched to commands purely by order. A
connection returned to the pool with a reply still unread hands the NEXT
request somebody else's answer — `akkar/redis.lua` records exactly that, a
`GET` reading a nil that never was and then reading a stranger's value. On
Postgres the equivalent is refused ("connection is busy"); here nothing
refuses, the stream realigns after one request, and what is left is a single
wrong answer with no error anywhere. So `broken` and `in_flight` are set on
this adapter with the same meanings `akkar/redis.lua` gives them, which is
what the pool's reuse predicate there reads.

## Capacity: `max_qps` and `latency_ms`

Construction-time knobs, honoured by advancing `akkar.time` rather than by
waiting on a wall clock, so a test against a slow or a saturated dependency
stays deterministic and fast. See the block above `serve` for the model and
for what it does not claim.
]]

local time = require "akkar.time"

local Memory = {}
Memory.__index = Memory

local M = {}

--- The clock is injectable so tests can move time without sleeping.
---
--- `max_qps` and `latency_ms` are both optional and both nil by default, so a
--- cache nobody configured behaves exactly as it did before either existed.
function M.new(options)
  options = options or {}
  if options.max_qps ~= nil and (tonumber(options.max_qps) or 0) <= 0 then
    error("akkar.cache.memory: max_qps must be a number greater than zero; " ..
          "a capacity of zero is a store nothing can ever reach, and the way " ..
          "to say that is :drop()", 0)
  end
  if options.latency_ms ~= nil and (tonumber(options.latency_ms) or -1) < 0 then
    error("akkar.cache.memory: latency_ms must be a number of milliseconds, " ..
          "not negative", 0)
  end
  return setmetatable({
    store = {},
    now = options.now or time.now,
    -- The capacity model, and the programmed faults. See `serve` and `admit`.
    max_qps    = options.max_qps and tonumber(options.max_qps) or nil,
    latency_ms = options.latency_ms and tonumber(options.latency_ms) or nil,
    faults     = {},
    -- Declared, not inferred. This adapter can run a script, so "can it
    -- EVAL" stopped being a usable proxy for "is this store shared" the
    -- moment it learned to -- and the warning that mattered was always the
    -- second one: a fleet of six processes with a counter each enforces six
    -- times the configured limit, which is not a limit.
    per_process = true,
  }, Memory)
end

local function live(self, key)
  local entry = self.store[key]
  if not entry then return nil end
  if entry.expires and entry.expires <= self.now() then
    self.store[key] = nil
    return nil
  end
  return entry
end

-- ================================================== capacity and faults
--
-- Every command this adapter answers passes through `admit` exactly once, and
-- that word is deliberate: it is the round trip a real client would have paid
-- for. `redis.call` inside a script does NOT pass through it, because `EVAL`
-- is one round trip on a real server no matter how many commands the script
-- runs, and charging it per call would model a Redis nobody has.
--
-- That is why the implementations below are plain locals with the commands
-- built on top of them. The gate is structural rather than a flag somebody
-- has to remember to clear -- a flag would also survive a coroutine abandoned
-- mid-command, which is exactly the state these faults exist to stage.

-- LITERAL FIRST, PATTERN SECOND. The same rule, and the same scar, as
-- `akkar/db/memory.lua`: a needle written here is a piece of a real key, and
-- keys are full of Lua pattern magic. `rate-limit:user-7` matched as a
-- pattern is a lazy quantifier three times over and matches nothing anybody
-- meant; `session:%s` is worse. Patterns still work, because `^ratelimit:`
-- is a deliberate and useful thing to write, so the needle is tried as plain
-- text first and as a pattern only if that finds nothing. `pcall` because a
-- needle chosen as text is under no obligation to compile as a pattern.
local function matches(text, needle)
  if text:find(needle, 1, true) then return true end
  local ok, found = pcall(text.find, text, needle)
  return ok and found ~= nil
end

Memory._matches = matches      -- exposed for tests; not part of the contract

-- The string a fault is matched against: the verb, and the key when the verb
-- has one. So `:fail "GET"` breaks every read, `:fail "session:7"` breaks
-- every command touching that key, and `:fail "GET session:7"` breaks exactly
-- one. A script has no key of its own -- its keys are its arguments -- so it
-- matches on the verb alone.
local KEYLESS = { EVAL = true, EVALSHA = true, SCRIPT = true,
                  PING = true, TIME = true }

local function signature(verb, key)
  if KEYLESS[verb] or key == nil then return verb end
  return verb .. " " .. tostring(key)
end

--- THE CAPACITY MODEL, and it is a model. It says what it is:
---
--- `latency_ms` is service time -- every admitted command takes that long.
--- `max_qps` is throughput -- the store serves commands one after another at
--- that rate, so command N cannot complete before `start + N/max_qps` and a
--- caller arriving into a saturated store waits for the queue ahead of it.
---
--- They are one queue and not two delays added together: WHICHEVER IS THE
--- TIGHTER CONSTRAINT IS THE ONE A CALLER FEELS. A store at 1500/s and 8 ms
--- is bounded by its service time, because 8 ms of work cannot be issued
--- 1500 times a second by one server; the same store at 50/s and 8 ms is
--- bounded by its rate. Adding the two would have invented a third store that
--- is slower than either number describes.
---
--- What it does NOT claim: that this is what a Redis under that load would
--- actually do. A real server's service time varies with the command, the
--- value size and the eviction it is doing; a real client's throughput is
--- bounded by the socket as much as by the server. This reproduces a queue
--- with a fixed service rate, which is the same model the diagram upstream is
--- drawn from -- and the whole point of the number appearing in both places is
--- that the simulation and the real run can then be COMPARED and found to
--- disagree. A model that presented itself as truth would teach less.
---
--- It waits through `akkar.time`, never through a wall clock of its own. Under
--- `akkar.time.manual` a wait advances timestamps and returns immediately, so
--- a test of a 1500/s store at 8 ms is deterministic and finishes now. Under
--- the real clock the same numbers cost real seconds, which is what makes one
--- configuration serve both a simulation and a real run.
---
--- STATED TWICE ON PURPOSE, once per adapter, and `spec/capacity_spec.lua`
--- drives both from the same table of numbers so the two cannot drift apart.
local function serve(self)
  if not self.max_qps and not self.latency_ms then return end

  local wait = 0
  if self.max_qps then
    local now  = time.monotime()
    local free = math.max(self.free_at or now, now)
    wait = free - now
    self.free_at = free + 1 / self.max_qps
  end
  wait = wait + (self.latency_ms or 0) / 1000

  -- Monotime rather than `self.now`: `os.time` counts whole seconds and an
  -- 8 ms service time is invisible to it.
  if wait > 0 then time.sleep(wait) end
end

local function fault_for(self, sig)
  for _, entry in ipairs(self.faults) do
    if matches(sig, entry.match) then return entry.effect end
  end
end

--- One round trip: the connection is checked, the capacity is paid, and any
--- programmed fault fires.
---
--- `in_flight` is raised BEFORE the wait and lowered after, exactly as
--- `akkar/redis.lua` does it around the write and the read, and for exactly
--- its reason: a coroutine abandoned while the command is outstanding leaves
--- the flag up, and the flag being up is the only thing that stops the pool
--- handing that connection to somebody who would then read a stranger's
--- reply. Each fault below decides for itself which flags it leaves behind,
--- because that is the whole content of the difference between them.
local function admit(self, verb, key)
  -- A BROKEN CONNECTION STAYS BROKEN. A real socket does not recover because
  -- the next caller asked nicely, and a fake that answered again after a
  -- reset by peer would let a pool pass a dead connection around while the
  -- test went green. Nothing un-breaks it but `reset`. See `Memory:drop`.
  if self.broken then
    error("redis: write failed: connection reset by peer", 0)
  end

  self.in_flight = true
  serve(self)

  local effect = fault_for(self, signature(verb, key))
  if effect then effect(self) end        -- raises, having set its own flags

  self.in_flight = false
end

--- Programs what a matching command does.
---
--- The counterpart of `akkar/db/memory.lua:on`, and the difference between
--- them is the difference between the two adapters. That one is a STAND-IN:
--- it executes no SQL, so every query has to be programmed or it raises.
--- This one is a real implementation, so programming is an OVERRIDE and a
--- command nobody programmed still does its real work. Keeping that true is
--- the point -- an adapter that started demanding to be told what `GET`
--- returns would have stopped being a cache.
---
--- `effect` is called as `effect(cache)` before the command runs. Raising is
--- how it changes the outcome; returning is how it lets the command proceed.
--- `fail`, `hang` and `drop` are the three worth having, and they are written
--- in terms of this.
function Memory:on(match, effect)
  self.faults[#self.faults + 1] = { match = match, effect = effect }
  return self
end

--- Makes a matching command come back as an ERROR REPLY.
---
--- The server answered; it answered badly. `WRONGTYPE Operation against a key
--- holding the wrong kind of value`, `NOSCRIPT No matching script`, `READONLY
--- You can't write against a read only replica`, `OOM command not allowed
--- when used memory > 'maxmemory'`, `NOAUTH Authentication required` -- all
--- of them real replies `akkar/redis.lua` raises today.
---
--- The connection is left HEALTHY, and that is not an oversight. `read_reply`
--- tags an error reply `"reply"` and `Redis:command` skips `broken` for it
--- precisely because the RESP stream is still in step; marking it broken here
--- would model a client that throws a good connection away on every
--- WRONGTYPE, which is the defect that module already fixed once.
function Memory:fail(match, message)
  return self:on(match, function(self_)
    self_.in_flight = false
    error("redis: " .. (message or "ERR command failed"), 0)
  end)
end

--- Makes a matching command TAKE TIME, so a deadline above it can fire.
---
--- `:fail` raises immediately, which exercises the error path and nothing
--- else. The defect class this project keeps finding is different: a
--- capability acquired, a coroutine abandoned mid-yield, and a release that
--- never runs. Staging it needs a command that YIELDS rather than one that
--- returns, and `akkar/db/memory.lua` grew this for the same reason.
---
--- Real seconds on purpose, and this is the one place in the module that does
--- not go through the capacity model. `akkar.time` can move a budget forward
--- without waiting, but it deliberately does not move the event loop -- see
--- that module's header -- and what has to happen here is a genuine yield, so
--- that whatever is racing this command actually gets scheduled. Which is why
--- it is `time.real.sleep` and not `time.sleep`: under a manual clock the
--- second one advances timestamps and returns at once, so `:hang` would
--- quietly stop hanging and become `:fail` under another name. `latency_ms`
--- wants exactly the opposite and gets it -- that one goes through
--- `akkar.time` precisely so a manual clock can collapse it.
---
--- It ends the way a real one ends: the socket timeout expires, and a
--- timed-out read has left the stream out of step, so the connection is
--- broken afterwards. That is the half `:fail` must not have.
function Memory:hang(match, seconds)
  return self:on(match, function(self_)
    time.real.sleep(seconds or 60)
    self_.in_flight = false
    self_.broken = true
    error("redis: the command was sent and never answered", 0)
  end)
end

--- Makes the CONNECTION die mid-command, not merely the command fail.
---
--- A write that failed, a bulk reply cut short, a header that did not parse:
--- `akkar/redis.lua` sets `broken` for each of them and for nothing else.
---
--- Why the distinction is worth a method of its own here, in this adapter's
--- own terms: RESP matches replies to commands by ORDER and by nothing else.
--- A failed command leaves a connection whose stream is in step, and it goes
--- back to the pool correctly. A dropped one must never go back -- the next
--- borrower's `GET` reads the reply that belonged to this command, which is a
--- cache miss that never happened followed by somebody else's value, with no
--- error raised anywhere. Postgres refuses that with "connection is busy";
--- Redis has nothing to refuse with, so the fake has to be right about it.
---
--- `in_flight` is deliberately left UP: the command was on the wire when the
--- transport died, and `akkar/pool.lua`'s reuse predicate for Redis reads
--- `not conn.broken and not conn.in_flight` -- both halves, because either
--- one alone lets a poisoned connection through.
function Memory:drop(match)
  return self:on(match, function(self_)
    self_.broken = true
    error("redis: write failed: connection reset by peer", 0)
  end)
end

-- ============================================================== the commands
-- The `do_` locals are the implementations. The methods are the round trips.

local function do_get(self, key)
  local entry = live(self, key)
  return entry and entry.value or nil
end

local function do_set(self, key, value, ttl)
  self.store[key] = {
    value = tostring(value),
    expires = ttl and (self.now() + ttl) or nil,
  }
  return "OK"
end

local function do_del(self, ...)
  local removed = 0
  for i = 1, select("#", ...) do
    local key = (select(i, ...))
    if live(self, key) then removed = removed + 1 end
    self.store[key] = nil
  end
  return removed
end

--- Counts, preserving any TTL already on the key -- which is what makes it
--- usable for a rate limit rather than only for a counter.
local function do_incr(self, key)
  local entry = live(self, key)
  local n = (entry and tonumber(entry.value) or 0) + 1
  self.store[key] = { value = tostring(n), expires = entry and entry.expires or nil }
  return n
end

local function do_expire(self, key, seconds)
  local entry = live(self, key)
  if not entry then return 0 end
  entry.expires = self.now() + seconds
  return 1
end

--- Redis semantics, so a test written against one holds against the other:
--- -2 when the key is gone, -1 when it has no expiry.
local function do_ttl(self, key)
  local entry = live(self, key)
  if not entry then return -2 end
  if not entry.expires then return -1 end
  return entry.expires - self.now()
end

function Memory:get(key)
  admit(self, "GET", key)
  return do_get(self, key)
end

function Memory:set(key, value, ttl)
  admit(self, "SET", key)
  return do_set(self, key, value, ttl)
end

function Memory:del(...)
  admit(self, "DEL", (select(1, ...)))
  return do_del(self, ...)
end

function Memory:incr(key)
  admit(self, "INCR", key)
  return do_incr(self, key)
end

function Memory:expire(key, seconds)
  admit(self, "EXPIRE", key)
  return do_expire(self, key, seconds)
end

function Memory:ttl(key)
  admit(self, "TTL", key)
  return do_ttl(self, key)
end

-- ================================================== hashes, sorted sets, eval
--
-- WHY THIS ADAPTER GREW A THIRD OF REDIS.
--
-- `akkar.limit` and `akkar.idempotency` do their whole job inside `EVAL`,
-- because every decision they make is read-then-write and only the server can
-- make that atomic. This adapter answered "unsupported command" to `EVAL`, so
-- both specs opened with a `reachable()` probe and a top-level `return` --
-- meaning that on a machine without Redis, the rate limiter, the concurrency
-- limiter, the load shedder and the whole idempotency module were **not
-- tested at all**. Two of the defects fixed this week lived in exactly there.
--
-- So the scripts run here now. The process is Lua and the scripts are Lua;
-- what was missing was the handful of data types they touch.
--
-- THE LIMIT, in this adapter's own voice: THIS EXECUTES THE SCRIPT, IT DOES
-- NOT PROVE THE SCRIPT IS ATOMIC. Atomicity is a property of Redis, and the
-- Redis-backed specs are where it is proved. A fake whose safety property
-- differs from the real one is how a test proves the wrong thing -- so this
-- one claims logic and says plainly that it does not claim isolation.

local function hash_of(self, key)
  local entry = live(self, key)
  if not entry then entry = {} self.store[key] = entry end
  entry.hash = entry.hash or {}
  return entry.hash
end

local function zset_of(self, key)
  local entry = live(self, key)
  if not entry then entry = {} self.store[key] = entry end
  entry.zset = entry.zset or {}
  return entry.zset
end

--- Members whose score falls inside [min, max], ordered by score.
local function zrange_by_score(zset, min, max)
  local out = {}
  for member, score in pairs(zset) do
    if score >= min and score <= max then out[#out + 1] = { member, score } end
  end
  table.sort(out, function(a, b)
    if a[2] == b[2] then return tostring(a[1]) < tostring(b[1]) end
    return a[2] < b[2]
  end)
  local members = {}
  for i, pair in ipairs(out) do members[i] = pair[1] end
  return members
end

local function score_bound(text, fallback)
  if text == "-inf" then return -math.huge end
  if text == "+inf" or text == "inf" then return math.huge end
  return tonumber(text) or fallback
end

-- A digest only has to be stable and unique among the scripts one process
-- loads; nothing here is a security boundary, and a real SHA-1 would be a
-- dependency bought for nothing.
local function digest_of(script)
  local h = 5381
  for i = 1, #script do
    h = (h * 33 + script:byte(i)) % 0x100000000
  end
  return string.format("%08x%08x", h, #script)
end

--- Redis converts a Lua number to an integer on the way out, and `false` to a
--- nil reply. Matching that matters: a script returning 1.5 must not reach a
--- caller as 1.5 here and 1 against a real server.
local function to_reply(value)
  if type(value) == "number" then return math.floor(value) end
  if value == false then return nil end
  if type(value) == "table" then
    if value.ok then return value.ok end
    if value.err then error(value.err, 0) end
    local out = {}
    for i, item in ipairs(value) do out[i] = to_reply(item) end
    return out
  end
  return value
end

-- Forward declaration: a script calls back into the dispatcher, and the
-- dispatcher runs scripts.
local dispatch

local function do_eval(self, script, numkeys, ...)
  local args = { ... }
  numkeys = tonumber(numkeys) or 0

  local KEYS, ARGV = {}, {}
  for i = 1, numkeys do KEYS[i] = args[i] end
  for i = numkeys + 1, #args do ARGV[#ARGV + 1] = tostring(args[i]) end

  local env = {
    KEYS = KEYS, ARGV = ARGV,
    tonumber = tonumber, tostring = tostring, type = type,
    ipairs = ipairs, pairs = pairs, next = next, select = select,
    math = math, table = table, string = string, error = error,
    pcall = pcall, assert = assert, unpack = table.unpack,
    redis = {
      -- Through the DISPATCHER, not through `command`. A script is one round
      -- trip on a real server however many commands it runs, so charging the
      -- capacity model per `redis.call` would invent a Redis nobody has -- and
      -- a fault programmed on `GET` must not fire for a `GET` the caller never
      -- sent. `EVAL` is what the caller sent, and `EVAL` is what is admitted.
      call = function(command, ...)
        local ok, result = pcall(dispatch, self, command, ...)
        if not ok then error(result, 0) end
        return result == nil and false or result
      end,
      status_reply = function(text) return { ok = text } end,
      error_reply  = function(text) return { err = text } end,
      sha1hex      = digest_of,
      breakpoint   = function() end,
      log          = function() end,
      LOG_WARNING  = 3,
    },
  }
  -- `pcall` RETURNS the error; `call` raises it. That is the entire
  -- difference between them, and this line used to make them the same
  -- function -- so a script written to inspect `result.err` and carry on
  -- aborted here instead, and the only place it did so was the fake. A test
  -- double whose failure mode differs from the real thing is worse than no
  -- double: it certifies scripts that Redis will run differently.
  env.redis.pcall = function(command, ...)
    local ok, result = pcall(dispatch, self, command, ...)
    if not ok then
      return { err = type(result) == "table" and result.err or tostring(result) }
    end
    return result == nil and false or result
  end

  local chunk, why = load(script, "=redis-script", "t", env)
  if not chunk then
    error("akkar.cache.memory: script would not compile: " .. tostring(why), 0)
  end
  return to_reply(chunk())
end

--- Every command, with no round trip charged and no fault consulted. This is
--- what a script's `redis.call` reaches and what `Memory:command` runs once it
--- has been admitted; nothing else should call it.
function dispatch(self, name, ...)
  local verb = tostring(name):upper()
  if verb == "GET"    then return do_get(self, ...) end
  if verb == "SET"    then
    -- `SET key value [NX] [EX seconds]`. NX is what makes SET a claim rather
    -- than a write, and `akkar.jobs` depends on the false it returns.
    local key, value = ...
    local ttl, only_if_absent
    local rest = { select(3, ...) }
    local i = 1
    while i <= #rest do
      local option = tostring(rest[i]):upper()
      if option == "NX" then only_if_absent = true i = i + 1
      elseif option == "EX" then ttl = tonumber(rest[i + 1]) i = i + 2
      elseif option == "PX" then ttl = (tonumber(rest[i + 1]) or 0) / 1000 i = i + 2
      else i = i + 1 end
    end
    if only_if_absent and live(self, key) then return nil end
    return do_set(self, key, value, ttl)
  end
  if verb == "DEL"    then return do_del(self, ...) end
  if verb == "INCR"   then return do_incr(self, ...) end
  if verb == "EXPIRE" then return do_expire(self, ...) end
  if verb == "TTL"    then return do_ttl(self, ...) end
  if verb == "PING"   then return "PONG" end
  if verb == "LLEN"   then
    local entry = live(self, (select(1, ...)))
    return entry and #entry.list or 0
  end
  if verb == "LPUSH" then
    local key, value = ...
    local entry = live(self, key) or { list = {} }
    entry.list = entry.list or {}
    table.insert(entry.list, 1, value)
    self.store[key] = entry
    return #entry.list
  end
  if verb == "BRPOP" then
    local key = (select(1, ...))
    local entry = live(self, key)
    if not entry or not entry.list or #entry.list == 0 then return nil end
    return { key, table.remove(entry.list) }
  end
  if verb == "RPOP" then
    local key = (select(1, ...))
    local entry = live(self, key)
    if not entry or not entry.list or #entry.list == 0 then return nil end
    return table.remove(entry.list)
  end
  if verb == "LRANGE" then
    local key, from, to = ...
    local entry = live(self, key)
    local list = entry and entry.list or {}
    local n = #list
    from, to = tonumber(from) or 0, tonumber(to) or -1
    if from < 0 then from = n + from end
    if to < 0 then to = n + to end
    local out = {}
    for i = from, to do
      if list[i + 1] ~= nil then out[#out + 1] = list[i + 1] end
    end
    return out
  end
  if verb == "LTRIM" then
    local key, from, to = ...
    local entry = live(self, key)
    if not entry or not entry.list then return "OK" end
    local list, n = entry.list, #entry.list
    from, to = tonumber(from) or 0, tonumber(to) or -1
    if from < 0 then from = n + from end
    if to < 0 then to = n + to end
    local kept = {}
    for i = from, to do
      if list[i + 1] ~= nil then kept[#kept + 1] = list[i + 1] end
    end
    entry.list = kept
    return "OK"
  end

  -- ------------------------------------------------------------------ hashes
  if verb == "HSET" or verb == "HMSET" then
    local key = (select(1, ...))
    local hash = hash_of(self, key)
    local fields = { select(2, ...) }
    local written = 0
    for i = 1, #fields - 1, 2 do
      if hash[tostring(fields[i])] == nil then written = written + 1 end
      hash[tostring(fields[i])] = tostring(fields[i + 1])
    end
    return verb == "HMSET" and "OK" or written
  end
  if verb == "HGET" then
    local key, field = ...
    local entry = live(self, key)
    return entry and entry.hash and entry.hash[tostring(field)] or nil
  end
  if verb == "HMGET" then
    local key = (select(1, ...))
    local entry = live(self, key)
    local hash = entry and entry.hash or {}
    local out = {}
    for i = 2, select("#", ...) do
      -- A missing field is `false` in a Redis script, not a hole: an array
      -- with a nil in the middle would change its own length.
      out[i - 1] = hash[tostring((select(i, ...)))] or false
    end
    return out
  end
  if verb == "HINCRBY" then
    local key, field, by = ...
    local hash = hash_of(self, key)
    local n = (tonumber(hash[tostring(field)]) or 0) + (tonumber(by) or 0)
    hash[tostring(field)] = tostring(n)
    return n
  end

  -- ------------------------------------------------------------- sorted sets
  if verb == "ZADD" then
    local key, score, member = ...
    local zset = zset_of(self, key)
    local added = zset[tostring(member)] == nil and 1 or 0
    zset[tostring(member)] = tonumber(score)
    return added
  end
  if verb == "ZREM" then
    local key = (select(1, ...))
    local zset = zset_of(self, key)
    local removed = 0
    for i = 2, select("#", ...) do
      local member = tostring((select(i, ...)))
      if zset[member] ~= nil then removed = removed + 1 end
      zset[member] = nil
    end
    return removed
  end
  if verb == "ZCARD" then
    local entry = live(self, (select(1, ...)))
    local n = 0
    if entry and entry.zset then for _ in pairs(entry.zset) do n = n + 1 end end
    return n
  end
  if verb == "ZRANGEBYSCORE" then
    local key, min, max = ...
    local entry = live(self, key)
    if not entry or not entry.zset then return {} end
    return zrange_by_score(entry.zset, score_bound(min, -math.huge),
                                       score_bound(max, math.huge))
  end
  if verb == "ZREMRANGEBYSCORE" then
    local key, min, max = ...
    local entry = live(self, key)
    if not entry or not entry.zset then return 0 end
    local doomed = zrange_by_score(entry.zset, score_bound(min, -math.huge),
                                               score_bound(max, math.huge))
    for _, member in ipairs(doomed) do entry.zset[member] = nil end
    return #doomed
  end

  -- --------------------------------------------------------------- the clock
  if verb == "TIME" then
    -- Redis answers seconds and microseconds, as strings, and the limiter's
    -- script divides the second by a million. Timestamps come from here
    -- rather than from the caller for the same reason they do on a real
    -- server: a client with a wrong clock must not be able to move a window.
    local now = self.now()
    local seconds = math.floor(now)
    return { tostring(seconds), tostring(math.floor((now - seconds) * 1000000)) }
  end

  -- --------------------------------------------------------------- scripting
  if verb == "EVAL" then return do_eval(self, ...) end
  if verb == "EVALSHA" then
    local sha = (select(1, ...))
    local script = self.scripts and self.scripts[tostring(sha)]
    -- The real server answers NOSCRIPT and the evaluator falls back to EVAL.
    if not script then error("NOSCRIPT No matching script", 0) end
    return do_eval(self, script, select(2, ...))
  end
  if verb == "SCRIPT" then
    local action, script = ...
    if tostring(action):upper() == "LOAD" then
      self.scripts = self.scripts or {}
      local sha = digest_of(script)
      self.scripts[sha] = script
      return sha
    end
    return "OK"
  end

  error("akkar.cache.memory: unsupported command '" .. verb ..
        "'; this adapter implements the contract, not all of Redis", 0)
end

Memory._dispatch = dispatch     -- exposed for tests; not part of the contract

--- One command, as a caller sends it: admitted first, then dispatched.
function Memory:command(name, ...)
  local verb = tostring(name):upper()
  admit(self, verb, (select(1, ...)))
  return dispatch(self, name, ...)
end

--- `EVAL`, as a caller sends it. One round trip whatever the script does.
function Memory:eval(script, numkeys, ...)
  admit(self, "EVAL")
  return do_eval(self, script, numkeys, ...)
end

function Memory:release() end
function Memory:close() end

--- Drops expired entries now rather than on next read.
function Memory:sweep()
  local dropped = 0
  for key in pairs(self.store) do
    if not live(self, key) then dropped = dropped + 1 end
  end
  return dropped
end

function Memory:size()
  local n = 0
  for _ in pairs(self.store) do n = n + 1 end
  return n
end

--- Throws away every entry, and puts the connection back on its feet.
---
--- It does NOT unprogram the faults, for the same reason `akkar/db/memory.lua`
--- does not unprogram its responses: a scenario is set up once and reset
--- between the requests inside it. `broken` and `in_flight` DO clear, because
--- the only thing that brings a dead connection back is a new one, and this is
--- how a test says it took one.
function Memory:reset()
  self.store = {}
  self.broken, self.in_flight, self.free_at = nil, nil, nil
  return self
end

function M.factory(options)
  local instance = M.new(options)
  return setmetatable({ instance = instance }, {
    __call = function() return instance end,
  })
end

M.Memory = Memory
return M
