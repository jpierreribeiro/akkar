--[[
The watchdog — akkar's answer to the failure mode that has no other symptom.

A blocking call in one handler freezes every request in the process, and
nothing in the response says so: the blocked requests simply take longer. The
hook is the only thing that can name it.

These tests did not exist until the hook's closure was pooled for allocation.
The pooling passed all 227 existing tests, which is exactly the problem: a
watchdog that quietly stopped firing would have passed them too, and the
framework would have lost the diagnostic without anyone noticing.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

-- The watchdog only fires inside a cqueues coroutine with a real server, so
-- these run against one, capturing the internal logger's output.
local cqueues = require "cqueues"
local request = require "http.request"

local PORT = 8396

local function run_server(routes, requests)
  local lines = {}
  local app = akkar.new()
  routes(app)

  local cq = cqueues.new()
  cq:wrap(function()
    pcall(function()
      app:run { port = PORT, check_capabilities = false,
                log = akkar.log.new { level = "warn", format = "text",
                                      sink = function(l) lines[#lines + 1] = l end } }
    end)
  end)
  cq:wrap(function()
    cqueues.sleep(0.12)
    for _, path in ipairs(requests) do
      local req = request.new_from_uri("http://127.0.0.1:" .. PORT .. path)
      local headers, stream = req:go(10)
      assert(headers, "no response for " .. path)
      -- Reading the body finishes the exchange.  Leaving it unread holds the
      -- connection open until lua-http's intra-stream timeout, which turned
      -- four tests into forty seconds of waiting.
      stream:get_body_as_string()
    end
    app:stop(1)
  end)
  assert(cq:loop(30))
  return table.concat(lines)
end

-- Burns CPU for `seconds` without ever yielding, which is what a blocking C
-- call looks like from the scheduler's point of view.
local function burn(seconds)
  return function()
    local deadline = os.clock() + seconds
    local n = 0
    while os.clock() < deadline do n = n + 1 end
    return { spun = n > 0 }
  end
end

describe("the blocking watchdog", function()
  it("names a handler that blocks the event loop", function()
    local out = run_server(function(app)
      app:get("/block", burn(0.15))
    end, { "/block" })

    assert.is_truthy(out:find("blocked the event loop", 1, true))
    assert.is_truthy(out:find("/block", 1, true) or out:find("watchdog_spec", 1, true))
  end)

  it("still fires on a later request, after its hook has been reused", function()
    -- The pooling hazard, stated exactly: `warned` is latched per request, so
    -- a watchdog handed back to the pool with `warned = true` would report the
    -- first blocking request of the process and stay silent for every one
    -- after it.
    local out = run_server(function(app)
      app:get("/block", burn(0.15))
    end, { "/block", "/block", "/block" })

    local count = select(2, out:gsub("blocked the event loop", ""))
    assert.equal(3, count)
  end)

  it("says nothing about a handler that returns promptly", function()
    local out = run_server(function(app)
      app:get("/fast", function() return { ok = true } end)
    end, { "/fast", "/fast" })

    assert.is_nil(out:find("blocked the event loop", 1, true))
  end)

  it("does not carry one request's elapsed CPU into the next", function()
    -- A reused watchdog whose `cpu` accumulator was not reset would eventually
    -- accuse an innocent handler.
    local out = run_server(function(app)
      app:get("/block", burn(0.15))
      app:get("/fast", function() return { ok = true } end)
    end, { "/block", "/fast", "/fast", "/fast" })

    local count = select(2, out:gsub("blocked the event loop", ""))
    assert.equal(1, count)
  end)
end)
