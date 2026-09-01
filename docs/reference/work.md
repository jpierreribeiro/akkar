# akkar.work

Helpers for work that computes rather than waits. One process runs one Lua VM
on one core with a cooperative scheduler, so a handler that computes for 250 ms
stalls every other request for 250 ms. These functions turn one long stall into
many short ones.

**When you need it.** A handler builds a CSV, renders a large list, or walks a
table with thousands of rows, and other requests go slow while it does.

```lua no-run
local work = require "akkar.work"
```

For work the caller is not waiting for at all, this is the wrong module. Put it
in a queue: see [akkar.jobs](jobs.md).

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`work.chunked`](#workchunkedevery) | function |
| [`work.queue`](#workqueuecache-name) | function |
| [`work.yielding`](#workyieldingevery-fn) | function |

## work.chunked(every)

**Returns** a function that wraps another function and returns the wrapper. The
wrapper passes its own arguments through, **appends a `yield` as one more
argument**, and returns whatever the wrapped function returns. Calling that
`yield` gives the scheduler a turn once every `every` calls, exactly as
[`work.yielding`](#workyieldingevery-fn) does -- the wrapper only saves you
building the counter.

```lua no-run
local slow = work.chunked(500)(function(rows, yield)
  return render(rows, yield)
end)
```

**The yield has to be called.** This wrapper used to be an identity wrapper:
the wrapped function was invoked without the `yield` the budget is spent
through, so nothing inside it could reach the scheduler and `chunked` over a
million iterations produced zero scheduler trips while documenting itself as a
yield budget. It is handed over now, but a body that ignores it still yields
nothing -- there is no way to interrupt Lua code that does not cooperate, and
this module's header says why.

```lua
local cqueues = require "cqueues"
local work    = require "akkar.work"

local loop = cqueues.new()
loop:wrap(function()
  local neighbour = 0
  loop:wrap(function()
    for _ = 1, 1000 do neighbour = neighbour + 1 cqueues.poll(0) end
  end)

  local total = work.chunked(1000)(function(n, yield)
    local sum = 0
    for i = 1, n do sum = sum + i yield() end
    return sum
  end)(1000000)

  print(total)                     --> 500000500000
  print(neighbour > 0)             --> true
end)
assert(loop:loop())
```

## work.queue(cache, name)

Builds a job queue over a Redis connection. It forwards to
`akkar.jobs.redis.new(cache, name)` and nothing else, so anything written
against the old `work.queue` still works.

**Returns** a `Queue`. Everything it can do is documented under
[akkar.jobs](jobs.md).

New code should call `akkar.jobs.redis` directly. The queue lives there because
the semantics of a job are separate from where a job is stored, and this
function predates that split.

```lua
local work  = require "akkar.work"
local redis = require "akkar.redis"

local conn  = redis.connect { port = 6379 }()
local queue = work.queue(conn, "ref_work_demo")

print(queue.key)          --> akkar:queue:ref_work_demo
queue:push("resize", { image_id = 7 })
print(queue:depth())      --> 1

local job = queue:pop(0)
print(job.kind)           --> resize
queue:ack(job)

conn:del(queue.key, queue.key .. ":processing", queue.key .. ":processing:at")
conn:release()
```

## work.yielding(every, fn)

Calls `fn(yield)`. Calling `yield()` inside `fn` gives the scheduler a turn once
every `every` calls, and does nothing on the calls in between. The counter is
kept inside the helper, so the loop body writes `yield()` and nobody maintains a
modulo.

| argument | type | default | meaning |
|---|---|---|---|
| `every` | number | `500` | one real yield per this many `yield()` calls |
| `fn` | function | required | called immediately as `fn(yield)` |

**Returns** whatever `fn` returns.

Yielding is not free. Measured on a loop of about 200 ms, recorded in the
module source:

| `every` | the task itself | worst neighbour wait |
|---|---|---|
| no yielding | 202 ms | 200.5 ms |
| 50000 | 520 ms | 28.7 ms |
| 2000 | 557 ms | 0.9 ms |

Neighbour latency falls by two orders of magnitude and the task itself gets
about 2.7 times slower, because each yield costs a trip through the scheduler.
Pick `every` coarse when the task matters more than its neighbours, fine when
the opposite.

```lua
local cqueues = require "cqueues"
local work    = require "akkar.work"

local loop = cqueues.new()
loop:wrap(function()
  local neighbour = 0
  loop:wrap(function()
    for _ = 1, 100 do neighbour = neighbour + 1 cqueues.poll(0) end
  end)

  local total = work.yielding(10, function(yield)
    local sum = 0
    for i = 1, 100 do
      sum = sum + i
      yield()
    end
    return sum
  end)

  print(total)                      --> 5050
  print("neighbour ran", neighbour) --> 10
end)
assert(loop:loop())
```

Inside a handler it looks like this. The response goes out after the whole loop
has run, and the requests beside it are not held up for the duration:

```lua
local akkar = require "akkar"
local work  = require "akkar.work"

local app = akkar.new()

app:get("/report", function()
  local rows = {}
  work.yielding(500, function(yield)
    for i = 1, 5000 do
      rows[#rows + 1] = { id = i, total = i * 3 }
      yield()
    end
  end)
  return { rows = akkar.array(rows) }
end)

local res = app:test{}:get "/report"
print(res.status, #res.body.rows)   --> 200 5000
```

## Not here

**Nothing that fixes a blocking C call.** Password hashing runs inside C for as
long as it runs and Lua never regains control, so there is no point at which a
yield could happen. The answers there are outside this module: run one process
per core so a blocked worker is one Nth of capacity, lower the cost factor
knowingly, or move the work behind a queue and change what the endpoint
promises.

**No threads.** One process, one VM, one core. More CPU means more processes.

**No time budget.** `every` counts calls, not milliseconds. A loop whose
iterations differ wildly in cost yields unevenly, and nothing here measures
that.

**No automatic yielding.** Nothing inserts a yield into a loop you did not write
one into.

## See also

- [akkar.jobs](jobs.md) for the other answer: leave the request entirely and let
  a separate process do the work on a separate core
- [akkar](akkar.md) for `app:test{}`, and for the watchdog that reports a
  blocked loop rather than fixing one
- the module source, `akkar/work.lua`, for the measurements above and for what
  neither helper solves
