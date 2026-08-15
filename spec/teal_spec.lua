--[[
The Teal declarations are checked, not just shipped.

A type declaration file that has drifted from the code it describes is worse
than none: it asserts guarantees that no longer hold.  These run the Teal
compiler against it and against two example handlers -- one that must pass and
one written to fail in three specific ways.

Skipped when `tl` is not installed, so nobody needs Teal to work on akkar.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local function tl_available()
  local pipe = io.popen "tl --version 2>/dev/null"
  if not pipe then return false end
  local out = pipe:read "a"
  pipe:close()
  return out ~= nil and out:match "%d" ~= nil
end

if not tl_available() then
  describe("Teal declarations", function()
    pending "tl is not installed; skipping (luarocks install --local tl)"
  end)
  return
end

local function check(path)
  local pipe = assert(io.popen("tl check --include-dir types " .. path .. " 2>&1"))
  local output = pipe:read "a"
  pipe:close()
  return output
end

describe("Teal declarations", function()
  it("the declaration file itself type-checks", function()
    assert.is_truthy(check("types/akkar.d.tl"):match "0 errors detected")
  end)

  it("a correct handler passes", function()
    local output = check "examples/teal/good.tl"
    assert.is_truthy(output:match "0 errors detected",
                     "expected a clean check, got:\n" .. output)
  end)

  it("catches a misspelled request field", function()
    -- req.parms instead of req.params: the kind of typo that in plain Lua is
    -- a nil index somewhere further down.
    local output = check "examples/teal/deliberately_wrong.tl"
    assert.is_truthy(output:match "invalid key 'parms'")
  end)

  it("catches a type mismatch in a handler", function()
    assert.is_truthy(check("examples/teal/deliberately_wrong.tl")
                       :match "got string, expected integer")
  end)

  it("catches an unknown app:run option at compile time", function()
    -- The same `timout` typo that config validation catches at startup and
    -- strict mode would catch at runtime -- here it never gets that far.
    assert.is_truthy(check("examples/teal/deliberately_wrong.tl"):match "unknown field timout")
  end)
end)
