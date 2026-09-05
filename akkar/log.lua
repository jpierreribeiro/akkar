--[[
akkar.log — structured logging.

Two formats, because the two audiences want opposite things.  A machine
grepping production wants one JSON object per line.  A person watching a
terminal wants to read it without a parser.  Making that a choice rather than
a compromise is cheaper than either audience losing.

The part that earns its keep is `:with`.  A logger bound to a request id is
handed to the handler as `req.log`, so correlation is a property of the
logger rather than something every call site has to remember to pass.  A rule
nobody has to follow is worth more than a rule everybody has to.

Output goes to stderr by default, so nothing needs configuring to work.
]]

local cjson = require "akkar.json"
local time  = require "akkar.time"

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }

local Logger = {}
Logger.__index = Logger

-- A logger and every `:with` derived from it share one unique sink function.
-- Keeping delivery state beside that function avoids adding a fifth field to
-- every request-bound logger (measured elsewhere in this file as 128 bytes).
local DELIVERY_OF = setmetatable({}, { __mode = "k" })

local function delivery_of(logger)
  local delivery = DELIVERY_OF[logger.sink]
  if not delivery then
    -- `sink` is a public field and old code may replace it after construction.
    -- Stay safe on that path too; log.new still gives every root a unique key.
    delivery = { dropped = 0 }
    DELIVERY_OF[logger.sink] = delivery
  end
  return delivery
end

-- Values that survive a JSON round-trip.  Anything else is stringified rather
-- than silently dropped, because a log line that quietly loses a field is
-- worse than an ugly one.
local function safe(value)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then return value end
  if kind == "nil" then return nil end
  if kind == "table" then
    local out = {}
    for k, v in pairs(value) do out[tostring(k)] = safe(v) end
    return out
  end
  return tostring(value)
end

local function merge(into, from)
  if not from then return into end
  for key, value in pairs(from) do into[key] = safe(value) end
  return into
end

--- Renders one field value for the text format.
---
--- AN ID IS NOT `7.0`, and this is the framework's own line doing it.
---
--- A job payload round-trips through JSON, and a JSON number comes back as a
--- Lua float. So `account_id = 7` in a handler became `account_id=7.0` in
--- akkar's own log, which reads like a bug to anybody grepping for an id and
--- is not one. Reported by someone writing the guide, who found it because
--- they pasted real output into a page and it looked wrong on the screen.
---
--- A float whose value is whole is printed without the fractional part. That
--- loses the distinction between `7` and `7.0`, which is a distinction a LOG
--- reader has never once wanted: a duration of two seconds reads better as
--- `2` than as `2.0`, and an id reads correctly only as `7`.
---
--- The bound matters. Beyond 2^53 a float can no longer represent every
--- integer, so `%d` on one would print a number that was never the value;
--- those keep their float rendering, where the exponent at least admits the
--- imprecision.
--- A decimal point, whatever LC_NUMERIC says. `akkar/metrics.lua` carries the
--- same three lines and the long version of why; the short version is that
--- Lua renders a float through C's `printf`, so under a comma locale
--- `tostring(0.0134)` is `0,0134`, and a duration written that way reaches the
--- log store as a string rather than as a number. Lower stakes than the
--- metrics case -- logfmt does not separate on a comma, so nothing is
--- MISPARSED -- but a `duration_s` that stops being numeric stops being
--- graphable, and the repair is the same three lines.
---
--- Under "C" this substitutes `.` for `.` and every log line is byte-identical.
local function decimal(rendered)
  if not rendered:find "%d" then return rendered end
  return (rendered:gsub("[^-+0-9eE]", "."))
end

local function render(value)
  if type(value) == "table" then return cjson.encode(value) end
  if math.type(value) == "float" and value == math.floor(value)
     and math.abs(value) < 2 ^ 53 then
    return string.format("%d", value)
  end
  if type(value) == "number" then return decimal(tostring(value)) end
  return tostring(value)
end

-- logfmt separates fields with a space, so a value that CONTAINS one ends its
-- field and starts another. Written raw, any value reachable from a request --
-- a name, a search term, a user agent, the request id itself -- forged fields:
-- an email of `a@b.test role=admin tenant=other` arrived at the log store as
-- three fields, two of them invented by the caller. A newline forged a whole
-- line, which is worse: it invents an event that never happened, at whatever
-- level it likes.
--
-- Text is the DEFAULT format, so this was on by default. Values that are
-- plainly safe are still written bare, because the point of logfmt is that a
-- person can read it.
local SAFE = "^[%w_%-%.:/@+]+$"

local function escape(text)
  return (text:gsub("[\\\"]", "\\%0")
              :gsub("%c", function(char)
                if char == "\n" then return "\\n" end
                if char == "\r" then return "\\r" end
                if char == "\t" then return "\\t" end
                return string.format("\\x%02x", char:byte())
              end))
end

-- `render` decides how a value READS; this decides whether it can escape its
-- own field. Both, in that order.
local function field_value(value)
  local text = render(value)
  if text:match(SAFE) then return text end
  return '"' .. escape(text) .. '"'
end

-- A key with a space or an `=` in it forges just as well as a value does, and
-- keys arrive from `bind` and from caller-supplied field tables.
local function field_key(key)
  key = tostring(key)
  if key:match(SAFE) then return key end
  return (key:gsub("[^%w_%-%.:/@+]", "_"))
end

local function format_text(entry)
  -- The message is positional rather than quoted, so it cannot carry its own
  -- `key=value` ambiguity away -- but a newline in it would still end the
  -- line, so control characters go.
  local parts = { string.format("%-5s %s", entry.level:upper(),
                                escape(tostring(entry.message))) }
  local keys = {}
  for key in pairs(entry) do
    if key ~= "level" and key ~= "message" and key ~= "time" then keys[#keys + 1] = key end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = field_key(key) .. "=" .. field_value(entry[key])
  end
  return table.concat(parts, " ")
end

--- Calls a sink without giving it control of the request or shutdown path.
---
--- A conventional callback returns nothing on success. File-like sinks may
--- instead return `nil, reason, errno`, and a stricter sink may raise. Both
--- failure shapes mean the line was dropped; neither is allowed to escape.
local function write_sink(sink, line)
  -- Fixed locals deliberately avoid allocating a result table for every log
  -- line. A sink with no returns is the conventional success shape.
  local ok, result, reason, errno = pcall(sink, line)
  if not ok then return false, tostring(result) end
  if result == false then
    return false, tostring(reason or "sink returned false")
  end
  if result == nil and (reason ~= nil or errno ~= nil) then
    return false, tostring(reason or errno)
  end
  return true
end

local function formatted(logger, entry)
  return logger.format == "json" and cjson.encode(entry) or format_text(entry)
end

function Logger:log(level, message, fields)
  if LEVELS[level] < LEVELS[self.level] then return end

  local entry = { level = level, message = message, time = time.now() }
  merge(entry, self.bound)
  merge(entry, fields)

  local delivered, why = write_sink(self.sink, formatted(self, entry) .. "\n")
  local delivery = delivery_of(self)
  local recovery_export
  if not delivered then
    delivery.dropped = delivery.dropped + 1
    delivery.last_error = why
  elseif delivery.dropped > 0 then
    -- The first ordinary line gets through before this notice, proving the
    -- sink has actually recovered. Only then announce how much evidence was
    -- lost. If the notice itself fails, keep the count for the next attempt.
    local recovery = {
      level = "warn", message = "log sink recovered", time = time.now(),
      dropped = delivery.dropped, last_error = delivery.last_error,
    }
    local recovered, recovery_error =
      write_sink(self.sink, formatted(self, recovery) .. "\n")
    if recovered then
      delivery.dropped, delivery.last_error = 0, nil
      recovery_export = recovery
    else
      delivery.last_error = recovery_error
    end
  end

  -- THE SECOND OUTPUT IS AN APPEND, and it comes after the sink on purpose.
  --
  -- `exporter` is anything with a `record(entry)` -- in practice the bounded
  -- queue from `akkar.trace`, which `akkar/otlp.lua` hands a log encoder.
  -- `record` adds the entry to a table or refuses it when the table is full,
  -- and nothing else: no encoding, no socket. The OTLP payload is built on
  -- the export loop, off the request. stderr is written FIRST so that a line
  -- reaches the operator's terminal even when the exporter is the thing that
  -- is broken.
  if self.exporter then
    self.exporter:record(entry)
    if recovery_export then self.exporter:record(recovery_export) end
  end
end

for level in pairs(LEVELS) do
  Logger[level] = function(self, message, fields) self:log(level, message, fields) end
end

--- Returns a logger carrying `fields` on every line it writes.
--- This is what makes `req.log` correlate without the caller doing anything.
function Logger:with(fields)
  local bound = {}
  merge(bound, self.bound)
  merge(bound, fields)
  local derived = setmetatable({
    level = self.level, format = self.format, sink = self.sink, bound = bound,
  }, Logger)
  -- Assigned after construction, not listed in the constructor. A fifth
  -- field in the constructor presizes the hash part for eight slots whether
  -- or not the value is nil, and this table is built once per request for
  -- `req.log` -- the cost lands on every request in the process, including
  -- the ones in a process that exports nothing. Measured: 128 bytes.
  if self.exporter then derived.exporter = self.exporter end
  return derived
end

--- Delivery failures observed by this logger and every logger derived from it.
--- Returns a copy so callers cannot erase an outage by mutating the result.
function Logger:stats()
  local delivery = delivery_of(self)
  return { dropped = delivery.dropped, last_error = delivery.last_error }
end

local M = {}

--- Builds a logger.
---
--- `exporter` is optional and additive: stderr (or `sink`) is written either
--- way, and the exporter receives the same entry as a table. See `Logger:log`
--- for what it may do with it, which is append and nothing more.
function M.new(options)
  options = options or {}
  local level = options.level or "info"
  if not LEVELS[level] then
    error("akkar.log: unknown level '" .. tostring(level) ..
          "'; use debug, info, warn or error", 2)
  end
  local target_sink = options.sink
                      or function(line) return io.stderr:write(line) end
  -- Unique per root logger, shared by its derived loggers. Besides carrying
  -- the side-table identity, this preserves every return value a file sink
  -- uses to report `nil, reason, errno`.
  local sink = function(line) return target_sink(line) end
  DELIVERY_OF[sink] = { dropped = 0 }

  local logger = setmetatable({
    level  = level,
    format = options.format or "text",
    sink   = sink,
    bound  = {},
  }, Logger)
  if options.exporter then
    if type(options.exporter.record) ~= "function" then
      error("akkar.log: exporter needs a record(entry) method; pass the " ..
            "logs exporter from akkar.otlp.new{}", 2)
    end
    logger.exporter = options.exporter
  end
  return logger
end

-- ================================================================== OTLP

-- The OpenTelemetry severity numbers, from the logs data model
-- (opentelemetry.io/docs/specs/otel/logs/data-model/): each named level owns
-- a range of four, and the FIRST of the range is the level itself -- DEBUG is
-- 5 to 8, INFO 9 to 12, WARN 13 to 16, ERROR 17 to 20. akkar has one
-- gradation per level, so each maps to the bottom of its range.
local SEVERITY = { debug = 5, info = 9, warn = 13, error = 17 }

-- The entry's own fields, which become LogRecord fields rather than
-- attributes. `trace_id` and `span_id` are whatever the record carries -- this
-- module does not know where they came from -- and are lifted only when they
-- are the shape W3C Trace Context gives them; a collector that receives a
-- malformed `traceId` rejects the whole batch, and a bad value is worth more
-- as an attribute than as the reason forty other records were lost.
local RECORD_FIELDS = { level = true, message = true, time = true,
                        trace_id = true, span_id = true }

local function hex_of(value, length)
  return type(value) == "string" and #value == length
         and value:match "^%x+$" and value:lower() or nil
end

--- One log entry as an OTLP `LogRecord`. Exported so a spec can assert on
--- the shape of a single record without a queue.
---
--- A table-valued field is carried as its JSON text, which is what the text
--- format prints for one too. `any_value` would have called `tostring` on it
--- and shipped `table: 0x55d1...`, which is a field lost with extra steps.
function M.record(entry)
  local trace = require "akkar.trace"
  local level = entry.level or "info"

  local attributes
  for key, value in pairs(entry) do
    if not RECORD_FIELDS[key] then
      attributes = attributes or {}
      attributes[key] = type(value) == "table" and cjson.encode(value) or value
    end
  end

  local stamp = trace.nanoseconds(entry.time or 0)
  local record = {
    timeUnixNano         = stamp,
    observedTimeUnixNano = stamp,
    severityNumber       = SEVERITY[level] or SEVERITY.info,
    severityText         = level:upper(),
    body                 = trace.any_value(tostring(entry.message)),
    attributes           = trace.attributes_of(attributes),
  }

  local trace_id = hex_of(entry.trace_id, 32)
  local span_id  = hex_of(entry.span_id, 16)
  if trace_id then record.traceId = trace_id end
  if span_id  then record.spanId  = span_id  end
  -- Lifted OR kept, never dropped: a value that was not an id still says
  -- something about the line it was on.
  if entry.trace_id and not trace_id then
    record.attributes = record.attributes or {}
    record.attributes[#record.attributes + 1] =
      { key = "trace_id", value = trace.any_value(tostring(entry.trace_id)) }
  end
  if entry.span_id and not span_id then
    record.attributes = record.attributes or {}
    record.attributes[#record.attributes + 1] =
      { key = "span_id", value = trace.any_value(tostring(entry.span_id)) }
  end
  return record
end

--- Builds the OTLP/HTTP JSON `ExportLogsServiceRequest` for a batch of
--- entries. The same shape as `akkar.trace.otlp` and for the same reason: a
--- value a test can assert on, without a collector.
function M.otlp(entries, resource)
  local trace = require "akkar.trace"
  local records = {}
  for i, entry in ipairs(entries) do records[i] = M.record(entry) end
  return {
    resourceLogs = { {
      resource  = { attributes = trace.attributes_of(resource) },
      scopeLogs = { { scope = { name = "akkar" }, logRecords = records } },
    } },
  }
end

M.Logger = Logger
M.LEVELS = LEVELS
M.SEVERITY = SEVERITY
return M
