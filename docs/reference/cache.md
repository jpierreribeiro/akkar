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
| [`cache:drop`](#cachedropmatch) | method |
| [`cache:eval`](#cacheevalscript-numkeys-) | method |
| [`cache:expire`](#cacheexpirekey-seconds) | method |
| [`cache:fail`](#cachefailmatch-message) | method |
| [`cache:get`](#cachegetkey) | method |
| [`cache:hang`](#cachehangmatch-seconds) | method |
| [`cache:incr`](#cacheincrkey) | method |
| [`cache:on`](#cacheonmatch-effect) | method |
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
| `max_qps` | number | none | how many commands the store serves per second. See [Capacity](#capacity-max_qps-and-latency_ms). |
| `latency_ms` | number | none | how long each command takes. |

**Returns** a `Cache`. Its `per_process` field is `true`, which is how a caller
that needs a value shared between processes finds out it is not going to get
one here.

**Raises** when `max_qps` is not greater than zero, or `latency_ms` is
negative.

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

### Capacity: max_qps and latency_ms

The two together are a store that is slow, or saturated, or both, without a
Redis existing — so a handler can be tested against the dependency a capacity
diagram describes rather than against one that always answers instantly.

They are **one queue, not two delays added together**. A command occupies the
store for `latency_ms`, and `max_qps` says how often a new one may start;
whichever is the tighter constraint is the one a caller feels. At 1500/s and
8 ms the service time binds, because 8 ms of work cannot be issued 1500 times a
second. At 50/s and 8 ms the rate binds.

One command is one round trip, and a script is one round trip however many
`redis.call`s it makes — because that is what it costs on a real server.

**The wait goes through [akkar.time](time.md), never through a wall clock of
its own.** Under `akkar.time.manual` a modelled second passes instantly, so a
test stays deterministic and fast; under the real clock the same numbers cost
real seconds. One configuration, and which behaviour you get is decided by
which clock is installed. ([`cache:hang`](#cachehangmatch-seconds) is
deliberately the exception.)

It is a model and it says so. A real server's service time varies with the
command, the value size and the eviction it is doing. This reproduces a queue
with a fixed service rate, which is what a capacity diagram is drawn from — and
the point of one number configuring both is that the prediction and the
measurement can then be compared and found to disagree.

```lua
local memory = require "akkar.cache.memory"
local time   = require "akkar.time"

local clock   = time.manual { monotime = 0 }
local restore = time.set(clock)

local cache = memory.new { max_qps = 1500, latency_ms = 8 }
for i = 1, 10 do cache:get("ref_cache_k" .. i) end

print(("%.3f"):format(clock.monotime()))   --> 0.080, and nothing waited
restore()
```

### Faults

A cache that always answers is not the cache anybody runs, so this one can be
made to break. [`cache:fail`](#cachefailmatch-message),
[`cache:hang`](#cachehangmatch-seconds) and [`cache:drop`](#cachedropmatch) are
the same three [akkar.db.memory](db.md#memory) has, named after what
[akkar.redis](redis.md) actually does — because a fake whose failures are not
failures the real adapter can produce is how a test proves the wrong thing.

| method | what really produces it | what it leaves behind |
|---|---|---|
| `fail` | an error reply: `WRONGTYPE`, `NOSCRIPT`, `READONLY`, `OOM`, `NOAUTH` | a **healthy** connection — the RESP stream is still in step |
| `hang` | a command sent and never answered, ended by the socket timeout | `broken`, because a timed-out read leaves the stream out of step |
| `drop` | a write that failed, a truncated reply, a header that did not parse | `broken` **and** `in_flight`, and every later command fails |

`fail` against `drop` is the distinction that matters, and it matters more on a
cache than on a database. RESP matches replies to commands by order and by
nothing else, so a connection put back in the pool with a reply still unread
hands the next request somebody else's answer — a cache miss that never
happened, then a stranger's value, with no error raised anywhere. Postgres
refuses that with "connection is busy"; Redis has nothing to refuse with.

**What a fault is matched against** is the verb, and the key when the verb has
one. So `"DEL"` is every delete, `"session:7"` is every command touching that
key, and `"GET session:7"` is exactly one. A script matches on `"EVAL"` alone.

The needle is tried as **plain text first and as a Lua pattern only if that
finds nothing**, because keys are full of pattern magic: `rate-limit:user-7`
read as a pattern matches nothing anybody meant. `^GET session:` still anchors.

The first fault that matches wins, in the order they were added.
[`cache:reset`](#cachereset) does not unprogram them.

```lua
local memory = require "akkar.cache.memory"

local cache = memory.new():fail("GET ref_cache_hot", "WRONGTYPE")

-- The command fails; the connection does not.
print(pcall(function() return cache:get "ref_cache_hot" end))
print(cache.broken)                       --> nil
print(cache:set("ref_cache_cold", "1"))   --> OK
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

### cache:drop(match)

Programs a matching command to kill the CONNECTION, not merely to fail it. It
raises `redis: write failed: connection reset by peer`, and **every** command
afterwards raises the same thing, which is what a dead transport does. Only
[`cache:reset`](#cachereset) undoes it.

It leaves `broken` and `in_flight` both set — the pair
[akkar.redis](redis.md)'s pool reads to decide a connection is not fit for
reuse. Both, because the command was on the wire when the transport died, and a
connection handed back with a reply still unread gives the next borrower that
reply as its own answer.

**Returns** the cache, so it chains.

```lua
local memory = require "akkar.cache.memory"

local cache = memory.new():drop "SET ref_cache_orders"

print(cache:get "ref_cache_anything")                                  --> nil
print(pcall(function() return cache:set("ref_cache_orders", "1") end))
print(pcall(function() return cache:get "ref_cache_anything" end))
print(cache.broken, cache.in_flight)

-- reset revives the connection. It does NOT unprogram the fault, so the
-- command that matched it drops again; everything else works.
cache:reset()
print(cache:get "ref_cache_anything")   --> nil, the connection is alive
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

### cache:fail(match, message)

Programs a matching command to come back as an **error reply**: the server
answered, and it answered badly. It raises `redis: <message>`, defaulting to
`redis: ERR command failed`.

The connection stays **usable**, and that is not an oversight. `WRONGTYPE`,
`NOSCRIPT`, `READONLY` and `OOM` leave the RESP stream perfectly in step, and
[akkar.redis](redis.md) deliberately does not mark the connection broken for
them — throwing a good connection away on every `WRONGTYPE` is a defect that
module already fixed once, measured as a pool going from `live=1 idle=1` to
`live=0 idle=0`.

**Returns** the cache, so it chains.

```lua
local memory = require "akkar.cache.memory"

local cache = memory.new()
cache:fail("INCR ref_cache_quota",
           "OOM command not allowed when used memory > 'maxmemory'")

print(pcall(function() return cache:incr "ref_cache_quota" end))
print(cache:set("ref_cache_other", "still works"))   --> OK
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

### cache:hang(match, seconds)

Programs a matching command to wait `seconds` (60 by default) and then raise
`redis: the command was sent and never answered` — a command that reached the
server and was never answered, ended by the socket's own timeout. It leaves the
connection `broken`, because a timed-out read has left the RESP stream out of
step.

The wait is real and it yields, which is the point: it stages a coroutine
abandoned mid-command, which raising immediately does not. A request deadline
above it fires, and what is then observable is whether the framework released
the capability — the defect class an audit of this project once found seven of.

**It waits on the real clock even when a manual one is installed**, which is
the opposite of what `latency_ms` does. A manual clock would collapse the wait
to nothing and `hang` would quietly become `fail` under another name.

**Returns** the cache, so it chains.

```lua
local akkar   = require "akkar"
local cqueues = require "cqueues"
local memory  = require "akkar.cache.memory"

local cache = memory.new():hang("GET ref_cache_slow", 0.3)

local app = akkar.new()
app:get("/slow", function(req) return { v = req.cache:get "ref_cache_slow" } end)

local client = app:test { cache = function() return cache end, timeout = 0.1 }

-- A deadline needs a controller to yield to; outside one it arms nothing.
local cq = cqueues.new()
cq:wrap(function()
  print(client:get("/slow").status)   --> 503, answered on the deadline
end)
assert(cq:loop(20))
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

### cache:on(match, effect)

Programs what a matching command does. `effect` is called as `effect(cache)`
before the command runs: raising is how it changes the outcome, returning is
how it lets the command proceed. `fail`, `hang` and `drop` are written in terms
of this and are the three worth having.

The counterpart of [`fake:on`](db.md#fakeonpattern-response), and the
difference between them is the difference between the two adapters. That one is
a stand-in: it executes no SQL, so a query nobody programmed raises. This one
is a real implementation, so programming is an **override** — a command nobody
programmed still does its real work.

**Returns** the cache, so it chains.

```lua
local memory = require "akkar.cache.memory"

local seen = 0
local cache = memory.new():on("INCR", function() seen = seen + 1 end)

print(cache:incr "ref_cache_n")   --> 1, the command still ran
print(cache:incr "ref_cache_n")   --> 2
print(seen)                       --> 2
```

### cache:release()

Does nothing and returns nothing. A pooled connection returns itself to its
pool here; this one has no pool and says so by doing nothing.

### cache:reset()

Throws away every entry, and puts a `broken` connection back on its feet.

Programmed faults **stay**, for the same reason `akkar.db.memory` keeps its
programmed responses: a scenario is set up once and reset between the requests
inside it. The modelled queue drains with the entries; the capacity itself
stays.

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
