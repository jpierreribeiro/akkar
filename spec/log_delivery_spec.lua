-- A log sink is an external resource and may fail exactly when its evidence is
-- needed most. Delivery failures must be observable without being able to
-- break a request or the shutdown path that is trying to report them.

package.path = "./?.lua;./?/init.lua;" .. package.path

local log = require "akkar.log"

describe("log sink delivery", function()
  it("counts a sink-returned failure without raising", function()
    local logger = log.new {
      sink = function() return nil, "No space left on device", 28 end,
    }

    assert.has_no.errors(function() logger:info "charged" end)
    assert.same({ dropped = 1, last_error = "No space left on device" },
                logger:stats())
  end)

  it("counts a sink raise without letting it escape", function()
    local logger = log.new {
      sink = function() error("collector unavailable", 0) end,
    }

    assert.has_no.errors(function() logger:error "payment failed" end)
    assert.equal(1, logger:stats().dropped)
    assert.is_truthy(logger:stats().last_error:find("collector unavailable", 1, true))
  end)

  it("shares the delivery count with request-bound loggers", function()
    local logger = log.new {
      sink = function() return nil, "ENOSPC", 28 end,
    }
    logger:with { request_id = "r1" }:info "one"
    logger:with { request_id = "r2" }:info "two"
    assert.equal(2, logger:stats().dropped)
  end)

  it("announces the loss and clears the count when the sink recovers", function()
    local failing, lines, exported = true, {}, {}
    local logger = log.new { sink = function(line)
      if failing then return nil, "ENOSPC", 28 end
      lines[#lines + 1] = line
      return true
    end, exporter = { record = function(_, entry)
      exported[#exported + 1] = entry.message
    end } }

    logger:info "lost"
    failing = false
    logger:info "delivered"

    assert.equal(0, logger:stats().dropped)
    assert.equal(2, #lines)
    assert.is_truthy(lines[1]:find("delivered", 1, true))
    assert.is_truthy(lines[2]:find("log sink recovered", 1, true))
    assert.is_truthy(lines[2]:find("dropped=1", 1, true))
    assert.same({ "lost", "delivered", "log sink recovered" }, exported)
  end)
end)
