--[[
`akkar.text.trim`, checked against the pattern it replaces.

The pattern is kept here as the reference. That duplication is the point: it
is the specification, and a trim that is faster and disagrees on any shape is
not an optimisation — every caller trims something a client sent, so a
disagreement is a difference in what akkar believes the client said.

`%s` in Lua is [ \t\n\v\f\r]. Six characters, not two. A trim that handles
fewer is not faster, it is wrong, and the random cases below draw from an
alphabet weighted towards all six.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local text = require "akkar.text"

--- What `trim` replaced.
local function reference(s) return s:match "^%s*(.-)%s*$" end

local function assert_same(s, why)
  assert.equal(reference(s), text.trim(s),
    ("%s: %q"):format(why or "disagreement", s))
end

describe("akkar.text.trim", function()
  it("agrees on the ordinary shapes", function()
    for _, s in ipairs {
      "", "a", " a", "a ", " a ", "  a  ",
      "a b", "  a b  ", "hello world",
      "no-whitespace-at-all", "192.168.1.1", "W/\"abc123\"",
    } do assert_same(s) end
  end)

  it("agrees on every character `%s` matches, not just space and tab", function()
    for _, ws in ipairs { " ", "\t", "\n", "\v", "\f", "\r" } do
      assert_same(ws .. "x" .. ws, "single " .. ("%q"):format(ws))
      assert_same(ws .. ws .. "x", "doubled")
      assert_same("x" .. ws .. ws, "trailing doubled")
    end
    assert_same(" \t\n\v\f\r x \r\f\v\n\t ", "all six either side")
  end)

  it("agrees on strings that are entirely whitespace", function()
    for _, s in ipairs { " ", "   ", "\t", "\n", "\r\n", " \t\n\v\f\r " } do
      assert_same(s, "all whitespace")
      assert.equal("", text.trim(s))
    end
  end)

  it("keeps whitespace in the middle", function()
    assert.equal("a  b", text.trim("  a  b  "))
    assert.equal("a\tb", text.trim("\ta\tb\t"))
    assert.equal("a\nb", text.trim(" a\nb "))
  end)

  it("returns the same string when there is nothing to remove", function()
    -- Not merely an equal string: the SAME one. A trim that reallocates an
    -- already-trimmed value would allocate on every header of every request
    -- for no reason, and this is the property that stops it.
    local s = "already-clean"
    assert.is_true(rawequal(s, text.trim(s)))
  end)

  it("agrees on the long shapes, which is why it exists", function()
    for _, n in ipairs { 100, 1000, 10000 } do
      assert_same(("x"):rep(n), "clean, " .. n .. " bytes")
      assert_same("  " .. ("x"):rep(n) .. "  ", "padded, " .. n .. " bytes")
      assert_same((" "):rep(n), "all whitespace, " .. n .. " bytes")
    end
  end)

  it("agrees on two hundred thousand random strings", function()
    -- Seeded, so a failure is reproducible. Drawn from an alphabet weighted
    -- towards whitespace, because a uniform draw over printable characters
    -- almost never produces the shapes that distinguish the two.
    math.randomseed(20260818)
    local alphabet = { " ", "\t", "\n", "\v", "\f", "\r",
                       "a", "b", "Z", "0", "-", ".", ",", ":" }

    local disagreements, first = 0, nil
    for _ = 1, 200000 do
      local n = math.random(0, 20)
      local parts = {}
      for i = 1, n do parts[i] = alphabet[math.random(#alphabet)] end
      local s = table.concat(parts)
      if text.trim(s) ~= reference(s) then
        disagreements = disagreements + 1
        first = first or s
      end
    end

    assert.equal(0, disagreements,
      ("%d random strings trimmed differently; first was %q")
        :format(disagreements, tostring(first)))
  end)

  -- NO TIMING CASE HERE, deliberately. An earlier version of this file
  -- asserted that trim beat the pattern at four sizes, and it took 63 seconds
  -- and failed once on a loaded machine. A timing assertion inside a unit
  -- suite is the thing this project distrusts everywhere else, and it does
  -- not become trustworthy because the number is ours.
  --
  -- The speed claim lives in `bench/study/trim-cost.lua`, where it can be
  -- re-taken. What belongs here is equivalence, which is exact and is the
  -- only property a wrong answer could violate.
end)
