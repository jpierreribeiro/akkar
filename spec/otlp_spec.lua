--[[
akkar.otlp — metrics and logs reach the collector the traces already reach,
through one setting, and never on a request's clock.

What is proven here is the SHAPE per signal and the RULES the shape rides on.
The shapes are the OpenTelemetry data models -- a counter is a cumulative,
monotonic Sum; a histogram carries per-bucket counts and the registry's own
bounds; a log line is a LogRecord with a severity number from the logs data
model -- asserted against an in-process fake collector, the same table with a
`post` method `spec/trace_spec.lua` uses. The rules are the ones
`akkar/trace.lua` argues for and this pipeline inherits by being the same
code: a request is never blocked on an export, the queue drops past a bound
and counts the drop, and stop exports once more.

Time moves with `akkar.time.manual` except in the one test that needs a
collector to genuinely hang, which runs a real cqueues loop and measures.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local otlp    = require "akkar.otlp"
local trace   = require "akkar.trace"
local metrics = require "akkar.metrics"
local log     = require "akkar.log"
local time    = require "akkar.time"
local json    = require "akkar.json"

local BASE = "http://collector.invalid:4318"

--- The same fake `spec/trace_spec.lua` uses: a `post` that remembers what it
--- was asked to send, so the bytes that would have left can be asserted on.
local function fake_collector(behaviour)
  local client = { calls = {} }
  function client:post(url, options)
    self.calls[#self.calls + 1] = { url = url, options = options }
    if behaviour then return behaviour(#self.calls, options, url) end
    return { status = 200, headers = {}, body = "" }
  end
  function client:calls_to(path)
    local out = {}
    for _, call in ipairs(self.calls) do
      if call.url:sub(-#path) == path then out[#out + 1] = call end
    end
    return out
  end
  return client
end

local function silent() end

--- Finds one metric by name in an `ExportMetricsServiceRequest`, from the
--- LAST resource in the batch, which is the most recent snapshot.
local function metric_named(body, name)
  local resources = body.resourceMetrics
  local scope = resources[#resources].scopeMetrics[1]
  for _, metric in ipairs(scope.metrics) do
    if metric.name == name then return metric end
  end
  return nil
end

local function attribute(list, key)
  for _, pair in ipairs(list or {}) do
    if pair.key == key then return pair.value end
  end
  return nil
end

-- =========================================================================

describe("one setting, three signals", function()
  it("derives the three URLs from one endpoint", function()
    local pipeline = otlp.new { http = fake_collector(), endpoint = BASE,
                                registry = metrics.new() }
    assert.equal(BASE .. "/v1/traces",  pipeline.traces.endpoint)
    assert.equal(BASE .. "/v1/metrics", pipeline.metrics.endpoint)
    assert.equal(BASE .. "/v1/logs",    pipeline.logs.endpoint)
  end)

  it("forgives a base that already ends in a signal path", function()
    -- `akkar.trace`'s own default is `.../v1/traces`; copying it here must
    -- not produce `/v1/traces/v1/metrics`.
    assert.equal(BASE .. "/v1/metrics",
                 otlp.endpoint_for(BASE .. "/v1/traces/", "metrics"))
    assert.equal("http://localhost:4318/v1/logs", otlp.endpoint_for(nil, "logs"))
  end)

  it("lets one signal have its own endpoint and headers", function()
    local pipeline = otlp.new {
      http = fake_collector(), endpoint = BASE,
      headers = { authorization = "Bearer shared" },
      logs = { endpoint = "http://logs.invalid/ingest",
               headers = { ["x-dataset"] = "prod" } },
    }
    assert.equal("http://logs.invalid/ingest", pipeline.logs.endpoint)
    assert.equal("Bearer shared", pipeline.logs.headers.authorization)
    assert.equal("prod", pipeline.logs.headers["x-dataset"])
    assert.equal("Bearer shared", pipeline.traces.headers.authorization)
    assert.is_nil(pipeline.traces.headers["x-dataset"])
  end)

  it("sends the shared headers on every signal's export", function()
    local collector = fake_collector()
    local pipeline = otlp.new {
      http = collector, endpoint = BASE, registry = metrics.new(),
      headers = { authorization = "Bearer k" },
    }
    pipeline.traces:record { name = "s", start_time = 0, duration = 0 }
    pipeline:logger({ sink = silent }):info "hello"
    assert.is_true(pipeline:stop())

    assert.equal(3, #collector.calls)
    for _, call in ipairs(collector.calls) do
      assert.equal("Bearer k", call.options.headers.authorization)
    end
  end)

  it("turns one signal off with `false`", function()
    local pipeline = otlp.new { http = fake_collector(), endpoint = BASE,
                                registry = metrics.new(), logs = false }
    assert.is_nil(pipeline.logs)
    assert.is_not_nil(pipeline.traces)
    assert.is_not_nil(pipeline.metrics)
    assert.is_nil(pipeline:stats().logs)

    -- A logger from a pipeline with logs off is a plain logger.
    local lines = {}
    local logger = pipeline:logger { sink = function(l) lines[#lines + 1] = l end }
    logger:info "still written"
    assert.equal(1, #lines)
    assert.is_nil(logger.exporter)
  end)

  it("has no metrics push without a registry, and says so if asked", function()
    local quiet = otlp.new { http = fake_collector(), endpoint = BASE }
    assert.is_nil(quiet.metrics)

    assert.has_error(function()
      otlp.new { http = fake_collector(), endpoint = BASE, metrics = true }
    end, "akkar.otlp: metrics need a registry; pass registry = " ..
         "akkar.metrics.new() or metrics = false")
  end)

  it("accepts the registry as the metrics option itself", function()
    local registry = metrics.new()
    local pipeline = otlp.new { http = fake_collector(), endpoint = BASE,
                                metrics = registry }
    assert.equal(registry, pipeline.metrics.registry)
  end)

  it("resolves an http factory once for all three exporters", function()
    local built = 0
    local collector = fake_collector()
    local pipeline = otlp.new {
      http = function() built = built + 1 return collector end,
      endpoint = BASE, registry = metrics.new(),
    }
    pipeline.traces:record { name = "s", start_time = 0, duration = 0 }
    pipeline:logger({ sink = silent }):info "x"
    pipeline:stop()
    assert.equal(3, #collector.calls)
    assert.equal(1, built, "the factory ran once per exporter, not once")
  end)

  it("is a no-op middleware with traces off", function()
    local pipeline = otlp.new { http = fake_collector(), traces = false }
    local app = akkar.new()
    app:use(pipeline:middleware())
    app:get("/", function() return { ok = true } end)
    assert.equal(200, app:test():get("/").status)
  end)
end)

-- =========================================================================

describe("metrics over OTLP", function()
  local clock, restore

  before_each(function()
    clock = time.manual { now = 1755000000 }
    restore = time.set(clock)
  end)
  after_each(function() restore() end)

  local function pushed(registry, collector, interval)
    local pipeline = otlp.new {
      http = collector, endpoint = BASE, registry = registry,
      metrics = { interval = interval or 60 },
    }
    clock:advance(interval or 60)
    assert.is_true(pipeline.metrics:tick())
    local calls = collector:calls_to "/v1/metrics"
    return calls[#calls].options.body, pipeline
  end

  it("sends a counter incremented three times as a cumulative monotonic Sum",
    function()
      local registry = metrics.new()
      for _ = 1, 3 do
        registry:counter("orders_total", 1, { { "kind", "card" } })
      end
      local body = pushed(registry, fake_collector())

      local metric = metric_named(body, "orders_total")
      assert.is_not_nil(metric, "the counter was not in the push")
      assert.is_true(metric.sum.isMonotonic)
      assert.equal(2, metric.sum.aggregationTemporality, "2 is CUMULATIVE")

      local point = metric.sum.dataPoints[1]
      assert.equal("3", point.asInt, "an int64 is a STRING in OTLP JSON")
      assert.equal("card", attribute(point.attributes, "kind").stringValue)
      assert.equal(trace.nanoseconds(registry.started), point.startTimeUnixNano)
      assert.equal(trace.nanoseconds(1755000060), point.timeUnixNano)

      -- And the JSON that would leave carries the quoted integer.
      assert.is_truthy(json.encode(body):find('"asInt":"3"', 1, true))
    end)

  it("carries the total, not the delta, so a dropped push loses nothing",
    function()
      local registry = metrics.new()
      registry:counter "hits"
      local collector = fake_collector()
      local body, pipeline = pushed(registry, collector)
      assert.equal("1", metric_named(body, "hits").sum.dataPoints[1].asInt)

      registry:counter "hits"
      registry:counter "hits"
      clock:advance(60)
      assert.is_true(pipeline.metrics:tick())
      local calls = collector:calls_to "/v1/metrics"
      assert.equal(2, #calls)
      assert.equal("3", metric_named(calls[2].options.body, "hits")
                            .sum.dataPoints[1].asInt)
    end)

  it("sends the latency histogram with per-bucket counts and the registry's bounds",
    function()
      local registry = metrics.new()
      registry:observe("GET", "/users/:id", 200, 0.003)
      registry:observe("GET", "/users/:id", 200, 0.02)
      registry:observe("GET", "/users/:id", 200, 0.02)
      registry:observe("GET", "/users/:id", 500, 20)
      local body = pushed(registry, fake_collector())

      local metric = metric_named(body, "akkar_request_duration_seconds")
      assert.equal("s", metric.unit)
      assert.equal(2, metric.histogram.aggregationTemporality)
      local point = metric.histogram.dataPoints[1]

      -- Bounds are the registry's own; counts are PER BUCKET (not cumulative
      -- as Prometheus renders them), with one more for beyond the last bound.
      assert.same(metrics.DEFAULT_BUCKETS, point.explicitBounds)
      assert.same({ "1", "0", "2", "0", "0", "0", "0", "0", "0", "0", "0", "1" },
                  point.bucketCounts)
      assert.equal("4", point.count)
      assert.is_true(math.abs(point.sum - 20.043) < 1e-9)
      assert.equal("/users/:id", attribute(point.attributes, "route").stringValue)
      assert.equal("GET", attribute(point.attributes, "method").stringValue)
    end)

  it("keeps the request counter bounded by route pattern, as the scrape does",
    function()
      local registry = metrics.new()
      local app = akkar.new()
      app:use(registry:middleware())
      app:get("/users/:id", function(req) return { id = req.params.id } end)
      local client = app:test()
      client:get "/users/1"
      client:get "/users/2"
      client:get "/users/3"

      local body = pushed(registry, fake_collector())
      local metric = metric_named(body, "akkar_requests_total")
      assert.equal(1, #metric.sum.dataPoints, "one series per route pattern")
      assert.equal("3", metric.sum.dataPoints[1].asInt)
      assert.equal("/users/:id",
                   attribute(metric.sum.dataPoints[1].attributes, "route").stringValue)
      assert.equal("200",
                   attribute(metric.sum.dataPoints[1].attributes, "status").stringValue)
    end)

  it("reads a pool at push time, exactly as a scrape reads it", function()
    local stats = { size = 4, live = 2, idle = 1, reserved = 0, waits = 3,
                    waited = 0.5, waited_max = 0.2, retired = 0, reaped = 0 }
    local pool = { stats = function() return stats end }
    local registry = metrics.new()
    registry:pool("main", pool)

    local collector = fake_collector()
    local body, pipeline = pushed(registry, collector)

    local waits = metric_named(body, "akkar_pool_waits_total")
    assert.is_true(waits.sum.isMonotonic)
    assert.equal("3", waits.sum.dataPoints[1].asInt)
    assert.equal("main", attribute(waits.sum.dataPoints[1].attributes, "pool").stringValue)
    local idle = metric_named(body, "akkar_pool_idle")
    assert.is_not_nil(idle.gauge, "pool occupancy is a Gauge")
    assert.equal("1", idle.gauge.dataPoints[1].asInt)
    assert.equal(0.5, metric_named(body, "akkar_pool_wait_seconds_total")
                          .sum.dataPoints[1].asDouble)

    -- Nothing sampled it in between: the next push sees the pool as it is
    -- THEN, and the scrape sees the same numbers.
    stats.idle, stats.waits = 4, 9
    clock:advance(60)
    assert.is_true(pipeline.metrics:tick())
    local second = collector:calls_to("/v1/metrics")[2].options.body
    assert.equal("4", metric_named(second, "akkar_pool_idle").gauge.dataPoints[1].asInt)
    assert.equal("9", metric_named(second, "akkar_pool_waits_total").sum.dataPoints[1].asInt)
    assert.is_truthy(registry:render():find('akkar_pool_idle{pool="main"} 4', 1, true))
  end)

  it("sends gauges as Gauge, with their labels as attributes", function()
    local registry = metrics.new()
    registry:gauge("queue_depth", 7, { { "queue", "emails" } })
    local body = pushed(registry, fake_collector())
    local metric = metric_named(body, "queue_depth")
    assert.is_nil(metric.sum)
    assert.equal("7", metric.gauge.dataPoints[1].asInt)
    assert.equal("emails", attribute(metric.gauge.dataPoints[1].attributes, "queue").stringValue)
    assert.is_nil(metric.gauge.dataPoints[1].startTimeUnixNano,
                  "a gauge is a sample, not a total since a start")
  end)

  it("pushes on the interval and not before", function()
    local registry = metrics.new()
    local collector = fake_collector()
    local pipeline = otlp.new { http = collector, endpoint = BASE,
                                registry = registry, metrics = { interval = 60 } }
    clock:advance(59)
    assert.is_false(pipeline:tick())
    assert.equal(0, #collector.calls)
    clock:advance(1)
    assert.is_true(pipeline:tick())
    assert.equal(1, #collector:calls_to "/v1/metrics")
    clock:advance(30)
    assert.is_false(pipeline:tick())
    assert.equal(1, #collector.calls)
  end)

  it("leaves the Prometheus scrape exactly as it was", function()
    local registry = metrics.new()
    registry:counter "hits"
    local app = akkar.new()
    registry:serve(app, "/metrics")
    pushed(registry, fake_collector())
    local text = app:test():get("/metrics").raw
    assert.is_truthy(text:find("hits 1", 1, true))
    assert.is_truthy(text:find("# TYPE akkar_requests_total counter", 1, true))
  end)

  it("keeps the snapshot inside the bound and counts what it refuses", function()
    local registry = metrics.new()
    local pipeline = otlp.new { http = fake_collector(), endpoint = BASE,
                                registry = registry, metrics = { max_queue = 2 } }
    for _ = 1, 5 do pipeline.metrics:record(registry:snapshot()) end
    local stats = pipeline:stats().metrics
    assert.equal(2, stats.queued)
    assert.equal(3, stats.dropped)
    assert.equal(5, stats.recorded)
  end)

  it("names the exporter in its reasons", function()
    local pipeline = otlp.new { endpoint = BASE, registry = metrics.new() }
    pipeline.metrics:record(pipeline.metrics.registry:snapshot())
    local ok, why = pipeline.metrics:flush()
    assert.is_nil(ok)
    assert.equal("akkar.otlp.metrics has no http capability", why)
  end)
end)

-- =========================================================================

describe("logs over OTLP", function()
  local TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"
  local SPAN_ID  = "00f067aa0ba902b7"

  local function exported(build)
    local collector = fake_collector()
    local pipeline = otlp.new { http = collector, endpoint = BASE }
    local lines = {}
    local logger = pipeline:logger {
      level = "debug", format = "json",
      sink = function(line) lines[#lines + 1] = line end,
    }
    build(logger, pipeline)
    assert.is_true(pipeline.logs:flush())
    local call = collector:calls_to("/v1/logs")[1]
    local records = call.options.body.resourceLogs[1].scopeLogs[1].logRecords
    return records, lines, call.options.body
  end

  it("sends a line as a LogRecord with the severity and attributes", function()
    local clock = time.manual { now = 1755000000 }
    local restore = time.set(clock)
    local records, lines, body = exported(function(logger)
      logger:warn("slow query", { ms = 250, table = "orders", ok = false })
    end)
    restore()

    assert.equal(1, #lines, "stderr (the sink) is still written")
    assert.equal(1, #records)
    local record = records[1]
    -- The logs data model: WARN is 13, the first of its range of four.
    assert.equal(13, record.severityNumber)
    assert.equal("WARN", record.severityText)
    assert.equal("slow query", record.body.stringValue)
    assert.equal("1755000000000000000", record.timeUnixNano)
    assert.equal(record.timeUnixNano, record.observedTimeUnixNano)
    assert.equal("250", attribute(record.attributes, "ms").intValue)
    assert.equal("orders", attribute(record.attributes, "table").stringValue)
    assert.equal(false, attribute(record.attributes, "ok").boolValue)
    assert.equal("akkar", body.resourceLogs[1].scopeLogs[1].scope.name)
    assert.equal("akkar", attribute(body.resourceLogs[1].resource.attributes,
                                    "service.name").stringValue)
  end)

  it("maps every akkar level onto the data model's number", function()
    local records = exported(function(logger)
      logger:debug "d" logger:info "i" logger:warn "w" logger:error "e"
    end)
    assert.same({ 5, 9, 13, 17 }, {
      records[1].severityNumber, records[2].severityNumber,
      records[3].severityNumber, records[4].severityNumber,
    })
    assert.same({ "DEBUG", "INFO", "WARN", "ERROR" }, {
      records[1].severityText, records[2].severityText,
      records[3].severityText, records[4].severityText,
    })
    assert.same(log.SEVERITY, { debug = 5, info = 9, warn = 13, error = 17 })
  end)

  it("carries bound fields through :with as attributes, which is how req.log arrives",
    function()
      local records = exported(function(logger)
        logger:with({ request_id = "r-1", tenant = "acme" }):info "charged"
      end)
      assert.equal("r-1", attribute(records[1].attributes, "request_id").stringValue)
      assert.equal("acme", attribute(records[1].attributes, "tenant").stringValue)
    end)

  it("exports what a handler writes through req.log", function()
    local collector = fake_collector()
    local pipeline = otlp.new { http = collector, endpoint = BASE }
    local app = akkar.new()
    app:get("/pay", function(req)
      req.log:info("paid", { amount = 10 })
      return { ok = true }
    end)
    local client = app:test { log = pipeline:logger { sink = silent } }
    assert.equal(200, client:get("/pay").status)

    assert.is_true(pipeline.logs:flush())
    local records = collector:calls_to("/v1/logs")[1].options.body
                      .resourceLogs[1].scopeLogs[1].logRecords
    local paid
    for _, record in ipairs(records) do
      if record.body.stringValue == "paid" then paid = record end
    end
    assert.is_not_nil(paid, "the handler's line was not exported")
    assert.equal("10", attribute(paid.attributes, "amount").intValue)
    assert.is_not_nil(attribute(paid.attributes, "request_id"),
                      "the id bound by akkar did not survive :with")
  end)

  it("lifts trace_id and span_id onto the record when the line carries them",
    function()
      local records = exported(function(logger)
        logger:info("in a span", { trace_id = TRACE_ID, span_id = SPAN_ID })
      end)
      assert.equal(TRACE_ID, records[1].traceId)
      assert.equal(SPAN_ID, records[1].spanId)
      assert.is_nil(attribute(records[1].attributes, "trace_id"))
      assert.is_nil(attribute(records[1].attributes, "span_id"))
    end)

  it("keeps a value that is not an id as an attribute rather than a bad traceId",
    function()
      -- A collector that receives a malformed `traceId` rejects the batch, so
      -- forty other records would pay for one odd field.
      local records = exported(function(logger)
        logger:info("odd", { trace_id = "not-hex", span_id = 42 })
      end)
      assert.is_nil(records[1].traceId)
      assert.is_nil(records[1].spanId)
      assert.equal("not-hex", attribute(records[1].attributes, "trace_id").stringValue)
      assert.equal("42", attribute(records[1].attributes, "span_id").stringValue)
    end)

  it("does not export a line below the level, exactly as it does not write it",
    function()
      local collector = fake_collector()
      local pipeline = otlp.new { http = collector, endpoint = BASE }
      local logger = pipeline:logger { level = "warn", sink = silent }
      logger:info "quiet"
      logger:debug "quieter"
      assert.equal(0, pipeline:stats().logs.recorded)
    end)

  it("writes a table-valued field as its JSON text", function()
    local records = exported(function(logger)
      logger:info("nested", { payload = { a = 1 } })
    end)
    assert.equal('{"a":1}', attribute(records[1].attributes, "payload").stringValue)
  end)

  it("refuses an exporter that cannot record", function()
    assert.has_error(function() log.new { exporter = {} } end,
      "akkar.log: exporter needs a record(entry) method; pass the logs " ..
      "exporter from akkar.otlp.new{}")
  end)
end)

-- =========================================================================

describe("never blocking a request on an export", function()
  it("does not touch the collector while serving, on any signal", function()
    -- The client RAISES if anything reaches it. If any signal exported
    -- inline, every one of these requests would be a 500.
    local hostile = { post = function() error("the collector is gone", 0) end }
    local registry = metrics.new()
    local pipeline = otlp.new { http = hostile, endpoint = BASE,
                                registry = registry }
    local app = akkar.new()
    app:use(pipeline:middleware())
    app:use(registry:middleware())
    app:get("/ping", function(req) req.log:info "pinged" return { pong = true } end)
    local client = app:test { log = pipeline:logger { sink = silent } }

    for _ = 1, 50 do
      assert.equal(200, client:get("/ping").status)
    end

    local stats = pipeline:stats()
    assert.equal(50, stats.traces.queued)
    assert.is_true(stats.logs.queued >= 50)
    assert.equal(0, stats.traces.batches, "a trace export ran during a request")
    assert.equal(0, stats.logs.batches, "a log export ran during a request")
    assert.equal(0, stats.metrics.batches, "a metrics push ran during a request")
  end)

  it("answers requests while the collector is hanging on an export", function()
    -- A real loop, because a hang is the one thing a manual clock cannot
    -- fake. The collector sleeps inside `post` on its first call; requests
    -- are served THROUGH that sleep and must finish while it is still in
    -- flight.
    local cqueues = require "cqueues"
    local in_flight, released = false, false
    local collector = fake_collector(function(n)
      if n == 1 then
        in_flight = true
        cqueues.sleep(0.6)
        in_flight, released = false, true
      end
      return { status = 200 }
    end)
    local registry = metrics.new()
    local pipeline = otlp.new {
      http = collector, endpoint = BASE, registry = registry,
      logs = { interval = 0.02 }, traces = { interval = 0.02 },
    }
    local app = akkar.new()
    app:use(pipeline:middleware())
    app:use(registry:middleware())
    app:get("/ping", function(req) req.log:info "pinged" return { pong = true } end)
    local client = app:test { log = pipeline:logger { sink = silent } }

    local served_during_hang, elapsed
    local cq = cqueues.new()
    pipeline:run(cq)
    cq:wrap(function()
      client:get "/ping"                      -- something to export
      repeat cqueues.sleep(0.005) until in_flight

      local started = time.monotime()
      served_during_hang = 0
      for _ = 1, 50 do
        if client:get("/ping").status == 200 and in_flight then
          served_during_hang = served_during_hang + 1
        end
      end
      elapsed = time.monotime() - started
      pipeline.stopped = true               -- end the loop; do not flush into the hang
    end)
    assert(cq:loop(5))

    assert.equal(50, served_during_hang,
                 "requests waited for the collector: " .. tostring(served_during_hang))
    assert.is_true(elapsed < 0.3,
      ("50 requests took %.3fs while the collector hung"):format(elapsed))
    assert.is_true(released, "the hang never finished, so the loop did not run")
  end)
end)

-- =========================================================================

describe("dropping beyond the bound", function()
  it("refuses log lines past max_queue, counts them, and keeps serving", function()
    local pipeline = otlp.new { http = fake_collector(), endpoint = BASE,
                                logs = { max_queue = 3 } }
    local app = akkar.new()
    app:get("/ping", function(req) req.log:info "line" return { pong = true } end)
    local client = app:test { log = pipeline:logger { level = "info", sink = silent } }

    for _ = 1, 10 do assert.equal(200, client:get("/ping").status) end

    local stats = pipeline:stats().logs
    assert.equal(3, stats.queued)
    assert.equal(stats.recorded - 3, stats.dropped, "drops must be counted")
    assert.is_true(stats.dropped >= 7)
  end)

  it("drops a failed batch of any signal instead of retrying it", function()
    local collector = fake_collector(function() return { status = 503 } end)
    local pipeline = otlp.new { http = collector, endpoint = BASE,
                                registry = metrics.new() }
    pipeline:logger({ sink = silent }):info "x"
    pipeline.traces:record { name = "s", start_time = 0, duration = 0 }
    pipeline.metrics:record(pipeline.metrics.registry:snapshot())

    local ok, why = pipeline:flush()
    assert.is_nil(ok)
    assert.equal("status 503; status 503; status 503", why)
    local stats = pipeline:stats()
    for _, name in ipairs(otlp.SIGNALS) do
      assert.equal(0, stats[name].queued, name)
      assert.equal(1, stats[name].dropped, name)
      assert.equal(1, stats[name].failed, name)
    end
    assert.is_true(pipeline:flush(), "a second flush has nothing to send")
    assert.equal(3, #collector.calls)
  end)
end)

-- =========================================================================

describe("stopping", function()
  it("exports every signal once more, metrics with a final snapshot", function()
    local clock = time.manual { now = 1755000000 }
    local restore = time.set(clock)
    local collector = fake_collector()
    local registry = metrics.new()
    local pipeline = otlp.new { http = collector, endpoint = BASE,
                                registry = registry }
    registry:counter "hits"
    pipeline.traces:record { name = "s", start_time = 0, duration = 0 }
    pipeline:logger({ sink = silent }):info "bye"

    -- Nothing is due: no interval has passed and no batch is full.
    assert.is_false(pipeline:tick())
    assert.equal(0, #collector.calls)

    assert.is_true(pipeline:stop())
    restore()

    assert.is_true(pipeline.stopped)
    assert.equal(1, #collector:calls_to "/v1/traces")
    assert.equal(1, #collector:calls_to "/v1/logs")
    local pushes = collector:calls_to "/v1/metrics"
    assert.equal(1, #pushes, "no final snapshot on stop")
    assert.equal("1", metric_named(pushes[1].options.body, "hits").sum.dataPoints[1].asInt)
    assert.same({ queued = 0 }, { queued = pipeline:stats().logs.queued })
  end)
end)

-- =========================================================================

describe("the log encoder alone", function()
  it("builds an ExportLogsServiceRequest a spec can assert on", function()
    local body = log.otlp({
      { level = "error", message = "boom", time = 1, code = 7 },
    }, { ["service.name"] = "tasks" })
    local record = body.resourceLogs[1].scopeLogs[1].logRecords[1]
    assert.equal(17, record.severityNumber)
    assert.equal("ERROR", record.severityText)
    assert.equal("1000000000", record.timeUnixNano)
    assert.equal("7", attribute(record.attributes, "code").intValue)
    assert.equal("tasks", attribute(body.resourceLogs[1].resource.attributes,
                                    "service.name").stringValue)
  end)
end)
