--[[
The error exporter: what leaves the process when akkar answers 500.

Three properties are being defended here and each one has a way of quietly
going missing.

**The response does not change.** `akkar/init.lua` keeps the 500 bare on
purpose -- "A Lua error carries file paths, line numbers and sometimes SQL" --
and the obvious way to build an error reporter is to have it also improve the
error message for the client. So the first test asserts the body is byte for
byte what it was before anything was installed, on the same request that
produced a full event.

**The request is never on the reporter's clock.** A tracker is a third
party's service, and the first thing that happens in an incident is that it
gets slow. A sink that blocks for a second is served here, and five failing
requests still answer in a fraction of one.

**The queue is bounded.** An unreachable tracker must cost a fixed amount of
memory, not a growing one, so the eleventh event past the bound is refused and
counted rather than kept.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar  = require "akkar"
local errors = require "akkar.errors"
local trace  = require "akkar.trace"
local time   = require "akkar.time"

--- A sink that keeps what it was handed.
---
--- A plain function, which is the whole contract: `akkar/errors.lua` gives it
--- exactly the document the HTTP sink would have POSTed, so asserting on what
--- this saw is asserting on the bytes that would have gone out.
local function collecting_sink()
  local seen = { documents = {}, events = {}, calls = 0 }
  return seen, function(document)
    seen.calls = seen.calls + 1
    seen.documents[#seen.documents + 1] = document
    for _, event in ipairs(document.events) do
      seen.events[#seen.events + 1] = event
    end
  end
end

--- An app whose one route raises, with a reporter on `on_error`.
local function failing_app(reporter, raise, path)
  local app = akkar.new()
  app:on_error(reporter:handler())
  app:get(path or "/orders/:id", function()
    error(raise or "a genuine bug", 0)
  end)
  return app
end

-- =========================================================================

describe("capturing the failure behind a 500", function()
  it("produces exactly one event, with the request's own context", function()
    local seen, sink = collecting_sink()
    local reporter = errors.new { sink = sink, service = "checkout" }
    local client = failing_app(reporter):test()

    local res = client:get "/orders/9f2b"

    assert.equal(500, res.status)
    assert.equal(1, reporter:stats().recorded)
    assert.equal(1, reporter:stats().queued)
    -- NOTHING WAS DELIVERED DURING THE REQUEST. If `capture` posted inline
    -- this would be 1 already, and the property in the next describe block
    -- would be gone with it.
    assert.equal(0, seen.calls)

    assert.is_true(reporter:flush())
    assert.equal(1, #seen.events)

    local event = seen.events[1]
    assert.equal("error", event.level)
    assert.equal("checkout", event.service)
    assert.equal(500, event.status)
    assert.equal("GET", event.method)
    assert.equal("a genuine bug", event.message)
    assert.is_number(event.timestamp)

    -- The join key back to the log lines and to the `x-request-id` the client
    -- was handed.
    assert.equal(res.headers["x-request-id"], event.request_id)

    -- THE ROUTE PATTERN, NOT THE PATH. `/orders/9f2b` in the event would mean
    -- one group per order id in whatever reads it.
    assert.equal("/orders/:id", event.route)
    assert.is_nil(event.path)
  end)

  it("leaves the 500 exactly as bare as it was", function()
    -- The reporter gets the detail; the client gets nothing. This is the
    -- property `akkar/init.lua` spends a paragraph on, asserted on the same
    -- request that produced a complete event.
    local seen, sink = collecting_sink()
    local reporter = errors.new { sink = sink }
    local client = failing_app(reporter,
      "akkar/db.lua:88: relation \"orders\" does not exist"):test()

    local res = client:get "/orders/1"
    reporter:flush()

    assert.equal(500, res.status)
    assert.same({ error = "internal server error" }, res.body)
    assert.is_nil(res.body.detail)

    local rendered = require("akkar.json").encode(res.body)
    assert.is_falsy(rendered:find("relation", 1, true),
      "the cause reached the client: " .. rendered)
    assert.is_falsy(rendered:find("akkar/db.lua", 1, true),
      "a source path reached the client: " .. rendered)

    -- And it did reach the reporter, or the test above proves nothing.
    assert.is_truthy(seen.events[1].message:find("relation", 1, true))
  end)

  it("carries the trace, so an event leads to its span", function()
    local seen, sink = collecting_sink()
    local reporter = errors.new { sink = sink }
    local exporter = trace.new { http = { post = function() return { status = 200 } end } }

    local app = failing_app(reporter)
    app:use(exporter:middleware())
    local client = app:test()

    local id = "4bf92f3577b34da6a3ce929d0e0e4736"
    client:get("/orders/1", {
      headers = { traceparent = "00-" .. id .. "-00f067aa0ba902b7-01" },
    })
    reporter:flush()

    assert.equal(id, seen.events[1].trace_id)
    assert.is_string(seen.events[1].span_id)
  end)

  it("carries the caller's trace when nothing local started a span", function()
    -- No exporter installed, so there is no local span -- and the inbound
    -- `traceparent` is still a trace, whose span id is the caller's. Same
    -- precedence `akkar/execution.lua` uses to bind the logger, and it has to
    -- survive the capability release: `internal_error` runs after it, and
    -- `req.trace` is a lazy field read off headers.
    local seen, sink = collecting_sink()
    local reporter = errors.new { sink = sink }
    local client = failing_app(reporter):test()

    client:get("/orders/1", {
      headers = { traceparent =
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
    })
    reporter:flush()

    assert.equal("4bf92f3577b34da6a3ce929d0e0e4736", seen.events[1].trace_id)
    assert.equal("00f067aa0ba902b7", seen.events[1].span_id)
  end)

  it("has no trace key at all on a request that carries no trace", function()
    -- Absent, not empty. A store indexing `trace_id` must not be handed a
    -- million empty strings; `spec/log_spec.lua` makes the same assertion
    -- about the log line.
    local seen, sink = collecting_sink()
    local reporter = errors.new { sink = sink }
    failing_app(reporter):test():get "/orders/1"
    reporter:flush()

    assert.is_nil(seen.events[1].trace_id)
    assert.is_nil(seen.events[1].span_id)
  end)

  it("has no route for a failure that happened before one was matched",
    function()
      -- Absent rather than filled in with the path. A fallback would put the
      -- cardinality back exactly on the errors that are hardest to read.
      local seen, sink = collecting_sink()
      local reporter = errors.new { sink = sink }
      local app = akkar.new()
      app:on_error(reporter:handler())
      app:use(function() error("a middleware fell over", 0) end)
      app:get("/orders/:id", function() return {} end)

      assert.equal(500, app:test():get("/orders/1").status)
      reporter:flush()
      assert.is_nil(seen.events[1].route)
      assert.equal("a middleware fell over", seen.events[1].message)
    end)

  it("lets an application keep its own 500 body, after the capture",
    function()
      local seen, sink = collecting_sink()
      local reporter = errors.new { sink = sink }
      local app = akkar.new()
      app:on_error(reporter:handler(function(_, req)
        return akkar.response(500, { instance = req.id })
      end))
      app:get("/boom", function() error("x", 0) end)

      local res = app:test():get "/boom"
      reporter:flush()
      assert.equal(res.headers["x-request-id"], res.body.instance)
      assert.equal(1, #seen.events)
    end)
end)

-- =========================================================================

describe("never blocking a request on the reporter", function()
  it("answers while the sink is asleep on its feet", function()
    -- A tracker that has gone slow is the normal case in an incident, and an
    -- inline capture would put its latency on every 500 -- on a cooperative
    -- scheduler, on the whole process.
    --
    -- The sink burns a WALL SECOND on purpose. If `capture` delivered
    -- inline, five requests would take five of them.
    local calls = 0
    local reporter = errors.new {
      sink = function()
        calls = calls + 1
        local until_ = time.monotime() + 1.0
        while time.monotime() < until_ do end
      end,
    }
    local client = failing_app(reporter):test()

    local started = time.monotime()
    for _ = 1, 5 do
      assert.equal(500, client:get("/orders/1").status)
    end
    local elapsed = time.monotime() - started

    assert.equal(0, calls, "the sink ran on the request's coroutine")
    assert.is_true(elapsed < 0.5, string.format(
      "five failing requests took %.3fs; a hanging sink is on the request " ..
      "path", elapsed))
    assert.equal(5, reporter:stats().queued)

    -- And the second the loop calls it, it does cost what it costs -- in the
    -- background, where that is somebody else's problem.
    local flushed = time.monotime()
    reporter:flush()
    assert.equal(1, calls)
    assert.is_true(time.monotime() - flushed >= 0.9,
      "the sink did not actually block, so the test above proved nothing")
  end)

  it("keeps serving when the sink raises rather than returning", function()
    local reporter = errors.new {
      sink = function() error("the tracker is gone", 0) end,
    }
    local client = failing_app(reporter):test()

    assert.equal(500, client:get("/orders/1").status)
    local ok, why = reporter:flush()
    assert.is_nil(ok)
    assert.is_truthy(tostring(why):find("the tracker is gone", 1, true))
    assert.equal(1, reporter:stats().failed)

    -- The batch is DROPPED, not retried: the request it describes was
    -- answered either way.
    assert.equal(1, reporter:stats().dropped)
    assert.equal(500, client:get("/orders/1").status)
  end)
end)

-- =========================================================================

describe("dropping events when the buffer is full", function()
  it("refuses past the bound instead of growing", function()
    local seen, sink = collecting_sink()
    local reporter = errors.new { sink = sink, max_queue = 3 }
    local client = failing_app(reporter):test()

    for _ = 1, 10 do
      assert.equal(500, client:get("/orders/1").status,
        "a full queue changed the answer the client got")
    end

    local stats = reporter:stats()
    assert.equal(10, stats.recorded)
    assert.equal(3, stats.queued, "the queue grew past its bound")
    assert.equal(7, stats.dropped)

    -- Counted, not silent. An operator watching `dropped` climb knows their
    -- tracker is unreachable; one with no counter has holes and no idea why.
    reporter:flush()
    assert.equal(3, #seen.events)
  end)

  it("does not even build the event it is about to refuse", function()
    -- The bound is checked before `event` runs, so a full queue costs a
    -- comparison rather than a sanitising pass on a failing request's clock.
    local reporter = errors.new { sink = function() end, max_queue = 1 }
    local built = 0
    local real = getmetatable(reporter).event
    getmetatable(reporter).event = function(self, ...)
      built = built + 1
      return real(self, ...)
    end

    for _ = 1, 20 do reporter:capture("boom") end
    getmetatable(reporter).event = real

    assert.equal(1, built, built .. " events were built for a queue of 1")
    assert.equal(19, reporter:stats().dropped)
  end)
end)

-- =========================================================================

describe("what the sanitiser takes out", function()
  it("cuts the traceback off", function()
    local message = errors.sanitise(
      "app.lua:4: boom\nstack traceback:\n\t[C]: in function 'error'\n" ..
      "\t/srv/app/handlers/orders.lua:19: in function <orders.lua:18>")
    assert.equal("app.lua:4: boom", message)
    assert.is_falsy(message:find("orders.lua", 1, true))
  end)

  it("takes the password out of a connection string", function()
    assert.equal(
      "could not connect to postgres://app:[redacted]@db:5432/orders",
      errors.sanitise "could not connect to postgres://app:hunter2@db:5432/orders")
  end)

  it("takes the value off the usual key names, whatever the case", function()
    local message = errors.sanitise(
      'refused: PASSWORD="hunter2" api_key: k-abc123 Authorization: Bearer eyJ0')
    assert.is_falsy(message:find("hunter2", 1, true), message)
    assert.is_falsy(message:find("k%-abc123"), message)
    assert.is_falsy(message:find("eyJ0", 1, true), message)
    -- Over-redacting is the right side to err on; reading like it was done
    -- twice is not.
    assert.is_falsy(message:find("%[redacted%]%s+%[redacted%]"), message)
  end)

  it("is one line, because it ends up in one", function()
    assert.equal("a b c", errors.sanitise "a\nb\r\n\tc")
  end)

  it("is bounded, and does not cut a codepoint in half", function()
    -- A JSON document carrying half a UTF-8 sequence is one some consumers
    -- reject outright -- so one long message would lose the whole batch.
    local message = errors.sanitise(string.rep("é", 400), 101)
    assert.is_true(#message <= 101 + #" [truncated]")
    assert.is_truthy(message:find(" [truncated]", 1, true))
    assert.is_truthy(utf8.len(message:gsub(" %[truncated%]", "")),
      "the truncation split a codepoint")
  end)

  it("reads a raised table for a message rather than its address", function()
    -- `table: 0x55f3...` differs on every run, so every occurrence would
    -- group separately in whatever reads these.
    assert.equal("no such tenant", errors.sanitise { message = "no such tenant" })
  end)
end)

-- =========================================================================

describe("delivery", function()
  it("POSTs one JSON document to the endpoint it was given", function()
    local sent = {}
    local reporter = errors.new {
      service  = "checkout",
      endpoint = "https://errors.invalid/ingest",
      headers  = { authorization = "Token abc" },
      http     = { post = function(_, url, options)
        sent[#sent + 1] = { url = url, options = options }
        return { status = 202 }
      end },
    }

    reporter:capture("boom")
    assert.is_true(reporter:flush())

    assert.equal(1, #sent)
    assert.equal("https://errors.invalid/ingest", sent[1].url)
    assert.equal("Token abc", sent[1].options.headers.authorization)
    assert.equal("checkout", sent[1].options.body.service)
    assert.equal("boom", sent[1].options.body.events[1].message)
    -- `akkar.http` encodes a table body as JSON, so this is the document.
    assert.is_string(require("akkar.json").encode(sent[1].options.body))
    assert.equal(1, reporter:stats().exported)
  end)

  it("counts a rejecting endpoint as a failed batch and drops it", function()
    local reporter = errors.new {
      endpoint = "https://errors.invalid/ingest",
      http     = { post = function() return { status = 503 } end },
    }
    reporter:capture("boom")
    local ok, why = reporter:flush()
    assert.is_nil(ok)
    assert.equal("status 503", why)
    assert.equal(1, reporter:stats().failed)
    assert.equal(1, reporter:stats().dropped)
  end)

  it("refuses to be built with nowhere to send", function()
    -- At construction, which is boot, and not at the first 500 -- the
    -- alternative is a service that looks instrumented for a month and has
    -- sent nothing.
    assert.has_error(function() errors.new {} end)
    local ok, why = pcall(errors.new, { http = { post = function() end } })
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("endpoint", 1, true))
  end)

  it("shares the queue and the loop with akkar.trace rather than copying them",
    function()
      -- The machinery is `trace.Batch`: one implementation of the queue swap,
      -- the two bounds and the background loop, because the argument for each
      -- is the same one and writing it twice is how the second copy goes
      -- subtly wrong.
      local reporter = errors.new { sink = function() end }
      assert.equal(trace.Batch.record, getmetatable(reporter).record)
      assert.equal(trace.Batch.flush,  getmetatable(reporter).flush)
      assert.equal(trace.Batch.run,    getmetatable(reporter).run)
      assert.are_not.equal(trace.Batch.encode, getmetatable(reporter).encode)
    end)

  it("comes due on both bounds, the same way a span batch does", function()
    local reporter = errors.new { sink = function() end,
                                  max_batch = 3, interval = 60 }
    assert.is_false(reporter:due())
    for _ = 1, 3 do reporter:capture("boom") end
    assert.is_true(reporter:due(), "the size bound never came due")
    assert.is_true(reporter:tick())
    assert.equal(3, reporter:stats().exported)
  end)
end)
