--[[
Running code you did not write — readiness item 7.

The happy path is one test. The rest are attempts to escape, because a
sandbox is only interesting where it fails, and every one of these is a thing
a real sandbox has been broken by.

What this cannot claim is stated in `akkar/vm.lua` and worth repeating: this
is a sandbox inside one Lua state, not an isolated VM. Against hostile code
the honest answer is a separate process.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local vm = require "akkar.vm"

describe("running a chunk", function()
  it("computes and returns a value", function()
    local ok, result = vm.eval "return 2 + 3"
    assert.is_true(ok)
    assert.equal(5, result)
  end)

  it("takes arguments and exposed values", function()
    local ok, result = vm.eval("return greet(...)", {
      expose = { greet = function(name) return "hello " .. name end },
    }, "ada")
    assert.is_true(ok)
    assert.equal("hello ada", result)
  end)

  it("reports a syntax error instead of raising", function()
    local ok, err = vm.eval "this is not lua"
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "could not compile")
  end)

  it("returns the chunk's own error rather than propagating it", function()
    local ok, err = vm.eval "error('the tenant is wrong')"
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "the tenant is wrong")
  end)
end)

describe("what the sandbox cannot reach", function()
  local function denied(source)
    local ok, result = vm.eval(source)
    -- Either it raised, or the name was simply not there.
    assert.is_true(not ok or result == nil,
      "reachable from inside the sandbox: " .. source)
  end

  it("has no filesystem", function()
    denied "return io"
    denied "return io.open('/etc/passwd')"
    denied "return dofile('/etc/passwd')"
    denied "return loadfile('/etc/passwd')"
  end)

  it("cannot start a process or stop this one", function()
    denied "return os.execute"
    denied "return os.exit"
    denied "return os.getenv('HOME')"
    denied "return os.remove"
  end)

  it("cannot require its way to the application", function()
    -- `require` reaches every module in the process, akkar's own included.
    denied "return require"
    denied "return require('akkar')"
    denied "return package"
  end)

  it("cannot undo the sandbox with debug", function()
    denied "return debug"
    denied "return debug.sethook"
    denied "return debug.getupvalue"
  end)

  it("cannot build a second, freer sandbox", function()
    denied "return load"
    denied "return load('return io', nil, 'bt')"
    denied "return string.dump"
  end)

  it("cannot stop the collector the memory ceiling depends on", function()
    denied "return collectgarbage"
  end)

  it("cannot see the host's globals", function()
    denied "return _ENV.arg"
    local ok, result = vm.eval "sneaky = 1; return sneaky"
    assert.is_true(ok)
    assert.equal(1, result)
    assert.is_nil(_G.sneaky, "a global escaped into the host")
  end)
end)

describe("bytecode is never accepted", function()
  it("refuses a precompiled chunk", function()
    -- Crafted bytecode can read and write arbitrary memory; the VM validates
    -- very little. This is why loading is text-only with no way to ask
    -- otherwise.
    local bytecode = string.dump(load "return 1")
    local ok, err = vm.eval(bytecode)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "could not compile")
  end)
end)

describe("budgets", function()
  it("stops an infinite loop", function()
    local ok, err, report = vm.eval("while true do end", { limits = { instructions = 50000 } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "instruction budget")
    assert.equal("instruction budget", report.exceeded)
  end)

  it("cannot be escaped by catching the error", function()
    -- A chunk that wraps its own loop in pcall would otherwise swallow the
    -- overrun and keep running. The counter is not reset, so the next firing
    -- raises again immediately.
    local ok, err = vm.eval([[
      while true do pcall(function() while true do end end) end
    ]], { limits = { instructions = 50000 } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "instruction budget")
  end)

  it("has no coroutine to run unmetered inside", function()
    -- The escape most likely to be missed: a hook is installed on ONE
    -- coroutine, so a chunk that spawns its own runs with no budget at all
    -- and hangs the process.
    local ok, result = vm.eval "return coroutine"
    assert.is_true(not ok or result == nil, "coroutine is reachable")
  end)

  it("stops a chunk that eats memory", function()
    local ok, err, report = vm.eval([[
      local t = {}
      for i = 1, 1e9 do t[i] = { i, i, i } end
    ]], { limits = { memory_kb = 2048, instructions = 1e9 } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "memory ceiling")
    assert.equal("memory ceiling", report.exceeded)
  end)

  it("bounds a single allocation that would outrun the sampler", function()
    -- ONE INSTRUCTION, A GIGABYTE: the hook never fires in between, so the
    -- memory ceiling -- which is a COUNT hook, and can only look BETWEEN
    -- instructions -- cannot be what stops this. The bound on the real
    -- `string.rep` is.
    --
    -- This test used to be byte-identical to "catches method syntax" below,
    -- which is a different claim about a different defence, so the sampler
    -- claim had no test at all. What makes this one about the sampler is that
    -- it pins WHICH defence fired: the sampler took ZERO samples.
    local ok, err, report = vm.eval("return string.rep('x', 2^30)",
                                    { limits = { memory_kb = 1024 } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "string.rep would build",
      "expected the rep bound to refuse it; got: " .. tostring(err))
    assert.is_nil(report.exceeded,
      "the memory ceiling claims it caught this, so the test is not about " ..
      "the sampler being outrun after all")
    assert.equal(0, report.instructions,
      "the hook fired " .. report.instructions .. " times, so there WAS a " ..
      "sample between the start and the gigabyte")

    -- And the contrast that gives the above its meaning: the same gigabyte,
    -- built in steps the hook does get to fire between, IS the sampler's job
    -- and is caught by the ceiling rather than by the bound.
    local stepped, _, stepped_report = vm.eval([[
      local t = {}
      for i = 1, 1e9 do t[i] = ('x'):rep(64) end
    ]], { limits = { memory_kb = 1024, instructions = 1e9 } })
    assert.is_false(stepped)
    assert.equal("memory ceiling", stepped_report.exceeded)
    assert.is_true(stepped_report.instructions > 0)
  end)

  it("needs no help with a wide format field", function()
    -- This was bounded here too, until the test found the premise was false:
    -- Lua 5.4 rejects any width of 100 or more as an invalid conversion
    -- specification, so one directive can produce at most 99 bytes.
    local ok, err = vm.eval "return string.format('%099999999d', 1)"
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "invalid conversion specification")
  end)

  it("reports what an accepted chunk actually used", function()
    -- So a caller can bill it, log it, or refuse it next time.
    local ok, _, report = vm.eval("local n = 0 for i = 1, 100000 do n = n + i end return n",
                                  { limits = { instructions = 1e7 } })
    assert.is_true(ok)
    assert.is_true(report.instructions > 0)
    assert.is_nil(report.exceeded)
  end)
end)

describe("the host is left as it was found", function()
  it("puts the host's own hook back", function()
    -- akkar's blocking watchdog is a count hook too. Losing it here would
    -- silence that diagnostic for every request that ran a sandbox.
    local fired = 0
    local mine = function() fired = fired + 1 end
    debug.sethook(mine, "", 10000)

    vm.eval("local n = 0 for i = 1, 10000 do n = n + i end return n")

    local after = debug.gethook()
    debug.sethook()
    assert.equal(mine, after, "the host's hook was not restored")
  end)

  it("leaves no hook behind when the host had none", function()
    debug.sethook()
    vm.eval "return 1"
    assert.is_nil(debug.gethook())
  end)

  it("makes the shared string metatable opaque", function()
    -- Every string in the process shares one metatable, and a sandbox can
    -- reach it with getmetatable(""). Left alone, untrusted code could
    -- rewrite __index and change what s:upper() means for the host.
    vm.harden()
    assert.not_equal("table", type(getmetatable ""))

    local ok, result = vm.eval "return getmetatable('')"
    assert.is_true(ok)
    assert.not_equal("table", type(result))
    assert.equal("ABC", ("abc"):upper(), "the host's strings still work")
  end)

  it("gives each sandbox its own random seed, not the host's", function()
    -- Reseeding a shared generator would make the host's request ids
    -- predictable.
    local ok = vm.eval "math.randomseed(1) return true"
    assert.is_true(ok)
  end)
end)

describe("bounding the real string library", function()
  it("catches method syntax, which never touches the sandbox's copy", function()
    -- The escape this was written for: `("x"):rep(n)` resolves through the
    -- shared string metatable to the real string library, so bounding only
    -- the sandbox's own `string` table does nothing at all.
    local ok, err = vm.eval("return ('x'):rep(2^30)", { limits = { memory_kb = 1024 } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "string.rep would build")
  end)

  it("catches both spellings the same way", function()
    local ok = vm.eval "return string.rep('x', 2^30)"
    assert.is_false(ok)
  end)

  it("leaves the host's own string library alone", function()
    -- The bound applies only while a sandbox is running. akkar itself reps
    -- and formats freely, and a limit that leaked out of the sandbox would
    -- break the framework around it.
    vm.eval "return 1"
    assert.equal(2 * 1024 * 1024, #("x"):rep(2 * 1024 * 1024))
  end)
end)
