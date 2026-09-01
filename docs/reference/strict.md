# akkar.strict

Puts a metatable on `_G` so that reading or writing an undeclared global
raises. Five functions and no configuration.

**When you need it.** In development and in the test suite, where a typo that
silently creates a global is a bug you want to find now. On a server it is
worse than a typo: a global written inside a handler outlives the request and
is visible to the next one, for another user.

```lua no-run
local strict = require "akkar.strict"
```

## strict.active()

**Returns** `true` when the check is installed, `false` when it is not.

```lua
local strict = require "akkar.strict"
assert(strict.active() == false)
local key = strict.on()
assert(strict.active() == true)
strict.off(key)
assert(strict.active() == false)
```

## strict.declare(...)

Marks one or more names as declared, so reading or writing them is allowed.
Takes any number of strings.

**Returns** nothing.

Works whether or not the check is on: the declared set is module state and is
consulted only while `strict.on()` is in force. Declaring a name never
undeclares another, and there is no way to undeclare one.

```lua
local strict = require "akkar.strict"

local key = strict.on()
strict.declare("counter", "registry")
counter = 0
registry = {}
assert(counter == 0)
strict.off(key)
```

## strict.declared(name)

**Returns** `true` when `name` is in the declared set, `false` otherwise. The
comparison is against `true` exactly, so this is always a boolean.

Note what the set contains after `strict.on()`: every key that was in `_G` at
that moment, which is the whole standard library plus anything the program set
up before deciding to be strict.

```lua
local strict = require "akkar.strict"

local key = strict.on()
assert(strict.declared "print" == true)     -- already in _G at snapshot time
assert(strict.declared "mystery" == false)
strict.declare "mystery"
assert(strict.declared "mystery" == true)
strict.off(key)
```

## strict.off(key)

Puts back whatever metatable `_G` had before `strict.on()` installed its own.

Takes the `key` that `strict.on()` returned and **raises** without it. Strict
mode is process-wide, so `off` used to be a switch that every handler in the
process could reach: any one of them could turn the check off for the whole
server and for every other request in it. Turning it off now belongs to
whoever turned it on.

**Returns** the module, so calls chain. Returns immediately if the check is not
active, key or no key.

Only the metatable this module installed comes off. If something else replaced
it in the meantime, that one is left where it is rather than removed -- the
same restraint `strict.on()` shows on the way in.

The declared set survives. Turning the check off and on again does not forget
what was declared, and the second `strict.on()` takes a fresh snapshot of `_G`
on top of it.

```lua
local strict = require "akkar.strict"

local key = strict.on()
assert(select(1, pcall(strict.off)) == false)        -- no key, no switch
assert(select(1, pcall(strict.off, {})) == false)    -- and not just any table
assert(strict.active() == true)

strict.off(key)
undeclared_and_fine = 1          -- no metatable, so no error
assert(undeclared_and_fine == 1)
```

## strict.on()

Snapshots the current contents of `_G` as declared, then installs `__newindex`
and `__index` on `_G`.

**Returns** the key that `strict.off` requires. Idempotent: a second call while
active does nothing at all, including taking a second snapshot, and hands back
the same key.

**Raises** when `_G` already carries a metatable somebody else installed.
Replacing it would silently break whatever was relying on it -- an ORM's lazy
loader, a REPL's autocomplete -- somewhere far from here, so two libraries
arguing over the global table is reported as the configuration error it is
rather than won quietly.

**Raises**, from the installed metamethods rather than from this call:

Writing an undeclared global, at level 2 so the position blamed is the caller's:

```
assignment to undeclared global 'counter' at app.lua:12
  a global written in a handler outlives the request and is visible to the next one
  did you mean `local counter`?  to declare it on purpose: require('akkar.strict').declare('counter')
```

Reading one:

```
read of undeclared global 'mystery' at app.lua:12
  most often a typo in a local name, or a module someone forgot to require
```

The position after `at` comes from `debug.getinfo`, and is `?` when there is no
frame to read.

```lua
local strict = require "akkar.strict"

local key = strict.on()

local ok, why = pcall(function() undeclared = 1 end)
assert(ok == false)
assert(why:find("assignment to undeclared global 'undeclared'", 1, true))

local read_ok, read_why = pcall(function() return also_undeclared end)
assert(read_ok == false)
assert(read_why:find("read of undeclared global 'also_undeclared'", 1, true))

strict.off(key)
```

## Not here

**A per-module or per-coroutine scope.** The metatable is on `_G`, so the
check is process-wide and so is the declared set.

**A way to undeclare a name.** `strict.declare` only adds.

**Automatic installation.** Requiring the module changes nothing. akkar turns
it on in development and in the test suite, and leaves it off in production
unless asked, because a false positive that takes down a live server is worse
than the bug it was looking for.

**A list of what is declared.** `strict.declared(name)` answers one name at a
time; the set itself is not exported.

## See also

- [akkar](akkar.md), which re-exports this module as `akkar.strict`
- `spec/000_strict_first_spec.lua`, named so that it runs before anything else
- the module source, `akkar/strict.lua`, for why the snapshot is taken at
  `on()` rather than at require time
