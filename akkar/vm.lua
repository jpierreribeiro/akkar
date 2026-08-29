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
- an instruction budget charged on every hook firing;
- a memory ceiling sampled on every LINE the chunk executes.

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

**And bounding `rep` does not bound `..`.** `s = s .. s` is one instruction,
twelve of them double a string twelve times, and the count hook fires every
thousand -- so it never fired at all. Measured: a chunk built a **4 GiB**
string against a 1 MB ceiling and the report came back `peak_kb = 0,
instructions = 0, exceeded = nil`. One tenant OOM-kills the process for every
tenant, and the sandbox says nothing happened.

Concatenation of two strings is executed by the VM without consulting any
metatable, so there is nothing to wrap. What there is instead is the **line**
hook: memory is sampled on every line the chunk executes, so a doubling loop
is checked once per iteration. The residual, stated rather than discovered:
the overshoot is bounded by what a single LINE can allocate, not by the
ceiling itself -- the run above now stops at 1,530 KB against 1,024. If that
margin matters, it is the separate-process answer above.

Two consequences of the line hook, both stated rather than discovered.
Installing it **starves the count hook**: measured on `while true do end`,
200,000 line events arrived with one count event beside them, so the budget is
charged on both -- `step` for a count event, one for a line -- and a chunk is
under-charged for its work rather than over-charged. And a sandbox now runs
about an order of magnitude slower than host code, which is the price of a
ceiling that is a ceiling.

**Anything reachable through the shared string metatable, not just `rep`.**
`env.string.dump = nil` removed the sandbox's copy, and the copy was never the
route: `("").dump` resolves through that same metatable to the real library. A
chunk handed a host function through the documented `options.expose` pattern
dumped it and read a live-looking API key out of the constant table. So
`dump` is withdrawn where `rep` is bounded -- on the real library, for the
duration of a run, on this coroutine only.

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

-- Per COROUTINE, not per process.
--
-- This was a pair of process globals: a depth counter incremented by `run`
-- and decremented after, plus a single limit that the last `compile` won.
-- Two defects came out of that, and both are cross-tenant:
--
-- A sandbox abandoned by a request deadline never runs the decrement, because
-- an abandoned coroutine never resumes. The bound then applied to the WHOLE
-- process, host code included, for the life of that process. Measured: one
-- timed-out request made a plain `("x"):rep(4 MiB)` in framework code fail
-- with one tenant's 64-byte ceiling.
--
-- And the single limit was last-writer-wins, so a tenant compiling with a
-- generous ceiling raised it for a tenant who had asked for nothing, and a
-- tenant compiling with a tiny one broke everybody else's strings.
--
-- Keyed on the running coroutine, both problems disappear by construction: an
-- abandoned coroutine's entry is simply garbage that nothing ever reads
-- again, and no two sandboxes can see each other's ceiling. The table holds
-- weak keys so a collected coroutine takes its entry with it.
local active = setmetatable({}, { __mode = "k" })
local bounds_installed = false

local function current_limit()
  local co = coroutine.running()
  return co and active[co] or nil
end

--- True while THIS coroutine is inside `run`.
---
--- Distinct from `current_limit`, which answers "how many bytes", because the
--- functions withdrawn from a sandbox are withdrawn regardless of size.
local function in_sandbox()
  local co = coroutine.running()
  return co ~= nil and active[co] ~= nil
end

local function install_string_bounds()
  if bounds_installed then return end
  bounds_installed = true

  local rep = string.rep

  string.rep = function(s, n, sep)
    local limit = current_limit()
    if limit then
      local size = (#tostring(s) + #tostring(sep or "")) * (tonumber(n) or 0)
      if size > limit then
        error(("string.rep would build %d bytes; the limit is %d")
              :format(size, limit), 2)
      end
    end
    return rep(s, n, sep)
  end

  -- `env.string.dump = nil` deleted the sandbox's COPY, and the copy is not
  -- the route: `("").dump` resolves through the shared string metatable to
  -- the real library, which is the exact mechanism this file already wrote
  -- down for `rep` and then did not generalise. Measured: a chunk handed a
  -- host function through the documented `options.expose` pattern dumped it
  -- and read a live-looking API key straight out of the constant table.
  --
  -- So it is withdrawn where it actually lives, on the same depth counter, and
  -- restored to the host the moment the run ends.
  local dump = string.dump

  string.dump = function(...)
    if in_sandbox() then
      error("string.dump produces bytecode, and bytecode carries the "
         .. "function's constants; it is not available inside a sandbox", 2)
    end
    return dump(...)
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

  -- The sandbox's copy points at the bounded one, so both spellings agree.
  env.string = env.string or {}
  env.string.rep = string.rep

  local state = { max_string = options.max_string or MAX_STRING }
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

  local function sample()
    local grown = collectgarbage "count" - baseline
    if grown > peak then peak = grown end
    return grown
  end

  -- Fires on every LINE as well as every `step` instructions.
  --
  -- Sampling only on the count hook meant the ceiling did not bound `..` at
  -- all: `for i = 1, 22 do s = s .. s end` is a couple of dozen instructions,
  -- so the hook never fired, and a measured run built a 4 GiB string against
  -- a 1 MB ceiling and reported `peak_kb = 0, instructions = 0, exceeded =
  -- nil`. One tenant OOM-kills the process for every tenant, and the report
  -- says nothing happened.
  --
  -- There is no allocation hook in Lua, and `..` on two strings is handled by
  -- the VM without consulting any metatable, so it cannot be wrapped the way
  -- `string.rep` is. The line hook is the closest thing to one: a doubling
  -- loop is checked once per iteration, so the overshoot is what a SINGLE
  -- LINE can allocate rather than what a program can. That residual is stated
  -- in the module comment rather than left to be discovered.
  -- A line hook fires on `run`'s OWN lines as well, including the ones after
  -- the chunk has returned and memory is still high. Raising there would
  -- happen outside the pcall and escape to the caller as a framework error
  -- rather than as this chunk's refusal. So the budget is only enforced on a
  -- frame belonging to the untrusted source -- checked on the raising path,
  -- which is taken once, and never on the sampling path, which is taken
  -- constantly.
  local chunk_source = debug.getinfo(chunk, "S").short_src

  local function in_the_chunk()
    local info = debug.getinfo(3, "S")     -- 1 = here, 2 = hook, 3 = interrupted
    return info ~= nil and info.short_src == chunk_source
  end

  -- Charged per hook firing, and the two firings are worth different amounts.
  --
  -- A count event means `step` instructions went by. A line event means at
  -- least one did. Both are charged because installing the line mask starves
  -- the count hook: measured on `while true do end`, 200,000 line events
  -- arrived with ONE count event beside them, so a budget fed only by count
  -- events stopped stopping infinite loops. Charging a line as one
  -- instruction under-counts real work and never over-counts it, which is the
  -- right direction for a budget to be wrong in.
  local function hook(event)
    used = used + (event == "count" and step or 1)
    local grown = sample()

    if used > max_instructions and in_the_chunk() then
      state.exceeded = state.exceeded or "instruction budget"
      state.reason = "akkar.vm: instruction budget of " .. max_instructions ..
                     " exhausted"
      error(state.reason, 2)
    end
    if grown > max_memory_kb and in_the_chunk() then
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
  debug.sethook(hook, "l", step)
  -- Marked on THIS coroutine only, so an abandoned run cannot bound anybody
  -- else and two tenants cannot see each other's ceiling.
  local co = coroutine.running()
  local restore = co and active[co]
  if co then active[co] = state.max_string or MAX_STRING end

  local results = table.pack(pcall(chunk, ...))
  debug.sethook(previous, previous_mask or "", previous_count or 0)

  -- The last thing a chunk does can be the expensive thing, and it happens
  -- after the final hook fired. Sampling once more is the difference between
  -- a report and a report that is wrong in the caller's favour -- the run
  -- that built four gigabytes reported `peak_kb = 0`.
  sample()

  if co then active[co] = restore end

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
