# akkar.vm

Runs untrusted Lua inside this process, under a curated environment, an
instruction budget and a memory ceiling. The chunk is loaded as text only,
never as bytecode.

**When you need it.** A customer publishes a hook, a validation rule or a
computed field, and it has to run here without reading the filesystem, opening
a socket, spinning forever, or reaching the application around it. If the code
is hostile rather than merely untrusted, run it in a separate process with an
OS-level sandbox instead.

```lua no-run
local vm = require "akkar.vm"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`vm.base_environment`](#vmbase_environment) | function |
| [`vm.compile`](#vmcompilesource-options) | function |
| [`vm.eval`](#vmevalsource-options-) | function |
| [`vm.harden`](#vmharden) | function |
| [`vm.run`](#vmrunchunk-limits-) | function |

## The environment a chunk sees

| present | notes |
|---|---|
| `assert`, `error`, `ipairs`, `next`, `pairs`, `select`, `tonumber`, `tostring`, `type` | as themselves |
| `rawequal`, `rawlen`, `rawget`, `rawset`, `setmetatable`, `getmetatable` | as themselves |
| `unpack` | is `table.unpack` |
| `pcall`, `xpcall` | wrappers that re-raise after a budget overrun |
| `math` | a copy, with `math.randomseed` replaced by a function that does nothing |
| `table` | a copy |
| `string` | a copy, with `string.dump` removed and `string.rep` pointing at the bounded one |
| `os` | only `time`, `clock`, `date`, `difftime` |
| `_G` | the environment itself, so `_G.x = 1` stays inside |

| absent | why |
|---|---|
| `io`, `dofile` | the filesystem |
| `require` | reaches every module in the process, akkar's included |
| `load` | would build a chunk with a different `_ENV`, or with bytecode |
| `debug` | `sethook`, `getlocal`, `getupvalue` undo all of this |
| `coroutine` | a hook is installed per coroutine, so a new one runs unmetered |
| `collectgarbage` | can stop the collector the memory ceiling relies on |

## vm.base_environment()

Builds a fresh copy of the table above.

**Returns** a table. Each call returns a new one, so mutating the result
affects nothing else.

```lua
local vm = require "akkar.vm"

local env = vm.base_environment()
assert(type(env.math.floor) == "function")
assert(env.io == nil)
assert(env.require == nil)
assert(env.coroutine == nil)
assert(env.load == nil)
assert(env.string.dump == nil)
assert(env._G == env)
```

## vm.compile(source, options)

Loads `source` as a chunk bound to a sandbox environment. Calls `vm.harden()`
and installs the bound on the real `string.rep` as a side effect.

| field | type | default | meaning |
|---|---|---|---|
| `env` | table | `vm.base_environment()` | replaces the environment wholesale |
| `expose` | table | `{}` | copied into the environment after it is built, so it adds to the default one |
| `name` | string | `"sandbox"` | the chunk name in error messages, used as `=<name>` |
| `max_string` | number | `1048576` | the largest string `string.rep` may build while this chunk runs |

The load mode is `"t"` and there is no way to ask for anything else.

**Returns** the compiled function, or `nil` and `akkar.vm: could not compile:
<message>`.

**Raises** `akkar.vm.compile needs source as a string; got <type>` when
`source` is not a string. A syntax error is a returned reason, not a raise.

```lua
local vm = require "akkar.vm"

local chunk = assert(vm.compile("return greeting .. ' world'", {
  expose = { greeting = "hello" },
  name = "tenant-hook",
}))
local ok, value = vm.run(chunk)
assert(ok)
assert(value == "hello world")

local bad, why = vm.compile "this is not lua"
assert(bad == nil)
assert(why:find("akkar.vm: could not compile", 1, true) == 1)
```

## vm.eval(source, options, ...)

Compiles and runs in one call. `options` is passed to `vm.compile`, and
`options.limits` is passed to `vm.run` as its limits. Extra arguments go to the
chunk.

**Returns** the same three values `vm.run` returns. A compile failure comes
back as `false, <reason>, {}`, with an empty report rather than one carrying
`instructions` and `peak_kb`.

```lua
local vm = require "akkar.vm"

local ok, value, report = vm.eval("local a, b = ... return a + b", {}, 2, 40)
assert(ok == true)
assert(value == 42)
assert(type(report.instructions) == "number")

local bad, why, empty = vm.eval "return ("
assert(bad == false)
assert(why:find("could not compile", 1, true))
assert(next(empty) == nil)
```

## vm.harden()

Sets `__metatable` on the shared string metatable to the string
`"string metatable is not available"`, after which `getmetatable("")` returns
that string instead of the table.

**Returns** `true`, always. Idempotent, and it never lowers protection somebody
else set: it writes `__metatable` only where that field is currently `nil`.

This is a process-wide change to a global type. It is done on first use rather
than at require time, and `vm.compile` calls it, so almost nobody calls it
directly.

```lua no-run
local vm = require "akkar.vm"
vm.harden()
-- getmetatable("") now answers "string metatable is not available"
```

## vm.run(chunk, limits, ...)

Runs a compiled chunk with a count hook installed. Extra arguments are passed
to the chunk.

| field | type | default | meaning |
|---|---|---|---|
| `instructions` | number | `10e6` | the budget. Exceeding it raises inside the chunk |
| `memory_kb` | number | `8192` | growth above the reading taken at entry, in KB. Exceeding it raises inside the chunk |
| `check_every` | number | `1000` | how many VM instructions between hook firings, and the amount `instructions` counts up by each time |

**Returns** three values, always, in this order:

1. `ok`, a boolean.
2. the chunk's **first** return value when `ok`, or the error when not.
3. `report`.

| report field | meaning |
|---|---|
| `instructions` | `check_every` multiplied by the number of hook firings. It is `0` for a chunk that finishes before the first firing |
| `peak_kb` | the largest growth over the entry reading seen at a hook firing |
| `exceeded` | `nil`, `"instruction budget"` or `"memory ceiling"` |
| `results` | present only when `ok`: everything the chunk returned, as a packed table with `n` |

Only the first return value is in position two, because the report has to have
a fixed position to be usable.

**Raises** `akkar.vm.run needs a compiled chunk; got <type>` when `chunk` is
not a function. Everything else the chunk does comes back as `false` and a
message.

**The overrun messages** are
`akkar.vm: instruction budget of <n> exhausted` and
`akkar.vm: memory ceiling of <n> KB exceeded (<m> KB)`.

A chunk cannot catch its own overrun and keep going. The sandbox's `pcall` and
`xpcall` re-raise once the run's state says the budget is gone, so
`while true do pcall(function() while true do end end) end` still ends.
Ordinary errors stay catchable.

The hook that was installed before the run is restored afterwards, and the run
state is keyed on the running coroutine, so two tenants running the same
compiled chunk cannot see each other's ceiling or clear each other's flag.

```lua
local vm = require "akkar.vm"

local chunk = assert(vm.compile "return 1, 2, 3")
local ok, first, report = vm.run(chunk)
assert(ok == true)
assert(first == 1)
assert(report.results.n == 3)
assert(report.results[3] == 3)
assert(report.exceeded == nil)

-- A budget that runs out.
local spin = assert(vm.compile "while true do end")
local finished, why, spent = vm.run(spin, { instructions = 50000 })
assert(finished == false)
assert(spent.exceeded == "instruction budget")
assert(why:find("instruction budget of 50000 exhausted", 1, true))

-- And it cannot be swallowed.
local greedy = assert(vm.compile "while true do pcall(function() while true do end end) end")
local caught = vm.run(greedy, { instructions = 50000 })
assert(caught == false)
```

## Process-wide effects

Two things outlive the sandbox, and both happen the first time `vm.compile`
runs.

**The string metatable is closed**, by `vm.harden()`. `getmetatable("")` in the
host answers a string from then on.

**The real `string.rep` is wrapped.** The wrapper checks a limit only while a
sandbox is running on the current coroutine, and calls straight through
otherwise, so host code is unaffected. It exists because `("x"):rep(n)` resolves
through the shared string metatable to the real library and never through the
sandbox's copy, so bounding only the copy would bound nothing.

Inside a sandbox that has exceeded its `max_string`, the message is
`string.rep would build <n> bytes; the limit is <m>`.

## Not here

**A separate Lua state.** Lua 5.4 has no way to create an isolated VM from
Lua. That needs C or a subprocess.

**Bytecode.** Loading is `"t"`, always. Crafted bytecode escapes every sandbox
ever written.

**A wall-clock timeout.** The budget is instructions, not seconds, and one
instruction can do unbounded work: `("x"):rep(2^30)` allocates a gigabyte
before the hook fires again. `string.rep` is bounded for exactly that reason;
nothing else is.

**A bound on `string.format`.** It was here and was taken out. Lua 5.4 rejects
any width of 100 or more as an invalid conversion specification, so a single
directive can produce at most 99 bytes.

**A security boundary against a determined attacker sharing your process.**
Said plainly in the module's own header, and repeated here.

## See also

- [akkar.build](build.md), which also refuses bytecode, and for the same reason
- the module source, `akkar/vm.lua`, for the three escapes and why the run state
  is per coroutine
