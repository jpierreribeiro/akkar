--[[
akkar.vm — running code you did not write.

The case: a customer publishes a hook, a validation rule, a computed field.
It has to run in this process, it must not read the filesystem, it must not
call out to the network, it must not spin forever, and it must not exhaust
memory. It also must not be able to reach the application around it.

## What this is, said plainly

A **sandbox inside one Lua state**, not a separate state. Lua 5.4 has no way
to create an isolated VM from Lua; that needs C (`lua_newstate`) or a
subprocess. What exists here is:

- a curated `_ENV` -- the untrusted chunk sees only what is listed below;
- text-only loading, because bytecode escapes every sandbox ever written;
- an instruction budget enforced by a count hook;
- a memory ceiling sampled at those same hook firings.

Within those limits it is real. Beyond them it is not a security boundary
against a determined attacker sharing your process, and this file will not
pretend otherwise. **If the code is hostile rather than merely untrusted, run
it in a separate process with an OS-level sandbox.** That is not a nicety;
it is the difference between a bug and a breach.

## Three escapes worth naming, because each one is quiet

**Bytecode.** `load` with mode `"b"` or `"bt"` accepts precompiled chunks, and
crafted bytecode can read and write arbitrary memory -- the VM validates very
little. Loading is `"t"` here and there is no way to ask for anything else.

**Coroutines.** `debug.sethook` installs a hook on **one coroutine**. A
sandboxed chunk that calls `coroutine.wrap(function() while true do end end)()`
runs with no hook at all and hangs the process. So `coroutine` is not in the
environment. This is the escape most likely to be missed, because the sandbox
otherwise looks complete.

**One instruction, unbounded work.** The budget counts instructions, and
`("x"):rep(2^30)` is one instruction that allocates a gigabyte before the hook
ever fires again.

Bounding the sandbox's own `string.rep` does **not** fix this, which the test
found: `("x"):rep(n)` is method syntax on a string, and that resolves through
the shared string metatable to the real `string` library, never through the
copy in the sandbox's environment. A curated `_ENV` does not cover strings at
all.

So the bound is installed on the real `string.rep`, and applies only while a
sandbox is running -- a depth counter set by `run`. Outside a run it behaves
exactly as it always did.

`string.format` was bounded here too, against a wide field like
`%099999999d`. It has been taken out: Lua 5.4 rejects any width of 100 or
more as an invalid conversion specification, so a single directive can
produce at most 99 bytes and there was nothing to defend against. The check
cost a pattern match on every `format` call inside a sandbox and bought
nothing.

**A `pcall` that swallows the budget.** This one was found by the test that
was written to prove it could not happen. A budget enforced by raising an
error is enforced only if the error escapes, and

    while true do pcall(function() while true do end end) end

catches every overrun and keeps going forever. Lua has no uncatchable error,
so the sandbox's `pcall` and `xpcall` re-raise anything thrown after the
budget is gone. Ordinary errors are still catchable, which is the point of
having them at all.

## The shared string metatable

Every string in the process shares one metatable, and `getmetatable("")`
reaches it from inside any sandbox. Left alone, untrusted code could rewrite
`__index` and change what `s:upper()` means for the host.

`akkar.vm.harden()` sets `__metatable` on it, after which `getmetatable("")`
returns a plain string instead of the table. This is a **process-wide** change
and it is done once, on first use, rather than silently at require time --
a library that mutates a global type when it is merely loaded is a library
that surprises people.
]]

local M = {}

-- What untrusted code may see.  Everything here is pure computation: nothing
-- reads the filesystem, opens a socket, starts a process, or reaches the
-- application. The rule for adding to this list is that the addition can do
-- none of those things even when called with hostile arguments.
local function base_environment()
  local env = {
    assert = assert, error = error, ipairs = ipairs, next = next,
    pairs = pairs, select = select, tonumber = tonumber,
    tostring = tostring, type = type, rawequal = rawequal,
    rawlen = rawlen, rawget = rawget, rawset = rawset, unpack = table.unpack,
    setmetatable = setmetatable, getmetatable = getmetatable,
  }

  env.math = {}
  for name, fn in pairs(math) do env.math[name] = fn end
  -- `math.random` shares one generator with the host, so a chunk could reseed
  -- it and make the host's ids predictable.  Each sandbox gets its own.
  env.math.randomseed = function() end

  env.table = {}
  for name, fn in pairs(table) do env.table[name] = fn end

  env.string = {}
  for name, fn in pairs(string) do env.string[name] = fn end
  env.string.dump = nil        -- produces bytecode; nothing good comes of it

  -- The clock, and nothing else from `os`.  `os.time` and `os.date` cannot
  -- affect anything; `os.execute`, `os.remove`, `os.getenv` and `os.exit`
  -- obviously can, and `os.exit` would take the whole server down.
  env.os = {
    time = os.time, clock = os.clock, date = os.date, difftime = os.difftime,
  }

  -- Deliberately absent, each for its own reason:
  --   io          the filesystem
  --   require     reaches every module in the process, including akkar's
  --   load        would let the chunk build a new one with a different _ENV,
  --               or with bytecode
  --   dofile      the filesystem again
  --   debug       sethook, getlocal, getupvalue -- it undoes all of this
  --   coroutine   a hook is per-coroutine, so a new one runs unmetered
  --   collectgarbage  can stop the collector the memory ceiling relies on

  env._G = env                 -- so `_G.x = 1` stays inside the sandbox
  return env
end

M.base_environment = base_environment

-- `pcall` and `xpcall` that cannot swallow a budget overrun.
--
-- A budget enforced by raising is enforced only if the error escapes, and a
-- chunk is free to wrap its own loop in `pcall`. Lua has no uncatchable
-- error, so these refuse to return normally once the run is over: ordinary
-- errors stay catchable, and the one the hook throws does not.
local function install_pcall(env, state)
  env.pcall = function(fn, ...)
    local results = table.pack(pcall(fn, ...))
    if state.exceeded then error(state.reason, 0) end
    return table.unpack(results, 1, results.n)
  end

  env.xpcall = function(fn, handler, ...)
    local results = table.pack(xpcall(fn, handler, ...))
    if state.exceeded then error(state.reason, 0) end
    return table.unpack(results, 1, results.n)
  end
end

-- Per-chunk state, so `run` and the sandbox's own `pcall` agree on whether
-- the budget is gone.  Weak keys: a compiled chunk nobody holds is collected
-- along with its state.
local chunk_state = setmetatable({}, { __mode = "k" })

-- A single `rep` can allocate more than the whole budget between two hook
-- firings, and it is bounded on the real library, because `("x"):rep(n)`
-- never touches the sandbox's copy.
local MAX_STRING = 1024 * 1024

-- Zero outside a run.  Lua runs one coroutine at a time and a sandboxed chunk
-- has no `coroutine` to yield with, so a plain counter is enough.
local sandbox_depth = 0
local sandbox_limit = MAX_STRING
local bounds_installed = false

local function install_string_bounds()
  if bounds_installed then return end
  bounds_installed = true

  local rep = string.rep

  string.rep = function(s, n, sep)
    if sandbox_depth > 0 then
      local size = (#tostring(s) + #tostring(sep or "")) * (tonumber(n) or 0)
      if size > sandbox_limit then
        error(("string.rep would build %d bytes; the limit is %d")
              :format(size, sandbox_limit), 2)
      end
    end
    return rep(s, n, sep)
  end
end

--- Makes `getmetatable("")` opaque, process-wide.
---
--- Called on first use rather than at require time, because a library that
--- mutates a global type merely by being loaded is a library that surprises
--- people. Idempotent, and it never lowers protection someone else set.
local hardened = false
function M.harden()
  if hardened then return true end
  local mt = getmetatable ""
  if type(mt) == "table" and rawget(mt, "__metatable") == nil then
    mt.__metatable = "string metatable is not available"
  end
  hardened = true
  return true
end

--- Compiles untrusted source into a callable.
---
--- `options.env` replaces the environment wholesale; `options.expose` adds to
--- the default one, which is the usual case -- a spec's hook wants the tenant's
--- own data, not the filesystem.
function M.compile(source, options)
  options = options or {}
  if type(source) ~= "string" then
    error("akkar.vm.compile needs source as a string; got " .. type(source), 2)
  end
  M.harden()

  local env = options.env or base_environment()
  install_string_bounds()
  if options.max_string then sandbox_limit = options.max_string end

  -- The sandbox's copy points at the bounded one, so both spellings agree.
  env.string = env.string or {}
  env.string.rep = string.rep

  local state = {}
  install_pcall(env, state)

  for name, value in pairs(options.expose or {}) do env[name] = value end

  -- Mode "t" is the whole argument: never "b", never "bt".  Crafted bytecode
  -- is not sandboxable, so it is never accepted, not even from a caller who
  -- believes the source is safe.
  local chunk, err = load(source, "=" .. (options.name or "sandbox"), "t", env)
  if not chunk then
    return nil, "akkar.vm: could not compile: " .. tostring(err)
  end
  chunk_state[chunk] = state
  return chunk
end

--- Runs a compiled chunk under an instruction budget and a memory ceiling.
---
--- Returns `ok, result_or_error, report` -- always three values, in that
--- order. The report carries the instructions used and the peak growth, so a
--- caller can bill it, log it, or refuse it next time.
---
--- Only the chunk's FIRST return value comes back in position two, because
--- the report has to have a fixed position to be usable. Everything the chunk
--- returned is in `report.results`.
---
--- A budget overrun raises inside the chunk. The sandbox's own `pcall` refuses
--- to return normally afterwards, so a chunk cannot catch the overrun and keep
--- running -- see `install_pcall`.
function M.run(chunk, limits, ...)
  if type(chunk) ~= "function" then
    error("akkar.vm.run needs a compiled chunk; got " .. type(chunk), 2)
  end
  limits = limits or {}
  local max_instructions = limits.instructions or 10e6
  local max_memory_kb    = limits.memory_kb or 8192
  local step             = limits.check_every or 1000

  local state = chunk_state[chunk] or {}
  state.exceeded, state.reason = nil, nil

  local baseline = collectgarbage "count"
  local used, peak = 0, 0

  local function hook()
    used = used + step
    local grown = collectgarbage "count" - baseline
    if grown > peak then peak = grown end

    if used > max_instructions then
      state.exceeded = state.exceeded or "instruction budget"
      state.reason = "akkar.vm: instruction budget of " .. max_instructions ..
                     " exhausted"
      error(state.reason, 2)
    end
    if grown > max_memory_kb then
      state.exceeded = state.exceeded or "memory ceiling"
      state.reason = ("akkar.vm: memory ceiling of %d KB exceeded (%.0f KB)")
                     :format(max_memory_kb, grown)
      error(state.reason, 2)
    end
  end

  -- Whatever the host had installed goes back on afterwards.  akkar's own
  -- blocking watchdog is a count hook too, and losing it here would silence
  -- the diagnostic for every request that ran a sandbox.
  local previous, previous_mask, previous_count = debug.gethook()
  debug.sethook(hook, "", step)
  sandbox_depth = sandbox_depth + 1
  local results = table.pack(pcall(chunk, ...))
  sandbox_depth = sandbox_depth - 1
  debug.sethook(previous, previous_mask or "", previous_count or 0)

  local report = { instructions = used, peak_kb = peak, exceeded = state.exceeded }
  if not results[1] then return false, results[2], report end

  report.results = table.pack(table.unpack(results, 2, results.n))
  return true, results[2], report
end

--- compile + run, for the common case.
function M.eval(source, options, ...)
  options = options or {}
  local chunk, err = M.compile(source, options)
  if not chunk then return false, err, {} end
  return M.run(chunk, options.limits, ...)
end

return M
