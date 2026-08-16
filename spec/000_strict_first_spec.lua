--[[
Strict mode is installed before any other spec runs.

The whole suite then runs under it, so akkar's ninth invariant -- nothing
global -- is checked against akkar's own code on every test run rather than
being a claim in a document.

Named 000_ because busted loads spec files in alphabetical order and this has
to be first.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

require("akkar.strict").on()

-- Busted itself and its assertion library set a few globals as they run.
-- Declaring them here keeps the check pointed at akkar and the specs rather
-- than at the test runner.
require("akkar.strict").declare(
  "describe", "it", "before_each", "after_each", "setup", "teardown",
  "pending", "assert", "spy", "stub", "mock", "finally", "randomize",
  "insulate", "expose", "lazy_setup", "lazy_teardown", "strict_setup",
  "strict_teardown", "async", "done"
)

describe("the suite itself", function()
  it("runs under strict mode", function()
    assert.is_true(require("akkar.strict").active())
  end)

  it("still sorts before every other spec, which is the whole mechanism", function()
    -- The `000_` prefix is load-bearing and nothing checked it. Add a spec
    -- that sorts earlier -- `0_helpers_spec.lua` would do it, and so would
    -- anything starting with a digit below zero's ASCII -- and strict mode
    -- gets installed AFTER that file has already run. Nothing fails; the
    -- guarantee simply stops covering one file, silently, and akkar's ninth
    -- invariant is checked against slightly less than the suite.
    --
    -- This is the cheapest possible tripwire: ask the filesystem.
    local names = {}
    local pipe = assert(io.popen "ls spec/*_spec.lua 2>/dev/null")
    for path in pipe:lines() do names[#names + 1] = path:match "([^/]+)$" end
    pipe:close()
    table.sort(names)

    assert.is_true(#names > 1, "no spec files found; is the working directory wrong?")
    assert.equal("000_strict_first_spec.lua", names[1],
      "'" .. tostring(names[1]) .. "' now loads before strict mode is installed")
  end)
end)
