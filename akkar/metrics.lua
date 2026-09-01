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
    counters = {},        -- [name|labels] = { name, labels, value }
    series   = {},        -- [name] = how many label combinations it holds
    pools    = {},         -- list of { label, pool }, read at render time
    pool_labels = {},      -- [label] = true, for the same bound counters have
    started  = time.now(),
  }, Registry)
end

local function key(...)
  return table.concat({ ... }, "\1")
end

-- A metric name and a label name are both fixed by the Prometheus text format
-- and neither can be repaired at scrape time, so both are checked where they
-- are written rather than where they are rendered.
local METRIC_NAME = "^[a-zA-Z_:][a-zA-Z0-9_:]*$"
local LABEL_NAME  = "^[a-zA-Z_][a-zA-Z0-9_]*$"

-- WHY THE COMBINATIONS ARE COUNTED.
--
-- The route label is bounded because akkar knows the pattern that matched,
-- and the method label is bounded because there are nine verbs.  An
-- application counter has neither guarantee: its label values are whatever
-- the handler passes, and a handler that reaches for an order id -- or a
-- customer id, or a client-supplied `result` string -- mints a series per
-- request.  That is the same failure the route label exists to prevent,
-- arriving through the door this method opens.
--
-- So the bound is on the number of distinct label combinations one counter
-- name may hold.  Past it every further combination folds into a single
-- `<other>` series, keeping the label NAMES so the series set stays uniform.
-- That is the answer `middleware` already gives an unrecognised method, and
-- it is chosen for the same reason: the total stays correct while the
-- breakdown stops growing.
--
-- Folded rather than raised.  A counter is measurement, and measurement must
-- not be able to fail the request it is measuring -- a handler incrementing a
-- counter in a loop should not become a 500 on the iteration that crosses a
-- limit it never knew about.  A bad NAME or a negative delta does raise: those
-- are programming mistakes, fixed once, at the call site.
local MAX_SERIES = 64

--- Increments an application counter, creating it at zero on first use.
---
--- `labels` is a LIST OF PAIRS, exactly as `gauge` takes them, because
--- Prometheus renders labels in order and a Lua map would order them
--- differently in every process.
---
--- Returns the new value, so a caller can assert on it without reaching into
--- the registry.
function Registry:counter(name, delta, labels)
  if type(name) ~= "string" or not name:match(METRIC_NAME) then
    error("akkar.metrics: invalid counter name " .. tostring(name), 2)
  end
  delta = delta == nil and 1 or delta
  if type(delta) ~= "number" or delta ~= delta or delta < 0 then
    error("akkar.metrics: counter delta must be a non-negative number, got "
          .. tostring(delta), 2)
  end

  local pairs_list = {}
  for index, pair in ipairs(labels or {}) do
    local label = tostring(pair[1])
    if not label:match(LABEL_NAME) then
      error("akkar.metrics: invalid label name " .. tostring(pair[1])
            .. " at position " .. index, 2)
    end
    pairs_list[index] = { label, tostring(pair[2]) }
  end

  local parts = {}
  for index, pair in ipairs(pairs_list) do
    parts[index] = pair[1] .. "=" .. pair[2]
  end
  local storage_key = key(name, table.concat(parts, ","))

  local found = self.counters[storage_key]
  if not found then
    local held = self.series[name] or 0
    if held >= MAX_SERIES then
      for index, pair in ipairs(pairs_list) do
        pairs_list[index] = { pair[1], "<other>" }
        parts[index] = pair[1] .. "=<other>"
      end
      storage_key = key(name, table.concat(parts, ","))
      found = self.counters[storage_key]
    end
    if not found then
      found = { name = name, labels = pairs_list, value = 0 }
      self.counters[storage_key] = found
      self.series[name] = held + 1
    end
  end

  found.value = found.value + delta
  return found.value
end

-- ===================================================================== pools

-- WHY A POOL IS READ AND NOT PUSHED.
--
-- `Pool` already keeps `waits`, `waited` and `waited_max` as plain fields and
-- hands them out through `Pool:stats()`; nothing was missing from the pool.
-- What was missing was a way for a scrape to reach them, and the two obvious
-- ways to build one are both wrong here.
--
-- Pushing from `Pool:get` -- calling `registry:counter` on the wait path --
-- would put a metrics call in the pool's hot path, which is measured: there
-- is an allocation ceiling per request in `spec/allocation_spec.lua`, and a
-- table per checkout to carry a label list would break it. It would also make
-- the pool depend on the registry, so a pool could only be measured by a
-- process that had one.
--
-- Sampling on a timer -- a coroutine reading `stats()` every second -- would
-- be worse than either. `akkar/pool.lua` says in its own comment at the top of
-- `Pool.new` that a `waited` sample is a measurement of the RUNNING
-- SCHEDULER: a sampler is another thing on that scheduler, it reads while the
-- numbers are moving, and it keeps reading on an idle process that nobody is
-- scraping.
--
-- So the registry holds a reference and reads it inside `render()`, which is
-- exactly what `serve`'s `sources` already does for a gauge -- the difference
-- being that a pool answers with nine numbers at once and three of them are
-- counters, which `sources` cannot express because a gauge is set and a
-- counter is only ever incremented.
--
-- THE LABEL IS BOUNDED, for the reason `Registry:counter` bounds its own.
-- A pool name is the application's string, so past `MAX_SERIES` distinct ones
-- every further pool folds into `pool="<other>"` and its numbers are summed
-- there. Two pools registered under one name sum as well, which is the right
-- answer for both a counter and an occupancy gauge.
local POOL_METRICS = {
  { name = "akkar_pool_size", kind = "gauge", field = "size",
    help = "Slots the pool may fill." },
  { name = "akkar_pool_connections", kind = "gauge", field = "live",
    help = "Connections that exist right now." },
  { name = "akkar_pool_idle", kind = "gauge", field = "idle",
    help = "Connections sitting in the idle set." },
  { name = "akkar_pool_reserved", kind = "gauge", field = "reserved",
    help = "Slots held by an open still in flight." },
  { name = "akkar_pool_waits_total", kind = "counter", field = "waits",
    help = "Checkouts that had to queue for a slot." },
  { name = "akkar_pool_wait_seconds_total", kind = "counter", field = "waited",
    help = "Seconds spent queued for a slot." },
  { name = "akkar_pool_wait_seconds_max", kind = "gauge", field = "waited_max",
    help = "Longest single wait for a slot observed so far." },
  { name = "akkar_pool_retired_total", kind = "counter", field = "retired",
    help = "Connections closed for age rather than for a verdict." },
  { name = "akkar_pool_reaped_total", kind = "counter", field = "reaped",
    help = "Slots recovered from an open nobody came back for." },
}

-- `waited_max` is a high-water mark, so pools sharing a label take the larger
-- of the two rather than the sum of them.
local POOL_MAX = { waited_max = true }

--- Registers a pool to be READ at every scrape, under `pool="<name>"`.
---
--- The registry keeps a reference and calls `pool:stats()` from `render()`.
--- Nothing is sampled, nothing is pushed, and the pool's checkout path is not
--- touched -- see the note above for why each of those matters.
---
--- Anything with a `stats()` returning the fields `Pool:stats()` returns will
--- do; the registry does not require `akkar.pool` specifically.
---
--- Returns the pool, so the call chains off a `db.connect{...}.pool`.
function Registry:pool(name, pool)
  if type(name) ~= "string" or name == "" then
    error("akkar.metrics: pool name must be a non-empty string, got "
          .. tostring(name), 2)
  end
  if type(pool) ~= "table" or type(pool.stats) ~= "function" then
    error("akkar.metrics: " .. name .. " is not a pool: no stats() to read", 2)
  end

  -- Raised rather than folded, unlike a label value: registering a pool
  -- happens once at boot, so a bad argument here is a startup failure the
  -- author sees immediately, not a 500 in the middle of a request.
  local label = name
  if not self.pool_labels[label] then
    local held = 0
    for _ in pairs(self.pool_labels) do held = held + 1 end
    if held >= MAX_SERIES then label = "<other>" end
    self.pool_labels[label] = true
  end

  self.pools[#self.pools + 1] = { label = label, pool = pool }
  return pool
end

-- Reads every registered pool once and folds them into one accumulator per
-- label, sorted so two scrapes of unchanged state produce identical text.
--
-- A pool whose `stats()` raises is skipped rather than allowed to fail the
-- scrape, for the reason `serve` already pcalls a gauge source: an
-- instrument must not be able to take down the thing that reads it.
function Registry:_pool_series()
  local order, by_label = {}, {}
  for _, entry in ipairs(self.pools) do
    local ok, stats = pcall(entry.pool.stats, entry.pool)
    if ok and type(stats) == "table" then
      local acc = by_label[entry.label]
      if not acc then
        acc = { label = entry.label }
        for _, metric in ipairs(POOL_METRICS) do acc[metric.field] = 0 end
        by_label[entry.label] = acc
        order[#order + 1] = entry.label
      end
      for _, metric in ipairs(POOL_METRICS) do
        local value = tonumber(stats[metric.field]) or 0
        if POOL_MAX[metric.field] then
          if value > acc[metric.field] then acc[metric.field] = value end
        else
          acc[metric.field] = acc[metric.field] + value
        end
      end
    end
  end
  table.sort(order)
  local out = {}
  for index, label in ipairs(order) do out[index] = by_label[label] end
  return out
end

-- An integer renders bare and a float renders with six decimals, which is the
-- resolution the histogram's `_sum` already uses. Without this a count that
-- arrived as a float would scrape as `3.0`, and a sub-millisecond wait would
-- scrape in Lua's scientific notation.
local function number(value)
  if math.type(value) == "integer" then return tostring(value) end
  return string.format("%.6f", value)
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
      local rendered = counter.labels and #counter.labels > 0
                       and labels_of(counter.labels) or ""
      line(counter.name .. rendered .. " " .. counter.value)
    end
  end

  -- Read here, at scrape time. Grouped by metric name rather than by pool
  -- because the exposition format requires every sample of one family to be
  -- contiguous, and a scrape that interleaves two families is rejected.
  local pools = self:_pool_series()
  if #pools > 0 then
    line ""
    for _, metric in ipairs(POOL_METRICS) do
      line("# HELP " .. metric.name .. " " .. metric.help)
      line("# TYPE " .. metric.name .. " " .. metric.kind)
      for _, acc in ipairs(pools) do
        line(metric.name .. labels_of { { "pool", acc.label } } ..
             " " .. number(acc[metric.field]))
      end
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
---
--- The METHOD label beside it needed the same treatment and did not have it.
--- The route was bounded exactly as documented while `req.method` -- which is
--- whatever token the client put on the request line -- went straight into a
--- label, so a caller sending a fresh verb per request minted a fresh series
--- per request.  Bounding one of two labels bounds nothing.
local METHODS = {
  GET = true, HEAD = true, POST = true, PUT = true, PATCH = true,
  DELETE = true, OPTIONS = true, TRACE = true, CONNECT = true,
}

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
    local method = req.method
    self:observe(METHODS[method] and method or "<other>",
                 req.route or "<unmatched>", status, elapsed)

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
