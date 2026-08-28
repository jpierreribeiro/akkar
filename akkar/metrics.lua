--[[
akkar.metrics — Prometheus text format, no dependency.

Labelled by ROUTE PATTERN, never by request path.  `/users/:id` is one series;
`/users/1`, `/users/2`, `/users/3` would be three million.  Unbounded label
cardinality is the classic way to take down a metrics backend, and a framework
that hands you `req.path` as a label is handing you that footgun.  akkar knows
the pattern that matched, so it uses that.

Deliberately small: counters, a latency histogram and gauges.  No summaries
with quantiles, because those cannot be aggregated across processes, and this
framework's answer to more CPU is more processes.
]]

local M = {}

-- Buckets in seconds, chosen for an API talking to a database: sub-millisecond
-- is noise here, and anything past 10 s has already hit the request deadline.
local DEFAULT_BUCKETS = { 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 }

local Registry = {}
Registry.__index = Registry

function M.new(options)
  options = options or {}
  return setmetatable({
    buckets  = options.buckets or DEFAULT_BUCKETS,
    requests = {},        -- [method|route|status] = count
    duration = {},        -- [method|route] = { counts = {}, sum, total }
    gauges   = {},        -- [name|labels] = value
    counters = {},        -- [name|labels] = monotonically increasing value
    started  = os.time(),
  }, Registry)
end

local function key(...)
  return table.concat({ ... }, "\1")
end

local METRIC_NAME = "^[a-zA-Z_:][a-zA-Z0-9_:]*$"

--- Increments an application counter. Labels are an ordered list of
--- { name, value } pairs so callers cannot accidentally create unstable keys.
function Registry:counter(name, delta, labels)
  if type(name) ~= "string" or not name:match(METRIC_NAME) then
    error("akkar.metrics: invalid counter name " .. tostring(name), 2)
  end
  delta = delta or 1
  if type(delta) ~= "number" or delta < 0 then
    error("akkar.metrics: counter delta must be a non-negative number", 2)
  end
  local label_key = ""
  for _, pair in ipairs(labels or {}) do
    label_key = label_key .. "\1" .. tostring(pair[1]) .. "\1" .. tostring(pair[2])
  end
  local storage_key = key(name, label_key)
  local found = self.counters[storage_key]
  if not found then
    found = { name = name, labels = labels, value = 0 }
    self.counters[storage_key] = found
  end
  found.value = found.value + delta
  return found.value
end

function Registry:observe(method, route, status, seconds)
  local counter = key(method, route, tostring(status))
  self.requests[counter] = (self.requests[counter] or 0) + 1

  local bucket_key = key(method, route)
  local hist = self.duration[bucket_key]
  if not hist then
    hist = { counts = {}, sum = 0, total = 0 }
    for i = 1, #self.buckets do hist.counts[i] = 0 end
    self.duration[bucket_key] = hist
  end
  hist.sum = hist.sum + seconds
  hist.total = hist.total + 1
  for i, edge in ipairs(self.buckets) do
    if seconds <= edge then hist.counts[i] = hist.counts[i] + 1 end
  end
end

--- Sets a gauge, for things that are read rather than counted: pool
--- occupancy, queue depth, in-flight requests.
function Registry:gauge(name, value, labels)
  self.gauges[key(name, labels or "")] = { name = name, labels = labels, value = value }
end

-- A label value may contain a quote or a backslash; Prometheus needs both
-- escaped or the scrape fails to parse.
local function escape(value)
  return (tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end

local function labels_of(pairs_list)
  local out = {}
  for _, pair in ipairs(pairs_list) do
    out[#out + 1] = pair[1] .. '="' .. escape(pair[2]) .. '"'
  end
  return "{" .. table.concat(out, ",") .. "}"
end

--- Renders the whole registry in Prometheus text format.
function Registry:render()
  local out = {}
  local function line(s) out[#out + 1] = s end

  line "# HELP akkar_requests_total Requests handled, by method, route and status."
  line "# TYPE akkar_requests_total counter"
  local names = {}
  for k in pairs(self.requests) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do
    local method, route, status = k:match "([^\1]*)\1([^\1]*)\1([^\1]*)"
    line("akkar_requests_total" ..
         labels_of { { "method", method }, { "route", route }, { "status", status } } ..
         " " .. self.requests[k])
  end

  if next(self.counters) then
    line ""
    local counter_keys = {}
    for k in pairs(self.counters) do counter_keys[#counter_keys + 1] = k end
    table.sort(counter_keys)
    local declared = {}
    for _, k in ipairs(counter_keys) do
      local counter = self.counters[k]
      if not declared[counter.name] then
        line("# TYPE " .. counter.name .. " counter")
        declared[counter.name] = true
      end
      line(counter.name .. labels_of(counter.labels or {}) .. " " .. counter.value)
    end
  end

  line ""
  line "# HELP akkar_request_duration_seconds Request duration."
  line "# TYPE akkar_request_duration_seconds histogram"
  local hist_keys = {}
  for k in pairs(self.duration) do hist_keys[#hist_keys + 1] = k end
  table.sort(hist_keys)
  for _, k in ipairs(hist_keys) do
    local method, route = k:match "([^\1]*)\1([^\1]*)"
    local hist = self.duration[k]
    for i, edge in ipairs(self.buckets) do
      line("akkar_request_duration_seconds_bucket" ..
           labels_of { { "method", method }, { "route", route }, { "le", tostring(edge) } } ..
           " " .. hist.counts[i])
    end
    line("akkar_request_duration_seconds_bucket" ..
         labels_of { { "method", method }, { "route", route }, { "le", "+Inf" } } ..
         " " .. hist.total)
    line("akkar_request_duration_seconds_sum" ..
         labels_of { { "method", method }, { "route", route } } ..
         " " .. string.format("%.6f", hist.sum))
    line("akkar_request_duration_seconds_count" ..
         labels_of { { "method", method }, { "route", route } } ..
         " " .. hist.total)
  end

  if next(self.gauges) then
    line ""
    local gauge_keys = {}
    for k in pairs(self.gauges) do gauge_keys[#gauge_keys + 1] = k end
    table.sort(gauge_keys)
    local declared = {}
    for _, k in ipairs(gauge_keys) do
      local g = self.gauges[k]
      if not declared[g.name] then
        line("# TYPE " .. g.name .. " gauge")
        declared[g.name] = true
      end
      line(g.name .. (g.labels and labels_of(g.labels) or "") .. " " .. g.value)
    end
  end

  line ""
  line "# TYPE akkar_uptime_seconds gauge"
  line("akkar_uptime_seconds " .. (os.time() - self.started))

  return table.concat(out, "\n") .. "\n"
end

-- Memory, from inside the process and from the kernel.
--
-- Two numbers because they answer different questions.  Lua's own heap says
-- whether the application is holding on to tables; RSS says what the operating
-- system thinks the process costs, which includes the C side -- socket
-- buffers, the TLS context, whatever a driver allocated.  A leak that shows in
-- one and not the other tells you which half to look at.
function Registry:memory()
  local lua_bytes = collectgarbage "count" * 1024

  local rss_bytes = 0
  local statm = io.open "/proc/self/statm"
  if statm then
    local fields = statm:read "l"
    statm:close()
    local pages = fields and fields:match "%d+%s+(%d+)"
    if pages then rss_bytes = tonumber(pages) * 4096 end
  end

  return lua_bytes, rss_bytes
end

-- ================================================================ integration

--- Middleware that records every request.
---
--- `req.route` is the pattern that matched, so the label set stays bounded no
--- matter how many distinct paths are requested.  A request that matched no
--- route is recorded as `<unmatched>` rather than by its path, for the same
--- reason: otherwise a scanner probing random URLs would create a series per
--- probe.
function Registry:middleware()
  local cqueues = require "cqueues"
  return function(req, next)
    local started = cqueues.monotime()
    local res = next(req)
    self:observe(req.method, req.route or "<unmatched>", res.status,
                 cqueues.monotime() - started)
    return res
  end
end

--- Mounts `GET /metrics` and returns the app.
---
--- `sources` maps a gauge name to a function returning its value, read at
--- scrape time -- pool occupancy and queue depth are worth knowing and are
--- cheap only when asked for.
function Registry:serve(app, path, sources)
  local akkar = require "akkar"
  app:get(path or "/metrics", function()
    -- Memory is always reported: a scrape that cannot answer "is it growing?"
    -- is missing the question most often asked of one.
    local lua_bytes, rss_bytes = self:memory()
    self:gauge("akkar_lua_heap_bytes", math.floor(lua_bytes))
    self:gauge("akkar_process_resident_bytes", rss_bytes)

    for name, source in pairs(sources or {}) do
      local ok, value = pcall(source)
      if ok and type(value) == "number" then self:gauge(name, value) end
    end
    return akkar.raw(self:render(), "text/plain; version=0.0.4")
  end)
  return app
end

M.Registry = Registry
M.DEFAULT_BUCKETS = DEFAULT_BUCKETS
return M
