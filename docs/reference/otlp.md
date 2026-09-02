# akkar.otlp

One telemetry pipeline: traces, metrics and logs exported as OTLP/HTTP JSON to
one collector, configured with one setting, flushed by one background loop.
Nothing here runs on a request; every signal appends to a bounded queue and is
posted later.

**When you need it.** You run an OpenTelemetry Collector, or a vendor endpoint
that speaks OTLP, and you want the metrics `akkar.metrics` already keeps and
the lines `akkar.log` already writes to reach it beside the spans
`akkar.trace` already exports -- without a second agent, a second endpoint or
a second set of credentials.

```lua no-run
local otlp = require "akkar.otlp"
```

## Contents

- [otlp.DEFAULTS](#otlpdefaults)
- [otlp.endpoint_for(base, signal)](#otlpendpoint_forbase-signal)
- [otlp.new(options)](#otlpnewoptions)
- [otlp.PATHS](#otlppaths)
- [otlp.SIGNALS](#otlpsignals)
- [Pipeline](#pipeline)
  - [pipeline:flush()](#pipelineflush)
  - [pipeline:logger(options)](#pipelineloggeroptions)
  - [pipeline:middleware(options)](#pipelinemiddlewareoptions)
  - [pipeline:run(controller)](#pipelineruncontroller)
  - [pipeline:stats()](#pipelinestats)
  - [pipeline:stop()](#pipelinestop)
  - [pipeline:tick()](#pipelinetick)
- [What each signal becomes](#what-each-signal-becomes)
- [The rules every signal follows](#the-rules-every-signal-follows)
- [Not here](#not-here)

## otlp.DEFAULTS

| key | value | meaning |
|---|---|---|
| `endpoint` | `"http://localhost:4318"` | the collector's base URL; a signal path is appended |
| `metrics_interval` | `60` | seconds between metric pushes, the OpenTelemetry SDK's own default |
| `metrics_queue` | `8` | snapshots held before new ones are dropped |

Traces and logs take their `max_batch`, `max_queue`, `interval` and `timeout`
from [trace.DEFAULTS](trace.md#tracedefaults): 256, 2048, 5 and 2.

## otlp.endpoint_for(base, signal)

The URL one signal is posted to: `base` with any trailing slash removed, any
signal path it already ends in removed, and the path for `signal` appended.
This is what the OTLP specification says a base endpoint means.

**Returns** a string.

```lua
local otlp = require "akkar.otlp"

print(otlp.endpoint_for("http://collector:4318", "metrics"))
--> http://collector:4318/v1/metrics

-- The traces default from akkar.trace can be pasted in without harm.
print(otlp.endpoint_for("http://localhost:4318/v1/traces", "logs"))
--> http://localhost:4318/v1/logs
```

## otlp.new(options)

Builds the pipeline. Every field is optional. A pipeline with no `http`
capability drops every batch and counts the drops.

| field | type | default | meaning |
|---|---|---|---|
| `http` | client or function | none | an `akkar.http` capability, or a factory returning one. Resolved **once** and shared by the three exporters. |
| `endpoint` | string | `otlp.DEFAULTS.endpoint` | the collector's base URL |
| `headers` | table | none | headers on every export, for an API key |
| `service` | string | `"akkar"` | the resource attribute `service.name` |
| `resource` | table | `{}` | further resource attributes |
| `registry` | registry | none | a registry from `akkar.metrics.new()`. **Metrics are pushed only when one is given.** |
| `sampler` | function | none | the head sampler for spans, as `akkar.trace.new` takes it |
| `timeout` | number | `2` | seconds one export may take, all signals |
| `interval` | number | `5` | seconds that make a span or log export due by time |
| `max_batch` | number | `256` | spans or lines that make an export due by size |
| `max_queue` | number | `2048` | spans or lines held before new ones are dropped |
| `traces` | `false` or table | on | `false` turns spans off; a table is merged over the shared fields for this signal only |
| `metrics` | `false`, table or registry | on with a registry | `false` turns the push off; a table may carry `registry`, `interval`, `max_queue`, `endpoint`, `headers`; a registry enables the push with the defaults |
| `logs` | `false` or table | on | `false` turns lines off; a table is merged over the shared fields for this signal only |

A per-signal table may carry its own `endpoint`, which is used exactly as
given, and its own `headers`, which are merged over the shared ones. The rest
of its fields are the fields above.

**Returns** a pipeline with the fields `traces`, `metrics` and `logs`, each an
[exporter](trace.md#exporter) or `nil` when the signal is off. Reach into them
for `:stats()` on one signal or for the tests you write against them.

**Raises** `akkar.otlp: metrics need a registry; pass registry =
akkar.metrics.new() or metrics = false` when `metrics = true` is asked for
without a registry, and `akkar.otlp: registry has no snapshot(); pass the
registry from akkar.metrics.new()` when the registry is not one. An unknown
option is ignored.

```lua
local akkar   = require "akkar"
local otlp    = require "akkar.otlp"
local metrics = require "akkar.metrics"

-- An `akkar.http` capability is anything with a `post` method. A real one
-- comes from `akkar.http.connect {}`; this one remembers what it was sent.
local sent = {}
local collector = {
  post = function(_, url, options)
    sent[#sent + 1] = { url = url, body = options.body }
    return { status = 200 }
  end,
}

local registry = metrics.new()
local pipeline = otlp.new {
  http     = collector,
  endpoint = "http://collector:4318",
  headers  = { authorization = "Bearer k" },
  service  = "tasks",
  registry = registry,
}

local app = akkar.new()
app:use(pipeline:middleware())          -- a server span per request
app:use(registry:middleware())          -- the request counter and histogram
app:get("/tasks/:id", function(req)
  req.log:info("fetched", { id = req.params.id })   -- a LogRecord
  return { id = req.params.id }
end)

local client = app:test { log = pipeline:logger { level = "info" } }
client:get "/tasks/1"
client:get "/tasks/2"

-- Nothing has left yet: no request touched the collector.
print(#sent)                                   --> 0

-- `stop` flushes every signal, metrics with a final snapshot.
print(pipeline:stop())                         --> true
for _, call in ipairs(sent) do print(call.url) end
--> http://collector:4318/v1/traces
--> http://collector:4318/v1/metrics
--> http://collector:4318/v1/logs

local requests
for _, metric in ipairs(sent[2].body.resourceMetrics[1].scopeMetrics[1].metrics) do
  if metric.name == "akkar_requests_total" then requests = metric end
end
print(requests.sum.isMonotonic, requests.sum.dataPoints[1].asInt)   --> true 2
```

The pipeline's own logger, `pipeline:logger`, writes to stderr as any logger
does; the export is in addition to that, never instead of it. The test client
above passes it as the `log` capability, which is what `app:run { log = ... }`
does in a real process.

## otlp.PATHS

`{ traces = "/v1/traces", metrics = "/v1/metrics", logs = "/v1/logs" }`, from
the OTLP specification.

## otlp.SIGNALS

`{ "traces", "metrics", "logs" }`, the order the pipeline ticks, flushes and
reports them in.

## Pipeline

### pipeline:flush()

Exports every queue now, in `otlp.SIGNALS` order. Not to be called from a
handler: everything in it can wait on a network.

**Returns** `true`, or `nil` and the reasons joined with `; `.

### pipeline:logger(options)

A logger whose lines also reach the collector. `options` is what
[log.new](log.md#lognewoptions) takes; `exporter` is set to the logs exporter,
and `req.log` inherits it through `:with`. With logs off it is a plain logger.

**Returns** a logger.

```lua
local otlp = require "akkar.otlp"

local pipeline = otlp.new { logs = { max_queue = 4 } }
local logger = pipeline:logger { level = "warn", sink = function() end }

for i = 1, 10 do logger:warn("line " .. i) end
logger:info "below the level: neither written nor queued"

local stats = pipeline:stats().logs
print(stats.recorded, stats.queued, stats.dropped)   --> 10 4 6
```

### pipeline:middleware(options)

The server-span middleware from the traces exporter, with the `options`
[exporter:middleware](trace.md#exportermiddlewareoptions) takes. With traces
off it is a middleware that does nothing, so the call site need not know
which signals are on.

**Returns** a middleware.

### pipeline:run(controller)

Runs one loop for every signal on a cqueues controller. Call it once, at
startup, from inside the loop akkar runs on or with the controller passed in.
The loop naps for a quarter of the shortest interval, at most a second, and
ticks every signal.

**Returns** the pipeline.

**Raises** `akkar.otlp: run() needs a cqueues controller; ...` when called
outside one with none given.

### pipeline:stats()

The counters per signal: `{ traces = {...}, metrics = {...}, logs = {...} }`,
each the table [exporter:stats](trace.md#exporterstats) returns. A signal that
is off is absent. Put every `dropped` and `failed` on a dashboard.

**Returns** a table.

### pipeline:stop()

Stops the loop after one last export of every signal. Metrics take one final
snapshot first, so the totals at shutdown reach the collector.

**Returns** `true`, or `nil` and the reasons joined.

### pipeline:tick()

Ticks every signal once: a span or log export when its size or time bound is
reached, a metrics snapshot and push when the metrics interval has passed.
This is what the loop calls, and what a test calls under a manual clock.

**Returns** `true` when anything was exported.

```lua
local otlp    = require "akkar.otlp"
local metrics = require "akkar.metrics"
local time    = require "akkar.time"

local clock = time.manual { now = 1755000000 }
local restore = time.set(clock)

local pushes = 0
local collector = { post = function() pushes = pushes + 1 return { status = 200 } end }
local registry = metrics.new()
registry:counter "hits"

local pipeline = otlp.new { http = collector, registry = registry,
                            metrics = { interval = 60 } }

clock:advance(59)
print(pipeline:tick(), pushes)     --> false 0
clock:advance(1)
print(pipeline:tick(), pushes)     --> true 1

restore()
```

## What each signal becomes

**Spans** are what [trace.otlp](trace.md#traceotlpspans-resource) builds, at
`/v1/traces`, unchanged.

**Metrics** are the registry read at push time by
[registry:snapshot](metrics.md#registrysnapshotnow) -- the same read as a
scrape, pools included -- and encoded by
[metrics.otlp](metrics.md#metricsotlpsnapshots-resource) as an
`ExportMetricsServiceRequest` at `/v1/metrics`. Following the metrics data
model:

| in the registry | in OTLP |
|---|---|
| `akkar_requests_total` and every `registry:counter` | a `Sum`, `aggregationTemporality = 2` (cumulative), `isMonotonic = true`; `startTimeUnixNano` is when the registry was built |
| every `registry:gauge`, the memory gauges, `akkar_uptime_seconds` | a `Gauge` |
| `akkar_request_duration_seconds` | a `Histogram` with `explicitBounds` = the registry's buckets and one `bucketCounts` entry per bucket plus one for beyond the last, **per bucket** rather than cumulative as Prometheus renders them |
| a pool from `registry:pool` | its counters as `Sum`, its occupancy as `Gauge`, under the attribute `pool` |
| labels | attributes, in sorted order |

Cumulative means every push carries the total since the registry was built,
so a push that is dropped loses nothing: the next one carries the same total
and everything after it.

**Log lines** become `LogRecord`s in an `ExportLogsServiceRequest` at
`/v1/logs`, built by [log.otlp](log.md#logotlpentries-resource). Following the
logs data model: `severityNumber` is 5 for `debug`, 9 for `info`, 13 for `warn`
and 17 for `error` (the first of each level's range of four), `severityText` is
the level in upper case, `body` is the message, and every other field -- the
ones bound with `:with`, the ones passed on the call -- is an attribute. A
`trace_id` and `span_id` on the line are lifted onto the record as `traceId`
and `spanId` when they are 32 and 16 hex characters; anything else stays an
attribute rather than becoming a `traceId` a collector would reject the
batch for.

Every 64-bit integer -- a timestamp, a count, an `asInt`, an `intValue` -- is
a **string**, which is what OTLP's JSON encoding requires of one.

## The rules every signal follows

They are the rules `akkar/trace.lua` argues for, and they hold here because
the three exporters are that module's exporter with three encoders.

- **A request is never blocked on an export.** Recording a span, a snapshot or
  a line appends to a table. The network happens on the loop.
- **The queue is bounded and drops beyond the bound**, refusing the newest
  and counting it in `dropped`. A collector that is gone costs a fixed amount
  of memory.
- **A failed batch is dropped, not retried**, and counted in `failed`.
- **Stop exports once more.** `pipeline:stop()` flushes every queue and
  pushes a final metrics snapshot.

Three queues rather than one, so the noisiest signal cannot squeeze the
others out of the bound.

## Not here

- **Protobuf or gRPC.** OTLP/HTTP JSON only.
- **Delta temporality.** Every sum is cumulative.
- **Log sampling or a second sink.** stderr is written first, always; the
  export is in addition. `akkar.log`'s `sink` is still the place for a file.
- **A metrics push without a registry.** The push reads the registry you
  already scrape, and nothing else.
- **Retry, backoff or a persistent buffer.** By design; the counters are what
  tell you a collector is missing.

## See also

- [akkar.trace](trace.md) for the exporter this is built on, spans, and why
  a request is never blocked on an export
- [akkar.metrics](metrics.md) for the registry, `registry:snapshot` and
  `metrics.otlp`
- [akkar.log](log.md) for `log.new { exporter = ... }`, `log.record` and
  `log.otlp`
- the OpenTelemetry specifications this follows: the
  [metrics data model](https://opentelemetry.io/docs/specs/otel/metrics/data-model/),
  the [logs data model](https://opentelemetry.io/docs/specs/otel/logs/data-model/)
  and [OTLP/HTTP with its JSON encoding](https://opentelemetry.io/docs/specs/otlp/)
- the module source, `akkar/otlp.lua`, for why there are three queues and
  one loop
