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

local time = require "akkar.time"

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
    started  = time.now(),
  }, Registry)
end

local function key(...)
  return table.concat({ ... }, "\1")
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
--- Records a gauge, optionally with labels.
---
--- `labels` is a LIST OF PAIRS -- `{ { "queue", "emails" }, { "state", "due" } }`
--- -- because Prometheus labels are ordered in the rendered line and a Lua map
--- would render in a different order on every process.
---
--- THE LABELLED PATH RAISED ON EVERY CALL, and nothing noticed for as long as
--- this module has existed. The map key was built with `table.concat{ name,
--- labels }`, which is `invalid value (at index 2) in table for 'concat'` the
--- moment `labels` is a table. So `render` had complete, correct label
--- support that could not be reached, and the spec only ever called this with
--- two arguments -- which is how a whole branch stays dead in a tested module.
---
--- Found by an agent writing reference documentation, who called every public
--- function with every documented argument rather than the arguments the
--- tests happened to use. That is the difference between a test suite and a
--- reader.
function Registry:gauge(name, value, labels)
  local label_key = ""
  if labels then
    local parts = {}
    for _, pair in ipairs(labels) do
      parts[#parts + 1] = tostring(pair[1]) .. "=" .. tostring(pair[2])
    end
    label_key = table.concat(parts, ",")
  end
  self.gauges[key(name, label_key)] =
    { name = name, labels = labels, value = value }
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
  line("akkar_uptime_seconds " .. (time.now() - self.started))

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
  else
    -- No /proc, which is every platform that is not Linux. Reporting zero
    -- there is worse than reporting nothing: a resident size of 0 reads as a
    -- process using no memory, and the pair of numbers exists precisely so a
    -- leak outside the Lua heap is visible.
    --
    -- `ps -o rss=` is POSIX and answers in kilobytes. `$PPID` inside the
    -- popen'd shell IS this process -- reading `ps` for the shell itself
    -- would measure the subprocess, which is the mistake to avoid here.
    --
    -- Only on the fallback path: Linux keeps the file read, and does not pay
    -- for a subprocess per scrape.
    local pipe = io.popen "ps -o rss= -p $PPID 2>/dev/null"
    if pipe then
      local kb = tonumber((pipe:read "a" or ""):match "%d+")
      pipe:close()
      if kb then rss_bytes = kb * 1024 end
    end
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
  local akkar = require "akkar"
  return function(req, next)
    local started = time.monotime()

    -- OBSERVED ON BOTH OUTCOMES. Raising is how akkar expresses a deliberate
    -- 404 and how a handler error becomes a 500, so measuring only the value
    -- that came back left the histogram blind to every error the server ever
    -- produced -- while reporting a clean latency distribution over the
    -- requests that happened to succeed.
    --
    -- That is worse than a missing metric. An operator reads this during an
    -- incident, and during an incident the errors ARE the traffic. A scrape
    -- that omits them says the server is healthy in the exact minute it is
    -- not.
    local ok, res = pcall(next, req)
    local elapsed = time.monotime() - started

    local status
    if ok then
      status = res.status
    elseif akkar.is_response(res) then
      status = res.status         -- a thrown response: 404, 412, 429
    else
      status = 500                -- a raised error, which dispatch turns into one
    end
    self:observe(req.method, req.route or "<unmatched>", status, elapsed)

    if not ok then error(res, 0) end
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
