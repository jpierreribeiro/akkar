--[[
akkar.errors — the failure behind a 500, out to something that keeps it.

## The gap this closes

`akkar/init.lua` has documented the hook for a long time:

    app:on_error(function(err, req)
      sentry:capture(err, { request_id = req.id, route = req.path })
      return akkar.response(500, { instance = req.id })
    end)

and shipped no `sentry`. The hook was real -- `internal_error` runs it after
every capability has gone back, on both the handler and the middleware paths,
and that placement was itself a repair -- but the thing on the other end of it
was left as an exercise. So the cause of a 500 reached exactly one place:
`internal:error("handler raised", ...)` on stderr, where it is found by
whoever is already tailing the right process at the right moment.

This is the other end. It is deliberately small: an error is a table, a queue
and a POST.

## NOT THE SENTRY ENVELOPE, AND THAT IS THE POINT

Sentry's ingestion format is a newline-delimited envelope with its own
headers, its own item types, a DSN that encodes a project id and a public key,
and a `sentry_client` handshake. Implementing it would mean owning a wire
format that belongs to one vendor, that changes on their schedule, and that
nothing in this repository can test against without a Sentry account.

So this POSTs one JSON document to one URL. Point it at Sentry through their
own relay, at an OpenTelemetry collector's HTTP receiver, at Loki, at a
Lambda, at four lines of your own that write to a file -- anything that reads
JSON. The shape is documented in `docs/reference/errors.md` and is stable;
what it is FOR is somebody else's decision.

## THE ONE RULE IS THE ONE `akkar.trace` ALREADY STATES

A request is never blocked on an export. An error tracker is a third party's
service and a third party's service is a thing that goes down -- usually
during the incident that is producing the errors you wanted to send it. A
runtime that POSTs an error inline has arranged for its 500s to take as long
as its error tracker's outage, on a scheduler where one blocked coroutine is
time in which akkar answers NOBODY.

So `capture` builds a table and appends it. The queue is bounded, a full queue
drops rather than grows, a failed batch is dropped rather than retried, and
the delivery happens on a background loop. None of that is written twice:
`akkar/trace.lua` has the machinery and the long argument for each of those
three choices, and this module is `trace.Batch` with a different `encode`.

The one thing `capture` does that `record` does not is BUILD the event, which
is a handful of pattern substitutions over a bounded string. That is not a
network call and it happens only on a request that has already failed -- and
it has to happen here, because `req` is about to be released and will not
exist when the batch flushes. The queue bound is therefore checked BEFORE the
event is built, so a full queue costs a comparison rather than a sanitising
pass whose result is discarded.

## WHAT GOES IN THE EVENT, AND WHAT NEVER DOES

**The route pattern, not the path.** `/orders/9f2b` and `/orders/7c41` are one
operation. An error tracker that groups by raw path produces one group per
order id, which is how a tracker stops grouping anything at all.
`akkar/trace.lua` names the same failure for span names and this is the same
decision for the same reason.

**Never the traceback, and never the raw message on the wire.** The 500 path
in `akkar/init.lua` already argues it: "A Lua error carries file paths, line
numbers and sometimes SQL." Its conclusion was that the RESPONSE stays bare,
and that property is untouched here -- `handler()` returns nil, which akkar
reads as "the hook declined", and the client gets the same
`{"error": "internal server error"}` it got before this module existed.

What is new is that the event travelling to the sink is sanitised too, which
is a weaker requirement and a real one: the destination is a third party, the
message is frequently attacker-influenced (it is the text of a failure the
request caused), and an unbounded field is both a leak and a bill. So the
message is cut at `stack traceback:`, collapsed to one line, has the obvious
credentials replaced, and is truncated to `max_message` bytes.

The redaction is A FLOOR, NOT A GUARANTEE, and saying so is the honest form:
it catches URLs with a password in them and `key = value` for the usual key
names, because those are what a database or an HTTP client actually raises. It
cannot catch a secret that does not look like one. The defence that does not
depend on pattern matching is `akkar.config`, whose secrets render as
`[redacted]` through `__tostring` and `__concat` and therefore never reach a
message in the first place.
]]

local time  = require "akkar.time"
local trace = require "akkar.trace"

local M = {}

local DEFAULTS = {
  service   = "akkar",
  -- Smaller than tracing's 256/2048 in both bounds, and the ratio is the
  -- argument. A span is emitted per request and an error is not, so a service
  -- with a queue of 2048 errors in it is a service in an incident, and 256 of
  -- them describe that incident exactly as well as 2048 do -- while the
  -- shorter batch means the first ones reach the tracker sooner, which is
  -- when somebody is looking.
  max_batch = 32,
  max_queue = 256,
  interval  = 5,
  timeout   = 2,
  -- Long enough for a real Lua error with a SQL statement in it, short enough
  -- that a message built from a request body cannot be used to post megabytes
  -- to a third party at the cost of one 500.
  max_message = 512,
}

M.DEFAULTS = DEFAULTS

-- =============================================================== sanitising

-- The same word `akkar/config.lua` uses, so an operator sees one spelling
-- whether the secret was caught by construction there or by pattern here.
local REDACTED = "[redacted]"

--- The same word, matched without regard to case.
---
--- Lua patterns have no case-insensitive flag and no alternation, so the
--- class is built out. Done once at load rather than per capture.
local function insensitive(word)
  return (word:gsub("%a", function(c)
    return "[" .. c:upper() .. c:lower() .. "]"
  end))
end

-- Each entry is a pattern and its replacement, applied in order.
--
-- The key names are the ones that actually appear in a raised Lua error in
-- this runtime: a DSN from a driver, a header echoed back by an HTTP client,
-- a config value interpolated into a message by somebody's own handler.
local SECRET_KEYS = {
  "password", "passwd", "secret", "token", "api_key", "apikey",
  "access_key", "private_key", "authorization",
}

local RULES = {
  -- CREDENTIALS IN A URL come first, because a DSN is the single most likely
  -- secret in a database error and it matches none of the key rules below:
  -- `postgres://app:hunter2@db:5432/orders` has no `password=` in it.
  { "://([^:@/%s]+):[^@/%s]+@", "://%1:" .. REDACTED .. "@" },
  -- `Bearer <token>`, which is what an HTTP client raises with the header
  -- still attached.
  { insensitive "bearer" .. "%s+[%w%-%._~%+/=]+", "Bearer " .. REDACTED },
}

for _, key in ipairs(SECRET_KEYS) do
  -- The value runs to the next separator. Quotes are consumed rather than
  -- excluded, so `password="hunter2"` loses the quotes with the secret --
  -- leaving `password=[redacted]` rather than `password="[redacted]"`, which
  -- would be a lie about the original shape either way and is shorter this
  -- way round.
  RULES[#RULES + 1] = {
    "(" .. insensitive(key) .. "%s*[=:]%s*)[^%s,;%)]+", "%1" .. REDACTED,
  }
end

M.REDACTED = REDACTED

--- One line, bounded, with the obvious credentials taken out.
---
--- Exported because it is the part worth testing directly and the part worth
--- reusing: a job runner that wants to log a failure the same way should not
--- have to reimplement it.
---
--- A table is read for a `message`, `error` or `detail` string before being
--- stringified, because a handler that raises a table -- which akkar allows,
--- and which `akkar.is_response` exists to tell apart -- otherwise arrives as
--- `table: 0x55f3...`, an address that identifies nothing and differs on
--- every run, so every occurrence groups separately in the tracker.
function M.sanitise(value, limit)
  limit = limit or DEFAULTS.max_message

  local text
  if type(value) == "table" then
    for _, key in ipairs { "message", "error", "detail" } do
      if type(value[key]) == "string" then text = value[key] break end
    end
  end
  text = text or tostring(value)

  -- THE TRACEBACK NEVER TRAVELS. Lua appends it with this exact header, and
  -- everything after it is a list of file paths in the deployment -- which is
  -- the thing `akkar/init.lua` refuses to put in a response body, for a
  -- destination that is at least ours. A third party's tracker is not.
  local cut = text:find("stack traceback:", 1, true)
  if cut then text = text:sub(1, cut - 1) end

  -- One line. A newline inside a JSON string is legal and a newline inside a
  -- log line is not, and this string ends up in both.
  text = (text:gsub("%c", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))

  for _, rule in ipairs(RULES) do text = (text:gsub(rule[1], rule[2])) end

  -- TWO RULES FIRE ON `authorization: Bearer <token>` -- the scheme rule
  -- takes the token and the key rule then takes the word `Bearer` -- and the
  -- result reads `authorization: [redacted] [redacted]`. Over-redacting is
  -- the right side to err on and looking careless is not, so a run collapses.
  -- Bounded, because a substitution that can reintroduce its own subject is
  -- how a sanitiser becomes an infinite loop on attacker-chosen input.
  for _ = 1, 8 do
    local collapsed, count = text:gsub("(%[redacted%])%s+%[redacted%]", "%1")
    text = collapsed
    if count == 0 then break end
  end

  if #text > limit then
    -- TRUNCATING BYTES CAN SPLIT A UTF-8 SEQUENCE IN HALF, and a JSON
    -- document carrying half a codepoint is one some consumers reject
    -- outright -- so the whole batch would be lost to one long message. The
    -- cut backs off over any trailing continuation byte.
    local at = limit
    while at > 1 do
      local next_byte = text:byte(at + 1)
      if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then break end
      at = at - 1
    end
    text = text:sub(1, at) .. " [truncated]"
  end

  return text
end

-- ================================================================ the event

local Reporter = setmetatable({}, { __index = trace.Batch })
Reporter.__index = Reporter

--- Builds the event for one failure. Returns a plain table.
---
--- Exported as a method so a spec can assert on the event without a queue,
--- and so an application with its own destination can reuse the shape.
---
--- `req` may be nil: `App:on_error` documents that the request "may be absent
--- for a failure that happened before one existed", and a job runner has none
--- at all. Every request field is simply missing then, rather than present
--- and empty -- for the reason `spec/log_spec.lua` gives about `trace_id`: a
--- store indexing a field must not be handed a million empty strings.
function Reporter:event(err, req, extra)
  local event = {
    timestamp = time.now(),
    level     = "error",
    service   = self.service,
    message   = M.sanitise(err, self.max_message),
    -- The status akkar is about to answer. It is 500 because that is the only
    -- status this hook exists on -- a thrown 404 unwinds through
    -- `akkar.is_response` and never reaches here -- and it is a field rather
    -- than a constant in the prose so an application whose `on_error` answers
    -- something else can say so.
    status    = (extra and extra.status) or 500,
  }
  if self.environment then event.environment = self.environment end

  if req then
    event.request_id = req.id
    event.method     = req.method
    -- THE ROUTE PATTERN, NOT THE PATH. `/orders/:id`, not `/orders/9f2b`.
    -- Written by dispatch in `akkar/init.lua`, so it is nil for a failure
    -- that happened before a route was matched -- which is itself worth
    -- knowing, and is why there is no fallback to `req.path` here. A fallback
    -- would silently reintroduce the cardinality this line exists to avoid,
    -- and it would do it exactly on the errors that are hardest to read.
    event.route      = req.route

    -- THE JOIN KEY. `akkar/execution.lua` binds these onto `req.log` and
    -- `akkar/trace.lua` puts `akkar.request_id` on the span; this is the
    -- third corner. An operator holding an event in the tracker can find the
    -- span in Jaeger and the lines on stderr without a timestamp search.
    --
    -- Same precedence as the logger's: the local span when one was started,
    -- else the inbound `traceparent`, whose span id is the caller's.
    local context = rawget(req, "span") or req.trace
    if context then
      event.trace_id = context.trace_id
      event.span_id  = context.span_id
    end
  end

  -- Caller context last and NON-OVERRIDING, so a passed `route` cannot
  -- quietly become a raw path and a passed `message` cannot bypass the
  -- sanitiser. Extra keys are welcome; replacing the sanitised ones is not.
  if extra then
    for key, value in pairs(extra) do
      if event[key] == nil then event[key] = value end
    end
  end

  return event
end

-- ============================================================= the reporter

--- Builds a reporter.
---
---     local reporter = akkar.errors.new {
---       service  = "checkout",
---       http     = akkar.http.connect { timeout = 2 },
---       endpoint = "https://errors.internal/ingest",
---       headers  = { authorization = "Bearer " .. token },
---     }
---     app:on_error(reporter:handler())
---     -- and, once, inside the controller akkar runs on:
---     reporter:run()
---
--- or, with no network at all:
---
---     akkar.errors.new { sink = function(document) ... end }
---
--- `http` is an `akkar.http` capability -- a factory or a client, the same
--- shape `app:run { http = ... }` takes. The reason is the one
--- `akkar/http.lua` gives at length: every I/O path here goes through an
--- adapter akkar owns, which is what makes a fake possible.
---
--- RAISES WHEN IT HAS NOWHERE TO SEND, and that is deliberate. `flush` counts
--- a missing destination rather than raising, because by then a request has
--- already failed and the tracker must not make it worse. Construction is not
--- that moment: it happens once, at boot, where a misconfigured reporter is a
--- typo somebody can still fix -- and the alternative is a service that looks
--- instrumented for a month and has sent nothing.
function M.new(options)
  options = options or {}

  if not options.sink and not options.http then
    error("akkar.errors.new needs a sink = function(document) or an " ..
          "http = <akkar.http capability> to send to", 2)
  end
  if options.http and not options.endpoint then
    error("akkar.errors.new needs an endpoint = <url> to POST to; there is " ..
          "no default, because there is no address a JSON error sink is " ..
          "conventionally at", 2)
  end

  local reporter = trace.batch({
    service     = options.service or DEFAULTS.service,
    environment = options.environment,
    max_message = options.max_message or DEFAULTS.max_message,
  }, {
    origin    = "akkar.errors",
    http      = options.http,
    sink      = options.sink,
    endpoint  = options.endpoint,
    headers   = options.headers,
    max_batch = options.max_batch or DEFAULTS.max_batch,
    max_queue = options.max_queue or DEFAULTS.max_queue,
    interval  = options.interval or DEFAULTS.interval,
    timeout   = options.timeout or DEFAULTS.timeout,
  })
  return setmetatable(reporter, Reporter)
end

--- The document a batch becomes: one JSON object with the events in a list.
---
--- An object rather than a bare array, because a bare top-level array is the
--- shape that cannot be extended -- adding a field later would change the
--- document's type -- and because `service` belongs to the batch rather than
--- being repeated on every event by whoever reads it.
function Reporter:encode(batch)
  return { service = self.service, events = batch }
end

--- Captures one failure. Returns true when it was queued, false when dropped.
---
--- Appends. No socket, no encoding beyond the event itself, no decision that
--- can take time -- it runs on the failing request's coroutine and everything
--- it does is time a user is waiting for a 500 they are already unhappy about.
function Reporter:capture(err, req, extra)
  -- THE BOUND IS CHECKED BEFORE THE EVENT IS BUILT, not after. Sanitising a
  -- message the queue is about to refuse is a pattern pass over 512 bytes
  -- done on a request's clock for nothing, and a full queue is exactly the
  -- state a service is in when it can least afford it: the queue fills
  -- because the tracker is unreachable, and the tracker is unreachable during
  -- the incident that is generating the errors.
  if #self.queue >= self.max_queue then
    self.counts.recorded = self.counts.recorded + 1
    self.counts.dropped  = self.counts.dropped + 1
    return false
  end
  return self:record(self:event(err, req, extra))
end

--- The `app:on_error` hook.
---
---     app:on_error(reporter:handler())
---
--- RETURNS NIL, which akkar reads as "the hook declined", so the built-in
--- `{"error": "internal server error"}` is what the client receives --
--- unchanged, and with nothing of the cause in it. That is the property the
--- 500 path was written to have and this module does not get to spend it.
---
--- An application that wants its own body passes one in, and it runs AFTER
--- the capture rather than around it:
---
---     app:on_error(reporter:handler(function(err, req)
---       return akkar.response(500, { instance = req.id })
---     end))
---
--- After, and outside any pcall of ours, for two reasons. The capture must
--- not be lost to a bug in somebody's response builder; and `internal_error`
--- already pcalls this whole hook and logs "the error handler itself raised",
--- so catching it here would replace a diagnostic with silence.
function Reporter:handler(inner)
  return function(err, req)
    self:capture(err, req)
    if inner then return inner(err, req) end
    return nil
  end
end

M.Reporter = Reporter

return M
