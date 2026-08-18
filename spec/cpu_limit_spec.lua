--[[
A handler that will not return is ended, and the process keeps serving.

THIS IS THE ONE THING NO DEADLINE IN THIS RUNTIME COULD DO. `akkar/execution.lua`
says it plainly: the request budget is cooperative and "can only fire while the
handler is yielding on I/O". `while true do end` yields never. Before this the
watchdog noticed and WARNED -- correct when the code is yours, useless when it
is a student's.

The mechanism is not new machinery. `akkar/vm.lua:334` has installed a count
hook that RAISES since the sandbox was written; this is the same idea moved to
the request path, riding the watchdog's own hook because `debug.sethook` allows
exactly one per coroutine.

WHAT THIS FILE DELIBERATELY DOES NOT CLAIM: that akkar is safe against hostile
code. `akkar/vm.lua:20-23` is explicit -- a sandbox inside one Lua state is not
a security boundary, and hostile code belongs in another process under an OS
sandbox. A CPU ceiling stops a runaway loop. It does not stop an adversary.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

describe("the instruction ceiling", function()
  local quiet = akkar.log.new { level = "error", sink = function() end }

  it("is off unless asked for", function()
    -- Every akkar before this ran without one, and a runtime that silently
    -- starts ending long handlers would break services that are merely slow.
    assert.is_nil(akkar.defaults.cpu_limit)
  end)

  it("ends a handler that never returns, and keeps serving", function()
    local app = akkar.new()
    app:get("/spin", function()
      local n = 0
      while true do n = n + 1 end          -- yields never, returns never
    end)
    app:get("/ping", function() return { pong = true } end)

    local client = app:test { cpu_limit = 2000000, log = quiet }

    local spun = client:get "/spin"
    assert.equal(503, spun.status)

    -- THE PROPERTY THAT MATTERS, and it is the second half rather than the
    -- first. Ending one request is easy; the question a teaching platform
    -- asks is whether the process that ran it is still a server afterwards.
    for _ = 1, 5 do
      local res = client:get "/ping"
      assert.equal(200, res.status)
      assert.is_true(res.body.pong)
    end
  end)

  it("does not disturb a handler that finishes under the ceiling", function()
    local app = akkar.new()
    app:get("/work", function()
      local total = 0
      for i = 1, 10000 do total = total + i end
      return { total = total }
    end)

    local client = app:test { cpu_limit = 50000000, log = quiet }
    local res = client:get "/work"
    assert.equal(200, res.status)
    assert.equal(50005000, res.body.total)
  end)

  it("refuses a ceiling that is not a positive number", function()
    local app = akkar.new()
    app:get("/x", function() return { ok = true } end)
    assert.has_error(function()
      app:run { cpu_limit = 0, port = 0, check_capabilities = false }
    end)
    assert.has_error(function()
      app:run { cpu_limit = "lots", port = 0, check_capabilities = false }
    end)
  end)

  it("does not displace the blocking watchdog's hook", function()
    -- `debug.sethook` allows ONE hook per coroutine, so the ceiling rides the
    -- watchdog's rather than installing a second. If it had ever taken the
    -- hook for itself, a server would stop reporting blocked handlers the
    -- moment somebody set a limit, and nothing else in this suite would see
    -- it.
    --
    -- Asserted on `debug.gethook` INSIDE a handler rather than on the log,
    -- because the watchdog writes to akkar's own internal logger and not to
    -- the `log` capability a test client passes -- the first version of this
    -- test watched the wrong stream and reported a defect that was its own.
    local seen_count, seen_hook
    local app = akkar.new()
    app:get("/look", function()
      seen_hook, _, seen_count = debug.gethook()
      return { ok = true }
    end)

    local with_limit = app:test { cpu_limit = 500000000, log = quiet }
    assert.equal(200, with_limit:get("/look").status)
    assert.is_function(seen_hook)
    assert.equal(200000, seen_count,
      "the hook is not the watchdog's 200,000-instruction count hook")

    -- And with no ceiling at all, the same hook is still there: the watchdog
    -- is not something the ceiling switched on.
    seen_hook, seen_count = nil, nil
    local without = app:test { log = quiet }
    assert.equal(200, without:get("/look").status)
    assert.is_function(seen_hook)
    assert.equal(200000, seen_count)
  end)
end)
