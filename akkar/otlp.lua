--[[
akkar.otlp — one telemetry pipeline: traces, metrics and logs to one
collector, through one setting, on one background loop.

## What was here, and what was three of

`akkar/trace.lua` already had everything an OTLP export needs and argued for
each piece: a bounded queue that drops rather than blocks, a flush bounded by
size and by time, a swap-before-post so a batch recorded mid-flight is not
lost, counters for every drop, an HTTP capability that a test can fake with a
table, int64s quoted the way OTLP's JSON mapping requires, and a loop that
flushes once more on stop. It had them for spans.

Metrics had a Prometheus scrape, which stays -- a scrape is the right shape
for Prometheus and nothing here changes it. Logs had stderr, which stays as
the default. What neither had was a way to reach the collector the traces
were already going to, and the honest way to give them one was NOT a second
exporter: it was to let the exporter in `akkar/trace.lua` stop assuming it
holds spans. So that module grew two options, `encode` and `name`, and this
one builds three exporters from it -- one per signal, each with its own
queue, bound and counters -- and runs their ticks from a single coroutine.

Three queues rather than one, deliberately. The signals have different
volumes and different worth: a process logs more lines than it records spans,
and a metrics snapshot is a handful of tables every minute that must never be
squeezed out by a burst of either. A shared queue would let the noisiest
signal starve the others of the bound; separate ones let each be dropped on
its own terms and counted on its own line.

## The metrics push is a scrape on a timer, and that is the whole design

`akkar/metrics.lua` reads a pool inside `render()` and gives the reason at
length: pushing from the checkout path costs an allocation per request, and
sampling on a timer reads while the numbers move. A push is neither. Every
`interval` seconds the loop calls `registry:snapshot()`, which is `render()`
in a second shape -- the same numbers, read at the same moment, pools
included -- and hands the result to the metrics exporter's queue. The
request path is not on the call graph. `spec/otlp_spec.lua` proves that with
an HTTP client that raises on contact.

Counters go as CUMULATIVE sums (opentelemetry.io/docs/specs/otel/metrics/
data-model/, "Sums"): every push carries the total since the registry was
built, so a push that is dropped -- by the bound, by a dead collector -- loses
nothing. The next one carries the same total and everything after it. That
is the property that makes drop-don't-block affordable for a metric, where
it would not be for a delta.

## The rules, inherited unchanged

A request is never blocked on an export: `record` appends and nothing else.
The queue is bounded and the newest is refused past it, counted. A failed
batch is dropped, not retried. `stop` exports once more and returns. Each of
those has its argument in `akkar/trace.lua`, and they hold here because it
is the same code.

## The wire format

OTLP/HTTP JSON (opentelemetry.io/docs/specs/otlp/, "JSON Protobuf Encoding"):
`ExportTraceServiceRequest` at `/v1/traces`, `ExportMetricsServiceRequest` at
`/v1/metrics`, `ExportLogsServiceRequest` at `/v1/logs`, each POSTed to the
base endpoint plus that path, which is what the specification says a base
endpoint means. The encoders live beside the data they encode --
`trace.otlp`, `metrics.otlp`, `log.otlp` -- so each can be asserted on as a
value without a collector.
]]

local trace = require "akkar.trace"
local time  = require "akkar.time"

local M = {}

-- The signal paths, from the OTLP specification. A base endpoint has one of
-- these appended; a per-signal endpoint is used exactly as given, which is
-- the distinction the specification draws between
-- `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`.
M.PATHS = { traces = "/v1/traces", metrics = "/v1/metrics", logs = "/v1/logs" }

M.SIGNALS = { "traces", "metrics", "logs" }

M.DEFAULTS = {
  endpoint = "http://localhost:4318",
  -- Sixty seconds, which is the OpenTelemetry SDK's own default for a
  -- periodic metric reader, and an order of magnitude longer than the span
  -- and log interval because a snapshot every five seconds is twelve times
  -- the bytes for the same curve.
  metrics_interval = 60,
  -- A snapshot is small and the loop flushes one the moment it is taken, so
  -- the queue holds more than one only when a flush could not run. Eight is
  -- room for that and no room for a collector that is gone to cost memory.
  metrics_queue = 8,
}

--- The URL one signal is posted to.
---
--- A base ending in a signal path -- `akkar.trace`'s own default is
--- `http://localhost:4318/v1/traces` -- has it removed first, so an operator
--- who copies that value into `endpoint` gets three correct URLs rather than
--- `/v1/traces/v1/metrics`.
function M.endpoint_for(base, signal)
  base = (base or M.DEFAULTS.endpoint):gsub("/+$", "")
  base = base:gsub("/v1/traces$", ""):gsub("/v1/metrics$", ""):gsub("/v1/logs$", "")
  return base .. M.PATHS[signal]
end

-- Later layers win. `select`, not `ipairs` over the pack: a nil layer in the
-- middle -- a signal given no table of its own -- would end an `ipairs` walk
-- before the layers after it, and the exporter behind it would be built
-- from the shared options alone, encoder included.
local function merged(...)
  local out = {}
  for i = 1, select("#", ...) do
    local layer = select(i, ...)
    if layer then
      for key, value in pairs(layer) do out[key] = value end
    end
  end
  return out
end

-- ======================================================== the metrics push

-- An exporter whose `tick` takes a snapshot when the interval has passed
-- and whose `stop` takes a last one. Everything else -- the queue, the
-- bound, the flush, the counters -- is `trace.Exporter` untouched.
local Metrics = setmetatable({}, { __index = trace.Exporter })
Metrics.__index = Metrics

--- Takes a snapshot when one is due, then exports if anything is queued.
---
--- `max_batch` is 1 on this exporter, so a snapshot is exported by the tick
--- that took it: the queue exists for the bound and the counters, not for
--- batching, because two snapshots in one request are two readings of the
--- same cumulative totals and the collector keeps the later.
function Metrics:tick()
  if time.monotime() - self.last_push >= self.interval then
    self.last_push = time.monotime()
    self:record(self.registry:snapshot())
  end
  return trace.Exporter.tick(self)
end

--- Stops after one last snapshot, so the final totals reach the collector.
function Metrics:stop()
  self.stopped = true
  self:record(self.registry:snapshot())
  return self:flush()
end

-- ============================================================ the pipeline

local Pipeline = {}
Pipeline.__index = Pipeline

-- Calls a factory the way `trace.Exporter:client` does -- under pcall, with
-- a failure remembered as `false` so it is not retried on every flush -- so
-- a shared factory behaves exactly as an unshared one would.
local function http_call(factory)
  local ok, client = pcall(factory)
  return ok and client or false
end

--- Builds the pipeline.
---
---     local otlp = akkar.otlp.new {
---       http     = akkar.http.connect { timeout = 2 },
---       endpoint = "http://collector:4318",
---       headers  = { authorization = "Bearer ..." },
---       service  = "checkout",
---       registry = registry,          -- enables the metrics push
---       logs     = { max_queue = 4096 },
---       traces   = { sampler = function(req) return req.path ~= "/health" end },
---     }
---     app:use(otlp:middleware())
---     app:run { log = otlp:logger { level = "info" } }
---     -- once, inside the controller akkar runs on:
---     otlp:run()
---
--- Every signal is on unless told otherwise. `traces = false`, `metrics =
--- false` and `logs = false` each turn one off; a table for any of them is
--- merged over the shared options, so one signal may have its own
--- `endpoint`, `headers`, `interval`, `max_queue` or `sampler`.
---
--- Metrics need a registry and are on only when one is given, as `registry`
--- or as `metrics = { registry = ... }` or as `metrics = registry`. Asking
--- for `metrics = true` without one is a boot error rather than a silent
--- nothing, for the reason `akkar/metrics.lua` raises on a bad pool at
--- registration: it is seen once, by the author, and not in an incident.
function M.new(options)
  options = options or {}

  -- ONE CLIENT FOR THREE EXPORTERS. `trace.Exporter:client` resolves a
  -- factory once per exporter; three exporters would resolve it three times
  -- and hold three connection pools to one collector. Memoised here so the
  -- factory runs once and the exporters share what it returns.
  local http = options.http
  if type(http) == "function" then
    local resolved
    http = function()
      if resolved == nil then resolved = http_call(options.http) end
      return resolved
    end
  end

  local shared = {
    http      = http,
    headers   = options.headers,
    service   = options.service,
    resource  = options.resource,
    timeout   = options.timeout,
    max_batch = options.max_batch,
    max_queue = options.max_queue,
    interval  = options.interval,
    sampler   = options.sampler,
  }

  local function signal(name, given, extra)
    if given == false then return nil end
    local own = merged(shared, type(given) == "table" and given or nil, extra)
    own.name     = "akkar.otlp." .. name
    own.headers  = merged(options.headers,
                          type(given) == "table" and given.headers or nil)
    if next(own.headers) == nil then own.headers = nil end
    own.endpoint = (type(given) == "table" and given.endpoint)
                   or M.endpoint_for(options.endpoint, name)
    return own
  end

  local self = setmetatable({ name = "akkar.otlp" }, Pipeline)

  local traces = signal("traces", options.traces, { encode = trace.otlp })
  if traces then self.traces = trace.new(traces) end

  local logs = signal("logs", options.logs, {
    encode = function(batch, resource)
      return require("akkar.log").otlp(batch, resource)
    end,
  })
  if logs then self.logs = trace.new(logs) end

  local registry = options.registry
  local given = options.metrics
  if type(given) == "table" then
    if type(given.snapshot) == "function" then
      registry, given = given, true
    else
      registry = given.registry or registry
    end
  end
  if given == true and not registry then
    error("akkar.otlp: metrics need a registry; pass registry = " ..
          "akkar.metrics.new() or metrics = false", 2)
  end
  if registry and given ~= false then
    if type(registry.snapshot) ~= "function" then
      error("akkar.otlp: registry has no snapshot(); pass the registry " ..
            "from akkar.metrics.new()", 2)
    end
    local metrics = signal("metrics", given, {
      encode    = function(batch, resource)
        return require("akkar.metrics").otlp(batch, resource)
      end,
      max_batch = 1,
      max_queue = (type(given) == "table" and given.max_queue)
                  or M.DEFAULTS.metrics_queue,
      interval  = (type(given) == "table" and given.interval)
                  or options.metrics_interval or M.DEFAULTS.metrics_interval,
    })
    local exporter = trace.new(metrics)
    exporter.registry  = registry
    exporter.last_push = time.monotime()
    self.metrics = setmetatable(exporter, Metrics)
  end

  return self
end

--- The exporters that are on, in a fixed order.
function Pipeline:each()
  local list = {}
  for _, name in ipairs(M.SIGNALS) do
    if self[name] then list[#list + 1] = self[name] end
  end
  return list
end

--- Ticks every exporter. This is what the loop calls.
function Pipeline:tick()
  local any = false
  for _, exporter in ipairs(self:each()) do
    -- pcall per signal, so a metrics snapshot that raises does not stop the
    -- logs from leaving in the same tick.
    local ok, did = pcall(exporter.tick, exporter)
    any = any or (ok and did) or false
  end
  return any
end

--- Exports every queue now. Returns true, or nil and the reasons joined.
---
--- Not to be called from a handler, for the reason `trace.Exporter:flush`
--- gives: everything in it can wait on a network.
function Pipeline:flush()
  local reasons
  for _, exporter in ipairs(self:each()) do
    local ok, why = exporter:flush()
    if not ok then
      reasons = reasons or {}
      reasons[#reasons + 1] = tostring(why)
    end
  end
  if reasons then return nil, table.concat(reasons, "; ") end
  return true
end

--- Runs one loop for every signal on a cqueues controller. Call it once.
---
--- The nap is a quarter of the SHORTEST interval, capped at a second, for
--- the reason `trace.Exporter:run` gives: the size bound wants checking
--- more often than the time bound.
function Pipeline:run(controller)
  local shortest = math.huge
  for _, exporter in ipairs(self:each()) do
    shortest = math.min(shortest, exporter.interval)
  end
  if shortest == math.huge then shortest = trace.DEFAULTS.interval end
  return trace.loop(self, controller, math.min(shortest / 4, 1))
end

--- Stops the loop after one last export of every signal.
function Pipeline:stop()
  self.stopped = true
  local reasons
  for _, exporter in ipairs(self:each()) do
    local ok, why = exporter:stop()
    if not ok then
      reasons = reasons or {}
      reasons[#reasons + 1] = tostring(why)
    end
  end
  if reasons then return nil, table.concat(reasons, "; ") end
  return true
end

--- The counters, per signal: `{ traces = {...}, metrics = {...}, logs = {...} }`,
--- each the table `trace.Exporter:stats` returns. A signal that is off is
--- absent. Put every `dropped` and `failed` on a dashboard.
function Pipeline:stats()
  local out = {}
  for _, name in ipairs(M.SIGNALS) do
    if self[name] then out[name] = self[name]:stats() end
  end
  return out
end

--- The server-span middleware, from the traces exporter.
---
--- With traces off it is a middleware that does nothing, so `app:use` at the
--- call site does not have to know which signals were configured.
function Pipeline:middleware(options)
  if self.traces then return self.traces:middleware(options) end
  return function(req, next) return next(req) end
end

--- A logger whose lines also reach the collector.
---
---     app:run { log = otlp:logger { level = "info", format = "json" } }
---
--- `akkar.log.new(options)` with `exporter` set to the logs exporter, which
--- `req.log` inherits through `:with`. With logs off it is a plain logger.
function Pipeline:logger(options)
  options = merged(options)
  if self.logs then options.exporter = self.logs end
  return require("akkar.log").new(options)
end

M.Pipeline = Pipeline
M.Metrics  = Metrics
return M
