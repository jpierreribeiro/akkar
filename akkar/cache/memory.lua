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

local Memory = {}
Memory.__index = Memory

local M = {}

--- The clock is injectable so tests can move time without sleeping.
function M.new(options)
  options = options or {}
  return setmetatable({
    store = {},
    now = options.now or os.time,
  }, Memory)
end

local function live(self, key)
  local entry = self.store[key]
  if not entry then return nil end
  if entry.expires and entry.expires <= self:now() then
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
    expires = ttl and (self:now() + ttl) or nil,
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
  entry.expires = self:now() + seconds
  return 1
end

--- Redis semantics, so a test written against one holds against the other:
--- -2 when the key is gone, -1 when it has no expiry.
function Memory:ttl(key)
  local entry = live(self, key)
  if not entry then return -2 end
  if not entry.expires then return -1 end
  return entry.expires - self:now()
end

function Memory:command(name, ...)
  local verb = tostring(name):upper()
  if verb == "GET"    then return self:get(...) end
  if verb == "SET"    then return self:set(...) end
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
