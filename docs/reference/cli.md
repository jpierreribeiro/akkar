# The `akkar` command

`luarocks install akkar` puts `akkar` on your PATH. Everything below is one
command; nothing needs a config file.

| command | what it does |
|---|---|
| [`akkar new`](#akkar-new-name) | create a project that runs |
| [`akkar run`](#akkar-run-applua) | start it |
| [`akkar test`](#akkar-test) | run its specs |
| [`akkar doctor`](#akkar-doctor-applua) | what is installed, and whether it answers |
| [`akkar build`](#akkar-build-applua) | one executable, no Lua needed to run it |
| [`akkar watch`](#akkar-watch----command) | restart any command when files change |
| `akkar version` | the version, and the Lua it is on |

## The first minute

```sh
akkar new my-api
cd my-api
akkar run
```

```sh
$ curl localhost:8080/health
{"ok":true}
```

## One file, three commands

`akkar run`, `akkar doctor` and `akkar build` all read the same shape: a file
that **returns the app**, optionally with the configuration `app:run` would
receive.

```lua no-run
local akkar = require "akkar"

local app = akkar.new()
app:get("/health", function() return { ok = true } end)

return app, { port = 8080 }
```

That is why the scaffold writes it that way. A file that calls `app:run()` at
the bottom works when you run it with `lua`, and then `akkar doctor` cannot
inspect it and `akkar build` cannot embed it, because loading the file starts a
server that never returns.

## akkar new NAME

Creates a project: `app.lua`, `spec/app_spec.lua`, `migrations/` and a
`README.md`.

Four files, deliberately. A scaffold that emits twelve teaches its own layout
rather than the framework, and every one of them is a file somebody has to read
before deleting it.

**Refuses to overwrite.** If `NAME/app.lua` exists the command stops and
changes nothing.

**Raises** on a name containing anything but letters, digits, dot, dash and
underscore.

## akkar run [app.lua]

Loads the file, installs signal handling and starts the server. The path
defaults to `app.lua`.

| option | meaning |
|---|---|
| `--watch` | restart when a file changes |
| `--root DIR` | what to watch; repeatable, defaults to `.` |

`--watch` restarts by re-running this same command without it, so the watched
process and the plain one start identically. A reload that ran something subtly
different would hide the bug it was meant to show you.

## akkar test [busted options]

Runs [busted](https://lunarmodules.github.io/busted/) over `spec/`, with
`package.path` pointing at the project so `require "app"` finds your app.

Anything after `akkar test` is passed straight through:

```sh
akkar test --tags=slow
akkar test spec/invoices_spec.lua
```

It is a wrapper, not a runner. Owning assertions, output formats and a plugin
surface to replace something every Lua developer already has would be a poor
trade.

**Fails** with the install line when busted is not on PATH. `BUSTED=` overrides
where to find it.

## akkar doctor [app.lua]

Reports the runtime, the installed libraries, the application's routes and
settings, and whether its capabilities answer. Exits `1` when something is
broken, so a deploy step can gate on it — a warning is not a failure.

| option | meaning |
|---|---|
| `--json` | machine-readable |
| `--no-probe` | skip anything that touches the network |

See [akkar.doctor](doctor.md).

## akkar build app.lua

Emits a C host embedding the Lua VM, every Lua module the application needs and
every native module, and links it into one executable. Deployment then needs no
Lua, no LuaRocks and no shared objects.

See [`docs/RUNTIME.md`](../RUNTIME.md) for what it produces and what it still
needs by hand.

## akkar watch -- COMMAND

Runs any command and restarts it when files change. `akkar run --watch` is this
with the command filled in.

```sh
akkar watch --root . -- ./my-api
```
