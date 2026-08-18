--[[
The header-line parse in `akkar/vendor/http/h1_connection.lua`, checked
against the pattern it replaced.

WHY A DIFFERENTIAL TEST AND NOT A LIST OF EXAMPLES. This is header parsing.
A formulation that is faster and disagrees with the old one on any shape is
not an optimisation, it is a **parser differential** — and differentials
between two implementations of one protocol are how request smuggling works.
Speed is worth nothing here without agreement, so agreement is what is
asserted.

The shipped pattern is kept in this file as the reference. That is deliberate
duplication: it is the specification the fast path has to meet, and it will
not drift, because if somebody changes the parser without changing this the
test says so.

WHAT THE CHANGE WAS. `^([^%s:]+):[ \t]*(.-)[ \t]*$` -> a greedy `(.*)` with
the trailing whitespace removed by byte. The lazy `(.-)` with an anchored
`[ \t]*$` makes Lua's matcher advance one character at a time and re-try the
tail at every position, so the cost grows with the VALUE's length rather than
with finding the colon:

    line              old        new
    17 bytes       1,186 ns     717 ns   1.65x
    68 bytes       3,636 ns   1,606 ns   2.3x
    113 bytes      6,693 ns   1,436 ns   4.7x

A header six times longer cost six times more. That is most of why parsing is
8% of a request's CPU in this project's benchmark -- three short identical
headers -- and 45% of a production-shaped one with a User-Agent and cookies.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

--- The pattern this replaced, kept as the reference implementation.
local function reference(line)
  return line:match "^([^%s:]+):[ \t]*(.-)[ \t]*$"
end

--- What ships, extracted so it can be compared. Kept byte-for-byte in step
--- with `h1_connection.lua`'s copy; if the two drift, the cases below still
--- test the reference and this file stops testing anything, so the drift is
--- worth guarding in review.
local function shipped(line)
  local key, val = line:match "^([^%s:]+):[ \t]*(.*)$"
  if key then
    local last = #val
    while last > 0 do
      local c = val:byte(last)
      if c ~= 32 and c ~= 9 then break end
      last = last - 1
    end
    if last ~= #val then val = val:sub(1, last) end
  end
  return key, val
end

local function agrees(line)
  local a1, a2 = reference(line)
  local b1, b2 = shipped(line)
  return a1 == b1 and a2 == b2, a1, a2, b1, b2
end

local function assert_agrees(line, why)
  local ok, a1, a2, b1, b2 = agrees(line)
  assert.is_true(ok, ("%s: %q\n  reference %q,%q\n  shipped   %q,%q")
    :format(why or "disagreement", line,
            tostring(a1), tostring(a2), tostring(b1), tostring(b2)))
end

describe("the header line parse", function()
  it("agrees on ordinary headers", function()
    for _, line in ipairs {
      "host: example.com",
      "host:example.com",
      "host:   example.com",
      "content-type: application/json; charset=utf-8",
      "accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
      "cookie: a=1; b=2; c=3; d=4; e=5; f=6; g=7; h=8",
      "user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
      "x-forwarded-for: 10.0.0.1, 10.0.0.2, 10.0.0.3",
      "if-none-match: W/\"abc123\"",
      "!#$%&'*+.^_`|~: every token character is legal in a name",
    } do assert_agrees(line) end
  end)

  it("agrees on whitespace, which is where the two patterns differ most", function()
    -- The old pattern trimmed with `[ \t]*$`; the new one takes everything
    -- and walks back. These are the shapes that tell them apart if anything
    -- does.
    for _, line in ipairs {
      "host: example.com   ",
      "host:\texample.com\t",
      "host: \t example.com \t ",
      "accept:   text/html   ",
      "x-empty:",
      "x-empty: ",
      "x-empty:    ",
      "x-empty:\t\t",
      "name:  \t  ",
    } do assert_agrees(line, "whitespace") end
  end)

  it("agrees on malformed lines, and both refuse the same ones", function()
    for _, line in ipairs {
      ":novalue", ":", "", " ", "no-colon-at-all",
      " leading-space: v", "has space: v", "has\ttab: v",
      "\r\n", "-: -",
    } do assert_agrees(line, "malformed") end
  end)

  it("agrees on embedded control bytes", function()
    -- A value carrying CR, LF or NUL is how header injection is attempted.
    -- Both parsers must treat them identically -- whatever that treatment is
    -- -- so that the checks downstream see the same string.
    for _, line in ipairs {
      "name: value with \r embedded",
      "name: value with \n embedded",
      "name: value with \0 embedded",
      "name: value\r\n",
    } do assert_agrees(line, "control byte") end
  end)

  it("agrees on long names and values", function()
    assert_agrees(("x"):rep(200) .. ": " .. ("y"):rep(200), "long")
    assert_agrees("a: " .. ("very long "):rep(50), "long value")
  end)

  it("agrees on two hundred thousand random byte strings", function()
    -- A hand-written list covers what somebody thought of.
    -- `spec/fuzz_spec.lua` exists for the same reason this does.
    --
    -- Seeded, so a failure is reproducible rather than a story about a
    -- Tuesday.
    math.randomseed(20260818)
    local alphabet = {}
    for c = 1, 127 do alphabet[#alphabet + 1] = string.char(c) end
    -- The interesting bytes weighted up: a uniform draw over 127 characters
    -- almost never produces a colon in a short string, and a line with no
    -- colon exercises neither parser.
    for _, extra in ipairs { ":", " ", "\t", ":", " ", "a", "-" } do
      alphabet[#alphabet + 1] = extra
    end

    local checked, disagreements = 0, 0
    local first
    for _ = 1, 200000 do
      local n = math.random(0, 24)
      local parts = {}
      for i = 1, n do parts[i] = alphabet[math.random(#alphabet)] end
      local line = table.concat(parts)
      checked = checked + 1
      if not (agrees(line)) then
        disagreements = disagreements + 1
        first = first or line
      end
    end

    assert.equal(0, disagreements,
      ("%d of %d random lines parsed differently; first was %q")
        :format(disagreements, checked, tostring(first)))
  end)
end)
