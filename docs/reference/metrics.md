# akkar.metrics

A Prometheus registry with no dependency: a request counter, a latency
histogram, gauges, and a `GET /metrics` endpoint that renders them as text.
Requests are labelled by route pattern, never by request path.

**When you need it.** Something scrapes this process for a request rate, an
error rate and a latency distribution, and you want the numbers to come from
inside the runtime rather than from a proxy in front of it.

```lua no-run
local metrics = require "akkar.metrics"
```

## Contents

- [metrics.DEFAULT_BUCKETS](#metricsdefault_buckets)
- [metrics.new(options)](#metricsnewoptions)
- [metrics.Registry](#metricsregistry)
- [Registry](#registry)
  - [registry:counter(name, delta, labels)](#registrycountername-delta-labels)
  - [registry:gauge(name, value, labels)](#registrygaugename-value-labels)
  - [registry:memory()](#registrymemory)
  - [registry:middleware()](#registrymiddleware)
  - [registry:observe(method, route, status, seconds)](#registryobservemethod-route-status-seconds)
  - [registry:render()](#registryrender)
  - [registry:serve(app, path, sources)](#registryserveapp-path-sources)
- [What is exported](#what-is-exported)
- [Not here](#not-here)

## metrics.DEFAULT_BUCKETS

The histogram bucket edges, in seconds:
`0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10`.

Chosen for an API talking to a database. Below a millisecond is noise, and past
10 seconds a request has already hit the default deadline.

## metrics.new(options)

Builds a registry. Counters start empty and the uptime clock starts now.

| field | type | default | meaning |
|---|---|---|---|
| `buckets` | table | `metrics.DEFAULT_BUCKETS` | histogram edges in seconds, ascending |

**Returns** a registry.

**Raises** nothing.

```lua
local metrics = require "akkar.metrics"

local registry = metrics.new()

registry:observe("GET", "/users/:id", 200, 0.012)
registry:observe("GET", "/users/:id", 404, 0.003)

io.write(registry:render())
```

## metrics.Registry

The metatable every registry shares. Exported for a test that wants to
identify one.

## Registry

### registry:counter(name, delta, labels)

Increments an application counter, creating it at zero on first use. `delta`
defaults to `1` and may be fractional; `labels` is a list of `{ name, value }`
pairs, in the order they should be rendered.

`name` is used verbatim as the Prometheus metric name, so it must already be a
valid one. Nothing here prefixes it with `akkar_`.

**Returns** the new value.

**Raises** on a `name` that is not a Prometheus metric name, on a `delta` that
is not a non-negative number, and on a label name that is not a Prometheus
label name. Each is a mistake at the call site, fixed once.

Does NOT raise when a counter name accumulates too many distinct label
combinations. Past 64 of them, every further combination folds into a single
series whose label values are `<other>` -- the same answer
`registry:middleware()` gives a method it does not recognise, and for the same
reason. The total stays correct and the breakdown stops growing.

That bound exists because this is the one place in the module where the label
values are yours rather than akkar's. The `route` label is bounded because
akkar knows the pattern that matched; a counter labelled with an order id is
a series per order, which is how a metrics backend falls over. Folding rather
than raising is deliberate: a counter must not be able to fail the request it
is measuring.

```lua
local metrics = require "akkar.metrics"

local registry = metrics.new()

registry:counter("commerce_checkouts_total", 1, { { "result", "created" } })
registry:counter("commerce_checkouts_total", 2, { { "result", "created" } })
registry:counter("commerce_checkouts_total", 1, { { "result", "declined" } })
registry:counter("commerce_retries_total")            -- no labels, delta 1

local text = registry:render()
assert(text:find('commerce_checkouts_total{result="created"} 3', 1, true))
assert(text:find("\ncommerce_retries_total 1\n", 1, true))
```

### registry:gauge(name, value, labels)

Sets a gauge, for a number that is read rather than counted: pool occupancy,
queue depth, in-flight requests. Setting the same name again replaces the
value.

`name` is used verbatim as the Prometheus metric name, so it must already be a
valid one. Nothing here prefixes it with `akkar_`.

**Returns** nothing.

**Raises** `invalid value (table) at index 2 in table for 'concat'` when
`labels` is given. The third argument is not usable: the key the gauge is
stored under is built by concatenating the arguments, and a table cannot be
concatenated. `render()` does know how to emit labels, so this is a defect and
not a design. Until it is fixed, put anything distinguishing into `name`.

```lua
local metrics = require "akkar.metrics"

local registry = metrics.new()

registry:gauge("akkar_pool_in_use", 3)
registry:gauge("akkar_pool_in_use", 4)   -- same name, replaced

local lua_bytes, rss_bytes = registry:memory()
print(lua_bytes > 0, rss_bytes >= 0)     --> true  true

io.write(registry:render())
```

### registry:memory()

Two memory numbers, because they answer different questions. Lua's own heap
says whether the application is holding on to tables; the resident set says
what the operating system thinks the process costs, including the C side.

**Returns** `lua_bytes, rss_bytes`, both numbers. `rss_bytes` is `0` where
`/proc/self/statm` cannot be read.

### registry:middleware()

Middleware that records every request into this registry.

The route label is `req.route`, the pattern that matched, so the label set
stays bounded however many distinct paths are requested. A request that
matched no route is recorded as `<unmatched>` rather than by its path.

The method label is bounded the same way, and needed to be: `req.method` is
whatever token the client put on the request line, so it went straight into a
label and a caller sending a fresh verb per request minted a fresh series per
request. Bounding one of two labels bounds nothing. Anything outside the nine
HTTP methods -- `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`,
`TRACE`, `CONNECT` -- is recorded as `<other>`.

Both outcomes are recorded. A handler that returns gives its response status;
a handler that throws a response gives that response's status; a raised error
is recorded as `500`, and then re-raised unchanged.

**Returns** a middleware function, for `app:use`.

### registry:observe(method, route, status, seconds)

Records one request by hand. `registry:middleware()` calls this; call it
yourself for work that is not an HTTP request but belongs in the same
histogram.

| argument | type | meaning |
|---|---|---|
| `method` | string | the label `method` |
| `route` | string | the label `route`. A pattern, not a path. |
| `status` | number or string | the label `status`, stringified |
| `seconds` | number | duration, added to the histogram and its sum |

**Returns** nothing.

### registry:render()

The whole registry in Prometheus text format, ending with a newline. Series
are sorted, so two scrapes of unchanged state produce identical text.

Always present:

| metric | type | labels |
|---|---|---|
| `akkar_requests_total` | counter | `method`, `route`, `status` |
| `akkar_request_duration_seconds_bucket` | histogram | `method`, `route`, `le` |
| `akkar_request_duration_seconds_sum` | histogram | `method`, `route` |
| `akkar_request_duration_seconds_count` | histogram | `method`, `route` |
| `akkar_uptime_seconds` | gauge | none |

Counters and gauges are rendered only when at least one has been set, each
with a `# TYPE` line written once per name.

**Returns** a string.

### registry:serve(app, path, sources)

Registers `GET <path>` on `app`, answering with the rendered registry as
`text/plain; version=0.0.4`.

| argument | type | default | meaning |
|---|---|---|---|
| `app` | app | none, required | the app to register on |
| `path` | string | `"/metrics"` | where the endpoint lives |
| `sources` | table | `{}` | gauge name to a function returning a number, read at scrape time |

Two gauges are always set at scrape time: `akkar_lua_heap_bytes` and
`akkar_process_resident_bytes`. A source that raises, or returns something
other than a number, is skipped and does not fail the scrape.

The endpoint is a plain route, so any middleware installed before it applies to
it. Exempt it from a rate limiter if you install one.

**Returns** the app, so the call chains.

```lua
local akkar   = require "akkar"
local metrics = require "akkar.metrics"

local app      = akkar.new()
local registry = metrics.new()

app:use(registry:middleware())
app:get("/users/:id", function(req) return { id = req.params.id } end)
registry:serve(app, "/metrics", { queue_depth = function() return 3 end })

local client = app:test {}
client:get "/users/42"
client:get "/users/43"

local scrape = client:get "/metrics"
print(scrape.status)                                       --> 200
print((scrape.raw:match "akkar_requests_total{[^\n]*"))
print((scrape.raw:match "\nqueue_depth (%S+)"))            --> 3
```

The scrape body is `scrape.raw`, not `scrape.body`: the endpoint answers with
a raw string rather than a table. The content type is on the response object
and the in-process test client does not surface it in `headers`.

## What is exported

`metrics.new`, `metrics.Registry` and `metrics.DEFAULT_BUCKETS`, and the
methods above. There is no module-level counter and no global registry: a
registry is a value you hold.

## Not here

- **Summaries and quantiles.** They cannot be aggregated across processes, and
  this runtime's answer to more CPU is more processes.
- **An unbounded label space.** `registry:counter` takes labels of your own
  naming, and stops at 64 combinations per counter name. See it above for why.
- **Labels on a gauge.** See `registry:gauge` above.
- **Pushing.** Nothing is sent anywhere. Something scrapes the endpoint.
- **Aggregation across processes.** Each process has its own registry and its
  own uptime. Summing them is the scraper's job.

## See also

- [akkar](akkar.md) for `app:use`, `req.route` and `app:test{}`
- [akkar.trace](trace.md) for per-request spans, which answer "why was this
  one slow" where a histogram answers "how many were"
- the module source, `akkar/metrics.lua`, for why the route pattern is the
  label and the path is not
