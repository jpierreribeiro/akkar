--[[
The collector mode `app:run { gc = ... }` selects.

This setting exists because the project measured it and then never shipped it.
`bench/study/gc-cost.sh` answered question 9 of the performance study on
16 August 2026:

    stopping the collector entirely   +3.5%   <- the hard ceiling
    generational                      +2.5%, and p99 7.50 ms -> 5.66 ms

and the measurement was taken by an environment variable in
`bench/study/apps/serve.lua`. akkar set the mode nowhere, so the one thing the
study found better than the default was available to the benchmark and to
nobody running a server.

WHAT THESE CASES CAN AND CANNOT CHECK. Lua exposes no way to ask which
collector is running -- `collectgarbage "count"` answers bytes and nothing
answers "mode". So these do not assert that generational is faster; that is
what the study box is for. They assert the two things a spec can: that the
setting is accepted and applied without raising, and that a wrong value is
refused loudly rather than silently ignored.

The second is the one that earns its place. `app:run { timout = 5 }` used to
be accepted in silence, leaving a server with a 30 s deadline its author
believed was 5 -- which is why SETTINGS exists at all, and why a new setting
has to join it.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local akkar   = require "akkar"

--- Starts a server with `config`, calls `body(port)`, stops.
---
--- The collector mode is process-wide, so every case puts it back. Without
--- that, one case here changes the arithmetic of every spec that runs after
--- it in the same busted process -- including the allocation ceilings.
local function with_server(config, body)
  local port = 8000 + math.random(0, 900)
  local app = akkar.new()
  app:get("/ping", function() return { pong = true } end)

  local cq = cqueues.new()
  local err
  cq:wrap(function()
    local ok, why = pcall(function()
      config.port = port
      config.check_capabilities = false
      config.log = akkar.log.new { level = "error", sink = function() end }
      app:run(config)
    end)
    if not ok then err = why end
  end)
  cq:wrap(function()
    cqueues.sleep(0.3)
    local ok, why = pcall(body, port, app)
    app:stop(1)
    if not ok then err = err or why end
  end)
  assert(cq:loop(60))
  collectgarbage "incremental"        -- put the process back
  if err then error(err, 0) end
end

describe("the collector mode", function()
  it("accepts generational and still serves", function()
    -- Nothing here can read the mode back, so the assertion is the one that
    -- matters in practice: a server configured this way answers requests.
    local answered
    with_server({ gc = "generational" }, function(_, app)
      answered = app:test():get "/ping"
    end)
    assert.equal(200, answered.status)
    assert.is_true(answered.body.pong)
  end)

  it("accepts incremental, said out loud", function()
    local answered
    with_server({ gc = "incremental" }, function(_, app)
      answered = app:test():get "/ping"
    end)
    assert.equal(200, answered.status)
  end)

  it("accepts a tuned incremental triple", function()
    local answered
    with_server({ gc = { "incremental", 400, 400, 13 } }, function(_, app)
      answered = app:test():get "/ping"
    end)
    assert.equal(200, answered.status)
  end)

  it("leaves the collector alone when nothing is asked for", function()
    -- The default is Lua's own, and it is a default rather than a decision:
    -- the numbers above predate the HTTP work that cut allocation per request
    -- by 21.6%, and less garbage means less for the collector to be good or
    -- bad at. Shipping a different default on a measurement taken against
    -- different code is what rule 1 of the performance study forbids.
    local answered
    with_server({}, function(_, app)
      answered = app:test():get "/ping"
    end)
    assert.equal(200, answered.status)
  end)

  it("refuses to stop the collector, because that is an instrument", function()
    -- `AKKAR_GC=off` exists in `bench/study/apps/serve.lua` to put an upper
    -- bound on what collector tuning could ever buy. A server that ships it
    -- does not run slowly, it runs out of memory.
    local ok, why = pcall(function()
      with_server({ gc = "off" }, function() end)
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("not a shipping configuration", 1, true),
      "the refusal did not say why: " .. tostring(why))
  end)

  it("refuses a mode it does not understand", function()
    for _, bad in ipairs { "gen", "gradual", 5, true } do
      local ok = pcall(function()
        with_server({ gc = bad }, function() end)
      end)
      assert.is_false(ok, ("gc = %s was accepted"):format(tostring(bad)))
    end
  end)

  it("is a known setting, so a typo is still an error", function()
    local app = akkar.new()
    local ok, why = pcall(function()
      app:run { cg = "generational", check_capabilities = false }
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("cg", 1, true))
  end)
end)
