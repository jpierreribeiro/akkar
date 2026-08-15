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
end)
