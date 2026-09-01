# akkar.doctor

Checks what is installed, what this application is configured with, and what
will bite later. Findings come at three levels, and only `fail` changes the
exit code, so a deploy step can gate on it.

**When you need it.** A fresh clone that will not start, a machine whose rock
versions you do not trust, or a deploy step that should refuse to ship an app
whose database does not answer.

```lua no-run
local doctor = require "akkar.doctor"
```

## Contents

- [The command line](#the-command-line)
- [Levels](#levels)
- [doctor.check_app(app, config, report)](#doctorcheck_appapp-config-report)
- [doctor.check_capabilities(config, report)](#doctorcheck_capabilitiesconfig-report)
- [doctor.check_descriptors(report)](#doctorcheck_descriptorsreport)
- [doctor.check_environment(report)](#doctorcheck_environmentreport)
- [doctor.cli(options)](#doctorclioptions)
- [doctor.descriptor_finding(soft, hard)](#doctordescriptor_findingsoft-hard)
- [doctor.format(report)](#doctorformatreport)
- [doctor.new_report()](#doctornew_report)
- [doctor.report(app, config, options)](#doctorreportapp-config-options)
- [doctor.Report](#doctorreport)
- [Report](#report)
  - [report:add(level, area, title, detail, fix)](#reportaddlevel-area-title-detail-fix)
  - [report:count(level)](#reportcountlevel)
  - [report:fail(area, title, detail, fix)](#reportfailarea-title-detail-fix)
  - [report:healthy()](#reporthealthy)
  - [report:ok(area, title, detail)](#reportokarea-title-detail)
  - [report:warn(area, title, detail, fix)](#reportwarnarea-title-detail-fix)
- [Not here](#not-here)

## The command line

```sh
akkar doctor [app.lua] [--json] [--no-probe]
```

| argument | meaning |
|---|---|
| `app.lua` | a file returning `app`, or `app, config`. Without it, only the environment is checked. |
| `--json` | one JSON object on stdout instead of the text report |
| `--no-probe` | skip anything that touches the network, which is the capability check |

Exit codes:

| code | meaning |
|---|---|
| `0` | nothing is broken. Warnings do not change this. |
| `1` | at least one `fail` finding |
| `2` | a usage error: an unknown option, or a file that does not load or does not return an app |

The text output groups findings by area, `fail` first inside each area, and
ends with a count and one of two sentences:

```
15 ok, 1 warning(s), 1 failure(s)
something is broken; the lines marked FAIL are the ones to read
```

The `--json` object has three keys: `healthy` (boolean), `findings` (the list,
each with `level`, `area`, `title` and optionally `detail` and `fix`), and
`summary` (counts of `ok`, `warn` and `fail`).

The file it loads is executed, so it must return the app rather than run it:

```lua no-run
local akkar = require "akkar"

local app = akkar.new()
app:get("/health/live", function() return { status = "pass" } end)

return app, { reuseport = true, timeout = 5 }
```

## Levels

| level | means | exit code |
|---|---|---|
| `ok` | checked, fine. Shown so the absence of a check is visible. | 0 |
| `warn` | works today, will bite. | 0 |
| `fail` | broken now. | 1 |

A missing optional dependency is a warning. A missing optional dependency that
another installed one silently needs is a failure, and so is a declared
capability that cannot be acquired, because the server would refuse to boot in
that state anyway.

## doctor.check_app(app, config, report)

Adds findings about an application: how many routes it has (counting mounted
sub-apps and hosts), which routes can never match, every setting whose value
the runtime would refuse, and which of `body_limit`, `timeout` and
`shutdown_grace` are in force, as numbers, with `configured` or `default`
beside each.

A route can never match when an earlier dynamic route of the same method has a
pattern that covers it. `/users/:id` followed by `/users/:name` is the usual
case: they compile to the same pattern and the second is unreachable.

`config` is the table `app:run{}` would receive. `report` is optional; a new
one is made when it is absent.

**Returns** the report.

**Adds a `fail`** with the title `not an akkar app` when `app` is not the value
`akkar.new()` returned.

**Adds a `fail` per setting whose value the runtime cannot use**, with the
message `akkar.check_settings` itself produces — the same function
`app:run{}` calls, which is exported precisely so a caller that must not bind a
port can ask. One call per setting, because `check_settings` raises on the
first value it rejects and a report that named only the first would cost a
second deploy:

```
FAIL  timeout is not a value the runtime can use
      app:run{}: timeout must be a number of seconds, or false for no deadline; got string "30"
```

**Adds a finding about the C driver when `AKKAR_DRIVER=pq`** — `ok` when
`akkar.pq` loads, `warn` when it does not, because `db.connect` raises at the
first *connection* rather than at load: a refusal to boot with
`check_capabilities` on, and a 500 in the middle of a run with it off.

That environment variable is the only driver signal this check can read.
`driver = "pq"` is given to `db.connect{}`, and what reaches `check_app` is the
factory that closed over it, so the name is not in the config — and a `driver`
key on the run config is not an alternative, because `app:run{}` rejects any
option it does not know. With `probe` on, the in-config case is still caught:
acquiring the capability raises the rock's own install message and that is
already a `fail`.

```lua
local akkar  = require "akkar"
local doctor = require "akkar.doctor"

local app = akkar.new()
app:get("/users/:id", function() return { ok = true } end)
app:get("/users/:name", function() return { ok = true } end)

local report = doctor.new_report()
doctor.check_app(app, { reuseport = true, timeout = 5 }, report)

for _, finding in ipairs(report.findings) do
  print(finding.level, finding.title)
end
```

```
ok	2 routes
warn	GET /users/:name can never match
ok	body_limit = 1048576 bytes
ok	timeout = 5 s
ok	shutdown_grace = 10 s
ok	reuseport is on
```

## doctor.check_capabilities(config, report)

Acquires each declared capability exactly as a request would, checks that it
answers its contract, and releases it.

| capability | must answer |
|---|---|
| `db` | `one`, `many`, `exec`, `transaction` |
| `cache` | `get`, `set`, `del` |

A capability that is absent from `config` is reported `ok`, with a note that
handlers reading it get a guard. One that raises on acquisition is a `fail`,
and so is one that answers only part of its contract.

This is the only part that touches the network, and the only part that can
hang. `doctor.report(app, config, { probe = false })` skips it.

**Returns** the report.

```lua
local doctor = require "akkar.doctor"

-- A cache capability that answers `get` and `set` but not `del`.
local report = doctor.new_report()
doctor.check_capabilities({ cache = { get = function() end, set = function() end } },
                          report)

print(report:healthy())            --> false
for _, finding in ipairs(report.findings) do
  print(finding.level, finding.title, finding.detail)
end
```

## doctor.check_descriptors(report)

Adds exactly one finding, in the area `descriptors`, about the descriptor
limits this process is running under and the `max_concurrent` akkar derives
from them.

This is the ceiling that decides how many requests the process can hold at
once, and nothing printed it before. `akkar.descriptor_ceiling` caps
`max_concurrent` at 66% of the **soft** limit, one descriptor per in-flight
request, so the common `ulimit -n 1024` yields 675 — a number nobody chose,
and the whole capacity of the process, pools and log files included.

Never a `fail`: a descriptor limit is an operational fact, not a broken
install, and a deploy gate should not refuse a service over it.

**Returns** the report.

## doctor.check_environment(report)

Adds findings about the machine: the Lua version, whether `math.type` exists,
each required rock, each optional rock, the OpenSSL version behind `luaossl`,
decoded from its packed integer, and the descriptor limits
([`check_descriptors`](#doctorcheck_descriptorsreport)).

Required: `cqueues`, `lua-http`, `lua-cjson`. Absence is a `fail`.

Optional: `pgmoon`, `luasocket` (for `mime`), `luaossl`, `tl`, `busted`,
`akkar-pq`. Absence is a `warn`, except that `mime` missing while `pgmoon` is
installed is a `fail`: the first query would die with a `require` traceback
naming a module nobody asked for.

`akkar-pq` is two halves and only one of them ships with akkar: `akkar/pq.lua`
is always there, `pq_native.so` is a separate rock. So its two failures are
told apart rather than both being called "not installed":

| what happened | reported as |
|---|---|
| `pq_native.so` is not built | `warn akkar-pq` — the Lua half is here, `db.connect { driver = "pq" }` would raise at the first connection |
| `pq_native.so` was built for a different Lua | `warn akkar-pq is built for the WRONG Lua`, with the marker check's own message |

The second one matters because `akkar/pq.lua` refuses that `.so` at load
rather than segfaulting on the first call — and telling somebody to install a
rock they already have, for the Lua they already run, wastes the afternoon this
file exists to save.

A version is read from the module's own `VERSION`, `_VERSION`, `version` or
`_version` field, and reported as `version not declared` where there is none.
Nothing is guessed from a directory name.

**Returns** the report.

## doctor.cli(options)

Runs the examination, prints it, and exits.

| field | type | default | meaning |
|---|---|---|---|
| `app` | app | none | passed to `check_app` |
| `config` | table | none | passed to `check_app` and `check_capabilities` |
| `json` | boolean | `false` | print one JSON object instead of the text report |
| `probe` | boolean | `true` | `false` skips `check_capabilities` |
| `exit` | boolean | `true` | `false` returns the report instead of calling `os.exit` |

**Returns** the report, but only when `exit = false`. Otherwise it does not
return: it calls `os.exit(0)` when healthy and `os.exit(1)` when not.

## doctor.descriptor_finding(soft, hard)

The rule [`check_descriptors`](#doctorcheck_descriptorsreport) applies, as a
pure function of the two numbers from `/proc/self/limits`.

**Returns** `level, title, detail, fix`.

| given | level | says |
|---|---|---|
| `soft >= 4096` | `ok` | the derived ceiling, and that an in-flight request holds one descriptor |
| `soft < 4096` | `warn` | that the soft limit is the whole capacity of the process, and the three ways to raise it: `ulimit -n`, `LimitNOFILE=` in a systemd unit, `--ulimit nofile=` on a container |
| `soft = nil` | `warn` | that **akkar derives no ceiling either** — `akkar.descriptor_limits` returns nil off Linux, so `max_concurrent` is never set and the server accepts until the kernel refuses. `docs/PLATFORMS.md` carries this as an open decision |

`hard` is used for one thing: whether `ulimit -n` can raise the soft limit
without root, which decides whether the fix is a shell line or a unit file.

Separate from the read because a test on a machine whose soft limit is
1,048,576 can never provoke the warning that matters. The numbers go in, so the
rule is checkable at any limit:

```lua
local doctor = require "akkar.doctor"

-- What a machine at the usual `ulimit -n 1024` would be told.
local level, title, _, fix = doctor.descriptor_finding(1024, 1048576)
print(level, title)
print(fix)
```

```
warn	max_concurrent 675, from a soft limit of 1024
`ulimit -n 8192` in the shell that starts it; `LimitNOFILE=8192` in the systemd unit; `--ulimit nofile=8192:8192` on the container
```

## doctor.format(report)

Renders a report as text. Findings are grouped by area in the order the areas
first appeared, and sorted `fail`, then `warn`, then `ok` inside each area.
Findings at the same level within an area are not in a defined order.

**Returns** a string, starting with a blank line and ending with the verdict
sentence.

```lua
local doctor = require "akkar.doctor"

local report = doctor.new_report()
report:ok("boot", "migrations applied", "3 files")
report:warn("boot", "no backup configured", "a restore has never been tested",
            "point BACKUP_URL at a bucket")
report:fail("boot", "queue unreachable", "connection refused on 6379")

print(report:count "ok", report:count "warn", report:count "fail")   --> 1  1  1
print(report:healthy())                                              --> false
print(doctor.format(report))
```

## doctor.new_report()

An empty report, for adding findings of your own or for passing to several
checks in turn.

**Returns** a report.

## doctor.report(app, config, options)

The whole examination. Runs `check_environment` always, `check_app` when `app`
is given, and `check_capabilities` when `config` is given and
`options.probe` is not `false`.

With neither argument it checks the environment, which is what a fresh clone
wants to know first.

**Returns** a report.

```lua
local doctor = require "akkar.doctor"

local report = doctor.report()

print(report:count "fail" == 0)   --> true when nothing is broken
print(report:healthy())           --> the same question
print(doctor.format(report))
```

## doctor.Report

The metatable every report shares.

## Report

A report holds `findings`, a list in the order they were added. Each finding
is a table with `level`, `area`, `title`, and optionally `detail` and `fix`.

### report:add(level, area, title, detail, fix)

Appends a finding. `level` is `"ok"`, `"warn"` or `"fail"`. `area` is the
heading it is grouped under. `fix` is the line printed after `fix:`.

The level is not validated. A level outside the three renders with a `nil`
marker and is counted by nothing.

**Returns** the report, so calls chain.

### report:count(level)

How many findings are at that level.

**Returns** a number.

### report:fail(area, title, detail, fix)

`report:add("fail", ...)`.

**Returns** the report.

### report:healthy()

Whether the report holds no `fail` finding. This is what decides the exit code.

**Returns** `true` or `false`.

### report:ok(area, title, detail)

`report:add("ok", ...)`. There is no `fix` on an ok finding.

**Returns** the report.

### report:warn(area, title, detail, fix)

`report:add("warn", ...)`.

**Returns** the report.

## Not here

- **Fixing anything.** Every finding carries a `fix` line for a human. Nothing
  is installed, written or restarted.
- **Which capabilities the routes actually use.** Deliberately not attempted:
  `debug.getupvalue` cannot see a `req.db` inside a function body, and warning
  about a guess is worse than saying nothing.
- **Checking your own dependencies.** The optional list is fixed and is about
  akkar's own stack.
- **A repeated or scheduled check.** This is one shot. The endpoint that
  answers the same question continuously is [akkar.health](health.md).
- **Anything about a running server.** It examines a process's environment and
  an app value, not a listening port.

## See also

- [akkar.health](health.md) for the continuous version of the reachability
  question
- [akkar.config](config.md) for making a missing setting a startup failure
  rather than something a doctor has to find
- the module source, `akkar/doctor.lua`, for the three traps this file was
  written to stop costing an afternoon each
