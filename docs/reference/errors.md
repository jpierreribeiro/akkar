# akkar.errors

The failure behind a 500, captured with the request's context and delivered to
something that keeps it. Capturing appends to a table; the delivery happens on
a background loop, never on the request.

**When you need it.** A handler raised in production, the client got
`{"error": "internal server error"}`, and the only record of *why* is a line
on stderr in whichever container happened to serve it.

```lua no-run
local errors = require "akkar.errors"
```

`app:on_error` has documented this hook since early on and akkar shipped
nothing on the other end of it. This is that end. It is **not** the Sentry
envelope protocol: it POSTs one JSON document to one URL, so it can be pointed
at Sentry through a relay, at an OpenTelemetry collector's HTTP receiver, at
Loki, at a Lambda, or at four lines of your own that append to a file.

## Contents

- [errors.new(options)](#errorsnewoptions)
- [errors.DEFAULTS](#errorsdefaults)
- [errors.REDACTED](#errorsredacted)
- [errors.sanitise(value, limit)](#errorssanitisevalue-limit)
- [errors.Reporter](#errorsreporter)
- [Reporter](#reporter)
  - [reporter:capture(err, req, extra)](#reportercaptureerr-req-extra)
  - [reporter:due()](#reporterdue)
  - [reporter:encode(batch)](#reporterencodebatch)
  - [reporter:event(err, req, extra)](#reportereventerr-req-extra)
  - [reporter:flush()](#reporterflush)
  - [reporter:handler(inner)](#reporterhandlerinner)
  - [reporter:run(controller)](#reporterruncontroller)
  - [reporter:stats()](#reporterstats)
  - [reporter:stop()](#reporterstop)
  - [reporter:tick()](#reportertick)
- [The event](#the-event)
- [The document on the wire](#the-document-on-the-wire)
- [What never reaches the client](#what-never-reaches-the-client)
- [What never reaches the sink](#what-never-reaches-the-sink)
- [Correlation](#correlation)
- [Not here](#not-here)

## errors.new(options)

Builds a reporter.

| key | default | what it is |
|---|---|---|
| `sink` | — | `function(document, events)`, called with what would have been POSTed |
| `http` | — | an `akkar.http` capability: a client, or a factory returning one |
| `endpoint` | — | the URL to POST to; required with `http` |
| `headers` | — | headers sent with every POST, for an API token |
| `service` | `"akkar"` | the service name, on every event and on the document |
| `environment` | — | on every event when set; omitted entirely when not |
| `max_batch` | `32` | events per delivery |
| `max_queue` | `256` | events held before new ones are refused |
| `interval` | `5` | seconds between deliveries |
| `timeout` | `2` | seconds a POST may take |
| `max_message` | `512` | bytes of message kept |

**Raises** when given neither `sink` nor `http`, and when given `http` with no
`endpoint`. That is deliberate and it is the one place this module raises:
construction happens once, at boot, where a misconfigured reporter is a typo
somebody can still fix. Everything after boot counts rather than raises,
because by then a request has already failed and the reporter must not make it
worse.

```lua
local akkar  = require "akkar"
local errors = require "akkar.errors"

local kept = {}
local reporter = errors.new {
  service = "checkout",
  sink    = function(document)
    for _, event in ipairs(document.events) do kept[#kept + 1] = event end
  end,
}

local app = akkar.new()
app:on_error(reporter:handler())
app:get("/orders/:id", function() error("no such tenant", 0) end)

local res = app:test():get "/orders/9f2b"

-- The client learns nothing it did not already know.
print(res.status, res.body.error)          --> 500  internal server error

-- Nothing was delivered on the request; the loop does that.
print(reporter:stats().queued)             --> 1
reporter:flush()

print(kept[1].message)                     --> no such tenant
print(kept[1].method, kept[1].route)       --> GET  /orders/:id
print(kept[1].request_id == res.headers["x-request-id"])   --> true
```

## errors.DEFAULTS

The defaults `errors.new` applies.

| key | value |
|---|---|
| `service` | `"akkar"` |
| `max_batch` | `32` |
| `max_queue` | `256` |
| `interval` | `5` |
| `timeout` | `2` |
| `max_message` | `512` |

Both bounds are smaller than `akkar.trace`'s 256 and 2048, and the ratio is
the argument: a span is emitted per request and an error is not, so a queue
holding 256 errors is a service in an incident — and 256 of them describe that
incident exactly as well as 2048 would, while the shorter batch means the
first ones arrive sooner, which is when somebody is looking.

## errors.REDACTED

The string `"[redacted]"`, which is what `akkar.config` also renders a secret
as. One spelling, whether the secret was caught by construction there or by
pattern here.

## errors.sanitise(value, limit)

The message that goes on an event: one line, bounded, with the obvious
credentials taken out.

- Everything from `stack traceback:` onward is cut.
- Control characters and runs of whitespace become one space.
- A URL with credentials in it loses the password.
- `key = value` and `key: value` lose the value, for the usual key names,
  whatever the case.
- `Bearer <token>` loses the token.
- The result is truncated to `limit` bytes (default `512`) without splitting a
  UTF-8 sequence, and gains ` [truncated]` when it was.

A table is read for a `message`, `error` or `detail` string before being
stringified, so a raised table does not arrive as `table: 0x55f3...` — an
address that differs on every run, and would therefore group separately in
whatever reads these.

**The redaction is a floor, not a guarantee.** It catches what a driver or an
HTTP client actually raises. It cannot catch a secret that does not look like
one; the defence that does not depend on pattern matching is `akkar.config`,
whose secrets render as `[redacted]` through `__tostring` and `__concat` and
so never reach a message at all.

```lua
local errors = require "akkar.errors"

print(errors.sanitise "could not connect to postgres://app:hunter2@db:5432/x")
--> could not connect to postgres://app:[redacted]@db:5432/x

print(errors.sanitise 'refused: api_key: k-abc123')
--> refused: api_key: [redacted]

print(errors.sanitise "boom\nstack traceback:\n\t/srv/app/handlers.lua:19")
--> boom

print(errors.sanitise { message = "no such tenant" })
--> no such tenant
```

## errors.Reporter

The reporter metatable, exported so a spec can extend it. It inherits
`trace.Batch` — the queue, the two bounds and the background loop are one
implementation shared with `akkar.trace`, because the argument for each of
those choices is the same argument and writing it twice is how the second copy
goes subtly wrong.

## Reporter

### reporter:capture(err, req, extra)

Builds the event and queues it. **Returns** `true` when it was kept, `false`
when the queue was full.

An append. No socket, no encoding beyond the event itself, no decision that
can take time — it runs on the failing request's coroutine, and everything it
does is time a user is already waiting for.

`req` may be nil: a job runner has none, and `app:on_error` documents that the
request "may be absent for a failure that happened before one existed". Every
request field is then simply missing, rather than present and empty.

`extra` is merged in last and **cannot override** a field the reporter set, so
a passed `route` cannot quietly become a raw path and a passed `message`
cannot bypass the sanitiser.

```lua
local errors = require "akkar.errors"

local seen
local reporter = errors.new { sink = function(d) seen = d.events end }

reporter:capture("the nightly rollup fell over", nil, { job = "rollup" })
reporter:flush()

print(seen[1].message, seen[1].job)   --> the nightly rollup fell over  rollup
print(seen[1].route)                  --> nil
```

### reporter:due()

Whether a delivery is due, by either bound: `max_batch` events queued, or
`interval` seconds since the last one. **Returns** `false` for an empty queue.

### reporter:encode(batch)

The document a batch becomes. **Returns** a table; `akkar.http` encodes it as
JSON.

### reporter:event(err, req, extra)

Builds one event without queueing it. **Returns** a plain table. Useful for a
destination this module does not speak to, and for asserting on the shape.

### reporter:flush()

Delivers what is queued, now. **Returns** `true`, or `nil` and a reason.

**Not to be called from a handler or from middleware.** Everything in it can
wait on a network. It exists to be called from `run`, and from a test.

A failed delivery **drops the batch** rather than retrying it. Retrying moves
the growth from this queue into a retry buffer and buys nothing: the request
each event describes was answered either way.

### reporter:handler(inner)

**Returns** a `function(err, req)` for `app:on_error`.

It captures, then returns `nil` — which akkar reads as "the hook declined", so
the client receives the built-in bare 500, unchanged. Pass `inner` to answer
with your own body; it runs *after* the capture, and outside any `pcall` of
ours, so a bug in it cannot lose the event and `internal_error` still logs
"the error handler itself raised".

```lua
local akkar  = require "akkar"
local errors = require "akkar.errors"

local reporter = errors.new { sink = function() end }

local app = akkar.new()
app:on_error(reporter:handler(function(_, req)
  return akkar.response(500, { instance = req.id })
end))
app:get("/boom", function() error("x", 0) end)

local res = app:test():get "/boom"
print(res.status, res.body.instance == res.headers["x-request-id"])
--> 500  true
```

### reporter:run(controller)

Starts the delivery loop on a cqueues controller. Call it once, at startup,
from inside the loop akkar runs on. **Returns** the reporter.

```lua no-run
app:run {
  port = 3000,
  on_start = function() reporter:run() end,
}
```

**Raises** when there is no controller and none was passed, rather than
silently never delivering.

### reporter:stats()

The counters. **Returns** a table.

| key | what it counts |
|---|---|
| `queued` | events waiting now |
| `recorded` | events captured, including the refused ones |
| `dropped` | events refused by the bound, plus every event in a failed batch |
| `exported` | events delivered |
| `failed` | batches that did not arrive |
| `batches` | deliveries attempted |

Put `dropped` and `failed` on a dashboard. Dropping is correct behaviour;
dropping *silently* is not, and an operator watching `dropped` climb knows
their tracker is unreachable rather than having a tracker with holes in it and
no idea why.

### reporter:stop()

Stops the loop, after one last delivery.

### reporter:tick()

Delivers if either bound has been reached. **Returns** `true` when it
delivered. This is what the loop calls.

## The event

| key | present when | what it is |
|---|---|---|
| `timestamp` | always | seconds since the epoch, from `akkar.time` |
| `level` | always | `"error"` |
| `service` | always | the `service` given to `errors.new` |
| `message` | always | the sanitised message |
| `status` | always | `500`, the status akkar is about to answer |
| `environment` | when configured | the `environment` given to `errors.new` |
| `request_id` | with a request | the same id the client got in `x-request-id` |
| `method` | with a request | `"GET"` |
| `route` | a route was matched | the **pattern**, `/orders/:id` |
| `trace_id` | the request carries a trace | joins to the span and the log line |
| `span_id` | the request carries a trace | the local span, else the caller's |

`route` is the pattern and not the path, and there is deliberately no fallback
to `req.path` when no route was matched. `/orders/9f2b` and `/orders/7c41` are
one operation; a tracker that groups by raw path produces one group per order
id, which is a tracker that has stopped grouping anything. A fallback would
put that back exactly on the errors that are hardest to read.

## The document on the wire

```lua
local errors = require "akkar.errors"
local json   = require "akkar.json"

local posted
local reporter = errors.new {
  service  = "checkout",
  endpoint = "https://errors.internal/ingest",
  headers  = { authorization = "Token abc" },
  http     = { post = function(_, url, options)
    posted = { url = url, body = options.body }
    return { status = 202 }
  end },
}

reporter:capture "the queue worker gave up"
reporter:flush()

print(posted.url)                       --> https://errors.internal/ingest
print(json.encode(posted.body.service)) --> "checkout"
print(#posted.body.events)              --> 1
```

An object with the events in a list, rather than a bare top-level array:
`service` belongs to the batch rather than being repeated on every event, and
a document that is already an object can grow a field later without changing
its type.

`http` is an `akkar.http` capability — a client or a factory, the same shape
`app:run { http = ... }` takes, and not a URL and a socket library. That is
what makes the table with a `post` method above a legitimate stand-in for the
real thing.

## What never reaches the client

The 500 is unchanged by installing this. `akkar/init.lua` keeps that body
deliberately bare — a Lua error carries file paths, line numbers and sometimes
SQL — and `reporter:handler()` returns nil rather than a body precisely so it
stays that way. The request id in `x-request-id` is the join: the client
quotes it, you find the event.

## What never reaches the sink

The traceback, ever. And the raw message: the destination is usually a third
party, the text of a failure is frequently influenced by whoever caused it,
and an unbounded field is both a leak and a bill. Hence `errors.sanitise`, and
hence `max_message`.

## Correlation

Three corners of the same join, and each is in a different file:

- `akkar/execution.lua` binds `trace_id` and `span_id` onto `req.log`;
- `akkar/trace.lua` puts `akkar.request_id` on the server span;
- this module puts `request_id`, `trace_id` and `span_id` on the event.

So an event in the tracker leads to the span in Jaeger and to the lines on
stderr, in any direction, without a timestamp search.

```lua
local akkar  = require "akkar"
local errors = require "akkar.errors"
local trace  = require "akkar.trace"

local event
local reporter = errors.new { sink = function(d) event = d.events[1] end }
local exporter = trace.new { http = { post = function() return { status = 200 } end } }

local app = akkar.new()
app:on_error(reporter:handler())
app:use(exporter:middleware())
app:get("/orders/:id", function() error("boom", 0) end)

app:test():get("/orders/1", {
  headers = { traceparent =
    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
})
reporter:flush()

print(event.trace_id)   --> 4bf92f3577b34da6a3ce929d0e0e4736
print(event.route)      --> /orders/:id
```

## Not here

**The Sentry envelope protocol.** A newline-delimited envelope, item types, a
DSN carrying a project id and a public key, a client handshake — one vendor's
format, on their release schedule, untestable here without an account. A
generic JSON POST reaches the same place through a relay and reaches
everything else directly.

**Grouping, fingerprinting and deduplication.** That is the tracker's job and
it is the reason to have one. This delivers events; it does not decide which
of them are the same event.

**Retries.** See `reporter:flush()`.

**Breadcrumbs and local variables.** Both mean carrying state through a
request for the benefit of a failure that usually does not happen. `req.log`
already writes the interesting ones down, with the same `trace_id` on them.
