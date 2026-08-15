--[[
W3C Trace Context — the same idea as `x-request-id`, in a format everything
else already speaks.

akkar accepts a `traceparent`, exposes it, and passes it back. It does not
create spans or export them: that is an OpenTelemetry dependency and an
adapter, and it belongs behind the same boundary as every other integration
here.

The tests that carry weight are the rejections. A `traceparent` arrives from
the network, and forwarding a malformed one corrupts somebody else's trace as
well as this one.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

local VALID = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

local function traced(header)
  local app = akkar.new()
  app:get("/", function(req) return { trace = req.trace } end)
  return app:test():get("/", { headers = { traceparent = header } })
end

describe("accepting a traceparent", function()
  it("takes the trace and span apart", function()
    local res = traced(VALID)
    assert.equal("4bf92f3577b34da6a3ce929d0e0e4736", res.body.trace.trace_id)
    assert.equal("00f067aa0ba902b7", res.body.trace.span_id)
    assert.is_true(res.body.trace.sampled)
    assert.equal(VALID, res.body.trace.traceparent)
  end)

  it("reads the sampled flag from the low bit, not from the byte", function()
    -- flags 00 is not sampled; 01 is. Treating the whole byte as a boolean
    -- would call every future flag combination "sampled".
    assert.is_false(traced(VALID:gsub("%-01$", "-00")).body.trace.sampled)
    assert.is_true(traced(VALID:gsub("%-01$", "-03")).body.trace.sampled)
    assert.is_false(traced(VALID:gsub("%-01$", "-02")).body.trace.sampled)
  end)

  it("echoes it back, so a client can tie the response to its trace", function()
    local app = akkar.new()
    app:get("/", function() return { ok = true } end)
    local res = app:test():get("/", { headers = { traceparent = VALID } })
    assert.equal(VALID, res.headers["traceparent"])
  end)

  it("carries tracestate alongside when the client sent one", function()
    local app = akkar.new()
    app:get("/", function(req) return { state = req.trace.tracestate } end)
    local res = app:test():get("/", {
      headers = { traceparent = VALID, tracestate = "vendor=value" } })
    assert.equal("vendor=value", res.body.state)
  end)
end)

describe("rejecting a malformed traceparent", function()
  local function rejected(header, why)
    local res = traced(header)
    assert.equal(200, res.status)
    assert.is_nil(res.body.trace, why .. " was accepted: " .. tostring(header))
  end

  it("refuses ids of the wrong length", function()
    rejected("00-4bf92f35-00f067aa0ba902b7-01", "a short trace id")
    rejected("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa-01", "a short span id")
  end)

  it("refuses an all-zero id, which the specification forbids", function()
    rejected("00-00000000000000000000000000000000-00f067aa0ba902b7-01", "a zero trace id")
    rejected("00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01", "a zero span id")
  end)

  it("refuses version ff, which the specification forbids", function()
    rejected("ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "version ff")
  end)

  it("refuses anything that is not the shape at all", function()
    for _, bad in ipairs {
      "", "not-a-traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-01",
      "00_4bf92f3577b34da6a3ce929d0e0e4736_00f067aa0ba902b7_01",
      "00-zzzz2f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      VALID .. "-extra",
    } do
      rejected(bad, "a malformed header")
    end
  end)

  it("is simply absent when the client sent nothing", function()
    local app = akkar.new()
    app:get("/", function(req) return { has = req.trace ~= nil } end)
    local res = app:test():get "/"
    assert.is_false(res.body.has)
    assert.is_nil(res.headers["traceparent"])
  end)
end)

describe("the cost of carrying it", function()
  it("costs nothing on a request that has no trace", function()
    -- Parsed on first read rather than in the constructor. Adding a ninth
    -- field to `req` grew the table's hash part and cost 191 bytes on EVERY
    -- request, including the overwhelming majority carrying no trace at all.
    local app = akkar.new()
    app:get("/ping", function() return { pong = true } end)
    local client = app:test()

    local function bytes_per_request(n)
      collectgarbage(); collectgarbage(); collectgarbage "stop"
      local before = collectgarbage "count"
      for _ = 1, n do client:get "/ping" end
      local after = collectgarbage "count"
      collectgarbage "restart"
      return (after - before) * 1024 / n
    end

    bytes_per_request(200)
    assert.is_true(bytes_per_request(2000) < 2600)
  end)
end)
