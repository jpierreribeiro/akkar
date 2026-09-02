--[[
akkar.trace — spans out, over `akkar.http`, and never on the request's clock.

## What was already here, and what was missing

akkar has spoken half of W3C Trace Context since early on. `akkar/init.lua`
parses an inbound `traceparent`, validates it rather than trusting it -- a
malformed trace id forwarded onward corrupts somebody else's trace as well as
this one -- exposes it as `req.trace`, and echoes it back on the response.
`akkar/http.lua` sends one onward on an outbound call, and its own comment
records why: *a trace that stops at the process boundary is a trace of one
process.*

What did not exist was the third piece: something that CREATES a span for the
work akkar did and EXPORTS it, so the trace is visible somewhere other than in
the headers of a request nobody kept. `spec/trace_spec.lua` said so plainly --
"it does not create spans or export them: that is an OpenTelemetry dependency
and an adapter" -- and this is that adapter, built the way every other one here
is built: over a capability akkar owns, with the transport a detail.

## THE ONE RULE: A REQUEST IS NEVER BLOCKED ON AN EXPORT

This is the whole design and everything else follows from it.

A tracing backend is a thing that goes down. It is usually somebody else's
service, it is frequently the first thing to fall over in the incident you are
trying to trace, and it is never on the critical path of answering a user. A
runtime that posts a span inline has arranged for its own p99 to be the
collector's p99 plus its own -- so the observability system becomes an outage
amplifier, which is the precise opposite of the reason it was installed.

akkar runs one coroutine at a time on a cooperative scheduler
(`akkar/crypto.lua` documents what that costs when something blocks), so
"inline" here is worse than a slow response: an export waiting on a dead
collector's TCP timeout is time in which akkar answers NOBODY.

So `record` does one thing: it appends to a table. No socket, no encoding, no
allocation beyond the span itself. The export happens in `flush`, which is
called from a background loop, and the middleware in this file never calls it.
`spec/trace_spec.lua` proves that by handing the exporter an HTTP client that
raises on contact and then serving requests through it: the responses are 200
and the client was never touched.

## DROPPING SPANS IS THE CORRECT BEHAVIOUR, AND IT IS NOT A COMPROMISE

The queue is bounded. When it is full, `record` refuses the span, increments a
counter, and returns. It does not grow, it does not block, and it does not
wait.

Say it the other way round and it is obvious: the alternative to dropping a
span is holding it, and holding spans while the collector is unreachable means
the buffer grows for as long as the outage lasts. A tracing outage then becomes
a memory exhaustion in the service being traced, which is a real way to turn an
incident in a system you do not own into an incident in one you do.

The same reasoning applies to a failed export: **the batch is dropped, not
retried.** Retrying moves the growth from the queue into a retry buffer and
changes nothing. Spans are the most disposable data in the system -- each one
describes work that already completed successfully or unsuccessfully on its
own terms, and the request it describes was answered either way.

What is NOT acceptable is dropping silently, so `:stats()` counts every drop
and every failed batch, and those counters are the thing to put on a dashboard.
An operator who sees `dropped` climbing knows their sampling is too generous or
their collector is gone; an operator with no counter just has a trace with
holes in it and no idea why.

## The flush is bounded twice, and it needs both bounds

**By size** -- `max_batch` spans -- because a batch has to fit in one request
and a collector will refuse one that does not.

**By time** -- `interval` seconds -- because a size bound alone means a quiet
service never exports at all. Nine requests an hour on a 256-span batch is a
trace that appears a month late, and the traces that matter most are usually
from exactly such a service.

## The timestamps, and an honest limit

A span carries a wall-clock start (so a human can find it) and a duration (so
it can be measured). Those come from two different clocks on purpose, and
`akkar/time.lua` explains why: a duration measured against wall time breaks
when NTP steps the clock, and a monotonic instant means nothing to a reader.

So: the start is `akkar.time.now()` and the duration is the difference of two
`akkar.time.monotime()` readings. The consequence, stated rather than
discovered: `now()` is `os.time`, which has **one-second resolution**, so a
span's absolute start time is accurate to a second while its duration is
accurate to microseconds. Two spans that began in the same second sort
arbitrarily against each other by start time. Reading the clock through the
capability is worth more than the sub-second stamp -- it is what lets
`spec/trace_spec.lua` prove the time bound without waiting for one.

## THE QUEUE AND THE LOOP ARE SHARED, AND THE ARGUMENT IS WHY

Everything above -- never on the request's clock, drop rather than grow, drop
rather than retry, two bounds and not one -- is an argument about getting data
out of a process, not an argument about spans. `akkar.errors` needs the same
one for captured failures.

So it lives once, in `M.Batch` below, and this file's exporter is that plus
two things that really are about tracing: how a span is started, and how a
batch of them is encoded. A second copy of a queue swap whose correctness only
shows under concurrency is how the second copy ends up subtly wrong.

## The wire format is OTLP/HTTP JSON

Because it is what a collector already accepts -- the OpenTelemetry Collector,
Jaeger, Tempo, Honeycomb and every vendor's endpoint -- and inventing one
would mean writing the collector too. It is generated here rather than pulled
in as a dependency: it is roughly forty lines of table building, and the
alternative is a protobuf runtime for a payload with eight fields in it.
]]

local crypto = require "akkar.crypto"
local time   = require "akkar.time"
local bitwise = require "akkar.bitwise"

local M = {}

-- OTLP span kinds, from the OpenTelemetry proto. Named rather than inlined
-- because `kind = 2` in a payload is unreadable and `kind = 3` on a server
-- span is a mistake nobody would spot in review.
M.KIND = {
  INTERNAL = 1,
  SERVER   = 2,
  CLIENT   = 3,
  PRODUCER = 4,
  CONSUMER = 5,
}

-- OTLP status codes. UNSET is not "unknown", it is "nobody claimed this span
-- succeeded or failed", which is the correct answer for most spans.
M.STATUS = { UNSET = 0, OK = 1, ERROR = 2 }

local DEFAULTS = {
  endpoint  = "http://localhost:4318/v1/traces",
  service   = "akkar",
  max_batch = 256,
  -- Deliberately several times `max_batch`, so a burst that outruns one flush
  -- is buffered rather than dropped, and deliberately finite, so a collector
  -- that is gone costs a bounded amount of memory and not a growing one.
  max_queue = 2048,
  interval  = 5,
  -- Shorter than `akkar.http`'s own 10-second default. An export that has not
  -- completed in two seconds is an export competing with the requests this
  -- process exists to answer, and a span is worth less than any of them.
  timeout   = 2,
}

-- ================================================================ ids

--- A 16-byte trace id, as 32 hex characters.
---
--- From `akkar.crypto`, which draws from the operating system's CSPRNG,
--- rather than from `math.random`. Not because a trace id is a secret -- it is
--- the opposite of a secret, it travels in a header across every service --
--- but because `math.random` is seeded predictably, and two processes that
--- start at the same moment would mint the same ids and silently merge two
--- unrelated traces into one.
function M.trace_id() return crypto.to_hex(crypto.random(16)) end

--- An 8-byte span id, as 16 hex characters.
function M.span_id() return crypto.to_hex(crypto.random(8)) end

--- Renders a `traceparent` for an outbound request.
---
--- The version is `00` and the flags carry the sampled bit in the LOW bit --
--- not the whole byte. `spec/trace_spec.lua` already asserts that distinction
--- on the way in, because treating the byte as a boolean calls every future
--- flag combination "sampled", and the two halves must agree or akkar would
--- emit a header it would itself reject.
function M.traceparent(trace_id, span_id, sampled)
  return ("00-%s-%s-%02x"):format(trace_id, span_id, sampled and 1 or 0)
end

-- ================================================================ OTLP JSON

--- Seconds since the epoch as a string of nanoseconds.
---
--- Integer arithmetic throughout, and that is load-bearing. `1755000000 * 1e9`
--- in floating point is 1.755e18, which is far past the 2^53 where a double
--- stops representing consecutive integers, so the last several digits of
--- every timestamp would be invented. Lua 5.4 has 64-bit integers and the
--- product fits in one with room to spare (the type tops out around 9.2e18,
--- which is the year 2262), so the multiplication is done there.
local function nanoseconds(seconds)
  local whole = math.floor(seconds)
  local fraction = seconds - whole
  return string.format("%d", bitwise.bor(whole, 0) * 1000000000 +
                             math.floor(fraction * 1e9 + 0.5))
end

M.nanoseconds = nanoseconds

--- One OTLP `AnyValue`.
---
--- `intValue` is a STRING in OTLP's JSON mapping, because the field is an
--- int64 and JSON numbers are doubles -- the same 2^53 problem as above, and
--- the protocol solved it by quoting. Emitting a bare number there is accepted
--- by some collectors and rejected by others, which is the worst kind of
--- wrong: it works until you change vendor.
local function any_value(value)
  local kind = type(value)
  if kind == "string"  then return { stringValue = value } end
  if kind == "boolean" then return { boolValue = value } end
  if kind == "number" then
    if math.type(value) == "integer" then return { intValue = tostring(value) } end
    return { doubleValue = value }
  end
  return { stringValue = tostring(value) }
end

--- A key/value map as OTLP's list of attributes, in a stable order.
---
--- Sorted, for the same reason `akkar.etag` sorts before hashing: `pairs()`
--- has no defined order in Lua, so the same attributes would serialise
--- differently on different runs. Here that costs no correctness and it costs
--- every test that asserts on a payload, which is enough.
local function attributes_of(map)
  if not map then return nil end
  local keys = {}
  for key in pairs(map) do keys[#keys + 1] = key end
  if #keys == 0 then return nil end
  table.sort(keys)

  local out = {}
  for i, key in ipairs(keys) do
    out[i] = { key = key, value = any_value(map[key]) }
  end
  return out
end

-- OTLP documents and need the same scalar wrapper the span encoder uses. It
-- was exported for exactly that and the extraction dropped it, which surfaced
-- as `attempt to call a nil value` inside the log encoder.
M.any_value = any_value
M.attributes_of = attributes_of

--- Builds the OTLP/HTTP JSON payload for a batch of spans.
---
--- Exported so a spec can assert on the exact shape that would go on the wire
--- without standing up a collector -- which is the same argument
--- `akkar/http.lua` makes for the response being a value: a value can be
--- logged, retried and asserted on.
function M.otlp(spans, resource)
  local out = {}
  for i, span in ipairs(spans) do
    local encoded = {
      traceId           = span.trace_id,
      spanId            = span.span_id,
      name              = span.name,
      kind              = span.kind or M.KIND.INTERNAL,
      startTimeUnixNano = nanoseconds(span.start_time),
      endTimeUnixNano   = nanoseconds(span.start_time + (span.duration or 0)),
      attributes        = attributes_of(span.attributes),
    }
    -- Omitted rather than sent empty. OTLP treats an all-zero parent id as
    -- "this is a root span", and a literal empty string is neither that nor a
    -- valid id -- collectors differ on which they reject.
    if span.parent_span_id then encoded.parentSpanId = span.parent_span_id end
    if span.status and span.status ~= M.STATUS.UNSET then
      encoded.status = { code = span.status, message = span.status_message }
    end
    out[i] = encoded
  end

  return {
    resourceSpans = { {
      resource = { attributes = attributes_of(resource) },
      scopeSpans = { { scope = { name = "akkar" }, spans = out } },
    } },
  }
end

-- ================================================================== a span

local Span = {}
Span.__index = Span

--- Ends the span and hands it to the exporter. Returns the span.
---
--- `status` may be a number from `M.STATUS` or one of the strings "ok" and
--- "error", because a caller writing `span:finish { status = "error" }` should
--- not have to look up that ERROR is 2.
function Span:finish(options)
  options = options or {}
  if self.finished then return self end
  self.finished = true

  -- The DURATION comes from the monotonic clock and the START came from the
  -- wall clock. See the header: an NTP step during a request would otherwise
  -- produce a negative duration, which every backend renders as a span that
  -- ended before it began.
  self.duration = time.monotime() - self.start_mono

  local status = options.status
  if status == "ok"    then status = M.STATUS.OK    end
  if status == "error" then status = M.STATUS.ERROR end
  if status then self.status = status end
  if options.message then self.status_message = options.message end

  for key, value in pairs(options.attributes or {}) do
    self.attributes[key] = value
  end

  if self.exporter then self.exporter:record(self) end
  return self
end

function Span:set(key, value)
  self.attributes[key] = value
  return self
end

--- The header to send on an outbound call made inside this span.
---
---     local res = req.http:get(url, { traceparent = req.span:traceparent() })
---
--- `akkar/http.lua` already accepts `traceparent` and upserts it, so this is
--- the piece that was missing rather than a new mechanism.
function Span:traceparent()
  return M.traceparent(self.trace_id, self.span_id, self.sampled)
end

M.Span = Span

-- ================================================== the batching machinery
--
-- THE QUEUE, THE BOUND AND THE LOOP, factored out of the exporter because
-- there is now more than one thing in this runtime that has to leave the
-- process without standing on the request's clock. `akkar.errors` sends
-- captured failures; this file sends spans.
--
-- The argument is identical in both cases -- a request is never blocked on an
-- export, a full queue drops rather than grows, a failed batch is dropped
-- rather than retried -- and it is exactly the kind of argument that goes
-- subtly wrong the second time somebody writes it out. The queue swap before
-- the network call is four lines and one of them is load-bearing under
-- concurrency only. So there is one of it.
--
-- What a user of this supplies is `encode`, which turns a batch into whatever
-- its destination reads: OTLP/HTTP JSON here, a generic JSON envelope there.
local Batch = {}
Batch.__index = Batch

--- Installs the queue-and-flush fields on `target`, and returns it.
---
--- Deliberately not a constructor. Both users of this have their own
--- metatable and their own fields; what they share is state, not identity, so
--- this fills in the shared half and the caller sets the metatable over it.
---
--- `origin` is the module's own name, and it is here rather than hardcoded so
--- that "has no http capability" names the thing that is misconfigured. An
--- operator reading `akkar.trace has no http capability` in a service that
--- also reports errors should not have to guess which of the two it is.
function M.batch(target, options)
  target.origin    = options.origin or "akkar.trace"
  target.http      = options.http
  target.sink      = options.sink
  target.endpoint  = options.endpoint
  target.headers   = options.headers
  target.max_batch = options.max_batch or DEFAULTS.max_batch
  target.max_queue = options.max_queue or DEFAULTS.max_queue
  target.interval  = options.interval or DEFAULTS.interval
  target.timeout   = options.timeout or DEFAULTS.timeout

  -- `encode` AS A CONSTRUCTOR OPTION, and it is not merely a convenience.
  --
  -- The two callers reached for opposite spellings: a batch that knows its own
  -- format overrides the `Batch:encode` METHOD (`akkar.errors` does, and so
  -- does the span exporter below), while `akkar.otlp` builds three exporters
  -- that differ ONLY in their encoder and passes each one as a FIELD. A field
  -- installed straight onto the table is then reached as `self:encode(batch)`
  -- and receives the exporter where it expects the batch -- which failed deep
  -- inside the encoder, on a nil timestamp, rather than at the point of
  -- confusion.
  --
  -- So a supplied function is wrapped into the method shape once, here, and is
  -- handed exactly what the standalone encoders take: the batch and the
  -- resource. Callers may still override the method directly; this only gives
  -- the field spelling a defined meaning instead of a misleading crash.
  if options.encode then
    local encode = options.encode
    target.encode = function(self, batch) return encode(batch, self.resource) end
  end

  target.queue      = {}
  target.last_flush = time.monotime()
  target.counts     = { recorded = 0, dropped = 0, exported = 0,
                        failed = 0, batches = 0 }
  return target
end

--- Turns a batch into the document its destination reads.
---
--- The identity is the default because a list of plain tables is already a
--- JSON array, which is a legitimate thing to POST. Both shipped users
--- override it.
function Batch:encode(batch) return batch end

--- Queues a finished item. Returns true when it was kept, false when dropped.
---
--- THE WHOLE FUNCTION IS AN APPEND, and that is the point. It performs no
--- encoding, opens no socket and makes no decision that can take time, because
--- it runs on the request's coroutine and everything it does is time the user
--- waits for.
---
--- When the queue is full the NEWEST item is refused rather than the oldest
--- being evicted. Both are O(1) and neither is obviously right, so the reason
--- is the cheaper one: evicting would mean the request path pays for the
--- backend's outage, and the refusal costs a comparison. The counter is what
--- makes the choice visible either way.
function Batch:record(item)
  self.counts.recorded = self.counts.recorded + 1
  if #self.queue >= self.max_queue then
    self.counts.dropped = self.counts.dropped + 1
    return false
  end
  self.queue[#self.queue + 1] = item
  return true
end

--- Is an export due, by either bound?
function Batch:due()
  if #self.queue == 0 then return false end
  if #self.queue >= self.max_batch then return true end
  return (time.monotime() - self.last_flush) >= self.interval
end

--- Exports if either bound has been reached. This is what the loop calls.
function Batch:tick()
  if not self:due() then return false end
  self:flush()
  return true
end

--- Resolves the HTTP capability once and keeps it.
---
--- A factory is called once rather than per flush. `akkar/init.lua` calls a
--- capability factory once per REQUEST and releases it at the end, because a
--- request is the lifetime of the work; an exporter is a process-lifetime
--- thing, so acquiring a connection per batch would open and close one every
--- few seconds forever.
function Batch:client()
  if self.resolved ~= nil then return self.resolved end
  local given = self.http
  if given == nil then return nil end
  if type(given) == "function" then
    local ok, client = pcall(given)
    self.resolved = ok and client or false
  else
    self.resolved = given
  end
  return self.resolved or nil
end

--- Hands one encoded batch to whatever is configured to take it.
--- Returns true, or nil and a reason.
---
--- TWO SINKS AND ONE CONTRACT. A function receives exactly the document the
--- HTTP sink would have POSTed, which is what makes the test double worth
--- anything: a spec asserting on what the function got is asserting on the
--- bytes that would have gone out, not on an internal shape that happens to
--- resemble them.
---
--- pcall on both, because the transport may RAISE rather than return a reason
--- -- a DNS failure inside lua-http does -- and so may somebody's sink. Either
--- would otherwise kill the coroutine the loop runs in and stop exporting for
--- the life of the process, with nothing in the log to say the loop had ended.
function Batch:deliver(payload, batch)
  if self.sink then
    local ok, res, why = pcall(self.sink, payload, batch)
    if not ok then return nil, tostring(res) end
    -- A sink that returns nothing has accepted the batch. `nil, "reason"` and
    -- a bare `false` are the two ways to say it did not, and both are counted
    -- as a failed batch rather than raised.
    if res == false or (res == nil and why ~= nil) then
      return nil, tostring(why or "the sink refused the batch")
    end
    return true
  end

  local client = self:client()
  local ok, res, why = pcall(client.post, client, self.endpoint, {
    body    = payload,
    headers = self.headers,
    timeout = self.timeout,
  })
  if not ok then return nil, tostring(res) end
  if not res then return nil, tostring(why or "export failed") end
  if res.status and res.status >= 400 then
    return nil, ("status %d"):format(res.status)
  end
  return true
end

--- Exports what is queued, now. Returns true, or nil and a reason.
---
--- **Not to be called from a handler or from middleware.** Everything in this
--- function can wait on a network, which is the one thing a request must not
--- do for a span or for a captured error. It exists to be called from `run`,
--- and from a test.
function Batch:flush()
  -- THE QUEUE IS SWAPPED BEFORE THE NETWORK CALL, not after.
  --
  -- akkar is cooperative, so the POST below yields and other requests run
  -- while it is in flight. Those requests record spans. Clearing the queue
  -- afterwards would throw away everything recorded during the export --
  -- silently, and only under load, which is when the data matters.
  local batch = self.queue
  self.queue = {}
  self.last_flush = time.monotime()
  if #batch == 0 then return true end

  if not self.sink and not self:client() then
    -- Counted as dropped, not raised. An exporter with no destination is a
    -- misconfiguration, and a misconfiguration in the observability system
    -- must not take down the service it is observing.
    self.counts.dropped = self.counts.dropped + #batch
    return nil, self.origin .. " has no http capability"
  end

  self.counts.batches = self.counts.batches + 1

  local ok, why = self:deliver(self:encode(batch), batch)
  if not ok then
    -- DROPPED, NOT RETRIED. See the header: retrying moves the growth from
    -- this queue into a retry buffer and buys nothing, because the request
    -- these records describe was already answered.
    self.counts.failed  = self.counts.failed + 1
    self.counts.dropped = self.counts.dropped + #batch
    return nil, why
  end

  self.counts.exported = self.counts.exported + #batch
  return true
end

--- The counters. Put `dropped` and `failed` on a dashboard.
function Batch:stats()
  return {
    queued   = #self.queue,
    recorded = self.counts.recorded,
    dropped  = self.counts.dropped,
    exported = self.counts.exported,
    failed   = self.counts.failed,
    batches  = self.counts.batches,
  }
end

--- Runs the flush loop on a cqueues controller. Call it once, at startup.
---
--- This is the only place `flush` is meant to be called from, and it is three
--- lines so that the interesting behaviour lives in `tick`, which a spec can
--- drive without a scheduler or a clock that moves on its own.
---
--- The loop sleeps for a FRACTION of the interval rather than for the whole of
--- it, because the size bound needs checking more often than the time bound: a
--- burst that fills `max_batch` in the first second of a five-second interval
--- should not wait out the other four.
--- Ticks anything with a `tick` and a `stopped` on `controller`, every `nap`
--- seconds, until it stops.
---
--- GENERIC ON PURPOSE, and the reason is a collision worth recording. Two
--- pieces of work factored this same loop out of `Exporter` at the same time
--- and arrived at byte-equivalent code: one as a free function over a subject,
--- one as a method on the batch. They were the same idea, so this is the one
--- implementation and `Batch:run` is a caller of it -- `akkar.otlp` drives
--- three exporters from a single coroutine and needs the free form, while a
--- lone batch reads better as `batch:run()`.
---
--- `pcall` around the tick so that one bad export cannot end the loop; `flush`
--- already swallows transport failures and this covers the rest.
function M.loop(subject, controller, nap)
  local cqueues = require "cqueues"
  controller = controller or cqueues.running()
  if not controller then
    error((subject.origin or subject.name or "akkar.trace")
          .. ": run() needs a cqueues controller; call it from inside the loop "
          .. "akkar runs on, or pass one", 3)
  end

  subject.stopped = false
  controller:wrap(function()
    while not subject.stopped do
      time.sleep(nap)
      pcall(function() subject:tick() end)
    end
  end)
  return subject
end

function Batch:run(controller)
  return M.loop(self, controller, math.min(self.interval / 4, 1))
end

--- Stops the loop, after one last export.
function Batch:stop()
  self.stopped = true
  return self:flush()
end

M.Batch = Batch

-- ============================================================== the exporter

-- INHERITS THE QUEUE AND THE LOOP from `Batch` above and adds the two things
-- that are actually about tracing: how a span is started, and how a batch of
-- them is encoded. Everything else an exporter does -- `record`, `due`,
-- `tick`, `flush`, `stats`, `run`, `stop` -- is the shared machinery.
local Exporter = setmetatable({}, { __index = Batch })
Exporter.__index = Exporter

--- OTLP/HTTP JSON, which is what a collector already accepts.
function Exporter:encode(batch) return M.otlp(batch, self.resource) end

--- Builds an exporter.
---
---     local exporter = akkar.trace.new {
---       http     = akkar.http.connect { timeout = 2 },
---       endpoint = "http://collector:4318/v1/traces",
---       service  = "checkout",
---     }
---     app:use(exporter:middleware())
---     -- and, once, inside the controller akkar runs on:
---     exporter:run()
---
--- `http` is an `akkar.http` capability -- a factory or a client, the same
--- shape `app:run { http = ... }` takes -- and NOT a URL and a socket library.
--- The reason is the one `akkar/http.lua` gives at length: every I/O path here
--- goes through an adapter akkar owns, which is what makes a fake possible.
--- `spec/trace_spec.lua` passes a table with a `post` method and nothing else.
function M.new(options)
  options = options or {}

  local resource = { ["service.name"] = options.service or DEFAULTS.service }
  for key, value in pairs(options.resource or {}) do resource[key] = value end

  -- The tracing half is `resource` and `sampler`; `M.batch` fills in the
  -- queue, the bounds and the destination, which are the same fields
  -- `akkar.errors` asks it for.
  local exporter = M.batch({ resource = resource, sampler = options.sampler }, {
    -- `origin` and `encode` are forwarded, and both matter to `akkar.otlp`:
    -- it builds three exporters through this constructor that differ only in
    -- what they encode and what they call themselves. Dropping `encode` here
    -- left all three encoding as SPANS, which surfaced as a nil timestamp deep
    -- inside the span encoder rather than as the missing option it was.
    origin    = options.origin or options.name or "akkar.trace",
    encode    = options.encode,
    http      = options.http,
    sink      = options.sink,
    endpoint  = options.endpoint or DEFAULTS.endpoint,
    headers   = options.headers,
    max_batch = options.max_batch,
    max_queue = options.max_queue,
    interval  = options.interval,
    timeout   = options.timeout,
  })
  return setmetatable(exporter, Exporter)
end

--- Starts a span. Returns nil when this trace is not being sampled.
---
--- Nil rather than a no-op span object, deliberately. A no-op span still
--- allocates, still has its attributes written into it, and still has to be
--- finished -- so the cost of tracing would be paid on every request whether
--- or not anything was collected. A caller writes `if req.span then` or uses
--- the middleware, which does.
function Exporter:start_span(options)
  options = options or {}

  return setmetatable({
    exporter       = self,
    trace_id       = options.trace_id or M.trace_id(),
    span_id        = M.span_id(),
    parent_span_id = options.parent_span_id,
    name           = options.name or "span",
    kind           = options.kind or M.KIND.INTERNAL,
    sampled        = options.sampled ~= false,
    start_time     = time.now(),
    start_mono     = time.monotime(),
    attributes     = options.attributes or {},
    status         = M.STATUS.UNSET,
  }, Span)
end

--- Server-span middleware.
---
---     app:use(exporter:middleware())
---
--- Continues the caller's trace when `req.trace` is present -- akkar has
--- already validated that header, so a malformed one has become nil and this
--- span starts a fresh trace rather than joining a corrupt one.
---
--- IT DOES NOT TOUCH THE RESPONSE. Not a header, not a copy, nothing: the
--- handler's value is returned exactly as it came back. `akkar.etag`,
--- `akkar.limit` and `akkar.auth` were each fixed for writing onto a table a
--- handler returned -- a hoisted or memoised response is shared between
--- requests -- and the cheapest way not to have that defect is to have nothing
--- to write.
function Exporter:middleware(options)
  options = options or {}
  -- Lazily, once, at construction rather than per request: `akkar` does not
  -- require this module, and keeping the edge one-directional at load time
  -- means nobody has to reason about the order later.
  local akkar = require "akkar"
  local name_of = options.name or function(req)
    -- The ROUTE, not the path, when akkar knows it. `/users/42` and
    -- `/users/43` are the same operation, and a backend that groups by raw
    -- path produces one bucket per user id -- which is how a tracing bill and
    -- a cardinality explosion happen at the same time.
    --
    -- NAMED AFTER THE HANDLER RAN, NOT BEFORE, AND THIS COST A TEST.
    --
    -- `req.route` is written by dispatch (`akkar/init.lua`), which happens
    -- BELOW every middleware -- so at the moment a middleware starts its span
    -- the field does not exist yet, and reading it there silently fell through
    -- to `req.path`. Every span was named after a raw URL, which is the exact
    -- cardinality explosion the fallback was written to avoid, and it would
    -- have looked correct in any test whose route had no parameters in it.
    return req.method .. " " .. (req.route or req.path or "/")
  end

  return function(req, next)
    -- THE UPSTREAM'S SAMPLING DECISION IS OBEYED. A service that records a
    -- span for a trace its caller decided not to sample produces an orphan:
    -- one span whose parent will never arrive, which every backend renders as
    -- a broken trace rather than as extra information.
    local inbound = req.trace
    if inbound and inbound.sampled == false then return next(req) end
    if options.sampler and not options.sampler(req) then return next(req) end
    if self.sampler and not self.sampler(req) then return next(req) end

    local span = self:start_span {
      trace_id       = inbound and inbound.trace_id,
      parent_span_id = inbound and inbound.span_id,
      -- A placeholder, replaced below once dispatch has told us the route.
      name           = req.method .. " " .. (req.path or "/"),
      kind           = M.KIND.SERVER,
      attributes     = {
        ["http.request.method"] = req.method,
        ["url.path"]            = req.path,
        -- THE JOIN KEY, the other way round. `req.log` carries the trace and
        -- span ids once a span exists; this carries the request id onto the
        -- span, so a span found in a backend leads to the log lines and the
        -- `x-request-id` a client was handed, and a log line leads back.
        --
        -- Under akkar's own namespace, and not under `http.`, because the
        -- semantic conventions define no request-id attribute -- the only
        -- header-shaped one, `http.request.header.<key>`, records what the
        -- CLIENT sent, and `req.id` is deliberately not that (`spec/
        -- log_spec.lua` says why). The naming guidance is explicit: an
        -- application-specific attribute is prefixed by the application's
        -- name, and "it is not recommended to use existing OpenTelemetry
        -- semantic convention namespace as a prefix for a new company- or
        -- application-specific attribute name".
        ["akkar.request_id"]    = req.id,
      },
    }
    req.span = span

    -- A LOGGER ACQUIRED BEFORE THIS MIDDLEWARE RAN has no span to bind to,
    -- and it is cached on the request, so every later line would miss the
    -- ids. Rebinding costs one small table on a traced request that already
    -- logged, and nothing at all otherwise -- `rawget`, so an unread `log`
    -- is not acquired here just to be rebound.
    local logger = rawget(req, "log")
    if logger then
      rawset(req, "log", logger:with {
        trace_id = span.trace_id, span_id = span.span_id,
      })
    end

    -- pcall, so a handler that RAISES still produces a span. A trace missing
    -- exactly the requests that failed is a trace of the requests nobody
    -- needed to look at.
    local ok, res = pcall(next, req)

    -- Named here, where `req.route` exists. See `name_of` above.
    span.name = name_of(req)

    if not ok then
      -- A THROWN RESPONSE IS NOT AN ERROR, and telling them apart is exactly
      -- what `akkar.is_response` is exported for -- `akkar/init.lua` says so:
      -- "middleware has to tell a thrown response from a raised error, and the
      -- alternative was comparing metatables".
      --
      -- A handler that throws a 404 to unwind has answered the request
      -- correctly. Recording that as a failed span would make the error rate
      -- on every dashboard equal to the rate at which people mistype URLs,
      -- which is the same reason a returned 4xx is UNSET below.
      local thrown = akkar.is_response(res) and res or nil
      span:finish {
        status = (not thrown or (thrown.status or 500) >= 500) and "error" or nil,
        message = (not thrown) and
                  (type(res) == "string" and res or "handler raised") or nil,
        attributes = thrown and
                     { ["http.response.status_code"] = thrown.status } or nil,
      }
      -- Rethrown with level 0 so the value is preserved unchanged: akkar
      -- dispatches on a THROWN RESPONSE as well as on an error string, and
      -- decorating it with a file and line would turn a thrown 404 into a 500
      -- whose body was a Lua source location.
      error(res, 0)
    end

    local status = 200
    if res == nil then
      status = 204
    elseif type(res) == "table" and res.__response == true
           and type(res.status) == "number" then
      status = res.status
    end

    -- A 4xx is UNSET, not ERROR, and that is OpenTelemetry's own rule for a
    -- SERVER span: the client asked for something it could not have, and the
    -- server did its job by saying so. Marking those as errors makes the error
    -- rate on every dashboard equal to the rate at which people mistype URLs.
    span:finish {
      status = status >= 500 and "error" or nil,
      attributes = { ["http.response.status_code"] = status },
    }
    return res
  end
end

M.Exporter = Exporter
M.DEFAULTS = DEFAULTS

return M
