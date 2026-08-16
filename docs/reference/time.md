# akkar.time

The clock the framework reads. Deadlines, the shutdown grace period, cache
expiry, job due times and metrics uptime all call this module instead of
`os.time` or `cqueues.monotime`, so one call replaces the clock for all of them.

**When you need it.** When a test has to prove what happens after a deadline
fires, a ttl expires or a retry backoff comes due, and you do not want the test
to sleep for that long.

```lua no-run
local time = require "akkar.time"
```

Only this spelling. `akkar.time` is not re-exported from the top-level module.

## Contents

- [Clock](#clock)
- [time.manual(options)](#timemanualoptions)
- [time.monotime()](#timemonotime)
- [time.now()](#timenow)
- [time.real](#timereal)
- [time.set(clock)](#timesetclock)
- [time.sleep(seconds)](#timesleepseconds)

## Clock

A clock is any table with three fields: `monotime`, `now` and `sleep`, each a
function taking no `self` argument. `time.real` and the table `time.manual`
returns are both clocks. A clock of your own only has to answer those three.

The table `time.manual` returns carries two extra members.

### clock:advance(seconds)

Moves both of the clock's readings forward by `seconds`. Defaults to `0`.

**Returns** the clock, so calls chain.

**Raises** nothing.

### clock.sleep(seconds)

Advances the clock by `seconds` and returns immediately. Nothing waits.

Written with a dot, not a colon. `clock.sleep(5)` is correct and
`clock:sleep(5)` raises, because the clock would arrive where `seconds` is
expected.

## time.manual(options)

Builds a clock that only moves when told.

| field | type | default | meaning |
|---|---|---|---|
| `monotime` | number | `0` | the first reading of `clock.monotime()` |
| `now` | number | `1755000000` | the first reading of `clock.now()` |

`options` may be omitted.

**Returns** a clock, with `advance` and `sleep` on it.

**Raises** nothing.

```lua
local time = require "akkar.time"

local clock = time.manual { now = 1755000000 }
assert(clock.monotime() == 0)
assert(clock.now() == 1755000000)

clock:advance(3600)
assert(clock.monotime() == 3600)
assert(clock.now() == 1755003600)

clock.sleep(10)                       -- returns at once, having advanced
assert(clock.monotime() == 3610)
```

A manual clock moves **timestamps and budgets**, not the event loop.
`cqueues.poll` still waits on real file descriptors for real milliseconds, and
a socket read still takes as long as the peer takes. Use it to prove what
happens after a deadline or a ttl, never to prove how two things race.

## time.monotime()

The current monotonic reading, from whichever clock is installed. Monotonic
because a budget measured against wall time breaks when NTP steps the clock.

**Returns** a number of seconds from an arbitrary origin. Only differences
between two readings mean anything.

**Raises** nothing.

```lua
local time = require "akkar.time"

local started = time.monotime()
assert(type(started) == "number")
assert(time.monotime() - started >= 0)
```

## time.now()

The current wall-clock reading, from whichever clock is installed. Wall clock
because a log line stamped with monotonic time means nothing to a reader.

**Returns** a Unix timestamp in seconds, the same shape `os.time` returns.

**Raises** nothing.

```lua
local time = require "akkar.time"
assert(math.abs(time.now() - os.time()) <= 1)
```

## time.real

The real clock, as a table: `monotime` is `cqueues.monotime`, `now` is
`os.time`, `sleep` is `cqueues.sleep`. It is what is installed before anything
calls `time.set`, and what `time.set(nil)` puts back.

Reading it is a way to call the real clock while a manual one is installed.

```lua
local time = require "akkar.time"

local clock = time.manual()
local restore = time.set(clock)
assert(time.now() == 1755000000)          -- the manual reading
assert(time.real.now() > 1755000000)      -- the real one, still available
restore()
```

## time.set(clock)

Installs a clock for the whole process. Passing `nil` installs `time.real`.

**Returns** a function that puts the previous clock back. Call it, do not
assume the next `set` will undo this one.

**Raises** nothing. The clock is not validated, so a table missing `monotime`,
`now` or `sleep` fails later, at the first call, not here.

```lua
local time = require "akkar.time"

local clock = time.manual { now = 1700000000 }
local restore = time.set(clock)

clock:advance(86400)
assert(time.now() == 1700086400)          -- a day passed; nothing waited

restore()
assert(math.abs(time.now() - os.time()) <= 1)
```

Process-wide by design, and that is a real limitation: two tests running at the
same time against different clocks would see each other. The restore function
is what keeps that from happening.

## time.sleep(seconds)

Sleeps through whichever clock is installed. Under `time.real` this is
`cqueues.sleep`, which yields to the event loop for that long. Under a manual
clock it advances the clock and returns at once.

**Returns** whatever the installed clock's `sleep` returns. `time.real.sleep`
returns nothing.

**Raises** whatever the installed clock raises. `cqueues.sleep` requires a
running cqueues controller and raises outside one.

```lua
local time = require "akkar.time"

local clock = time.manual()
local restore = time.set(clock)

time.sleep(120)                           -- immediate
assert(time.monotime() == 120)

restore()
```

## Not here

- **A virtual event loop.** `cqueues.poll` is untouched, so I/O still takes real
  time. Making time virtual inside the scheduler would mean writing a second
  scheduler.
- **Per-request or per-app clocks.** `time.set` is process-wide. The `clock`
  capability an application passes to `app:run` is a separate slot; this module
  is what the framework itself reads.
- **Timers, schedules or cron.** Recurring work is `akkar.jobs`.

## See also

- [akkar](akkar.md) for `app:run { timeout = ... }`, the request deadline this
  clock measures
- the module source, `akkar/time.lua`, for why a manual clock is honest about
  what it does not move
