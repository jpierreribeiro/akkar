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

--[[
=============================================================================
akkar.trace — creating the spans, and exporting them without ever making a
request wait for a collector.

Everything above tests the half akkar always had: a `traceparent` accepted,
validated and echoed. What follows tests the half that did not exist, and its
first rule is a negative one.

**A REQUEST IS NEVER BLOCKED ON AN EXPORT.** A tracing backend is a thing that
goes down, it is frequently the first thing to fall over in the incident you
are trying to trace, and akkar runs one coroutine at a time -- so an export
waiting on a dead collector's TCP timeout is time in which akkar answers
NOBODY. The test for that hands the exporter an HTTP client that RAISES on
contact and then serves requests through it: the responses are 200 and the
client was never touched.

**DROPPING SPANS IS CORRECT WHEN THE BUFFER IS FULL.** The alternative to
dropping is holding, and holding while the collector is unreachable means the
buffer grows for as long as the outage lasts -- so an incident in a system you
do not own becomes a memory exhaustion in one you do. What is not acceptable
is dropping silently, so the counters are asserted too.

Time moves with `akkar.time.manual`. Nothing here sleeps.
]]

local trace = require "akkar.trace"
local time  = require "akkar.time"

local COLLECTOR = "http://collector.invalid:4318/v1/traces"

--- An `akkar.http` capability that records what it was asked to send.
---
--- A table with a `post` method and nothing else, which is the whole point of
--- `akkar/http.lua` being a capability: the contract is small enough to fake,
--- so a test can assert on the bytes that would have gone out without standing
--- up a collector.
local function fake_collector(behaviour)
  local client = { calls = {} }
  function client:post(url, options)
    self.calls[#self.calls + 1] = { url = url, options = options }
    if behaviour then return behaviour(#self.calls, options) end
    return { status = 200, headers = {}, body = "" }
  end
  return client
end

local function exporter_with(options)
  options = options or {}
  options.endpoint = options.endpoint or COLLECTOR
  return trace.new(options)
end

local function traced_app(exporter, build)
  local app = akkar.new()
  app:use(exporter:middleware())
  if build then build(app) else
    app:get("/ping", function() return { pong = true } end)
  end
  return app
end

-- =========================================================================

describe("never blocking a request on an export", function()
  it("does not touch the collector while serving a request", function()
    -- The client RAISES if anything reaches it. If the middleware exported
    -- inline, every one of these requests would be a 500.
    local hostile = { post = function() error("the collector is gone", 0) end }
    local exporter = exporter_with { http = hostile }
    local client = traced_app(exporter):test()

    for _ = 1, 50 do
      assert.equal(200, client:get("/ping").status)
    end

    assert.equal(50, exporter:stats().recorded)
    assert.equal(50, exporter:stats().queued)
    assert.equal(0, exporter:stats().batches, "an export ran during a request")
  end)

  it("keeps answering when the collector is down and flush is called",
    function()
      local exporter = exporter_with {
        http = fake_collector(function() return nil, "connection refused" end),
      }
      local client = traced_app(exporter):test()

      client:get "/ping"
      local ok, why = exporter:flush()
      assert.is_nil(ok)
      assert.is_truthy(why:find("connection refused", 1, true), why)

      -- The service is unaffected, which is the property being defended.
      assert.equal(200, client:get("/ping").status)
    end)

  it("survives a transport that raises rather than returning a reason",
    function()
      -- A DNS failure inside lua-http raises. An exporter that propagated it
      -- would kill the coroutine its loop runs in and stop exporting for the
      -- life of the process, with nothing in the log to say the loop ended.
      local exporter = exporter_with {
        http = { post = function() error("name resolution failed", 0) end },
      }
      exporter:record(exporter:start_span { name = "x" }:finish())

      local ok, why = exporter:flush()
      assert.is_nil(ok)
      assert.is_truthy(tostring(why):find("name resolution", 1, true))
      assert.equal(1, exporter:stats().failed)
    end)

  it("counts a missing http capability instead of raising", function()
    -- A misconfiguration in the tracing system must not take down the service
    -- it was installed to observe.
    local exporter = exporter_with {}
    local client = traced_app(exporter):test()
    assert.equal(200, client:get("/ping").status)

    local ok, why = exporter:flush()
    assert.is_nil(ok)
    assert.is_truthy(why:find("http capability", 1, true), why)
    assert.equal(1, exporter:stats().dropped)
  end)
end)

-- =========================================================================

describe("dropping spans when the buffer is full", function()
  it("refuses the span, counts it, and does not raise", function()
    local exporter = exporter_with { max_queue = 3 }

    local kept = 0
    for i = 1, 10 do
      if exporter:record { name = "span-" .. i, start_time = 0, duration = 0 } then
        kept = kept + 1
      end
    end

    assert.equal(3, kept)
    local stats = exporter:stats()
    assert.equal(3, stats.queued)
    assert.equal(10, stats.recorded)
    assert.equal(7, stats.dropped, "drops must be counted, never silent")
  end)

  it("keeps serving requests once the buffer has filled", function()
    -- The whole reason the queue is bounded: a collector that is gone must
    -- cost a fixed amount of memory and nothing else.
    local exporter = exporter_with { max_queue = 5, http = fake_collector() }
    local client = traced_app(exporter):test()

    for _ = 1, 200 do
      assert.equal(200, client:get("/ping").status)
    end

    assert.equal(5, exporter:stats().queued)
    assert.equal(195, exporter:stats().dropped)
  end)

  it("drops a failed batch instead of retrying it", function()
    -- Retrying moves the growth out of the queue and into a retry buffer and
    -- buys nothing: the request each span describes was already answered.
    local collector = fake_collector(function() return { status = 503 } end)
    local exporter = exporter_with { http = collector }

    for i = 1, 4 do
      exporter:record { name = "s" .. i, start_time = 0, duration = 0 }
    end
    assert.is_nil(exporter:flush())

    assert.equal(0, exporter:stats().queued)
    assert.equal(4, exporter:stats().dropped)
    assert.equal(1, exporter:stats().failed)

    -- A second flush has nothing to send, which is what "not retried" means.
    assert.is_true(exporter:flush())
    assert.equal(1, #collector.calls)
  end)
end)

-- =========================================================================

describe("the two flush bounds", function()
  it("comes due on the size bound", function()
    local exporter = exporter_with { max_batch = 3, interval = 3600 }

    for i = 1, 2 do
      exporter:record { name = "s" .. i, start_time = 0, duration = 0 }
      assert.is_false(exporter:due())
    end
    exporter:record { name = "s3", start_time = 0, duration = 0 }
    assert.is_true(exporter:due())
  end)

  it("comes due on the time bound, which a quiet service needs", function()
    -- A size bound alone means a service with nine requests an hour never
    -- exports, and the traces that matter most are usually from exactly such a
    -- service. Proven with a manual clock rather than by waiting.
    local clock = time.manual { now = 1755000000 }
    local restore = time.set(clock)

    local collector = fake_collector()
    -- Constructed AFTER the clock is installed, because `last_flush` is
    -- stamped in the constructor.
    local exporter = exporter_with { http = collector, max_batch = 1000,
                                     interval = 5 }
    exporter:record { name = "lonely", start_time = 0, duration = 0 }

    assert.is_false(exporter:due())
    assert.is_false(exporter:tick())

    clock:advance(5)
    assert.is_true(exporter:due())
    assert.is_true(exporter:tick())
    assert.equal(1, #collector.calls)
    assert.equal(0, exporter:stats().queued)

    restore()
  end)

  it("is never due with an empty queue", function()
    local clock = time.manual { now = 1755000000 }
    local restore = time.set(clock)
    local exporter = exporter_with { http = fake_collector(), interval = 5 }
    clock:advance(3600)
    assert.is_false(exporter:due())
    assert.is_false(exporter:tick())
    restore()
  end)

  it("swaps the queue BEFORE the network call, not after", function()
    -- akkar is cooperative, so the POST yields and other requests run while it
    -- is in flight. Those requests record spans. Clearing the queue afterwards
    -- would throw every one of them away -- silently, and only under load,
    -- which is when the traces matter.
    --
    -- The fake records a span from inside `post`, which is the moment a real
    -- coroutine would have.
    local exporter
    local collector = fake_collector(function()
      exporter:record { name = "arrived mid-flight", start_time = 0,
                        duration = 0 }
      return { status = 200 }
    end)
    exporter = exporter_with { http = collector }

    exporter:record { name = "first", start_time = 0, duration = 0 }
    assert.is_true(exporter:flush())

    assert.equal(1, exporter:stats().queued,
                 "a span recorded during the export was lost")
    assert.equal(1, exporter:stats().exported)
  end)
end)

-- =========================================================================

describe("the payload that would go on the wire", function()
  it("is OTLP, at the endpoint it was given", function()
    local collector = fake_collector()
    local exporter = exporter_with { http = collector, service = "checkout" }
    local client = traced_app(exporter):test()

    client:get "/ping"
    assert.is_true(exporter:flush())

    local call = collector.calls[1]
    assert.equal(COLLECTOR, call.url)

    local resource_spans = call.options.body.resourceSpans[1]
    assert.equal("service.name", resource_spans.resource.attributes[1].key)
    assert.equal("checkout",
                 resource_spans.resource.attributes[1].value.stringValue)

    local span = resource_spans.scopeSpans[1].spans[1]
    assert.equal("GET /ping", span.name)
    assert.equal(trace.KIND.SERVER, span.kind)
    assert.equal(32, #span.traceId)
    assert.equal(16, #span.spanId)
    assert.is_nil(span.parentSpanId, "a root span must not carry a parent id")
  end)

  it("renders nanoseconds with integer arithmetic, not with a double", function()
    -- 1755000000 * 1e9 is 1.755e18, far past the 2^53 where a double stops
    -- representing consecutive integers, so every timestamp's last digits
    -- would be invented. Lua 5.4 has 64-bit integers and this is the assertion
    -- that keeps the multiplication in them.
    assert.equal("1755000000000000000", trace.nanoseconds(1755000000))
    assert.equal("1755000000500000000", trace.nanoseconds(1755000000.5))
    assert.equal("0", trace.nanoseconds(0))
  end)

  it("quotes an int64 attribute, because OTLP's JSON mapping does", function()
    -- A bare number there is accepted by some collectors and rejected by
    -- others, which is the worst kind of wrong: it works until you change
    -- vendor.
    local attributes = trace.attributes_of {
      count = 7, ratio = 0.5, name = "x", on = true }

    -- Sorted, so the payload does not change when nothing did -- the same
    -- reason `akkar.etag` sorts before hashing.
    assert.same({ "count", "name", "on", "ratio" },
                { attributes[1].key, attributes[2].key,
                  attributes[3].key, attributes[4].key })
    assert.equal("7", attributes[1].value.intValue)
    assert.equal("x", attributes[2].value.stringValue)
    assert.is_true(attributes[3].value.boolValue)
    assert.equal(0.5, attributes[4].value.doubleValue)
  end)

  it("carries the duration from the monotonic clock", function()
    local clock = time.manual { now = 1755000000, monotime = 100 }
    local restore = time.set(clock)

    local collector = fake_collector()
    local exporter = exporter_with { http = collector }
    local span = exporter:start_span { name = "slow" }
    clock:advance(2)
    span:finish()
    exporter:flush()
    restore()

    local encoded = collector.calls[1].options.body
                      .resourceSpans[1].scopeSpans[1].spans[1]
    assert.equal("1755000000000000000", encoded.startTimeUnixNano)
    assert.equal("1755000002000000000", encoded.endTimeUnixNano)
  end)
end)

-- =========================================================================

describe("joining the caller's trace", function()
  it("continues the inbound trace and parents itself to its span", function()
    local exporter = exporter_with { http = fake_collector() }
    local client = traced_app(exporter):test()

    client:get("/ping", { headers = { traceparent = VALID } })

    local span = exporter.queue[1]
    assert.equal("4bf92f3577b34da6a3ce929d0e0e4736", span.trace_id)
    assert.equal("00f067aa0ba902b7", span.parent_span_id)
    assert.not_equal("00f067aa0ba902b7", span.span_id)
  end)

  it("starts a fresh trace when the header was malformed", function()
    -- akkar has already validated and dropped it, so `req.trace` is nil and
    -- this span must not join a corrupt trace.
    local exporter = exporter_with { http = fake_collector() }
    local client = traced_app(exporter):test()

    client:get("/ping", { headers = { traceparent = "00-nonsense-01" } })

    local span = exporter.queue[1]
    assert.equal(32, #span.trace_id)
    assert.is_nil(span.parent_span_id)
  end)

  it("obeys the caller's decision not to sample", function()
    -- Recording a span for a trace the caller dropped produces an orphan: one
    -- span whose parent never arrives, which every backend renders as a broken
    -- trace rather than as extra information.
    local exporter = exporter_with { http = fake_collector() }
    local client = traced_app(exporter):test()

    local unsampled = VALID:gsub("%-01$", "-00")
    assert.equal(200, client:get("/ping", {
      headers = { traceparent = unsampled } }).status)
    assert.equal(0, exporter:stats().recorded)

    client:get("/ping", { headers = { traceparent = VALID } })
    assert.equal(1, exporter:stats().recorded)
  end)

  it("emits a traceparent akkar itself would accept", function()
    -- The two halves have to agree or akkar would send a header it would
    -- reject on the way back in. Round-tripped through the framework's own
    -- parser rather than through a second regex written here.
    local exporter = exporter_with {}
    local span = exporter:start_span { name = "outbound" }

    local parsed = akkar.trace_context { traceparent = span:traceparent() }
    assert.is_table(parsed, "akkar rejected its own traceparent")
    assert.equal(span.trace_id, parsed.trace_id)
    assert.equal(span.span_id, parsed.span_id)
    assert.is_true(parsed.sampled)

    -- The sampled flag lives in the LOW bit, which the tests at the top of
    -- this file assert on the way in.
    local quiet = exporter:start_span { name = "outbound", sampled = false }
    assert.is_false(
      akkar.trace_context { traceparent = quiet:traceparent() }.sampled)
  end)

  it("hands the span to the handler, so an outbound call can carry it",
    function()
      -- `akkar/http.lua` already accepts `traceparent` and upserts it; this is
      -- the piece that was missing rather than a new mechanism.
      local exporter = exporter_with {}
      local app = traced_app(exporter, function(a)
        a:get("/call", function(req)
          return { header = req.span:traceparent() }
        end)
      end)

      local res = app:test():get("/call", { headers = { traceparent = VALID } })
      assert.is_truthy(res.body.header:find(
        "4bf92f3577b34da6a3ce929d0e0e4736", 1, true))
    end)
end)

-- =========================================================================

describe("what the span says about the request", function()
  it("is named after the ROUTE, not the path", function()
    -- `/users/42` and `/users/43` are the same operation. A backend that
    -- groups by raw path produces one bucket per user id, which is a
    -- cardinality explosion and a tracing bill at the same time.
    --
    -- `req.route` is written by dispatch, BELOW every middleware, so reading
    -- it when the span starts silently falls through to `req.path` -- and that
    -- would look correct in any test whose route had no parameters in it.
    local exporter = exporter_with {}
    local app = traced_app(exporter, function(a)
      a:get("/users/:id", function(req) return { id = req.params.id } end)
    end)

    app:test():get "/users/42"
    assert.equal("GET /users/:id", exporter.queue[1].name)
  end)

  it("marks a 5xx as an error and a 4xx as unset", function()
    -- OpenTelemetry's own rule for a SERVER span: a 4xx means the client asked
    -- for something it could not have and the server did its job by saying so.
    -- Marking those as errors makes the error rate on every dashboard equal to
    -- the rate at which people mistype URLs.
    local exporter = exporter_with {}
    local app = traced_app(exporter, function(a)
      a:get("/missing", function() return akkar.not_found() end)
      a:get("/broken", function() return akkar.response(500, { error = "x" }) end)
    end)
    local client = app:test()

    client:get "/missing"
    assert.equal(trace.STATUS.UNSET, exporter.queue[1].status)
    assert.equal(404, exporter.queue[1].attributes["http.response.status_code"])

    client:get "/broken"
    assert.equal(trace.STATUS.ERROR, exporter.queue[2].status)
  end)

  it("still produces a span when the handler raises", function()
    -- A trace missing exactly the requests that failed is a trace of the
    -- requests nobody needed to look at.
    --
    -- WHAT THE MIDDLEWARE ACTUALLY SEES HERE IS A 500, NOT A RAISE, and that
    -- was worth finding out rather than assuming: akkar catches a handler's
    -- error BELOW the middleware chain and turns it into a response, so
    -- `pcall(next, req)` returns normally. The span is an error because the
    -- status is 500, by the ordinary path.
    local exporter = exporter_with {}
    local app = traced_app(exporter, function(a)
      a:get("/boom", function() error("a genuine bug", 0) end)
    end)

    local res = app:test():get "/boom"
    assert.equal(500, res.status)

    local span = exporter.queue[1]
    assert.equal(trace.STATUS.ERROR, span.status)
    assert.equal(500, span.attributes["http.response.status_code"])
  end)

  it("still produces a span when something BELOW it raises past the handler",
    function()
      -- The path the `pcall` in the middleware is actually for: a middleware
      -- nested inside this one raises, and nothing has turned it into a
      -- response yet. Without the pcall the span would simply never be
      -- recorded, and the requests that vanish from a trace would be exactly
      -- the ones worth looking at.
      local exporter = exporter_with {}
      local app = akkar.new()
      app:use(exporter:middleware())
      app:use(function() error("a middleware fell over", 0) end)
      app:get("/ping", function() return { pong = true } end)

      local res = app:test():get "/ping"
      assert.equal(500, res.status)

      local span = exporter.queue[1]
      assert.equal(trace.STATUS.ERROR, span.status)
      assert.is_truthy(span.status_message:find("a middleware fell over", 1, true))
    end)

  it("does NOT call a thrown response an error", function()
    -- `akkar.is_response` exists precisely so middleware can tell the two
    -- apart -- `akkar/init.lua` says so where it exports the function. A
    -- handler that throws a 404 to unwind has answered the request correctly,
    -- and the error rate must not count it.
    --
    -- Thrown from a middleware BELOW this one, on purpose. A throw from a
    -- HANDLER is caught by dispatch and arrives here as an ordinary response,
    -- so it would exercise nothing: this is the only arrangement in which the
    -- thrown value actually reaches the `pcall` and `is_response` has to do
    -- the work. Without that branch this span would be marked ERROR, and every
    -- 404 in the application would appear on the error rate.
    local exporter = exporter_with {}
    local app = akkar.new()
    app:use(exporter:middleware())
    app:use(function() error(akkar.not_found "gone", 0) end)
    app:get("/thrown", function() return { ok = true } end)

    local res = app:test():get "/thrown"
    assert.equal(404, res.status)

    local span = exporter.queue[1]
    assert.equal(trace.STATUS.UNSET, span.status)
    assert.equal(404, span.attributes["http.response.status_code"])
    assert.is_nil(span.status_message)
  end)

  it("DOES call a thrown 5xx an error", function()
    local exporter = exporter_with {}
    local app = akkar.new()
    app:use(exporter:middleware())
    app:use(function() error(akkar.unavailable "draining", 0) end)
    app:get("/thrown", function() return { ok = true } end)

    assert.equal(503, app:test():get("/thrown").status)
    assert.equal(trace.STATUS.ERROR, exporter.queue[1].status)
  end)
end)

describe("what the exporter does to the response", function()
  it("returns the handler's value untouched", function()
    -- `akkar.etag`, `akkar.limit` and `akkar.auth` were each fixed for writing
    -- a header onto the table a handler returned: a hoisted or memoised
    -- response is shared between requests, so request A's header lands in a
    -- table request B also returns. The cheapest way not to have that defect
    -- is to have nothing to write, and this middleware writes nothing.
    --
    -- akkar now normalises at every hop, so what a middleware receives is a
    -- fresh response rather than the handler's own table -- checked rather
    -- than assumed, and it makes this assertion belt-and-braces today. The
    -- invariant being defended is still this module's, not the framework's.
    local HOISTED = { cached = true }
    local exporter = exporter_with {}
    local app = traced_app(exporter, function(a)
      a:get("/hoisted", function() return HOISTED end)
    end)

    local client = app:test()
    assert.is_true(client:get("/hoisted").body.cached)
    assert.is_true(client:get("/hoisted").body.cached)

    assert.is_nil(HOISTED.headers, "the handler's table was mutated")
    assert.is_nil(HOISTED.status, "the handler's table was mutated")
    assert.is_nil(HOISTED.__response, "the handler's table was mutated")
  end)

  it("leaves the traceparent echo alone", function()
    -- akkar already echoes the inbound header, and two mechanisms writing the
    -- same header is how one of them silently wins.
    local exporter = exporter_with {}
    local res = traced_app(exporter):test():get("/ping", {
      headers = { traceparent = VALID } })
    assert.equal(VALID, res.headers["traceparent"])
  end)
end)

describe("the background loop", function()
  -- What is proven here is the wiring, not the waiting. The loop's BODY is
  -- `tick`, which the two-bounds block above drives directly under a manual
  -- clock; what is left is a `cqueues.sleep` in a wrapped coroutine, and the
  -- only way to exercise that is to wait for real seconds. `akkar/time.lua`
  -- states the same limit from the other side: a manual clock moves timestamps
  -- and budgets, and it does not move the event loop.
  it("refuses to start outside a controller, rather than silently not running",
    function()
      -- An exporter whose loop never started looks exactly like an exporter
      -- with nothing to send, so this has to be an error and not a nil return.
      local ok, why = pcall(function() return exporter_with{}:run() end)
      assert.is_false(ok)
      assert.is_truthy(tostring(why):find("controller", 1, true), tostring(why))
    end)

  it("flushes one last time on stop", function()
    -- Otherwise a shutdown loses whatever the last interval collected, which
    -- is the window most likely to contain the request that caused it.
    local collector = fake_collector()
    local exporter = exporter_with { http = collector }
    exporter:record { name = "last", start_time = 0, duration = 0 }

    assert.is_true(exporter:stop())
    assert.is_true(exporter.stopped)
    assert.equal(1, #collector.calls)
    assert.equal(0, exporter:stats().queued)
  end)
end)

describe("sampling", function()
  it("returns nil rather than a no-op span when not sampling", function()
    -- A no-op span still allocates, still has its attributes written into it
    -- and still has to be finished, so the cost of tracing would be paid on
    -- every request whether or not anything was collected.
    local exporter = exporter_with { sampler = function() return false end }
    local app = traced_app(exporter, function(a)
      a:get("/ping", function(req) return { has_span = req.span ~= nil } end)
    end)

    local res = app:test():get "/ping"
    assert.is_false(res.body.has_span)
    assert.equal(0, exporter:stats().recorded)
  end)
end)
