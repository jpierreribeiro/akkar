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
]]

local time = require "akkar.time"

local Memory = {}
Memory.__index = Memory

local M = {}

--- The clock is injectable so tests can move time without sleeping.
function M.new(options)
  options = options or {}
  return setmetatable({
    store = {},
    now = options.now or time.now,
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

function Memory:get(key)
  local entry = live(self, key)
  return entry and entry.value or nil
end

function Memory:set(key, value, ttl)
  self.store[key] = {
    value = tostring(value),
    expires = ttl and (self.now() + ttl) or nil,
  }
  return "OK"
end

function Memory:del(...)
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
function Memory:incr(key)
  local entry = live(self, key)
  local n = (entry and tonumber(entry.value) or 0) + 1
  self.store[key] = { value = tostring(n), expires = entry and entry.expires or nil }
  return n
end

function Memory:expire(key, seconds)
  local entry = live(self, key)
  if not entry then return 0 end
  entry.expires = self.now() + seconds
  return 1
end

--- Redis semantics, so a test written against one holds against the other:
--- -2 when the key is gone, -1 when it has no expiry.
function Memory:ttl(key)
  local entry = live(self, key)
  if not entry then return -2 end
  if not entry.expires then return -1 end
  return entry.expires - self.now()
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

function Memory:eval(script, numkeys, ...)
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
      call = function(command, ...)
        local ok, result = pcall(self.command, self, command, ...)
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
    local ok, result = pcall(self.command, self, command, ...)
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

function Memory:command(name, ...)
  local verb = tostring(name):upper()
  if verb == "GET"    then return self:get(...) end
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
    return self:set(key, value, ttl)
  end
  if verb == "DEL"    then return self:del(...) end
  if verb == "INCR"   then return self:incr(...) end
  if verb == "EXPIRE" then return self:expire(...) end
  if verb == "TTL"    then return self:ttl(...) end
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
  if verb == "EVAL" then return self:eval(...) end
  if verb == "EVALSHA" then
    local sha = (select(1, ...))
    local script = self.scripts and self.scripts[tostring(sha)]
    -- The real server answers NOSCRIPT and the evaluator falls back to EVAL.
    if not script then error("NOSCRIPT No matching script", 0) end
    return self:eval(script, select(2, ...))
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

function Memory:reset()
  self.store = {}
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
