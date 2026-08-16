# akkar.pool

A bounded pool of resources. It knows nothing about what it holds: opening one
is a function you pass in, and whether a returned one is fit for reuse is a
predicate you pass in.

**When you need it.** Rarely, directly. `db.connect { pool_size = 10 }` builds
one and hands it to you as `open.pool`. Reach for this module when you are
writing an adapter of your own that holds a connection, a client or a handle
that costs real time to create.

```lua no-run
local Pool = require "akkar.pool"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`pool:close`](#poolclose) | method |
| [`pool:get`](#poolget) | method |
| [`pool:put`](#poolputresource) | method |
| [`pool:reap`](#poolreap) | method |
| [`pool:reserved`](#poolreserved) | method |
| [`pool:stats`](#poolstats) | method |
| [`Pool.new`](#poolnewopen-size-reusable) | function |

Also on this page:
[What the pool writes on a resource](#what-the-pool-writes-on-a-resource) and
[Not here](#not-here).

## Pool.new(open, size, reusable)

Creates a pool. Nothing is opened yet.

| argument | type | meaning |
|---|---|---|
| `open` | function | returns a fresh resource, or raises. May yield |
| `size` | number | the most resources that may exist at once |
| `reusable` | function or nil | given a returned resource, answers whether to keep it |

A resource is a table. It must have a `close` method, which the pool calls when
`reusable` rejects it and when the pool itself is closed.

`reusable` is where "fit for reuse" is defined, because the answer differs per
backend: `akkar.db` rejects a connection that is inside a transaction, marked
broken, holding a query nobody read, or already disconnected. A predicate that
raises counts as a rejection.

**Returns** a [Pool](#pool).

```lua
local Pool = require "akkar.pool"

local opened = 0
local pool = Pool.new(function()
  opened = opened + 1
  return { id = opened, close = function(self) self.closed = true end }
end, 2, function(resource) return not resource.broken end)

local first = pool:get()
print(first.id, opened)
pool:put(first)
print("reused:", pool:get().id == first.id)
```

## Pool

### pool:close()

Closes every idle resource and forgets the reservations. `live` goes to zero.

Resources that are checked out are not touched: the pool does not hold them and
cannot reach them. `akkar` calls this after the drain at shutdown, when nothing
is checked out any more.

**Returns** nothing.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function()
  return { close = function(self) self.closed = true end }
end, 2)

local one = pool:get()
pool:put(one)
pool:close()

print(one.closed, pool:stats().live, pool:stats().idle)
```

### pool:get()

Takes a resource: an idle one if there is one, a fresh one from `open` if there
is room, and otherwise it waits.

Waiting **yields** the coroutine. It does not block the process and it does not
spin, so every other request in the process keeps running. When a resource
comes back, every waiter is woken, not one: a waiter whose deadline already
fired never takes its wakeup, and handing the wakeup to it would leave a live
waiter asleep beside an idle resource.

While `open` runs, the slot is reserved rather than spent. `open` yields, so a
deadline can land inside it, and a slot counted as live would then be gone for
the life of the process. See [`reap`](#poolreap).

**Returns** a resource, with `pool` set on it.

**Raises** whatever `open` raised, after freeing the slot it had reserved and
waking a waiter.

```lua
local cqueues = require "cqueues"
local Pool    = require "akkar.pool"

local opened = 0
local pool = Pool.new(function()
  opened = opened + 1
  return { id = opened, close = function() end }
end, 1)

local cq = cqueues.new()
cq:wrap(function()
  local held = pool:get()
  cqueues.sleep(0.05)
  pool:put(held)
end)
cq:wrap(function()
  cqueues.sleep(0.01)
  local held = pool:get()          -- the pool is full, so this waits
  print("got id", held.id, "after", pool:stats().waits, "wait(s)")
  pool:put(held)
end)
assert(cq:loop())

print("opened in total:", opened)
```

### pool:put(resource)

Returns a resource. Runs `reusable` on it: kept ones go to the idle set, and
rejected ones are closed and their slot freed. Either way, every waiter is
woken.

Putting the same resource twice does nothing the second time. That guard is
load bearing: without it, the idle set held one object twice and two callers of
`get` received the same table, and a rejected resource returned twice drove
`live` negative, which made the pool open more resources than its size.

**Returns** nothing.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function()
  return { close = function(self) self.closed = true end }
end, 2, function(resource) return not resource.broken end)

local good, bad = pool:get(), pool:get()

pool:put(good)
print("idle", pool:stats().idle, "live", pool:stats().live)

bad.broken = true
pool:put(bad)
print("closed", bad.closed, "idle", pool:stats().idle, "live", pool:stats().live)

pool:put(bad)                      -- the second put is ignored
print("live still", pool:stats().live)
```

### pool:reap()

Recovers slots reserved by coroutines nobody will ever resume, by running the
garbage collector twice and counting what the weak table lost.

An abandoned coroutine is suspended, not dead, so `coroutine.status` says
nothing useful about it. What distinguishes it is that nothing references it any
more. Twice rather than once because the abandoned handler is held by its
`cqueues` controller, and it takes one collection to run that controller's
finalizer and a second to collect what the finalizer dropped.

[`get`](#poolget) calls this itself when the pool looks full, before parking, so
you usually do not.

**Returns** how many slots were freed, and `0` immediately when nothing is
reserved.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function() return { close = function() end } end, 2)
print(pool:reserved(), pool:reap())
```

### pool:reserved()

How many slots are held by an `open` still in flight.

**Returns** a number.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function() return { close = function() end } end, 2)
pool:get()
print(pool:reserved())
```

### pool:stats()

A snapshot, for a health endpoint or a log line.

| field | meaning |
|---|---|
| `size` | the maximum |
| `live` | resources that exist right now, checked out or idle |
| `idle` | resources sitting in the pool |
| `reserved` | slots held by an `open` still running |
| `reaped` | slots recovered from abandoned coroutines since the pool was made |
| `waits` | how many times a caller had to queue |
| `waited` | total seconds spent queueing |
| `waited_max` | the longest single wait, in seconds |

`live` and `reserved` are two numbers on purpose. A pool reporting one total
cannot say whether it is busy or stuck. `waits` and `waited` are the numbers
that decide pool size: a p99 made of queueing is a different problem from a p99
made of work, and from the outside they look the same.

**Returns** a table.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function() return { close = function() end } end, 4)
local held = pool:get()

local stats = pool:stats()
print(stats.size, stats.live, stats.idle, stats.reserved, stats.reaped)
print(stats.waits, stats.waited, stats.waited_max)

pool:put(held)
print(pool:stats().idle)
```

## What the pool writes on a resource

Three fields, on the table you returned from `open`. They are readable, and
`akkar.db`'s `reusable` predicate reads its own separate flags rather than
these.

| field | when |
|---|---|
| `pool` | set on `get`, cleared on `put`. This is what `conn:release()` follows |
| `pooled` | `true` while the resource sits in the idle set |
| `discarded` | `true` once `reusable` rejected it and it was closed |

`pooled` and `discarded` together are what make a second `put` a no-op.

## Not here

There is no timeout on `get`. A caller that should give up waiting sets a
deadline above the pool, which abandons the coroutine, and `reap` is what
recovers the slot afterwards.

There is no minimum size and no pre-warming. The first `size` calls to `get`
each open one resource, and after that the pool is full.

There is no health check on an idle resource. The predicate runs when a
resource comes back, not while it sits, so a connection that a database closed
while it was idle is discovered by the request that borrows it.

There is no `Pool:size(n)`. The size is fixed when the pool is made.

## See also
- [akkar.db](db.md) builds one of these from `pool_size` and defines what "reusable" means for a connection
- the module source, `akkar/pool.lua`, for the measured reasons behind waking every waiter and collecting twice
