# akkar.breaker

A circuit breaker: after enough failures against a dependency, calls to it are
refused at once instead of made, until a cooldown has passed and a probe has
shown it is back.

**When you need it.** When a service you call is down and every request to
you is still dialling it. The deadline bounds what *one* such call costs; it
does not stop the next thousand from each paying that cost. A breaker does.

```lua no-run
local breaker = require "akkar.breaker"
```

Only this spelling. `akkar.breaker` is not re-exported from the top-level
module.

## Contents

- [breaker.new(options)](#breakernewoptions)
- [breaker.is(value)](#breakerisvalue)
- [breaker.OPEN](#breakeropen)
- [breaker.STATE_CODE](#breakerstate_code)
- [Breaker](#breaker)
- [With akkar.http](#with-akkarhttp)
- [With akkar.metrics](#with-akkarmetrics)

## breaker.new(options)

Builds a breaker in the `closed` state.

| field | type | default | meaning |
|---|---|---|---|
| `threshold` | number | required | without `window`: consecutive failures that open it; with `window`: the failure ratio in `(0, 1]` that does |
| `window` | number | none | seconds over which the ratio is measured; its presence selects the sampling policy |
| `minimum` | number | `10` | sampling only: calls that must be in the window before the ratio is judged |
| `cooldown` | number | `30` | seconds spent `open` before probes are allowed |
| `half_open_max` | number | `1` | probes issued per half-open period; all must succeed to close |
| `is_failure` | function | `first == nil` | called with the results of a call; `true` means it failed |
| `on_change` | function | none | `on_change(breaker, from, to)` on every transition; an error in it is swallowed |
| `buckets` | number | `10` | sampling only: fixed slices the window is divided into |

Two policies, selected by whether `window` is given. **Consecutive** opens on
`threshold` failures in a row; a success resets the run. **Sampling** opens
when `failures / calls` over the last `window` seconds reaches `threshold`,
once at least `minimum` calls have been seen -- so a dependency that answers
one call in three still trips, where a consecutive count would be reset by
every success.

A call **fails** when it raises, or when `is_failure` says so. The default is
the adapter convention: a first result of `nil` is a failure. Replace it when
`nil` means something the dependency did on purpose -- a lookup that answers
`nil, "not found"` is the dependency working, and a run of misses must not
open the breaker on it.

**Returns** a [Breaker](#breaker).

**Raises** on a missing or non-positive `threshold`, a fractional `threshold`
without a `window`, a `threshold` above `1` with one, a non-positive
`cooldown` or `window`, a `half_open_max` below `1`, or an `is_failure` that
is not a function.

```lua
local breaker = require "akkar.breaker"
local time    = require "akkar.time"

local clock = time.manual()
local restore = time.set(clock)

local b = breaker.new { threshold = 3, cooldown = 30 }

local function down() return nil, "connection refused" end
for _ = 1, 3 do b:call(down) end
print(b:current())                           --> open

print(b:call(down))                          --> nil   breaker open

clock:advance(30)                            -- the cooldown, without waiting
print(b:current())                           --> half_open

print(b:call(function() return "hello" end)) --> hello
print(b:current())                           --> closed

restore()
```

The sampling policy:

```lua
local breaker = require "akkar.breaker"

-- Open when half the calls in the last minute failed, judged only once ten
-- calls have been seen.
local b = breaker.new { threshold = 0.5, window = 60, minimum = 10 }

for _ = 1, 10 do
  b:call(function() return nil, "timed out" end)
  b:call(function() return "ok" end)
end
print(b:current())                           --> open
```

## breaker.is(value)

**Returns** `true` when `value` came from `breaker.new`. `akkar.http` uses it
to tell an instance it should share from a table of options it should build
one breaker per origin from.

```lua
local breaker = require "akkar.breaker"
print(breaker.is(breaker.new { threshold = 1 }))   --> true
print(breaker.is({ threshold = 1 }))               --> false
```

## breaker.OPEN

The string `"breaker open"`, which every refused call returns as its reason.
Compare against the constant rather than the spelling.

```lua
local breaker = require "akkar.breaker"
local b = breaker.new { threshold = 1 }
b:call(function() return nil, "x" end)
local res, why = b:call(function() return "never" end)
print(res, why == breaker.OPEN)              --> nil   true
```

## breaker.STATE_CODE

`{ closed = 0, half_open = 1, open = 2 }`, the numbers `stats().state` and the
`akkar_breaker_state` gauge carry. An alert is `akkar_breaker_state > 0`.

## Breaker

What `breaker.new` returns. Every method is called with a colon.

### b:allow()

Whether a call may run now, applying any transition the clock has caused. In
`half_open` this **claims** one probe.

**Returns** `true`, or `nil, "breaker open"`.

**Raises** nothing.

Use this with `b:success()` and `b:failure()` when the thing under the breaker
does not fit in one function -- `akkar.http` does, because it decides that a
`5xx` is a failure after the exchange. Otherwise use `b:call`.

### b:call(fn, ...)

Runs `fn(...)` if the breaker allows it and reports the outcome.

**Returns** everything `fn` returned, or `nil, "breaker open"` without calling
`fn`.

**Raises** whatever `fn` raised, after counting it as a failure. The breaker
observes errors; it does not swallow them.

### b:current()

**Returns** `"closed"`, `"open"` or `"half_open"`, after applying any
transition the clock has caused. Read it, do not read `b.state`.

### b:failure()

Reports that a call `b:allow()` let through failed. In `half_open` this opens
the breaker again and re-arms the cooldown.

### b:reset()

Closes the breaker and forgets the failures behind the trip.

### b:stats()

**Returns** `{ state = code, trips = n, refused = n, calls = n, failures = n,
successes = n }`. `state` is a [STATE_CODE](#breakerstate_code); `trips`
counts every entry into `open`; `refused` counts calls that never ran; the
rest count calls that did.

### b:success()

Reports that a call `b:allow()` let through succeeded. In `half_open` the
breaker closes once `half_open_max` probes have succeeded.

### b:trip()

Holds the breaker `open` until `b:reset()`, whatever the clock does. For a
dependency an operator knows is down or is about to take down.

```lua
local breaker = require "akkar.breaker"
local time    = require "akkar.time"
local clock = time.manual()
local restore = time.set(clock)

local b = breaker.new { threshold = 1, cooldown = 10 }
b:trip()
clock:advance(3600)
print(b:current())                           --> open
b:reset()
print(b:current())                           --> closed
restore()
```

## A probe that never reports

A probe is a call let through in `half_open`. If the coroutine running it is
abandoned -- the execution's deadline fired while it waited on the socket --
its verdict never arrives. The breaker does not wait for it: after another
`cooldown` with no verdict the probes are issued again.

## With akkar.http

`http.connect { breaker = ... }` consults the breaker **before dialling**. A
refusal opens no connection, takes no pool slot and spends none of the
execution's budget. A `5xx` or a transport error is a failure; a `4xx` is the
dependency working.

| value of `breaker` | what it does |
|---|---|
| a table of `breaker.new` options | one breaker **per origin**, built on first use, keyed as the pools are (`scheme://host:port`) |
| a breaker instance | one breaker shared by every origin the client talks to |

A refused request returns `nil, "breaker open"` immediately: it is not retried
and no backoff is slept, because the cooldown is measured in seconds and the
request's budget is not. The breakers appear under `client:stats().breakers`,
by origin, or under `"*"` for a shared instance.

```lua
local http    = require "akkar.http"
local breaker = require "akkar.breaker"

local per_origin = http.connect {
  timeout = 2,
  breaker = { threshold = 5, cooldown = 30 },
}
local shared = http.connect {
  timeout = 2,
  breaker = breaker.new { threshold = 0.5, window = 60 },
}
print(per_origin ~= shared)                  --> true
```

## With akkar.metrics

`registry:breaker(name, b)` reads `b:stats()` at every scrape, the way
`registry:pool` reads a pool. Nothing is pushed from the breaker's own path.

```lua
local breaker = require "akkar.breaker"
local metrics = require "akkar.metrics"

local registry = metrics.new()
local b = registry:breaker("payments", breaker.new { threshold = 1 })
b:call(function() return nil, "down" end)
b:call(function() return "never runs" end)

local text = registry:render()
print(text:match 'akkar_breaker_state{breaker="payments"} %d')
--> akkar_breaker_state{breaker="payments"} 2
print(text:match 'akkar_breaker_refused_total{breaker="payments"} %d')
--> akkar_breaker_refused_total{breaker="payments"} 1
```

The series are `akkar_breaker_state` (gauge), `akkar_breaker_trips_total`,
`akkar_breaker_refused_total`, `akkar_breaker_calls_total` and
`akkar_breaker_failures_total` (counters), labelled `breaker="<name>"`. Two
breakers under one name sum their counters and report the worse state.

## Not here

- **A timeout.** The deadline already is one, and it propagates:
  `execution.bounded` gives an outbound call whatever the execution has left.
  A call the breaker lets through is bounded as usual; the breaker adds nothing
  to that and takes nothing from it.
- **A bulkhead.** `akkar.limit.concurrent` caps calls in flight.
- **A generic retry.** `akkar.http` retries what is safe to retry, and
  `akkar.jobs` retries with backoff. Compose them the way `akkar.http` does:
  retries outside, the breaker inside, so a retry after the trip is refused
  without dialling.
- **A shared, cross-process breaker.** State is per process. Each worker
  discovers a dead dependency on its own, `threshold` calls at a time; that is
  the same choice `akkar.limit.shed` makes for the same reason.
- **A `closed`/`open` timer.** Nothing runs on a schedule. State is settled
  when the next call asks, by reading `akkar.time`.

## See also

- [http](http.md) for the `breaker` field of `http.connect`
- [metrics](metrics.md) for `registry:breaker`
- [time](time.md), whose manual clock is what makes the cooldown provable
- the module source, `akkar/breaker.lua`, for why the failure test is
  configurable and why an abandoned probe cannot wedge the breaker
