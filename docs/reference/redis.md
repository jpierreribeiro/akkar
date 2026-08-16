# akkar.redis

The Redis adapter. It speaks RESP2 over a cqueues socket, so a command yields
the event loop while it waits instead of stalling every other request in the
process.

**When you need it.** State that has to be shared between processes: a cache
two workers agree on, a rate limit counted across a fleet, a job queue a
separate worker reads. `akkar.jobs.redis`, `akkar.limit` and
`akkar.idempotency` all take a connection from here.

```lua no-run
local redis = require "akkar.redis"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`conn.broken`](#connection) | field |
| [`conn.in_flight`](#connection) | field |
| [`conn:close`](#connclose) | method |
| [`conn:command`](#conncommand) | method |
| [`conn:del`](#conndel) | method |
| [`conn:expire`](#connexpirekey-seconds) | method |
| [`conn:get`](#conngetkey) | method |
| [`conn:incr`](#connincrkey) | method |
| [`conn:ping`](#connping) | method |
| [`conn:release`](#connrelease) | method |
| [`conn:set`](#connsetkey-value-ttl) | method |
| [`conn:settimeout`](#connsettimeoutseconds) | method |
| [`conn:ttl`](#connttlkey) | method |
| [`redis.connect`](#redisconnectconfig) | function |
| [`redis.Redis`](#redisredis-metatable) | table |

## redis.connect(config)

Builds a connector. It does not open a connection; calling what it returns
does.

| field | type | default | meaning |
|---|---|---|---|
| `host` | string | `"127.0.0.1"` | |
| `port` | number | `6379` | |
| `timeout` | number | `5` | how long a single read may wait, in seconds. Without a bound, a Redis that accepts the connection and then stops answering parks a worker for ever. |
| `password` | string | none | sends `AUTH` as soon as the socket opens |
| `database` | number | none | sends `SELECT` as soon as the socket opens |
| `pool_size` | number | `10` | how many connections to keep. `0` means no pool at all. |

**Returns** a callable table holding a pool. Calling it hands out a
`Connection`; `conn:release()` puts it back. With `pool_size = 0` it returns a
plain function instead, and every call opens a fresh connection.

**Raises**, at the moment a connection is opened rather than here, when `AUTH`
or `SELECT` is refused. The socket is closed before the error is raised, so a
wrong password does not leak a descriptor per attempt.

A wrong `host` or `port` does not raise here and does not raise when the
connector is called. The socket is connected lazily, so a refused connection
surfaces on the first command as `redis: write failed: 111`.

The config is not checked for unknown keys. `redis.connect { prot = 6380 }`
connects to 6379 without complaint, which is not how `app:run{}` behaves.

```lua
local redis = require "akkar.redis"

local connect = redis.connect { host = "127.0.0.1", port = 6379 }
local conn = connect()

print(conn:ping())                              --> PONG
print(conn:set("ref_redis_hello", "world"))     --> OK
print(conn:get "ref_redis_hello")               --> world
print(conn:del "ref_redis_hello")               --> 1

conn:release()
```

Connections come back from the pool, so a released one is handed out again:

```lua
local redis = require "akkar.redis"

local connect = redis.connect { port = 6379, pool_size = 4 }

local first = connect()
first:release()
local second = connect()
print(first == second)   --> true
second:release()

-- pool_size = 0 is a plain function, and every call is a new socket.
local unpooled = redis.connect { port = 6379, pool_size = 0 }
print(type(unpooled))    --> function
local fresh = unpooled()
print(fresh:ping())      --> PONG
fresh:close()
```

## redis.Redis (metatable)

The connection metatable. `Redis._encode` and `Redis._read_reply` hang off it
for the protocol tests and are not part of the contract.

## Connection

What the connector hands out. It answers `get`, `set` and `del`, which is the
whole `cache` capability contract, so it can be passed to `app:run { cache =
... }` directly with no wrapper.

Two fields carry the connection's health, and the pool reads both before
handing it out again:

| field | meaning |
|---|---|
| `broken` | a write failed, a read failed, or the reply was not RESP. The stream is out of step and the connection must not be reused. |
| `in_flight` | set before the write and cleared after the reply is read. Still set means a coroutine was abandoned mid-command, and the next reader would get somebody else's answer. |

An error reply from the server (`WRONGTYPE`, `NOSCRIPT`) is not a broken
connection. It is the server answering normally with bad news, and the stream
is still in step afterwards.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:command("LPUSH", "ref_redis_list", "a")

-- GET against a list is an error reply, not a transport failure.
local ok, err = pcall(conn.get, conn, "ref_redis_list")
print(ok, err)
print(conn.broken)     --> nil, the connection is still usable
print(conn:ping())     --> PONG

conn:del "ref_redis_list"
conn:release()
```

### conn:close()

Closes the socket and forgets it. Safe to call twice.

Every later command **raises** `redis: connection is closed`.

### conn:command(...)

Sends one command and reads one reply. Each argument is encoded as a bulk
string, so a value containing a space or a newline is harmless. This is the
method every other one on this page is built from, and it is how you reach a
verb akkar has no helper for.

**Returns** the reply: a string for a simple or bulk reply, a number for an
integer reply, a table for an array reply, `nil` for a null reply.

**Raises** `redis: connection is closed` when the socket is gone,
`redis: write failed: <errno>` when the command could not be sent, and
`redis: <server text>` for anything else, including error replies from the
server.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:command("HSET", "ref_redis_user", "name", "noether", "city", "erlangen")
print(conn:command("HGET", "ref_redis_user", "name"))   --> noether

local pair = conn:command("HMGET", "ref_redis_user", "name", "city")
print(pair[1], pair[2])                                 --> noether erlangen

conn:del "ref_redis_user"
conn:release()
```

### conn:del(...)

Deletes every key given.

**Returns** how many existed.

### conn:expire(key, seconds)

Puts a new expiry on an existing key.

**Returns** `1` when the key was there, `0` when it was not.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:set("ref_redis_session", "abc")
print(conn:expire("ref_redis_session", 60))    --> 1
print(conn:expire("ref_redis_absent", 60))     --> 0

conn:del "ref_redis_session"
conn:release()
```

### conn:get(key)

**Returns** the value as a string, or `nil` when the key is absent. Never a
JSON null sentinel: one of those leaking into a handler was a real defect
already.

### conn:incr(key)

Adds one, treating an absent key as zero.

**Returns** the new value as a number.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:del "ref_redis_counter"
print(conn:incr "ref_redis_counter")   --> 1
print(conn:incr "ref_redis_counter")   --> 2

conn:del "ref_redis_counter"
conn:release()
```

### conn:ping()

**Returns** the string `PONG`. The cheapest way to find out whether the
connection is alive.

### conn:release()

Returns the connection to its pool, or closes it when there is no pool.

Call it on every path. A connection that is taken and never released is one the
pool cannot hand to anybody else.

### conn:set(key, value, ttl)

Stores `value` under `key`. `ttl` is in seconds and optional; with it the call
becomes `SET key value EX ttl`.

**Returns** the string `OK`.

For `SET` with `NX`, use `conn:command("SET", key, value, "NX", "EX", ttl)`,
which answers `nil` rather than `OK` when the key already existed. That `nil`
is what makes `SET` a claim rather than a write, and it is what
`akkar.jobs.redis` builds deduplication out of.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:del "ref_redis_lock"
print(conn:command("SET", "ref_redis_lock", "1", "NX", "EX", 60))            --> OK
print(tostring(conn:command("SET", "ref_redis_lock", "1", "NX", "EX", 60)))  --> nil

conn:del "ref_redis_lock"
conn:release()
```

### conn:settimeout(seconds)

Sets how long a read on this connection may wait. Passing nothing puts the
connection's own default back, so a caller that raised the bound cannot leave
the socket unbounded by accident.

**Returns** the connection, so it can be chained.

Needed because one command is legitimately slower than the rest. `BRPOP key N`
blocks inside the server for up to N seconds, and a socket timeout below N
would kill a wait that is working exactly as intended. `akkar.jobs.redis`
raises the bound around its own blocking calls and puts it back on every path.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379, timeout = 5 }()

conn:settimeout(15)          -- a blocking command is about to run
print(conn:command("BRPOP", "ref_redis_empty", 1))   --> nil, nothing arrived
conn:settimeout(nil)         -- back to the connection's own 5 seconds

conn:release()
```

### conn:ttl(key)

**Returns** the seconds left, `-1` when the key exists with no expiry, `-2`
when the key is absent.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:set("ref_redis_brief", "1", 30)
print(conn:ttl "ref_redis_brief")     --> 30
print(conn:ttl "ref_redis_gone")      --> -2

conn:del "ref_redis_brief"
conn:release()
```

## Not here

**No pipelining.** One command, one reply, one round trip. A script through
`EVAL` is how several operations cost one trip, and it makes them atomic as
well.

**No pub/sub.** A subscribed connection stops answering ordinary commands, which
a pooled connection cannot do. `conn:command("SUBSCRIBE", ...)` sends the
command and then leaves you holding a connection the pool must never get back.

**No `MULTI` and `EXEC` helpers.** The raw commands go through `conn:command`,
but nothing here keeps a transaction on one connection for you. Use a script.

**No cluster, no sentinel, no TLS.** One host, one port, a plain socket.

**No config validation.** Unknown keys in the `connect` table are ignored rather
than rejected, which is not how [`app:run`](akkar.md#apprunconfig) behaves.

**No RESP3.** The reply reader handles the five RESP2 types and raises
`unexpected RESP tag` on anything else.

## See also

- [akkar.cache.memory](cache.md) for the same contract without a server, for
  tests and single-process deployments
- [akkar.jobs](jobs.md), whose Redis store is built on a connection from here
- [akkar](akkar.md) for `app:run { cache = ... }`, which takes a connection
  directly
- the module source, `akkar/redis.lua`, for why the protocol is written out
  rather than depended upon
