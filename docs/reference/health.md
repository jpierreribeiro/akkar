# akkar.health

Liveness and readiness probes. `live()` answers from two numbers and touches
nothing; `ready()` runs the checks you registered, each under its own timeout,
and caches the result.

**When you need it.** A container platform asks two different questions on a
schedule: restart this process, and route traffic to this process. Answering
both from the same endpoint is how one slow database restarts a whole fleet.

```lua no-run
local health = require "akkar.health"
```

## Contents

- [health.DEFAULT_CACHE](#healthdefault_cache)
- [health.DEFAULT_TIMEOUT](#healthdefault_timeout)
- [health.Health](#healthhealth)
- [health.new(options)](#healthnewoptions)
- [What a check returns](#what-a-check-returns)
- [Health](#health)
  - [probe:invalidate()](#probeinvalidate)
  - [probe:live()](#probelive)
  - [probe:ready(options)](#probereadyoptions)
- [Serving the two endpoints](#serving-the-two-endpoints)
- [Not here](#not-here)

## health.DEFAULT_CACHE

`5`. The default `cache`, in seconds.

## health.DEFAULT_TIMEOUT

`2`. The default `timeout`, in seconds, applied per check.

## health.Health

The metatable every probe shares. Exported for a test that wants to identify
one. Nothing in akkar requires you to touch it.

## health.new(options)

Builds a probe.

| field | type | default | meaning |
|---|---|---|---|
| `checks` | table | `{}` | name to function. Read only by `ready()`. |
| `timeout` | number | `2` | seconds one check may take. `0` or `nil` runs the check with no deadline. |
| `cache` | number | `5` | seconds a readiness result is reused, failures included. `0` disables the cache. |

**Returns** a probe.

**Raises**

- `akkar.health: unknown option '<key>'; use checks, timeout or cache`
- `akkar.health: check '<name>' is a <type>, not a function`

```lua
local health = require "akkar.health"

local probe = health.new {
  checks = {
    disk  = function() return true end,
    queue = function() return false, "backlog is 12000 deep" end,
  },
  timeout = 1,
  cache   = 5,
}

local ready = probe:ready()
print(ready.status)                    --> fail
print(ready.checks.disk.status)        --> pass
print(ready.checks.queue.status)       --> fail
print(ready.checks.queue.reason)       --> backlog is 12000 deep
print(probe:live().status)             --> pass
```

## What a check returns

A check is a function of no arguments.

| it returns | result |
|---|---|
| `true` | pass |
| `false` or `nil`, plus a reason string | fail, with `reason` set |
| `false` or `nil`, no reason | fail, with no `reason` field |
| it raises | fail, with the first line of the error as `reason` |
| it does not return within `timeout` | fail, `reason = "timed out after <n>s"`, and `timed_out = true` |

A check that raises does not take the probe down: the endpoint that is meant
to say which dependency is unhappy must not answer 500 itself.

The timeout is cooperative. A check that waits on I/O is interrupted on time;
a check that burns CPU without yielding is not interrupted by anything. A
timed-out check leaks its scheduler until the collector runs, which is
affordable because the cache means one timing-out check costs one of those per
cache period rather than one per probe.

## Health

### probe:invalidate()

Throws the cached readiness result away, so the next `ready()` runs the checks.
For a process that has just finished starting up, or a test that has just
repaired what a check was failing on.

**Returns** the probe.

### probe:live()

Is this process running its event loop?

Touches nothing: it reads no check, opens no connection, and answers from the
start time it has held since it was constructed. `checks` is empty by
construction, not because none passed.

**Returns** a table.

| field | type | meaning |
|---|---|---|
| `status` | string | always `"pass"` |
| `checks` | table | always empty |
| `uptime` | number | seconds since the probe was created |

### probe:ready(options)

Should this process be sent traffic?

Every check runs, in name order, even after one has failed. The result is
cached for `cache` seconds, failures included, so a dependency that is down is
not hammered by the probes reporting that it is down. Pass
`{ fresh = true }` to bypass the cache and run the checks now; the result of a
fresh run is still stored.

Each call returns a fresh copy, so a handler decorating the result cannot write
into the cache.

**Returns** a table.

| field | type | meaning |
|---|---|---|
| `status` | string | `"pass"` when every check passed, else `"fail"` |
| `checks` | table | one entry per check, keyed by name |
| `cached` | boolean | whether this answer came from the cache |
| `uptime` | number | seconds since the probe was created |

Each entry in `checks` carries:

| field | type | meaning |
|---|---|---|
| `status` | string | `"pass"` or `"fail"` |
| `took_ms` | number | how long the check took, rounded to a millisecond |
| `reason` | string | present only on a failure that gave one |
| `timed_out` | boolean | present only when the check ran out of time |

```lua
local health = require "akkar.health"

local calls = 0
local probe = health.new {
  checks = { thing = function() calls = calls + 1 return true end },
  cache  = 5,
}

probe:ready()
probe:ready()
print(calls, probe:ready().cached)          --> 1   true
print(probe:ready({ fresh = true }).cached) --> false
print(calls)                                --> 2
probe:invalidate()
probe:ready()
print(calls)                                --> 3
```

## Serving the two endpoints

Neither method is a response. Both return a table, which a handler returns or
turns into a 503. Point the platform's restart policy at the liveness path and
its traffic routing at the readiness path, never the other way round.

```lua
local akkar  = require "akkar"
local health = require "akkar.health"

local probe = health.new {
  checks = { cache = function() return false, "redis is not answering" end },
  cache  = 0,
}

local app = akkar.new()

app:get("/health/live", function() return probe:live() end)

app:get("/health/ready", function()
  local result = probe:ready()
  if result.status == "fail" then error(akkar.unavailable(result)) end
  return result
end)

local client = app:test {}
print(client:get("/health/live").status)    --> 200
print(client:get("/health/ready").status)   --> 503
```

## Not here

- **Routes.** The module registers nothing. The two paths above are yours to
  write, which is why they can be exempted from a rate limiter or renamed.
- **A status code.** Both methods return a table with a `status` string in it.
  Turning a failure into 503 is the handler's line.
- **A startup probe.** There are two questions here, not three. A process that
  is still starting fails readiness, which is what a start-up probe would say.
- **Checks that akkar supplies.** There is no built-in database check. A check
  is a function you write, because only you know which dependency this service
  cannot serve without.
- **Any check inside `live()`.** By construction, and a test enforces it.

## See also

- [akkar](akkar.md) for `app:test{}`, `akkar.unavailable` and
  `check_capabilities`
- [akkar.doctor](doctor.md) for the one-shot version of the same question at
  boot or on a deploy
- the guide, `docs/guide/11-not-falling-over.md`, for what happens to a fleet
  whose liveness probe queries the database
- the module source, `akkar/health.lua`, for why failures are cached too
