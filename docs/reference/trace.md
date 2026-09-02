# akkar.trace

W3C Trace Context spans, exported as OTLP/HTTP JSON over an `akkar.http`
capability. Recording a span appends to a table; the export happens on a
background loop, never on the request.

**When you need it.** A request crosses three services and you want one
timeline for it in Jaeger, Tempo or an OpenTelemetry Collector, including the
requests that failed.

```lua no-run
local trace = require "akkar.trace"
```

## Contents

- [trace.attributes_of(map)](#traceattributes_ofmap)
- [trace.Batch](#tracebatch)
- [trace.DEFAULTS](#tracedefaults)
- [trace.Exporter](#traceexporter)
- [trace.KIND](#tracekind)
- [trace.nanoseconds(seconds)](#tracenanosecondsseconds)
- [trace.new(options)](#tracenewoptions)
- [trace.otlp(spans, resource)](#traceotlpspans-resource)
- [trace.Span](#tracespan)
- [trace.span_id()](#tracespan_id)
- [trace.STATUS](#tracestatus)
- [trace.trace_id()](#tracetrace_id)
- [trace.traceparent(trace_id, span_id, sampled)](#tracetraceparenttrace_id-span_id-sampled)
- [Exporter](#exporter)
  - [exporter:client()](#exporterclient)
  - [exporter:due()](#exporterdue)
  - [exporter:flush()](#exporterflush)
  - [exporter:middleware(options)](#exportermiddlewareoptions)
  - [exporter:record(span)](#exporterrecordspan)
  - [exporter:run(controller)](#exporterruncontroller)
  - [exporter:start_span(options)](#exporterstart_spanoptions)
  - [exporter:stats()](#exporterstats)
  - [exporter:stop()](#exporterstop)
  - [exporter:tick()](#exportertick)
- [Span](#span)
  - [span:finish(options)](#spanfinishoptions)
  - [span:set(key, value)](#spansetkey-value)
  - [span:traceparent()](#spantraceparent)
- [Timestamps](#timestamps)
- [Correlation with logs](#correlation-with-logs)
- [Not here](#not-here)

## trace.attributes_of(map)

Turns a key to value table into OTLP's list of attributes, sorted by key so
two runs serialise identically.

A string becomes `stringValue`, a boolean `boolValue`, a Lua integer
`intValue` (as a **string**, which is what OTLP's JSON mapping requires for an
int64), a float `doubleValue`. Anything else is stringified.

**Returns** a list, or `nil` for a `nil` or empty map.

## trace.Batch

The queue, the two bounds and the background loop, on their own metatable.
`record`, `due`, `tick`, `client`, `deliver`, `flush`, `stats`, `run` and
`stop` are defined here; an `Exporter` inherits all of them and adds
`start_span`, `middleware` and `encode`.

It is separate because there is more than one thing in this runtime that has
to leave the process without standing on the request's clock: `akkar.errors`
is the other, and every argument on this page — never inline, drop rather than
grow, drop rather than retry, two bounds and not one — is its argument too.
Writing a queue swap whose correctness only shows under concurrency a second
time is how the second copy goes subtly wrong.

`trace.batch(target, options)` installs those fields on a table; the caller
sets its own metatable over it. `options.origin` is the module's own name, so
`"akkar.trace has no http capability"` names the thing that is misconfigured.

A consequence worth knowing: `sink = function(document, spans)` works on an
exporter too, and receives exactly the OTLP document that would have been
POSTed.

## trace.DEFAULTS

The defaults `trace.new` applies.

| key | value |
|---|---|
| `endpoint` | `"http://localhost:4318/v1/traces"` |
| `service` | `"akkar"` |
| `max_batch` | `256` |
| `max_queue` | `2048` |
| `interval` | `5` |
| `timeout` | `2` |

## trace.Exporter

The metatable every exporter shares.

## trace.KIND

The OTLP span kinds: `INTERNAL = 1`, `SERVER = 2`, `CLIENT = 3`,
`PRODUCER = 4`, `CONSUMER = 5`.

## trace.nanoseconds(seconds)

Seconds since the epoch as a string of nanoseconds, computed in 64-bit integer
arithmetic so the digits are not invented by a double.

**Returns** a string.

## trace.new(options)

Builds an exporter. Everything is optional, but an exporter with no `http`
capability drops every batch.

| field | type | default | meaning |
|---|---|---|---|
| `http` | client or function | none | an `akkar.http` capability, or a factory returning one. Anything with a `post(url, options)` method works. |
| `endpoint` | string | `"http://localhost:4318/v1/traces"` | where a batch is posted |
| `headers` | table | none | extra headers on the export request, for an API key |
| `service` | string | `"akkar"` | becomes the resource attribute `service.name` |
| `resource` | table | `{}` | further resource attributes, merged over `service.name` |
| `max_batch` | number | `256` | spans that make an export due by size |
| `max_queue` | number | `2048` | spans held before new ones are dropped |
| `interval` | number | `5` | seconds that make an export due by time |
| `timeout` | number | `2` | seconds one export may take |
| `sampler` | function | none | called with the request; a falsy answer means no span |

**Returns** an exporter.

**Raises** nothing. An unknown option is ignored.

```lua
local trace = require "akkar.trace"

-- An `akkar.http` capability is anything with a `post` method. A real one
-- comes from `akkar.http.connect {}`.
local sent = {}
local collector = {
  post = function(_, _, options) sent[#sent + 1] = options.body return { status = 200 } end,
}

local exporter = trace.new { http = collector, service = "tasks" }

local span = exporter:start_span { name = "charge card", kind = trace.KIND.CLIENT }
span:set("payment.provider", "stripe")
span:finish { status = "ok" }

print(exporter:stats().recorded)   --> 1
print(exporter:stats().queued)     --> 1
print(exporter:flush())            --> true
print(exporter:stats().exported)   --> 1
print(sent[1].resourceSpans[1].scopeSpans[1].spans[1].name)   --> charge card
```

## trace.otlp(spans, resource)

Builds the OTLP/HTTP JSON payload for a list of spans. `resource` is a table
of resource attributes.

Exported so a test can assert on the exact shape that would go on the wire
without a collector.

A span in the list is a plain table with `trace_id`, `span_id`, `name`,
`kind`, `start_time`, `duration`, `attributes`, and optionally
`parent_span_id`, `status` and `status_message`. `parentSpanId` is omitted
rather than sent empty, and `status` is omitted when it is `UNSET`.

**Returns** a table ready for `akkar.json.encode`.

```lua
local trace = require "akkar.trace"
local json  = require "akkar.json"

local payload = trace.otlp({
  {
    trace_id   = "4bf92f3577b34da6a3ce929d0e0e4736",
    span_id    = "00f067aa0ba902b7",
    name       = "GET /tasks/:id",
    kind       = trace.KIND.SERVER,
    start_time = 1755000000,
    duration   = 0.0125,
    attributes = { ["http.response.status_code"] = 200 },
  },
}, { ["service.name"] = "tasks" })

print(json.encode(payload.resourceSpans[1].scopeSpans[1].spans[1]))
```

## trace.Span

The metatable every span shares.

## trace.span_id()

An 8-byte span id as 16 hex characters, from the operating system's CSPRNG.

**Returns** a string.

## trace.STATUS

The OTLP status codes: `UNSET = 0`, `OK = 1`, `ERROR = 2`. `UNSET` is not
"unknown", it is "nobody claimed this span succeeded or failed", which is the
right answer for most spans.

## trace.trace_id()

A 16-byte trace id as 32 hex characters, from the operating system's CSPRNG
rather than `math.random`, so two processes starting at the same moment do not
mint the same ids.

**Returns** a string.

## trace.traceparent(trace_id, span_id, sampled)

Renders a `traceparent` header value. The version is `00` and `sampled` sets
the low bit of the flags byte.

**Returns** a string, `00-<32 hex>-<16 hex>-<2 hex>`.

```lua
local trace = require "akkar.trace"

local trace_id = trace.trace_id()
local span_id  = trace.span_id()

print(#trace_id, #span_id)                              --> 32  16
print(trace.traceparent(trace_id, span_id, true))       --> 00-<32>-<16>-01
print(trace.traceparent(trace_id, span_id, false))      --> 00-<32>-<16>-00
print(trace.nanoseconds(1755000000.25))                 --> 1755000000250000000
```

## Exporter

### exporter:client()

Resolves the `http` capability once and keeps it. A factory is called on the
first use, not on every flush.

**Returns** the client, or `nil` when none was configured or the factory
raised.

### exporter:due()

Whether an export is due: the queue is not empty, and either it has reached
`max_batch` or `interval` seconds have passed since the last flush.

**Returns** `true` or `false`.

### exporter:flush()

Exports what is queued, now.

The queue is swapped for an empty one **before** the network call, so spans
recorded while the export is in flight are kept for the next batch.

A failed export drops its batch. It is not retried: the requests those spans
describe were answered either way, and a retry buffer grows for as long as the
collector is gone. Failures are counted, not raised.

**Not to be called from a handler or from middleware.** Everything in it can
wait on a network.

**Returns** `true`, or `nil` and a reason string:

| reason | when |
|---|---|
| `akkar.trace has no http capability` | `http` was not configured, or the factory raised |
| `status <n>` | the collector answered 400 or above |
| the error text | the transport raised, a DNS failure for instance |

### exporter:middleware(options)

Server-span middleware, for `app:use`.

It continues the caller's trace when `req.trace` is present, using that trace
id and the caller's span id as the parent. akkar has already validated the
inbound header, so a malformed one starts a fresh trace rather than joining a
corrupt one. When the caller's decision was not to sample, no span is made.

The span is exposed to the handler as `req.span`. Nothing is written onto the
response: the handler's value comes back exactly as it was returned.

| option | type | default | meaning |
|---|---|---|---|
| `name` | function | `req.method .. " " .. req.route` | names the span, called after the handler ran so `req.route` exists |
| `sampler` | function | none | called with the request; a falsy answer means no span |

The span name uses the route pattern, not the path, so `/tasks/7` and
`/tasks/8` are one operation. Attributes set: `http.request.method`,
`url.path`, `http.response.status_code`, and `akkar.request_id`, which is
`req.id` -- the same value `req.log` writes as `request_id` and the response
carries as `x-request-id`. It sits under akkar's own namespace because the
semantic conventions define no request-id attribute, and their one
header-shaped attribute records what the client sent, which `req.id` is not. Status is `ERROR` for a raised error
or a 5xx, and left `UNSET` for a 4xx, which is OpenTelemetry's own rule for a
server span.

**Returns** a middleware function.

```lua
local akkar = require "akkar"
local trace = require "akkar.trace"

local sent = {}
local collector = {
  post = function(_, _, options) sent[#sent + 1] = options.body return { status = 200 } end,
}
local exporter = trace.new { http = collector, service = "tasks" }

local app = akkar.new()
app:use(exporter:middleware())
app:get("/tasks/:id", function(req) return { id = req.params.id } end)

local client = app:test {}
print(client:get("/tasks/7").status)     --> 200
print(client:get("/tasks/8").status)     --> 200

exporter:flush()
local spans = sent[1].resourceSpans[1].scopeSpans[1].spans
print(#spans)                            --> 2
print(spans[1].name)                     --> GET /tasks/:id
print(spans[1].kind)                     --> 2
```

### exporter:record(span)

Queues a finished span. `span:finish` calls this; call it yourself only for a
span you built by hand.

The whole function is an append. It encodes nothing and opens no socket,
because it runs on the request's coroutine. When the queue holds `max_queue`
spans the newest is refused rather than the oldest evicted, and `dropped` is
incremented.

**Returns** `true` when the span was kept, `false` when it was dropped.

### exporter:run(controller)

Starts the flush loop on a cqueues controller. Call it once, at startup, from
inside the loop akkar runs on.

The loop wakes every `min(interval / 4, 1)` seconds and calls `tick`, which
flushes when `due()`. One bad tick cannot end the loop.

**Returns** the exporter.

**Raises** `akkar.trace: run() needs a cqueues controller; call it from inside
the loop akkar runs on, or pass one` when there is no running controller and
none was passed.

### exporter:start_span(options)

Starts a span.

| option | type | default | meaning |
|---|---|---|---|
| `name` | string | `"span"` | the span name |
| `kind` | number | `KIND.INTERNAL` | one of `trace.KIND` |
| `trace_id` | string | a new one | the trace to join |
| `parent_span_id` | string | none | the parent within that trace |
| `sampled` | boolean | `true` | carried into `span:traceparent()` |
| `attributes` | table | `{}` | the span's attributes, used as given |

**Returns** a span. Despite what the source docstring says, it never returns
`nil`: the sampling decision is made in the middleware, which does not call
this when a trace is not sampled.

### exporter:stats()

The counters. Put `dropped` and `failed` on a dashboard: a trace with holes in
it and no counter is a trace nobody can explain.

**Returns** a table.

| field | meaning |
|---|---|
| `queued` | spans waiting right now |
| `recorded` | spans handed to `record`, kept or not |
| `dropped` | spans refused by a full queue, plus every span in a batch that failed to export |
| `exported` | spans a collector accepted |
| `failed` | batches that failed |
| `batches` | batches attempted |

```lua
local trace = require "akkar.trace"

local exporter = trace.new { max_queue = 2 }      -- and no http capability

for i = 1, 3 do exporter:start_span { name = "n" .. i }:finish() end

print(exporter:stats().recorded)   --> 3
print(exporter:stats().queued)     --> 2
print(exporter:stats().dropped)    --> 1, the third was refused
print(exporter:flush())            --> nil, akkar.trace has no http capability
print(exporter:stats().dropped)    --> 3, the batch went too
```

### exporter:stop()

Stops the loop and exports once more.

**Returns** what `flush` returns.

### exporter:tick()

Flushes if either bound has been reached, and does nothing otherwise. This is
what the loop calls, and what a test drives instead of waiting.

**Returns** `true` when it flushed, `false` when nothing was due.

## Span

### span:finish(options)

Ends the span, measures its duration against the monotonic clock, and hands it
to the exporter. Finishing a span twice does nothing the second time.

| option | type | meaning |
|---|---|---|
| `status` | number or string | a `trace.STATUS` value, or `"ok"` or `"error"` |
| `message` | string | the status message |
| `attributes` | table | merged over the attributes already set |

**Returns** the span.

### span:set(key, value)

Sets one attribute.

**Returns** the span, so calls chain.

### span:traceparent()

The `traceparent` header to send on an outbound call made inside this span, so
the next service joins this trace.

```lua no-run
local res = req.http:get(url, { traceparent = req.span:traceparent() })
```

**Returns** a string.

## Timestamps

A span carries a wall-clock start so a human can find it, and a duration
measured on the monotonic clock so an NTP step cannot make it negative.

The start comes from `akkar.time.now()`, which is `os.time` and has
**one-second resolution**. Two spans that began in the same second sort
arbitrarily against each other by start time, while their durations are
accurate to microseconds.

`endTimeUnixNano` is computed as `start_time + duration` in floating point
before being split into nanoseconds, so its last digits drift by tens of
nanoseconds. `startTimeUnixNano` does not: it goes through the integer path.

## Correlation with logs

A span and a log line from the same request share two keys, one in each
direction. `req.log` carries `trace_id` and `span_id` once the middleware has
started a span (and the inbound trace's ids even when it has not); the server
span carries `akkar.request_id`. Either one leads to the other, and a log
line from a request with no trace carries neither key rather than an empty
one. See [akkar.log](log.md#loggerwithfields).

```lua
local akkar = require "akkar"
local trace = require "akkar.trace"
local log   = require "akkar.log"
local json  = require "akkar.json"

local lines = {}
local logger = log.new { format = "json", sink = function(line) lines[#lines + 1] = line end }
local exporter = trace.new {}

local app = akkar.new()
app:use(exporter:middleware())
app:get("/tasks/:id", function(req) req.log:info("looked up") return { id = req.params.id } end)

local res = app:test({ log = logger }):get "/tasks/7"
local span = exporter.queue[1]
local line = json.decode(lines[1])

print(line.trace_id == span.trace_id)                              --> true
print(line.span_id == span.span_id)                                --> true
print(span.attributes["akkar.request_id"] == res.headers["x-request-id"])   --> true
```

## Not here

- **Client spans around outbound HTTP.** `akkar.http` sends a `traceparent`,
  and `span:traceparent()` supplies it, but nothing wraps an outbound call in
  a span for you.
- **Database or cache spans.** Only the server span exists, from
  `exporter:middleware()`.
- **Retry of a failed export.** By design. The batch is dropped and counted.
- **Metrics or logs over OTLP.** Spans only. Metrics are
  [akkar.metrics](metrics.md), a Prometheus scrape.
- **Protobuf.** The payload is OTLP/HTTP JSON, generated here.
- **Head sampling by ratio.** `sampler` is a function you write. There is no
  `ratio = 0.1`.

## See also

- [akkar](akkar.md) for `req.trace`, the validated inbound `traceparent`, and
  for `app:use`
- [akkar.metrics](metrics.md) for the aggregate view of the same requests
- the module source, `akkar/trace.lua`, for why a request is never blocked on
  an export
