# akkar.cache.memory

An in-process cache adapter. It is a real implementation rather than a
stand-in: a TTL really expires, `incr` really counts, and `eval` really runs a
Redis script.

**When you need it.** A test that needs a cache without a Redis running, and a
single-process deployment that wants caching and does not want a second
service. It is per-process, so two worker processes hold two caches that do not
agree with each other.

```lua no-run
local memory = require "akkar.cache.memory"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`cache.per_process`](#cache) | field |
| [`cache:close`](#cacheclose) | method |
| [`cache:command`](#cachecommandname-) | method |
| [`cache:del`](#cachedel) | method |
| [`cache:eval`](#cacheevalscript-numkeys-) | method |
| [`cache:expire`](#cacheexpirekey-seconds) | method |
| [`cache:get`](#cachegetkey) | method |
| [`cache:incr`](#cacheincrkey) | method |
| [`cache:release`](#cacherelease) | method |
| [`cache:reset`](#cachereset) | method |
| [`cache:set`](#cachesetkey-value-ttl) | method |
| [`cache:size`](#cachesize) | method |
| [`cache:sweep`](#cachesweep) | method |
| [`cache:ttl`](#cachettlkey) | method |
| [`memory.factory`](#memoryfactoryoptions) | function |
| [`memory.Memory`](#memorymemory-metatable) | table |
| [`memory.new`](#memorynewoptions) | function |

## memory.factory(options)

Builds one cache and returns a callable that always hands back that same cache.
`options` is passed through to `memory.new`.

**Returns** a table. Calling it returns the `Cache`. Its `instance` field is the
same `Cache`.

```lua
local memory = require "akkar.cache.memory"

local cache = memory.factory()
assert(cache() == cache())
assert(cache() == cache.instance)

cache():set("ref_cache_hits", 1)
print(cache.instance:get "ref_cache_hits")
```

## memory.Memory (metatable)

The metatable every cache carries. Exposed so a caller can extend it or check
`getmetatable(cache) == memory.Memory`.

## memory.new(options)

Builds a cache. `options` may be omitted.

| field | type | default | meaning |
|---|---|---|---|
| `now` | function | `akkar.time.now` | reads the current time in seconds. Injected so a test can move time instead of sleeping. |

**Returns** a `Cache`. Its `per_process` field is `true`, which is how a caller
that needs a value shared between processes finds out it is not going to get
one here.

```lua
local memory = require "akkar.cache.memory"

local clock = 1000
local cache = memory.new { now = function() return clock end }

cache:set("ref_cache_token", "abc", 30)
print(cache:get "ref_cache_token")   --> abc

clock = clock + 31
print(cache:get "ref_cache_token")   --> nil
print(cache.per_process)             --> true
```

## Cache

The object `memory.new` returns. It satisfies the `cache` capability contract
that `app:run{}` and `app:test{}` check, which is `get`, `set` and `del`.

Expiry is lazy. An entry is dropped when it is next read, not by a timer, so an
expired key still occupies memory until something touches it or `cache:sweep()`
runs.

```lua
local akkar  = require "akkar"
local memory = require "akkar.cache.memory"

local app = akkar.new()

app:get("/count", function(req)
  return { seen = req.cache:incr "ref_cache_visits" }
end)

local client = app:test { cache = memory.new() }
print(client:get("/count").body.seen)   --> 1
print(client:get("/count").body.seen)   --> 2
```

### cache:close()

Does nothing and returns nothing. It exists so a caller can treat this and a
Redis connection the same way.

### cache:command(name, ...)

Runs one Redis command by name. `name` is matched without regard to case. The
reply follows Redis: a missing key is `nil`, a count is a number, `SET` answers
the string `OK`.

The commands implemented:

| group | verbs |
|---|---|
| strings | `GET`, `SET` (with `NX`, `EX`, `PX`), `DEL`, `INCR`, `EXPIRE`, `TTL` |
| lists | `LPUSH`, `RPOP`, `BRPOP`, `LLEN`, `LRANGE`, `LTRIM` |
| hashes | `HSET`, `HMSET`, `HGET`, `HMGET`, `HINCRBY` |
| sorted sets | `ZADD`, `ZREM`, `ZCARD`, `ZRANGEBYSCORE`, `ZREMRANGEBYSCORE` |
| scripting | `EVAL`, `EVALSHA`, `SCRIPT LOAD` |
| other | `PING`, `TIME` |

`BRPOP` does not block. It pops if something is there and returns `nil`
otherwise, because nothing in this process could push while it waited.

**Raises** `akkar.cache.memory: unsupported command 'X'; this adapter
implements the contract, not all of Redis` for any other verb. `EVALSHA` for a
script that was never `SCRIPT LOAD`ed raises `NOSCRIPT No matching script`, the
same reply a real server sends.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

-- SET NX is a claim rather than a write: the second one answers nil.
print(cache:command("SET", "ref_cache_lock", "1", "NX", "EX", 60))
print(tostring(cache:command("SET", "ref_cache_lock", "1", "NX", "EX", 60)))

local ok, err = pcall(cache.command, cache, "SINTERCARD", "a", "b")
print(ok, err)
```

### cache:del(...)

Deletes every key given.

**Returns** how many of them were live at the time. An expired key counts as
absent.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_a", "1")
cache:set("ref_cache_b", "2")
print(cache:del("ref_cache_a", "ref_cache_b", "ref_cache_never"))   --> 2
```

### cache:eval(script, numkeys, ...)

Runs `script` the way Redis `EVAL` does. The first `numkeys` extra arguments
become `KEYS`, the rest become `ARGV` as strings. Inside the script,
`redis.call`, `redis.pcall`, `redis.status_reply`, `redis.error_reply`,
`redis.sha1hex` and `redis.log` are available, and `redis.call` goes back
through `cache:command`.

Replies are converted the way a real server converts them: a number is
truncated to an integer, `false` becomes `nil`.

**Returns** the converted reply.

**Raises** `akkar.cache.memory: script would not compile: ...` when `load`
rejects the script, and whatever `redis.call` raises when the script calls a
command this adapter does not implement.

**This runs the script. It does not make the script atomic.** Atomicity is a
property of a real Redis server, and only a Redis-backed test proves it.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

local n = cache:eval([[
  local current = tonumber(redis.call('GET', KEYS[1]) or '0')
  redis.call('SET', KEYS[1], current + tonumber(ARGV[1]))
  return current + tonumber(ARGV[1])
]], 1, "ref_cache_score", 7)

print(n)                            --> 7
print(cache:get "ref_cache_score")  --> 7
```

### cache:expire(key, seconds)

Sets a new expiry, counted from now, on a key that already exists.

**Returns** `1` when the key was there, `0` when it was not.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_session", "x")
print(cache:expire("ref_cache_session", 60))   --> 1
print(cache:expire("ref_cache_missing", 60))   --> 0
```

### cache:get(key)

**Returns** the stored value as a string, or `nil` when the key is absent or
expired. Values are stored through `tostring`, so a number goes in and a string
comes out.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_n", 41)
print(type(cache:get "ref_cache_n"), cache:get "ref_cache_n")   --> string 41
print(tostring(cache:get "ref_cache_absent"))                   --> nil
```

### cache:incr(key)

Adds one, treating an absent key as zero. Any expiry already on the key is
kept, which is what makes it usable for a rate limit and not only for a
counter.

**Returns** the new value, as a number.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_calls", 0, 60)
print(cache:incr "ref_cache_calls")   --> 1
print(cache:ttl "ref_cache_calls")    --> 60, the expiry survived the incr
```

### cache:release()

Does nothing and returns nothing. A pooled connection returns itself to its
pool here; this one has no pool and says so by doing nothing.

### cache:reset()

Throws away every entry.

**Returns** the cache, so it can be chained.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_x", "1")
print(cache:reset():size())   --> 0
```

### cache:set(key, value, ttl)

Stores `value` under `key`. `ttl` is in seconds and is optional; without it the
entry never expires. `value` is stored as `tostring(value)`.

**Returns** the string `OK`.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

print(cache:set("ref_cache_greeting", "hello"))       --> OK
print(cache:set("ref_cache_greeting", "hello", 30))   --> OK
```

### cache:size()

**Returns** how many entries the table holds, counting entries that have
expired but have not been read since. `cache:sweep()` first if you want the
live count.

### cache:sweep()

Drops every expired entry now instead of waiting for the next read.

**Returns** how many were dropped.

```lua
local memory = require "akkar.cache.memory"

local clock = 1000
local cache = memory.new { now = function() return clock end }

cache:set("ref_cache_one", "1", 5)
cache:set("ref_cache_two", "2")
clock = clock + 10

print(cache:size())    --> 2, the expired entry is still occupying memory
print(cache:sweep())   --> 1
print(cache:size())    --> 1
```

### cache:ttl(key)

**Returns** the seconds left, or `-1` when the key exists with no expiry, or
`-2` when the key is absent or expired. Those two numbers are Redis's, so a
test written against one store holds against the other.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_forever", "1")
cache:set("ref_cache_brief", "1", 30)

print(cache:ttl "ref_cache_forever")   --> -1
print(cache:ttl "ref_cache_brief")     --> 30
print(cache:ttl "ref_cache_gone")      --> -2
```

## Not here

**No `require "akkar.cache"`.** There is no module of that name. `akkar/cache/`
holds one file, `memory.lua`, and `akkar.cache.memory` is the whole of it.

**No Redis cache adapter.** A connection from [akkar.redis](redis.md) already
answers `get`, `set` and `del`, so it satisfies the `cache` capability directly
and needs no wrapper.

**No `KEYS`, no `SCAN`, no deleting by pattern.** `cache:command` raises for
those rather than pretending.

**No size limit and no eviction policy.** Nothing here bounds how much the table
holds. A cache that only ever grows needs a `ttl` on every `set`.

**No sharing between processes.** `per_process` is `true` and it is not a
configuration option. A counter that has to be right across a fleet belongs in
Redis.

## See also

- [akkar](akkar.md) for `app:run { cache = ... }` and `app:test { cache = ... }`,
  which inject a cache as `req.cache`
- [akkar.redis](redis.md) for the store that is shared between processes
- [akkar.jobs](jobs.md), whose Redis store is built on a cache-shaped object
- the module source, `akkar/cache/memory.lua`, for why an in-memory adapter
  grew a third of Redis
