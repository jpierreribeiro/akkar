# akkar.log

Structured logging in two formats: one JSON object per line for a collector,
or aligned text for a terminal. A logger can carry bound fields, which is how
`req.log` correlates every line of one request without the handler passing
anything.

**When you need it.** You want your own logger for code that runs outside a
request (a worker, a migration, a boot-time check), or you want to replace the
one akkar writes its own lines through by passing `app:run { log = ... }`.

```lua no-run
local log = require "akkar.log"
```

## Contents

- [log.LEVELS](#loglevels)
- [log.Logger](#loglogger)
- [log.new(options)](#lognewoptions)
- [Logger](#logger)
  - [logger:debug(message, fields)](#loggerdebugmessage-fields)
  - [logger:error(message, fields)](#loggererrormessage-fields)
  - [logger:info(message, fields)](#loggerinfomessage-fields)
  - [logger:log(level, message, fields)](#loggerloglevel-message-fields)
  - [logger:warn(message, fields)](#loggerwarnmessage-fields)
  - [logger:with(fields)](#loggerwithfields)
- [Not here](#not-here)

## log.LEVELS

The level names and their numeric severities, as a table. A message is written
when its own severity is not lower than the logger's.

| name | severity |
|---|---|
| `debug` | 10 |
| `info` | 20 |
| `warn` | 30 |
| `error` | 40 |

## log.Logger

The metatable every logger shares. Exported so a test can check that a value
is a logger, and so a caller can add a method to every logger in the process.
Nothing in akkar requires you to touch it.

## log.new(options)

Builds a logger. All fields are optional.

| field | type | default | meaning |
|---|---|---|---|
| `level` | string | `"info"` | one of `debug`, `info`, `warn`, `error`. Lines below it are not written and not formatted. |
| `format` | string | `"text"` | `"json"` writes one JSON object per line. Any other value writes text. |
| `sink` | function | writes to stderr | called with one string per line, newline included. |

**Returns** a logger.

**Raises** `akkar.log: unknown level '<name>'; use debug, info, warn or error`
when `level` is not one of the four. `format` is not validated: a value that is
not `"json"` produces text output.

```lua
local log = require "akkar.log"

local logger = log.new { level = "info", sink = function(line) io.write(line) end }

logger:info("server started", { port = 3000 })
logger:debug("not printed, below the level")
```

```
INFO  server started port=3000
```

## Logger

### logger:debug(message, fields)

Writes at `debug`. Same shape as `logger:info`.

### logger:error(message, fields)

Writes at `error`. Same shape as `logger:info`.

### logger:info(message, fields)

Writes one line at `info`. `message` is a string. `fields` is an optional table
of extra keys, merged over the logger's bound fields.

A field value that is a string, a number or a boolean is written as it is. A
table is written recursively. Anything else (a function, a userdata) is passed
through `tostring` rather than dropped.

In text format the fields are sorted by key and the timestamp is not printed.
In JSON format the entry carries `level`, `message` and `time` (seconds since
the epoch, from `akkar.time`) alongside the fields.

**Returns** nothing.

```lua
local log = require "akkar.log"

local logger = log.new { format = "json", sink = function(line) io.write(line) end }
logger:info("payment taken", { account_id = 7, amount = 12.5 })
```

```
{"amount":12.5,"level":"info","time":1786890561,"account_id":7,"message":"payment taken"}
```

### logger:log(level, message, fields)

The method the four named ones call. `level` is a level name.

**Returns** nothing.

**Raises** `attempt to compare nil with number` when `level` is not a known
name. Unlike `log.new`, this path does not check the name first, so prefer the
named methods.

### logger:warn(message, fields)

Writes at `warn`. Same shape as `logger:info`.

### logger:with(fields)

Returns a new logger that writes `fields` on every line, on top of whatever it
already carried. The original logger is unchanged, and level, format and sink
are copied.

This is what akkar itself does per request: `req.log` is the configured logger
with `request_id` bound to that request, `client_request_id` when the caller
sent an `x-request-id`, and `trace_id` and `span_id` when the request carries
a trace: an inbound `traceparent`, or a span started by
[akkar.trace](trace.md)'s middleware, whichever is the span the line is
written inside. A request with no trace gets **no** `trace_id` key, rather
than an empty one. Those two names are the fields the OpenTelemetry log data
model puts on a log record for correlation, so a collector that indexes them
joins a line to its span without being told how.

**Returns** a logger.

```lua
local akkar = require "akkar"
local log   = require "akkar.log"
local json  = require "akkar.json"

local lines = {}
local logger = log.new { format = "json", sink = function(line) lines[#lines + 1] = line end }

local app = akkar.new()
app:get("/", function(req) req.log:info("handler ran") return { ok = true } end)
local client = app:test { log = logger }

client:get("/", { headers = {
  traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
} })
print(json.decode(lines[1]).trace_id)   --> 4bf92f3577b34da6a3ce929d0e0e4736
print(json.decode(lines[1]).span_id)    --> 00f067aa0ba902b7

client:get "/"
print(json.decode(lines[2]).trace_id)   --> nil: no trace, no key
```

```lua
local log = require "akkar.log"

local logger = log.new { sink = function(line) io.write(line) end }
local bound = logger:with { request_id = "1a2b3c" }

bound:warn("slow query", { took_ms = 120 })
bound:with({ table_name = "tasks" }):error("query failed")
```

```
WARN  slow query request_id=1a2b3c took_ms=120
ERROR query failed request_id=1a2b3c table_name=tasks
```

## Not here

- **Log file rotation.** The sink is a function, so writing to a file, to a
  socket or to a rotating handle is the caller's to arrange.
- **A global logger.** There is no module-level `log.info`. A logger is a
  value, and the one akkar hands a handler is `req.log`.
- **Redaction.** A field is written as it is given. A value wrapped by
  `akkar.config.secret` is safe (it holds nothing), but a plain string holding
  a password is written in full.
- **Sampling or rate limiting of lines.** Every line above the level is
  written.

## See also

- [akkar](akkar.md) for `app:run { log = ... }`, which replaces the logger
  akkar writes its own lines through, and for `req.log`
- [akkar.config](config.md) for `config:redacted()`, the value to log when the
  word `[redacted]` is wanted in the line
- the module source, `akkar/log.lua`, for why an integer-valued float prints
  without its fractional part
