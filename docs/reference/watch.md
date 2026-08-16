# akkar.watch

Polls a set of files and restarts a command whenever any of them changes. Four
functions: three that answer questions about the filesystem, and one loop that
uses them.

**When you need it.** During development, so that saving `app.lua` brings the
server back without a keystroke. Nothing here is reachable from `app:run`, and
nothing here belongs in production: the process is stopped and started, so a
request in flight is dropped.

```lua no-run
local watch = require "akkar.watch"
```

## Index

Every public symbol on this page, in alphabetical order, and the command that
wraps them.

| symbol | kind |
|---|---|
| [`akkar watch`](#command-line-akkar-watch) | command |
| [`watch.changed`](#watchchangedbefore-after) | function |
| [`watch.files`](#watchfilesroots-pattern) | function |
| [`watch.run`](#watchruncommand-roots-options) | function |
| [`watch.snapshot`](#watchsnapshotpaths) | function |

## Command line: akkar watch

```sh
akkar watch [--root DIR] [--interval SECONDS] [--pattern GLOB] -- <command>
```

| flag | value | default | meaning |
|---|---|---|---|
| `--root` | DIR | `.`, repeatable | a directory to watch |
| `--interval` | SECONDS | `0.5` | seconds between polls, passed through `tonumber` |
| `--pattern` | GLOB | `*.lua` | the `find -name` pattern |
| `--` | | required | everything after it is the command, joined with single spaces |

**Writes** two files in the working directory, both with fixed names that the
command line does not expose: `akkar-watch.out`, which holds the child's
standard output and standard error, and `akkar-watch.pid`, which holds the
child's process group leader. The pid file is removed on every stop and written
again on every start.

**Prints** the command and the roots when it begins:

```
akkar watch: ./myapp run app.lua
  roots: ., lib
```

and one line for every restart:

```
akkar watch: 3 file(s) changed, restarting -- ./app.lua
```

The named file is the first change in sorted order, not necessarily the one
that was saved.

**Exit codes.** The loop does not end on its own: `akkar watch` runs until it
is interrupted, and there is no `--once`. It exits 2 before starting anything
for an unknown option, for a flag with no value, for a bare argument before
`--`, and when no command follows `--`.

## watch.changed(before, after)

Compares two snapshots.

**Returns** a sorted list of paths whose timestamp differs, plus every path in
`before` that is absent from `after`. Additions and removals both count: a path
present only in `after` differs from `nil` and appears, and a path present only
in `before` is added by the second pass.

```lua
local watch = require "akkar.watch"

local before = { ["a.lua"] = 100, ["b.lua"] = 200 }
local after  = { ["a.lua"] = 100, ["b.lua"] = 201, ["c.lua"] = 300 }

local changes = watch.changed(before, after)
assert(#changes == 2)
assert(changes[1] == "b.lua")
assert(changes[2] == "c.lua")

-- A file that went away is a change too.
local gone = watch.changed(before, { ["a.lua"] = 100 })
assert(#gone == 1 and gone[1] == "b.lua")
```

## watch.files(roots, pattern)

Every file under `roots` matching `pattern`. Runs `find <root> -name <pattern>
-type f`, so it needs a shell, and a root that does not exist contributes
nothing rather than raising.

| argument | type | default | meaning |
|---|---|---|---|
| `roots` | list of string | required | directories to search, each one separately |
| `pattern` | string | `"*.lua"` | the `find -name` pattern |

**Returns** a sorted list of paths. Duplicates are not removed, so a path under
two overlapping roots appears twice.

```lua
local watch = require "akkar.watch"

local dir = "/tmp/ref_watch_1"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "return 1\n"
file:close()

local found = watch.files { dir }
assert(#found == 1)
assert(found[1] == dir .. "/app.lua")

os.execute(("rm -rf %q"):format(dir))
```

## watch.run(command, roots, options)

Starts `command`, then polls and restarts it whenever anything under `roots`
changes. The loop ends only when `options.should_stop()` answers true, and it
is asked at the top of every iteration, before the sleep.

| field | type | default | meaning |
|---|---|---|---|
| `interval` | number | `0.5` | seconds passed to `sleep` |
| `pattern` | string | `"*.lua"` | passed to `watch.files` |
| `log` | string | `"akkar-watch.out"` | where the child's output goes. Never `/dev/null` |
| `pidfile` | string | `"akkar-watch.pid"` | where the child's process group leader is recorded |
| `should_stop` | function | `function() return false end` | called at the top of each iteration; a true answer ends the loop |
| `on_restart` | function | none | called with the list of changed paths, before the stop and start |
| `sleep` | function | `os.execute("sleep <seconds>")` | how the loop waits |
| `start` | function | `setsid sh -c 'echo $$ > pidfile; exec <command>' >log 2>&1 &` | how the child is started |
| `stop` | function | reads `pidfile`, sends `TERM` to the negative pid then to the pid, removes `pidfile` | how the child is stopped |

The order on each tick is: ask `should_stop`, sleep, list the files, snapshot
them, compare. On a difference: adopt the new snapshot, count the restart, call
`on_restart`, `stop`, `start`. `stop` is also called once before the first
`start`, and once more after the loop ends.

The default `sleep` shells out to `sleep(1)` rather than using `cqueues.sleep`,
because the watcher has to run where nothing is installed. The default `stop`
kills by pid and never by command line: the command appears verbatim in the
watcher's own command line, so a pattern match would kill the watcher.

**Returns** `{ restarts = <count>, watching = <number of files at the last
poll> }`.

**Raises** nothing of its own.

```lua
local watch = require "akkar.watch"

local dir = "/tmp/ref_watch_2"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "return 1\n"
file:close()

-- Every side effect is replaced, so nothing is spawned and nothing is killed.
local started, stopped, ticks = {}, 0, 0
local report = watch.run("./myapp run app.lua", { dir }, {
  sleep = function() end,
  start = function(cmd) started[#started + 1] = cmd end,
  stop  = function() stopped = stopped + 1 end,
  should_stop = function()
    ticks = ticks + 1
    if ticks == 2 then
      local added = assert(io.open(dir .. "/second.lua", "w"))
      added:write "return 2\n"
      added:close()
    end
    return ticks > 4
  end,
})

assert(report.restarts == 1)
assert(report.watching == 2)
assert(#started == 2)          -- the first start, and the one after the change
assert(stopped == 3)           -- before the first start, at the restart, at the end

os.execute(("rm -rf %q"):format(dir))
```

Running it with the defaults spawns a detached process group, writes
`akkar-watch.pid` and `akkar-watch.out` in the working directory, and does not
return.

## watch.snapshot(paths)

The modification time of each path, read with `stat -c %Y`. Runs one process
per path.

**Returns** a table mapping each path to a number, or to `nil` where `stat`
answered nothing, which is what a file that has been deleted between the `find`
and the `stat` looks like.

`stat` rather than reading the file: opening a file the editor is half way
through writing gives a truncated read, and a watcher that restarts on a
partial save restarts twice per keystroke.

```lua
local watch = require "akkar.watch"

local dir = "/tmp/ref_watch_3"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "return 1\n"
file:close()

local seen = watch.snapshot { dir .. "/app.lua", dir .. "/absent.lua" }
assert(type(seen[dir .. "/app.lua"]) == "number")
assert(seen[dir .. "/absent.lua"] == nil)

os.execute(("rm -rf %q"):format(dir))
```

## Not here

**inotify.** Polling with `stat`, twice a second by default. inotify would be
fewer syscalls and one more C dependency, on a project whose build story is
about having fewer of those.

**Hot swapping.** This stops and starts a process. `App:swap_host` replaces a
running application in place and is a different feature with an unsettled
answer for capability lifetime.

**A configurable log or pid path on the command line.** `watch.run` takes
`options.log` and `options.pidfile`; `akkar watch` does not pass either, so the
command line always uses `akkar-watch.out` and `akkar-watch.pid`.

## See also

- [akkar.build](build.md), for the binary this restarts
- [akkar](akkar.md), for `app:swap_host`, which is the hot swapping this is not
- `bin/akkar`, for the command line that wraps it
- the module source, `akkar/watch.lua`, for why it kills by pid and not by
  pattern
