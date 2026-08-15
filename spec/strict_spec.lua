--[[
Strict mode.

The ninth invariant in PLAN.md has said "nothing global" since the beginning.
These make it a property rather than a claim.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar  = require "akkar"
local strict = require "akkar.strict"

describe("strict mode", function()
  after_each(function() strict.off() end)

  it("raises on assignment to an undeclared global", function()
    strict.on()
    local ok, err = pcall(function()
      local chunk = load "akkar_spec_leaked = 1"
      chunk()
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "undeclared global 'akkar_spec_leaked'")
  end)

  it("explains why it matters on a server, not just that it happened", function()
    strict.on()
    local _, err = pcall(function() load "akkar_spec_leaked2 = 1" () end)
    -- A message that only says "undeclared global" teaches nothing.
    assert.is_truthy(tostring(err):match "outlives the request")
    assert.is_truthy(tostring(err):match "did you mean `local")
  end)

  it("raises on reading an undeclared global", function()
    strict.on()
    local ok, err = pcall(function() return load "return akkar_spec_typo" () end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "read of undeclared global")
  end)

  it("leaves the standard library alone", function()
    strict.on()
    assert.is_function(print)
    assert.is_table(table)
    assert.is_function(require)
  end)

  it("allows a global that was declared on purpose", function()
    strict.on()
    strict.declare "akkar_spec_intentional"
    local ok = pcall(function() load "akkar_spec_intentional = 42" () end)
    assert.is_true(ok)
    assert.is_true(strict.declared "akkar_spec_intentional")
  end)

  it("is idempotent and reversible", function()
    strict.on()
    strict.on()
    assert.is_true(strict.active())
    strict.off()
    assert.is_false(strict.active())
    local ok = pcall(function() load "akkar_spec_after_off = 1" () end)
    assert.is_true(ok)
  end)

  it("catches a handler leaking state between requests", function()
    strict.on()
    local app = akkar.new()
    -- The bug this exists for: a counter that looks local and is not, so the
    -- second request sees the first request's value.
    app:get("/count", function()
      local chunk = load "akkar_spec_counter = (akkar_spec_counter or 0) + 1 return akkar_spec_counter"
      return { n = chunk() }
    end)

    local res = app:test():get "/count"
    assert.equal(500, res.status)     -- caught, rather than silently shared
  end)
end)
