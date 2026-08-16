# akkar.build

Turns an application and its modules into one C file and, unless told not to,
links that file into a single executable containing the Lua VM, every Lua
module as source, and every native module.

**When you need it.** You are producing a deployable artefact: a container
image with no Lua, no LuaRocks and no `.so` in it. Almost everybody reaches
this module through the `akkar build` command rather than through Lua.

```lua no-run
local build = require "akkar.build"
```

## Index

Every public symbol on this page, in alphabetical order, and the two commands
that wrap them.

| symbol | kind |
|---|---|
| [`akkar archive`](#command-line-akkar-archive) | command |
| [`akkar build`](#command-line-akkar-build) | command |
| [`build.archive`](#buildarchiveoptions) | function |
| [`build.collect`](#buildcollectroot-into) | function |
| [`build.emit`](#buildemitplan) | function |
| [`build.module_name_for`](#buildmodule_name_forroot-path) | function |
| [`build.module_name_of`](#buildmodule_name_ofsymbol) | function |
| [`build.plan`](#buildplanoptions) | function |
| [`build.recipes`](#buildrecipes) | table |
| [`build.required_names`](#buildrequired_namespaths) | function |
| [`build.run`](#buildrunoptions) | function |
| [`build.symbols_in`](#buildsymbols_inarchive) | function |

## Command line: akkar build

```sh
akkar build app.lua [options]
```

`app.lua` is the entry file. It is embedded like any other module, under the
name `__akkar_entry`, and required by the generated `main`.

| flag | value | default | meaning |
|---|---|---|---|
| `-o` | NAME | the entry file's basename without `.lua` | the executable to write |
| `--root` | DIR | none, repeatable | a directory of Lua modules to embed. The first root wins, so listing your own directory first shadows a library module |
| `--archive` | A.a | none, repeatable | a static archive of native modules |
| `--lua-lib` | PATH | none | `liblua.a`. Required unless `--c-only` |
| `--lua-inc` | DIR | none | the directory holding `lua.h`. Required unless `--c-only` |
| `--libs` | "..." | `-lm -ldl -lpthread` | extra linker flags |
| `--cc` | NAME | `$CC`, or `cc` | the compiler |
| `--c-only` | | off | write the C and stop, without compiling |

The directory holding akkar itself is appended to the roots without being
asked for, so `--root` never has to name akkar. Everything else the
application needs is a root the caller states.

**Writes** the C file at `<output>.c`, and the executable at `<output>` unless
`--c-only`.

**Prints** one line on success, to standard output:

```
akkar build: 141 Lua modules, 47 native modules -> /build/akkar-app
```

The last field is the binary, or the C file when `--c-only` was given.

**Exit codes.** 0 on success. 2 on any failure, with the reason on standard
error prefixed `akkar: `. There is no exit code 1 from this command. The
failures are: an unknown option, a flag with no value after it, no entry file
(`build needs an entry file: akkar build app.lua`), a missing `--lua-lib` or
`--lua-inc` while compiling, and anything `build.run` returns as a reason.

## Command line: akkar archive

```sh
akkar archive LIBRARY --source DIR --lua-inc DIR [options]
```

Compiles a C rock's source tree into one static archive that `akkar build
--archive` can consume.

| flag | value | default | meaning |
|---|---|---|---|
| `--source` | DIR | none, required | the unpacked source directory |
| `--lua-inc` | DIR | none, required | the directory holding `lua.h` |
| `--lua-api` | VERSION | `5.4` | substituted into the recipe's make target and object globs |
| `-o` | PATH | `<library>.a` | the archive to write |
| `--cc` | NAME | `$CC`, or `cc` | the compiler |

`LIBRARY` is a key of [`build.recipes`](#buildrecipes): `cqueues`, `luaossl`,
`lua-cjson` or `lpeg`.

**Prints** `akkar archive: 12 objects -> cqueues.a`.

**Exit codes.** 0 on success, 2 for a bad command line, and 1 for an unknown
library name. A missing library name is a command line failure and prints the
known ones; a name that is not a recipe gets past the command line and reaches
`build.archive`, whose raise is not caught here, so it arrives as a Lua
traceback rather than as a one line `akkar: ` message.

**Not in `akkar help`.** `akkar archive` is dispatched by `bin/akkar` and is
absent from the usage text that `akkar help` prints.

## What the built binary does

The generated `main` reads `argv` before requiring the embedded entry module.

| invocation | behaviour |
|---|---|
| `./app` | requires `__akkar_entry`, the embedded entry file |
| `./app run other.lua` | loads and runs `other.lua` from disk instead, with `arg[0]` set to that path and `arg[1..]` to the remaining parameters |
| `./app --akkar-version` | prints the `built_with` string and exits 0 |
| anything else | the entry module again, with `arg` built as a standalone interpreter would |

A raise from the entry module prints `akkar: <message>` on standard error and
exits 1.

## build.archive(options)

Compiles a library's source into a static archive. Every command it runs keeps
its output, so a failure names the command and quotes what it said.

| field | type | default | meaning |
|---|---|---|---|
| `source` | string | required | the unpacked source directory |
| `output` | string | required | the `.a` to write |
| `lua_include` | string | required | where `lua.h` lives |
| `recipe` | string or table | `{}` | a key of `build.recipes`, or a table of the same shape |
| `lua_api` | string | `"5.4"` | substituted into `recipe.make` and into each `recipe.objects` pattern |
| `sources` | list of string | none | used when the recipe has no `make` and no `sources` of its own |
| `cc` | string | `$CC`, or `cc` | the compiler |
| `stage` | string | `source .. "/.akkar-archive"` | where colliding objects are copied before archiving |

With `recipe.make` set, `make <target> CPPFLAGS=...` runs in `source`, the
`recipe.objects` globs are expanded, and colliding basenames are renamed
`dup1_<base>` when `recipe.prefix_collisions` is true. Without it, each file in
`sources` is compiled with `-c -O2 -fPIC`.

**Returns** `{ archive = output, objects = <count> }`, or `nil` and a reason.

**Raises** `akkar.build: no source directory`, `akkar.build: no lua_include`,
`akkar.build: no output` when those are missing, and
`akkar.build: no recipe for '<name>'; pass `sources` or `make` explicitly`
for a recipe name that is not in `build.recipes`.

**Returns `nil` and a reason** when `make` fails, when a compile fails, when
two objects share a basename and the recipe does not say which wins, when no
object files were produced, and when `ar` fails.

```lua no-run
-- Compiling a real rock needs its unpacked source, so this is not run here.
local build = require "akkar.build"
local result, why = build.archive {
  recipe = "lpeg",
  source = "/tmp/lpeg-1.1.0",
  lua_include = "/usr/include/lua5.4",
  output = "/tmp/lpeg.a",
}
```

## build.collect(root, into)

Finds every `.lua` file under `root` and maps its module name to its path.
Runs `find`, so it needs a shell.

**Returns** `into`, or a new table, keyed by module name. An existing key is
never overwritten, which is what makes the first root win.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_1"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/greet.lua", "w"))
file:write "return {}\n"
file:close()

local found = build.collect(dir)
assert(found.greet == dir .. "/greet.lua")

os.execute(("rm -rf %q"):format(dir))
```

## build.emit(plan)

Writes the C host for a plan and returns it as a string. Every Lua module goes
in as a hex array of its source bytes and is registered in `package.preload`;
every native module is declared and registered under its real name.

| field | type | default | meaning |
|---|---|---|---|
| `entry` | string | required | the module name `main` requires |
| `lua` | table | required | `[module name] = path` |
| `native` | table | `{}` | `[module name] = luaopen symbol` |
| `built_with` | string | `"akkar dev-1"` | what the binary prints for `--akkar-version` |

**Returns** the C source, or `nil` and `cannot read <path> for module <name>:
<why>` when a listed file cannot be read.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_2"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "print 'hello'\n"
file:close()

local source = build.emit {
  entry = "__akkar_entry",
  lua = { __akkar_entry = dir .. "/app.lua" },
  native = {},
  built_with = "akkar dev-1",
}
assert(source:find("AKKAR_ENTRY", 1, true))
assert(source:find("int main(int argc, char **argv)", 1, true))

os.execute(("rm -rf %q"):format(dir))
```

## build.module_name_for(root, path)

The module name a file under `root` would be required by. `init.lua` is
stripped, matching `package.path`, so `<root>/akkar/init.lua` is `akkar` and
not `akkar.init`.

**Returns** a string.

```lua
local build = require "akkar.build"
assert(build.module_name_for("/srv/app", "/srv/app/akkar/init.lua") == "akkar")
assert(build.module_name_for("/srv/app", "/srv/app/lib/util.lua") == "lib.util")
```

## build.module_name_of(symbol)

The module name a `luaopen_` symbol belongs to, by rule: a leading underscore
is part of the name, every other underscore is a separator.

**Returns** a string, or `nil` when the symbol does not start with `luaopen_`.

The rule cannot recover a name that genuinely contains an underscore.
`luaopen__openssl_x509_verify_param` is `_openssl.x509.verify_param` and this
answers `_openssl.x509.verify.param`. That is why `build.plan` consults
`build.required_names` first and falls back to this rule only for symbols
nothing asked for by name.

```lua
local build = require "akkar.build"
assert(build.module_name_of "luaopen_lpeg" == "lpeg")
assert(build.module_name_of "luaopen__cqueues_socket" == "_cqueues.socket")
assert(build.module_name_of "not_a_symbol" == nil)
```

## build.plan(options)

Collects the Lua modules under every root, adds the entry file under a name no
application would choose, reads the `luaopen_` symbols out of every archive,
and decides which symbol belongs to which module name.

| field | type | default | meaning |
|---|---|---|---|
| `entry` | string | required | path of the entry Lua file |
| `roots` | list of string | `{}` | directories of Lua modules; the first root wins on a name collision |
| `archives` | list of string | `{}` | static archives to read symbols from |
| `native` | table | `{}` | `[module name] = symbol`, applied last, so it wins over anything derived |
| `entry_name` | string | `"__akkar_entry"` | the name the entry file is embedded under |

Naming happens in three passes: names literally required by the embedded
sources first, then `build.module_name_of` for whatever symbol is left over,
then `options.native`.

**Returns** `{ entry = <name>, lua = { [name] = path }, native = { [name] =
symbol } }`, or `nil` and a reason when an archive cannot be read.

**Raises** `akkar.build: no entry file` when `entry` is missing.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_3"
os.execute(("rm -rf %q && mkdir -p %q/lib"):format(dir, dir))
local lib = assert(io.open(dir .. "/lib/greet.lua", "w"))
lib:write "return {}\n"
lib:close()
local entry = assert(io.open(dir .. "/app.lua", "w"))
entry:write 'require "greet"\n'
entry:close()

local plan = build.plan { entry = dir .. "/app.lua", roots = { dir .. "/lib" } }
assert(plan.entry == "__akkar_entry")
assert(plan.lua.greet == dir .. "/lib/greet.lua")
assert(plan.lua.__akkar_entry == dir .. "/app.lua")

os.execute(("rm -rf %q"):format(dir))
```

## build.recipes

What each known library needs, as a table keyed by library name. Anything not
here can still be archived by passing the same fields to `build.archive`
explicitly.

| key | fields | why |
|---|---|---|
| `cqueues` | `make = "all%s"`, `objects = { "src/%s/*.o", "src/lib/*.o" }`, `prefix_collisions = true` | `src/lib` and `src/<api>` both define `socket.o`, `dns.o` and `notify.o` |
| `luaossl` | `make = "all%s"`, `cppflags = "-DHAVE_DLADDR=0"`, `objects = { "src/%s/*.o" }` | without the flag the binary dies at startup on a `dlopen` of itself |
| `lua-cjson` | `sources = { "lua_cjson.c", "fpconv.c", "strbuf.c" }` | `fpconv.c` or `dtoa.c`, never both: each defines `fpconv_strtod` |
| `lpeg` | `sources = { "lpcap.c", "lpcode.c", "lpcset.c", "lpprint.c", "lptree.c", "lpvm.c" }` | six named sources and nothing else |

`%s` in `make` and in `objects` is replaced with `lua_api`.

## build.required_names(paths)

Reads every literal `require "name"` and `require 'name'` out of the files in
`paths` and returns them as a set. `paths` is iterated with `pairs`, so the
`plan.lua` table can be passed straight in.

**Returns** a table where `[name] = true`.

A module fetched through a computed name is invisible here, as it is to any
tool that reads source instead of running it.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_4"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write 'local x = require "cqueues"\nlocal y = require("akkar.db")\n'
file:close()

local names = build.required_names { dir .. "/app.lua" }
assert(names.cqueues == true)
assert(names["akkar.db"] == true)

os.execute(("rm -rf %q"):format(dir))
```

## build.run(options)

Plans, emits the C, writes it, and links the executable unless `compile` is
`false`. This is what `akkar build` calls.

Takes every field [`build.plan`](#buildplanoptions) takes, plus:

| field | type | default | meaning |
|---|---|---|---|
| `output` | string | `"akkar-app"` | the executable to write |
| `c_out` | string | `output .. ".c"` | the C file to write |
| `compile` | boolean | `true` | `false` writes the C and returns without linking |
| `cc` | string | `$CC`, or `cc` | the compiler |
| `cflags` | string | `"-Os"` | compiler flags |
| `libs` | string | `"-lm -ldl -lpthread"` | linker flags, appended last |
| `lua_library` | string | required when compiling | `liblua.a` |
| `lua_include` | string | required when compiling | where `lua.h` lives |

The link line always carries `-no-pie` and `-rdynamic`. `-no-pie` is not
optional: luaossl asks the dynamic loader for the running image, and a
position-independent executable cannot be reopened that way.

`built_with` is not carried through here. `build.plan` returns only `entry`,
`lua` and `native`, so a binary built by `build.run` always reports
`akkar dev-1` for `--akkar-version`. Setting it needs a hand-made plan passed
to [`build.emit`](#buildemitplan).

**Returns** `{ c = <path>, binary = <path>, modules = { lua = n, native = n } }`,
or `{ c = <path>, modules = ... }` with no `binary` when `compile` is `false`.
Returns `nil` and a reason when planning fails, when emitting fails, when the C
file cannot be opened, or when the compiler refuses (`the compiler refused
(<kind> <code>): <command>`).

**Raises** `akkar.build: no lua_library (the path to liblua.a)` and
`akkar.build: no lua_include (the directory holding lua.h)` when those are
missing and `compile` is not `false`. Those two are raises, not returned
reasons, unlike every other failure of this function.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_5"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "print 'hello'\n"
file:close()

-- `compile = false` writes the C host and stops, so no compiler is involved.
local result, why = build.run {
  entry = dir .. "/app.lua",
  output = dir .. "/app",
  compile = false,
}
assert(result, why)
assert(result.c == dir .. "/app.c")
assert(result.binary == nil)
assert(result.modules.lua >= 1)

os.execute(("rm -rf %q"):format(dir))
```

## build.symbols_in(archive)

Reads the `luaopen_` symbols defined by a static archive, by running
`nm -g --defined-only`.

**Returns** a sorted list of symbol names, or `nil` and `could not run nm:
<why>`. An archive that does not exist is not an error here: `nm` writes to
standard error, which is discarded, and the list comes back empty.

```lua no-run
local build = require "akkar.build"
local symbols = build.symbols_in "/build/cqueues.a"
-- { "luaopen__cqueues", "luaopen__cqueues_socket", ... }
```

## Not here

**Dependency resolution.** This module embeds the modules it is told about. It
does not work out what an application loads.

**Cross-compilation.** It builds for the machine it runs on.

**Bytecode.** Lua modules are embedded as source. Bytecode is not portable
across versions or word sizes, and `akkar.vm` refuses to load it on principle.

**`--trace`.** The module header mentions `akkar build --trace` as the way to
find out what an application loads. No such flag exists, in `bin/akkar` or
here.

## See also

- [akkar.vm](vm.md), which refuses bytecode for the same reason this module does
  not emit it
- [Putting it on the internet](../guide/12-deploying.md), which builds this into
  a container image
- `bin/akkar`, for the command line that wraps it
- the module source, `akkar/build.lua`, for why the naming rule is what it is
