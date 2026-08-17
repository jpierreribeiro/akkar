--[[
akkar — a microframework for JSON APIs on cqueues and lua-http.

Three ideas shape everything here, and each one comes from a concrete defect
in a framework that exists:

  1. Handlers RETURN a response instead of mutating a context, which makes
     writing the response twice structurally impossible.
  2. All I/O goes through adapters the framework owns, never through a
     library called directly from a handler.
  3. A watchdog warns when a handler blocks the event loop without yielding —
     the number one failure mode of Lua on a server, and one that Go and Node
     leave silent.
]]

local cqueues = require "cqueues"
local time    = require "akkar.time"
local server  = require "akkar.vendor.http.server"
local headers = require "akkar.vendor.http.headers"
local cjson   = require "akkar.json"
local log     = require "akkar.log"
local multipart = require "akkar.multipart"
-- The execution machinery, with no HTTP in it. `akkar.execution` requires only
-- `cqueues` and `akkar.time`, so there is no cycle back to this file.
local execution = require "akkar.execution"

local akkar = {}

-- ============================================================== hostile bytes
--
-- A JSON text SHALL be encoded in UTF-8 (RFC 8259). cjson does not enforce
-- that on the way out: given a Lua string holding `\xC3\x28` it emits those
-- bytes, and the document is then not JSON. Measured, not assumed.
--
-- akkar echoes plenty of caller-supplied text -- a path parameter into a 404,
-- a header into a response, a validation error naming the value it rejected
-- -- so a client sending eight bad bytes could make akkar answer something no
-- strict parser will read.
--
-- CLEANED WHERE IT ENTERS, NOT WHERE IT LEAVES, and that is a measurement
-- rather than a preference. Validating every encoded response was tried
-- first: one `utf8.len` over the finished document costs **20.8% on a
-- hundred-row response and 59.9% on a thousand**, which is a tax on exactly
-- the endpoints this framework is trying to be good at. A path parameter and
-- a header are tens of bytes, once per request, and the check is free at that
-- size.
--
-- What that leaves outside the guarantee, said plainly: text coming back from
-- the database. Postgres validates encoding on the way in for a UTF8
-- database, so a `text` column is already valid; a `bytea` handed straight to
-- a response is the caller's decision and akkar does not inspect it.
--
-- A valid string is returned UNCHANGED and allocates nothing, which is what
-- keeps this off the allocation ceiling. Only bytes that are already broken
-- pay for the repair.
local function safe_text(value)
  if type(value) ~= "string" then return value end
  if utf8.len(value) then return value end

  -- U+FFFD per invalid byte, which is what every other decoder does and what
  -- makes the result inspectable rather than merely legal.
  local out, i, n = {}, 1, #value
  while i <= n do
    local ok = utf8.len(value, i, i)
    if ok then
      local _, stop = utf8.offset(value, 2, i), nil
      stop = (_ or (n + 1)) - 1
      out[#out + 1] = value:sub(i, stop)
      i = stop + 1
    else
      out[#out + 1] = "\239\191\189"      -- U+FFFD
      i = i + 1
    end
  end
  return table.concat(out)
end

akkar.safe_text = safe_text


-- ================================================================= responses
local Response = {}
Response.__index = Response

local function response(status, body, extra_headers)
  return setmetatable({ status = status, body = body, headers = extra_headers,
                        __response = true }, Response)
end
akkar.response = response

local function is_response(v)
  return type(v) == "table" and v.__response == true
end

akkar.ok          = function(body) return response(200, body) end
akkar.created     = function(body) return response(201, body) end
akkar.no_content  = function()     return response(204, nil)  end
akkar.bad_request = function(m)    return response(400, { error = m or "bad request" }) end
akkar.unauthorized= function(m)    return response(401, { error = m or "unauthorized" }) end
akkar.forbidden   = function(m)    return response(403, { error = m or "forbidden" }) end
akkar.not_found   = function(m)    return response(404, { error = m or "not found" }) end
akkar.conflict    = function(m)    return response(409, { error = m or "conflict" }) end
akkar.too_large   = function(m)    return response(413, { error = m or "payload too large" }) end
akkar.unavailable = function(m)    return response(503, { error = m or "service unavailable" }) end

--- A response that is not JSON: Prometheus text, a CSV export, an SVG.
--- The body is written exactly as given, with the content type stated.
function akkar.raw(body, content_type, status)
  local res = response(status or 200, nil)
  res.raw = tostring(body)
  res.content_type = content_type or "text/plain; charset=utf-8"
  return res
end

--- A response whose body is produced as it is written, for the case that does
--- not fit inside "the handler returns the response": an export nobody wants
--- to hold in memory.
---
---     return akkar.stream(function(write)
---       write '{"rows":['
---       for i, row in ipairs(rows) do
---         if i > 1 then write "," end
---         write(cjson.encode(row))
---       end
---       write ']}'
---     end)
---
--- The invariant survives, and that is why it is shaped this way. The handler
--- still **returns a value**. It never receives a connection to write into,
--- never sets a status out of band, and cannot answer twice. The value simply
--- describes a body produced on demand rather than one already in hand.
---
--- Three consequences, none of them hidden:
---
--- **The status is committed with the first byte.** A producer that raises
--- after writing cannot become a 500 -- the 200 is already on the wire. akkar
--- logs it and drops the connection, which is the only honest signal left, and
--- the client sees a truncated response rather than a plausible lie. Validate
--- before the first `write`, where returning or raising a normal response
--- still works.
---
--- **Capabilities stay alive until the body is finished.** A stream reading
--- from `req.db` holds that connection for the whole write, because releasing
--- it when the handler returned would hand a live cursor to the next request.
--- A slow client therefore holds a pool slot for as long as it reads. That is
--- the cost of streaming out of a database, and it is better stated here than
--- discovered in production.
---
--- **The deadline covers the handler, not the body.** A 200 MB export is meant
--- to outlive a 30-second request budget. The watchdog still applies: a
--- producer that burns CPU without yielding stalls the process exactly as a
--- handler would.
function akkar.stream(producer, options)
  if type(producer) ~= "function" then
    error("akkar.stream needs a function(write); got " .. type(producer), 2)
  end
  options = options or {}
  local res = response(options.status or 200, nil, options.headers)
  res.stream = producer
  res.content_type = options.content_type or "application/json"
  return res
end

-- 405 carries Allow.  A 405 without it tells the client it guessed wrong but
-- not what would have been right, which is the whole value of the status.
akkar.method_not_allowed = function(allowed)
  return response(405, { error = "method not allowed", allowed = allowed },
                  { ["allow"] = table.concat(allowed, ", ") })
end

-- Safe defaults, applied unless app:run{} overrides them.  The point is that
-- `app:run()` with no arguments is already production-shaped: a body limit and
-- a deadline exist whether or not anyone remembered to ask for them.
akkar.defaults = {
  body_limit     = 1024 * 1024,   -- 1 MB
  timeout        = 30,            -- seconds of wall clock per request
  shutdown_grace = 10,            -- seconds to drain before saying so
}

-- ================================================== capabilities and settings
-- THE CLOSED SET.  This is the boundary that keeps `req` from decaying into a
-- service locator.
--
-- `req` carries two different kinds of thing, and only one of them is open to
-- extension:
--
--   request data   method, path, params, query, body, headers
--                  derived from the HTTP request itself
--
--   capabilities   db, cache, log, clock
--                  infrastructure injected from app:run{}
--
-- The closed set now lives in `akkar/execution.lua`, because it is a property
-- of an execution and not of a request. Aliased as a local so every use below
-- reads exactly as it did.
local CAPABILITIES = execution.CAPABILITIES

-- What each capability must be able to do.  Checked once at startup, so a
-- misconfigured adapter fails at boot the way a duplicate route already does,
-- rather than on whichever request first happens to touch it.
local CONTRACTS = {
  db    = { "one", "many", "exec", "transaction" },
  cache = { "get", "set", "del" },
  log   = { "debug", "info", "warn", "error", "with" },
  -- The outbound half. `request` is the whole contract -- the verb helpers are
  -- conveniences over it -- so an adapter answering only `request` is a valid
  -- one, which is what makes a fake possible without reimplementing six
  -- methods that all do the same thing.
  http  = { "request", "get", "post" },
}

-- The framework's own voice.  Replaced by `app:run { log = ... }`, but present
-- so nothing has to be configured for diagnostics to appear.
local internal = log.new { level = "info", format = "text" }


-- Everything else app:run{} accepts.  Listed so that a typo is an error rather
-- than silence: `app:run { timout = 5 }` used to be ignored, leaving a server
-- running with a 30 s deadline the author believed was 5 s.
local SETTINGS = {
  host = true, port = true, tls = true, ctx = true,
  body_limit = true, timeout = true, shutdown_grace = true,
  check_capabilities = true, reuseport = true, strict = true,
  max_concurrent = true, trusted_proxies = true,
  repair_substrate = true,
}

-- Route options, checked for the same reason: `app:post("/x", { bdy = ... })`
-- silently declaring no schema at all is worse than an error, because the
-- route then accepts anything while looking validated.
local ROUTE_OPTIONS = {
  params = true, query = true, body = true, response = true, before = true,
}

local function nearest(word, candidates)
  -- Levenshtein, small enough to be worth it: a suggestion turns "unknown
  -- option" into a one-second fix.
  local best, best_distance = nil, math.huge
  for candidate in pairs(candidates) do
    local previous = {}
    for j = 0, #candidate do previous[j] = j end
    for i = 1, #word do
      local current = { [0] = i }
      for j = 1, #candidate do
        local cost = word:sub(i, i) == candidate:sub(j, j) and 0 or 1
        current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      end
      previous = current
    end
    if previous[#candidate] < best_distance then
      best, best_distance = candidate, previous[#candidate]
    end
  end
  if best_distance <= math.max(2, #word // 3) then return best end
end

local function check_config(config, allowed, what)
  for key in pairs(config) do
    if not allowed[key] then
      local suggestion = nearest(key, allowed)
      error(string.format("unknown %s option '%s'%s", what, key,
                          suggestion and ("; did you mean '" .. suggestion .. "'?")
                                      or ""), 3)
    end
  end
end

-- Acquires each configured capability once, checks it answers its contract,
-- and lets it go again.
--
-- This deliberately makes the server refuse to start when the database is
-- unreachable.  That is right for a service whose every route needs it, and
-- wrong for one that should come up degraded and serve a health endpoint --
-- hence `check_capabilities = false`.
--- A deadline the database has never heard of.
---
--- akkar's deadline stops akkar waiting. It does not stop Postgres working:
--- the server notices a departed client only when it next tries to write, and
--- a query producing no output until it completes may not try for minutes. So
--- under load a timeout can leave the database BUSIER than no timeout at all,
--- which is the opposite of the point.
---
--- Asked once, at boot, on a connection that is already open for the contract
--- check -- so it costs nothing per request and it is loud exactly once.
local function warn_unbounded_statements(instance, config)
  if config.timeout == nil and akkar.defaults.timeout == nil then return end
  if type(instance) ~= "table" or type(instance.one) ~= "function" then return end

  local ok, row = pcall(function() return instance:one "show statement_timeout" end)
  if not ok or type(row) ~= "table" then return end        -- not Postgres; fine

  -- Through the logger the application configured, not the framework's own.
  -- A boot-time warning that ignores the configured sink is a warning that
  -- never reaches whatever collects logs in production.
  local log_to = config.log or internal

  local setting = row.statement_timeout
  if setting == nil or setting == "0" then
    log_to:warn("db has no statement_timeout, so a request deadline does " ..
                  "not stop the query", {
      request_deadline_s = config.timeout or akkar.defaults.timeout,
      consequence = "an abandoned query keeps a backend busy after the 503, " ..
                    "and akkar discards the connection rather than reading a " ..
                    "reply it can no longer place -- so every timed-out query " ..
                    "also costs a reconnect",
      fix = "db.connect { statement_timeout = <seconds> }, matching the deadline",
    })
  end
end

local function check_capability_contracts(config)
  for name, methods in pairs(CONTRACTS) do
    local provided = config[name]
    if provided ~= nil then
      local instance = provided
      if type(provided) == "function" or
         (type(provided) == "table" and getmetatable(provided)
          and getmetatable(provided).__call) then
        local ok, result = pcall(provided)
        if not ok then
          error(string.format("akkar: %s could not be acquired: %s",
                              name, tostring(result)), 0)
        end
        instance = result
      end

      local missing = {}
      for _, method in ipairs(methods) do
        if type(instance) ~= "table" or type(instance[method]) ~= "function" then
          missing[#missing + 1] = ":" .. method
        end
      end

      if name == "db" and #missing == 0 then
        pcall(warn_unbounded_statements, instance, config)
      end

      -- Release before raising, so a failed check does not also leak the
      -- connection it just opened.
      if type(instance) == "table" and type(instance.release) == "function" then
        pcall(function() instance:release() end)
      end

      if #missing > 0 then
        error(string.format(
          "akkar: %s does not satisfy the %s contract; missing %s",
          name, name, table.concat(missing, ", ")), 0)
      end
    end
  end
end

local function callable(x)
  if type(x) == "function" then return true end
  local mt = type(x) == "table" and getmetatable(x)
  return mt and mt.__call ~= nil or false
end

-- cjson represents JSON null with a sentinel userdata rather than nil, because
-- a Lua table cannot hold a nil value.  Left alone it leaks into user code in
-- two ugly ways: `{"email": null}` on an OPTIONAL field was rejected as
-- "expected string", and a body of bare `null` reached the validator as
-- userdata and became a 500.
--
-- JSON null means absent, so it is turned back into absent here, once, at the
-- edge -- rather than making every handler and every schema know about a
-- sentinel.
local function strip_nulls(value)
  if value == cjson.null then return nil end
  if type(value) ~= "table" then return value end
  for key, inner in pairs(value) do
    if inner == cjson.null then value[key] = nil
    elseif type(inner) == "table" then strip_nulls(inner) end
  end
  return value
end

-- Walking every field of every row costs real time on a large body, and on
-- almost every body it finds nothing.  A JSON null can only exist in the
-- decoded value if the literal bytes `null` appear in the document, so a
-- substring scan -- one pass in C, no allocation -- rules the walk out
-- entirely.
--
-- The test is conservative in the safe direction.  A string value like
-- "nullable" matches and we walk anyway, which is exactly today's behaviour;
-- there is no document containing a null that this scan can miss.
local function strip_nulls_in(raw, value)
  if raw:find("null", 1, true) then return strip_nulls(value) end
  return value
end

-- ================================================================ validation
-- Two spellings of the same thing.  The short one expands into the long one:
--   "string?"                    ==  v.string { optional = true }
--   v.string { min = 1, max = 9 }
local v = {}
akkar.v = v

-- WHICH CONSTRAINTS EXIST, checked when the rule is built.
--
-- A misspelled constraint used to be ignored in silence, so
-- `v.string { pattern = "@" }` -- `match` is the real name -- accepted every
-- string, and `v.string { mn = 5 }` accepted the empty one. The schema reads
-- as if it validates and does not, which is the worst way for a validator to
-- be wrong.
--
-- `expand` already raises on an unknown schema TYPE. Being strict about the
-- type and silent about the constraints was the inconsistency.
--
-- Checked here rather than in `check_one` on purpose: rules are built once at
-- startup, so a bad schema fails at boot and costs nothing per request.
--
-- Found by porting a real service, where `pattern` was the first thing a hand
-- reached for.
local CONSTRAINTS = {
  kind = true, optional = true, default = true,
  min = true, max = true, match = true, one_of = true,
}

local function validator(kind)
  return function(opts)
    opts = opts or {}
    for key in pairs(opts) do
      if not CONSTRAINTS[key] then
        local known = {}
        for name in pairs(CONSTRAINTS) do
          if name ~= "kind" then known[#known + 1] = name end
        end
        table.sort(known)
        error(("unknown constraint '%s' in v.%s{}; use %s")
              :format(tostring(key), kind, table.concat(known, ", ")), 2)
      end
    end
    opts.kind = kind
    return opts
  end
end

v.string  = validator "string"
v.integer = validator "integer"
v.number  = validator "number"
v.boolean = validator "boolean"
v.table   = validator "table"

local SHORTHAND = { string = true, integer = true, number = true,
                    boolean = true, table = true }

local function expand(rule)
  if type(rule) == "table" then return rule end
  if type(rule) ~= "string" then
    error("invalid schema rule: " .. type(rule), 0)
  end
  local optional = rule:sub(-1) == "?"
  local kind = optional and rule:sub(1, -2) or rule
  if not SHORTHAND[kind] then
    error("unknown schema type: '" .. rule ..
          "'; use string, integer, number, boolean, table (with ? for optional)", 0)
  end
  return { kind = kind, optional = optional }
end

--- Expands every shorthand rule in a schema, once, at route registration.
---
--- `expand` above returns a table rule untouched and ALLOCATES for a string
--- one. So `{ id = "integer", cursor = "string?" }` built two tables on every
--- request, for ever, while the identical schema written with `v.integer{}`
--- built none. Measured on a route with four shorthand rules: 4,428
--- bytes/request against 4,012 for the `v.*` form -- 416 bytes, ~104 per rule,
--- bought back by doing this at boot.
---
--- A NEW TABLE, not a mutation of the caller's. Two routes may share one
--- schema table, and rewriting it under them would work by luck rather than by
--- design.
---
--- After this, `expand` inside `validate` finds a table and returns it
--- untouched -- so `validate` needs no change, and `akkar.validate` keeps
--- accepting raw schemas from callers who never registered a route.
---
--- One deliberate consequence: a bad rule now raises where the route is
--- DECLARED instead of when it is first served. That matches what this file
--- already does with a misspelled constraint and with a duplicate route, and
--- a schema that can never validate anything is worth failing the boot for.
local function expand_schema(schema, what)
  if type(schema) ~= "table" then
    error(("%s must be a table of rules; got %s"):format(what, type(schema)), 0)
  end
  local out = {}
  for field, rule in pairs(schema) do
    local ok, expanded = pcall(expand, rule)
    if not ok then
      -- Name the field. `unknown schema type: 'strng'` with no field is a
      -- message that sends the reader looking through every rule they wrote.
      error(("%s.%s: %s"):format(what, tostring(field), tostring(expanded)), 0)
    end
    out[field] = expanded
  end
  return out
end

local SCHEMA_SLOTS = { "params", "query", "body", "response" }

local function check_one(value, rule, coerce)
  if value == nil then
    if rule.optional then return nil, nil end
    return nil, "required"
  end

  local kind = rule.kind
  if kind == "integer" or kind == "number" then
    -- Route and query values arrive as strings; coercing is right there.
    if coerce and type(value) == "string" then value = tonumber(value) end
    if type(value) ~= "number" then return nil, "expected " .. kind end
    if kind == "integer" and value % 1 ~= 0 then return nil, "expected integer" end
    -- AN INTEGER RULE PRODUCES A LUA INTEGER, not merely an integral float.
    --
    -- JSON has one number type, so `cjson` hands back `120000.0` -- subtype
    -- float -- while the coercing path used for query strings produced a real
    -- integer from `"120000"`. The same rule therefore returned two different
    -- subtypes depending on where the value arrived, and `//`, `%`, bitwise
    -- operators and `string.format("%d", ...)` all behave differently across
    -- that line. `%d` on a float with no integer representation RAISES.
    --
    -- Found porting a service whose money arithmetic is deliberately
    -- integer-only, with a comment in the original saying so.
    if kind == "integer" then value = math.tointeger(value) or value end
    if rule.min and value < rule.min then return nil, "min is " .. rule.min end
    if rule.max and value > rule.max then return nil, "max is " .. rule.max end
  elseif kind == "string" then
    if coerce and type(value) == "number" then value = tostring(value) end
    if type(value) ~= "string" then return nil, "expected string" end
    if rule.min and #value < rule.min then return nil, "min length " .. rule.min end
    if rule.max and #value > rule.max then return nil, "max length " .. rule.max end
    if rule.match and not value:match(rule.match) then return nil, "invalid format" end
    if rule.one_of then
      local found = false
      for _, allowed in ipairs(rule.one_of) do
        if value == allowed then found = true break end
      end
      if not found then
        return nil, "must be one of: " .. table.concat(rule.one_of, ", ")
      end
    end
  elseif kind == "boolean" then
    if coerce and value == "true"  then value = true  end
    if coerce and value == "false" then value = false end
    if type(value) ~= "boolean" then return nil, "expected boolean" end
  elseif kind == "table" then
    if type(value) ~= "table" then return nil, "expected table" end
  end

  if rule.default ~= nil and value == nil then value = rule.default end
  return value, nil
end

-- Returns (clean_table, nil) or (nil, failures_by_field)
local function validate(input, schema, coerce)
  -- Defensive: anything that is not a table is treated as absent, so a
  -- surprising body shape becomes a field-level error rather than a 500.
  if type(input) ~= "table" then input = {} end
  -- `failures` is built only when something fails, and the happy path is the
  -- overwhelming majority. It used to be allocated unconditionally, and a
  -- request declaring `params` and `query` pays for `validate` twice (three
  -- times with a body), so that was up to three empty tables per request
  -- representing nothing having gone wrong.
  --
  -- `any` is gone with it: `failures ~= nil` already carries that fact.
  local cleaned, failures = {}, nil
  for field, rule in pairs(schema) do
    local expanded = expand(rule)
    local value = input[field]
    if value == nil and expanded.default ~= nil then value = expanded.default end
    local got, err = check_one(value, expanded, coerce)
    if err then
      failures = failures or {}
      failures[field] = err
    else
      cleaned[field] = got
    end
  end
  if failures then return nil, failures end
  return cleaned, nil
end
akkar.validate = validate

-- ================================================================== watchdog
-- A blocking call freezes the whole process silently.  An instruction-count
-- hook catches it: when consecutive hook firings are close together on the
-- clock, no I/O happened between them, so the handler is burning CPU without
-- yielding.  Measured cost: 0.16-0.35 us per switch, under 2% overhead.
local WATCHDOG_INSTRUCTIONS = 200000
local WATCHDOG_LIMIT        = 0.100   -- seconds of uninterrupted CPU

-- The hook closure is built per request.  It was pooled for a while, on the
-- reasoning that had made the deadline controllers worth pooling: same object,
-- every request, measurable allocation.  It cut 257 bytes per request and
-- measured **+2.1% against a 3.4% noise floor** -- nothing -- so the pool was
-- taken back out and the machinery with it.
--
-- Recorded rather than quietly reverted, because the reasoning was sound and
-- someone will have it again.
local function install_watchdog(where)
  local cpu, last, warned = 0, time.monotime(), false
  debug.sethook(function()
    local now = time.monotime()
    local dt = now - last
    last = now
    if dt < 0.050 then cpu = cpu + dt else cpu = 0 end
    if cpu > WATCHDOG_LIMIT and not warned then
      warned = true
      internal:warn("handler blocked the event loop without yielding", {
        blocked_ms = math.floor(cpu * 1000),
        at = where,
        traceback = debug.traceback("", 2),
        hint = "this stalls every request in this process",
      })
    end
  end, "", WATCHDOG_INSTRUCTIONS)
end

local function remove_watchdog()
  debug.sethook()
end

-- ================================================================== deadline
-- Moved to `akkar/execution.lua` whole, comments included: a wall-clock budget
-- is a property of an execution, not of an HTTP request. Aliased as a local so
-- every call site below is unchanged.
local with_deadline = execution.with_deadline


-- ==================================================================== guards
-- Moved to `akkar/execution.lua`: a guard is what an unconfigured capability
-- reads as, and capabilities are an execution concern. Aliased so the call
-- sites below are unchanged.
local guard = execution.guard


local function unescape(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- ==================================================================== router
local App = {}
App.__index = App

function akkar.new()
  return setmetatable({ routes = {}, middleware = {}, exact = {}, mounts = {} }, App)
end

local MAGIC = "[%-%.%+%[%]%(%)%$%^%%%?%*]"

local function compile(path)
  local names, pattern = {}, "^"
  for segment in path:gmatch "[^/]+" do
    if segment:sub(1, 1) == ":" then
      names[#names + 1] = segment:sub(2)
      pattern = pattern .. "/([^/]+)"
    else
      pattern = pattern .. "/" .. segment:gsub(MAGIC, "%%%0")
    end
  end
  if pattern == "^" then pattern = "^/?" end
  return pattern .. "$", names
end

for _, method in ipairs { "get", "post", "put", "patch", "delete" } do
  App[method] = function(self, path, opts, handler)
    if handler == nil then opts, handler = nil, opts end
    if type(handler) ~= "function" then
      error("handler for " .. method:upper() .. " " .. path .. " is not a function", 2)
    end
    local verb = method:upper()
    local info = debug.getinfo(2, "Sl")
    local where = info.short_src .. ":" .. info.currentline
    if opts then check_config(opts, ROUTE_OPTIONS, verb .. " " .. path) end

    -- Invariant: a duplicate route fails at startup, naming both sites.
    for _, r in ipairs(self.routes) do
      if r.method == verb and r.path == path then
        error(string.format("duplicate route: %s %s\n  already registered at %s\n  duplicated at %s",
                            verb, path, r.where, where), 2)
      end
    end

    -- Every schema this route declares is expanded HERE, once, rather than
    -- rebuilt on every request inside `validate`. See `expand_schema`.
    --
    -- `opts` is copied before being written to: the table belongs to the
    -- caller, who may be reusing it for another route or reading it back.
    if opts then
      local copied = false
      for _, slot in ipairs(SCHEMA_SLOTS) do
        if opts[slot] ~= nil then
          if not copied then
            local fresh = {}
            for k, val in pairs(opts) do fresh[k] = val end
            opts, copied = fresh, true
          end
          local ok, expanded = pcall(expand_schema, opts[slot], slot)
          if not ok then
            error(("%s %s: %s"):format(verb, path, tostring(expanded)), 2)
          end
          opts[slot] = expanded
        end
      end
    end

    local pattern, names = compile(path)
    local route = { method = verb, path = path, pattern = pattern, names = names,
                    handler = handler, opts = opts, where = where }
    self.routes[#self.routes + 1] = route
    if #names == 0 then self.exact[verb .. " " .. path] = route end
    return self
  end
end

function App:use(fn)
  self.middleware[#self.middleware + 1] = fn
  -- The chain is built once and memoised, and `app:test{}` builds it. So a
  -- middleware registered after the first test client -- or after any earlier
  -- `app:run` in the same process -- used to be appended to a list nobody
  -- read again: it was silently ignored, and the failure looks exactly like
  -- middleware that does not work.
  --
  -- Silent is the problem. Authentication registered one line too late is not
  -- a bug that announces itself.
  self._chain, self._chain_short = nil, nil
  return self
end

--- Registers what to do when akkar is about to answer 500.
---
---     app:on_error(function(err, req)
---       sentry:capture(err, { request_id = req.id, route = req.path })
---       return akkar.response(500, { instance = req.id })
---     end)
---
--- `err` is whatever was raised, untouched. `req` is the request, and it may
--- be absent for a failure that happened before one existed.
function App:on_error(fn)
  if type(fn) ~= "function" then
    error("app:on_error needs a function(err, req); got " .. type(fn), 2)
  end
  self._on_error = fn
  return self
end

-- A sub-application is an ordinary app mounted under a prefix.  One concept
-- instead of two, and the sub-app stays testable on its own.
function App:mount(prefix, sub)
  self.mounts[#self.mounts + 1] = { prefix = prefix, app = sub }
  return self
end

-- =========================================================== apps from data
--
-- Routes, validation and mounts described by a table rather than by calls, so
-- an application can be built from a spec a customer publishes instead of from
-- source someone deploys.
--
--     akkar.from_spec({
--       middleware = { "auth" },
--       routes = {
--         { method = "GET", path = "/users/:id",
--           params = { id = "integer" },
--           response = { id = "integer", name = "string" },
--           handler = "users.show" },
--       },
--     }, { handlers = handlers, middleware = middleware })
--
-- **Handlers are named, never carried.** The spec says `"users.show"` and the
-- caller supplies the table those names resolve against. A spec that carried
-- executable code would mean anyone who can publish a spec can run anything in
-- the process, and the specs that most want this shape are exactly the ones
-- arriving from outside. Running customer-authored logic safely is a different
-- problem with a different answer (an isolated VM), and conflating the two
-- would quietly answer it wrong.
--
-- Schemas need no translation: `"string?"` and `{ kind = "integer", min = 1 }`
-- are already the data form, so a spec round-trips through JSON as it stands.
--
-- Everything is checked while building. A spec is data, which means it is
-- probably generated, which means the error has to name the route it came
-- from -- "route 3 (GET /users/:id)" -- rather than failing on the first
-- request that touches it.
local VERBS_FROM_SPEC = { GET = true, POST = true, PUT = true, PATCH = true,
                          DELETE = true, HEAD = true, OPTIONS = true }

local function spec_error(index, route, message)
  error(("akkar.from_spec: route %d (%s %s): %s"):format(
        index, tostring(route and route.method or "?"),
        tostring(route and route.path or "?"), message), 0)
end

local function resolve(name, table_of, what, index, route)
  if type(name) == "function" then return name end
  if type(name) ~= "string" then
    spec_error(index, route, what .. " must be a name; got " .. type(name))
  end
  local found = table_of and table_of[name]
  if not found then
    spec_error(index, route, ("no %s named '%s' was provided"):format(what, name))
  end
  return found
end

function akkar.from_spec(spec, options)
  if type(spec) ~= "table" then
    error("akkar.from_spec needs a table; got " .. type(spec), 2)
  end
  options = options or {}
  local app = akkar.new()

  for i, name in ipairs(spec.middleware or {}) do
    app:use(resolve(name, options.middleware, "middleware", i, nil))
  end

  for i, route in ipairs(spec.routes or {}) do
    if type(route) ~= "table" then
      error(("akkar.from_spec: route %d is a %s, not a table"):format(i, type(route)), 0)
    end
    local verb = tostring(route.method or "GET"):upper()
    if not VERBS_FROM_SPEC[verb] then
      spec_error(i, route, "unknown method")
    end
    if type(route.path) ~= "string" or route.path:sub(1, 1) ~= "/" then
      spec_error(i, route, "path must be a string beginning with /")
    end

    local handler = resolve(route.handler, options.handlers, "handler", i, route)

    -- Only the declarative keys travel.  A spec that could set arbitrary route
    -- options would be a second, undocumented API surface.
    local opts = {}
    for _, key in ipairs { "params", "query", "body", "response" } do
      if route[key] ~= nil then opts[key] = route[key] end
    end
    for _, name in ipairs(route.before or {}) do
      opts.before = opts.before or {}
      opts.before[#opts.before + 1] =
        resolve(name, options.middleware, "middleware", i, route)
    end

    local ok, err = pcall(function()
      app[verb:lower()](app, route.path, next(opts) and opts or nil, handler)
    end)
    if not ok then spec_error(i, route, tostring(err)) end
  end

  for prefix, sub in pairs(spec.mounts or {}) do
    app:mount(prefix, type(sub) == "table" and sub.routes
                      and akkar.from_spec(sub, options) or sub)
  end

  return app
end

-- ============================================================= host routing
--
-- `acme.example.com` and `globex.example.com` reaching different applications
-- in one process. Only paths could distinguish them before, which forces every
-- multi-tenant service into `/t/:tenant/...` and leaks the tenant into every
-- URL a customer ever sees.
--
--     app:host("acme.example.com", acme)
--     app:host("*.example.com", tenant_app)     -- one label, not a suffix match
--
-- The host selects the **whole application**, not just its routes: its
-- middleware, its error handling, its OpenAPI document. Selecting only the
-- routes would run the wrong app's authentication against the right app's
-- handler, which is a worse bug than having no host routing at all.
--
-- Exact beats wildcard, and a host matching nothing falls through to this
-- app's own routes -- so adding a host never takes away an answer that already
-- worked.
local function normalize_host(host)
  if not host then return nil end
  host = tostring(host):lower()
  host = host:gsub("%.$", "")           -- the fully-qualified trailing dot
  -- Strip the port, but not the colons of an IPv6 literal: `[::1]:8080` keeps
  -- its brackets and loses its port, `[::1]` keeps everything.
  if host:sub(1, 1) == "[" then
    return (host:gsub("%]:%d+$", "]"))
  end
  return (host:gsub(":%d+$", ""))
end
akkar.normalize_host = normalize_host

function App:host(pattern, sub)
  self.hosts = self.hosts or {}
  pattern = normalize_host(pattern)

  local wildcard = pattern:match "^%*%.(.+)$"
  for _, existing in ipairs(self.hosts) do
    if existing.pattern == pattern then
      error("akkar: host '" .. pattern .. "' is already routed; the second " ..
            "registration would silently never match", 2)
    end
  end

  self.hosts[#self.hosts + 1] = { pattern = pattern, suffix = wildcard, app = sub }
  return self
end

--- Replaces the app answering for a host, atomically, without dropping a
--- request.
---
--- "Atomically" is a real claim and it is worth saying why it holds. One Lua
--- VM runs one coroutine at a time and switches only at a yield; assigning a
--- field yields nowhere. So no request can observe the moment between the old
--- app and the new one.
---
--- A request already in flight keeps the app it was routed to and finishes
--- against it. That is the intended semantics, not a limitation: swapping an
--- application out from under a handler halfway through would be worse than
--- letting the last few requests finish on the old one.
function App:swap_host(pattern, sub)
  self.hosts = self.hosts or {}
  pattern = normalize_host(pattern)
  for _, entry in ipairs(self.hosts) do
    if entry.pattern == pattern then
      local previous = entry.app
      entry.app = sub
      return previous
    end
  end
  -- Adding through swap is allowed; it is what the first publish of a tenant
  -- looks like, and refusing it would force callers to track which is which.
  return self:host(pattern, sub) and nil
end

--- The app that answers for this host, or nil to use this one.
function App:for_host(host)
  if not self.hosts then return nil end
  host = normalize_host(host)
  if not host then return nil end

  for _, entry in ipairs(self.hosts) do        -- exact first, always
    if not entry.suffix and entry.pattern == host then return entry.app end
  end
  for _, entry in ipairs(self.hosts) do
    if entry.suffix then
      -- `*.example.com` matches `a.example.com` and not `a.b.example.com`,
      -- and never the bare `example.com`.  A suffix match would hand
      -- `evil-example.com` to the tenant app.
      local label = host:match("^([^.]+)%." .. entry.suffix:gsub("%p", "%%%0") .. "$")
      if label then return entry.app end
    end
  end
  return nil
end

-- Percent-decoding happens here rather than on the whole path, because
-- decoding first would let %2F smuggle a segment separator into a parameter.
local function decode_params(names, captured)
  local params = {}
  for i, name in ipairs(names) do params[name] = safe_text(unescape(captured[i])) end
  return params
end

function App:match(method, path)
  local hit = self.exact[method .. " " .. path]
  if hit then return hit, {} end
  for _, r in ipairs(self.routes) do
    if r.method == method and #r.names > 0 then
      local captured = { path:match(r.pattern) }
      if captured[1] ~= nil then return r, decode_params(r.names, captured) end
    end
  end
  for _, m in ipairs(self.mounts) do
    if path:sub(1, #m.prefix) == m.prefix then
      local rest = path:sub(#m.prefix + 1)
      if rest == "" then rest = "/" end
      -- THE THIRD RETURN IS THE APP THAT OWNS THE ROUTE, and it exists because
      -- without it a mounted route ran the PARENT's middleware and not its own.
      --
      -- That is not an ergonomic gap, it is a way to serve a protected route to
      -- anybody: put the private routes in a sub-app, `sub:use(auth...)`,
      -- `app:mount("/private", sub)` -- the shape every framework teaches --
      -- and akkar answered 200 with no credential, no error and no warning.
      --
      -- Found within an hour of porting a real service, which is the argument
      -- for porting one.
      local route, params, owners = m.app:match(method, rest)
      if route then
        -- Outermost first, so a mount inside a mount still runs both.
        if owners then
          table.insert(owners, 1, m.app)
          return route, params, owners
        end
        return route, params, { m.app }
      end
    end
  end
  return nil
end

-- Which methods this path would accept.  Empty means the path itself is
-- unknown, which is a 404; non-empty with the requested method absent is a
-- 405, and the difference matters to whoever is holding the client.
function App:methods_for(path)
  local seen, list = {}, {}
  local function add(verb)
    if not seen[verb] then seen[verb] = true list[#list + 1] = verb end
  end
  for _, r in ipairs(self.routes) do
    if #r.names == 0 then
      if r.path == path then add(r.method) end
    elseif path:match(r.pattern) then
      add(r.method)
    end
  end
  for _, m in ipairs(self.mounts) do
    if path:sub(1, #m.prefix) == m.prefix then
      local rest = path:sub(#m.prefix + 1)
      if rest == "" then rest = "/" end
      for _, verb in ipairs(m.app:methods_for(rest)) do add(verb) end
    end
  end
  table.sort(list)
  return list
end

-- ================================================================== dispatch
local function normalize(value)
  if value == nil then return response(204, nil) end
  if is_response(value) then return value end
  if type(value) ~= "table" then
    error(string.format("handler returned %s; return a table, nil, or akkar.*()",
                        type(value)), 0)
  end
  return response(200, value)
end

-- Applies a route's `response` schema to what the handler produced.
--
-- Filtering first is the part that earns its keep: a handler doing `select *`
-- and returning the row leaks whatever the table happens to hold, and
-- `password_hash` is the classic.  Declaring the shape now removes the field
-- instead of merely documenting that it should not be there.
--
-- A mismatch is a 500, not a 422.  A response that does not match its own
-- contract is a server bug, and telling the client it sent bad input would be
-- a lie about whose fault it is.
--
-- Only success bodies are touched.  An error response is the framework's own
-- shape and has nothing to do with the route's schema.
--- Turns an internal failure into a response, through the application's own
--- handler when it registered one.
---
--- Three places produce a 500 -- a handler that raised, middleware that
--- raised, and a response that did not match its own schema -- and until now
--- each assembled the body itself and dropped the cause on the floor.
--- Middleware saw the 500 come back through the chain, which is correct, but
--- nothing could see WHY. Sentry, an internal error code and RFC 7807 output
--- all had nowhere to attach.
---
--- Two rules keep the invariants intact:
---
--- The handler's return value goes through `normalize` like any other
--- response, so a handler that returns a string or a number becomes the
--- default 500 rather than escaping as something the server cannot send.
---
--- If the error handler itself raises, the default 500 takes over. A bug in
--- the error handler must not crash the server through the exact path that
--- exists to stop that happening.
---
--- The default is unchanged and stays deliberately bare: `{"error":
--- "internal server error"}`. A Lua error carries file paths, line numbers
--- and sometimes SQL. The detail belongs in the log beside the request id,
--- which is already how it works and is why the response carries that id.
-- A 500 that has not consulted `app:on_error` yet.
--
-- The hook must run AFTER the request's capabilities are released, and the two
-- paths that produce a 500 sat on opposite sides of that release: a middleware
-- raising is caught outside it, a handler raising is caught deep inside, while
-- the connection is still checked out. Calling the hook where the error was
-- caught therefore handed one error handler a live `req.db` and the other one
-- a connection already back in the pool -- and possibly already handed to
-- another request. An `on_error` that records the failure in the database,
-- which is the obvious shape for one, would have been writing it down through
-- somebody else's connection.
--
-- So the cause travels to the release point and the hook runs there, once, on
-- both paths. Wrapped in a table because the cause may legitimately be nil.
local function pending_error(err)
  local res = response(500, { error = "internal server error" })
  res.__pending = { cause = err }
  return res
end

local function internal_error(app, err, req)
  local fallback = response(500, { error = "internal server error" })

  local handler = app and app._on_error
  if not handler then return fallback end

  local ok, result = pcall(handler, err, req)

  -- `normalize` turns nil into 204, which is the right reading of "the
  -- handler had nothing to add" everywhere except here: answering an empty
  -- SUCCESS to a request that failed would be the worst outcome of the three.
  -- Returning nothing from an error handler means it declined.
  if ok and result == nil then return fallback end

  if not ok then
    internal:error("the error handler itself raised", {
      request_id = req and req.id,
      detail = tostring(result),
      hint = "the built-in 500 was sent instead",
    })
    return fallback
  end

  local valid, response_or_why = pcall(normalize, result)
  if not valid then
    internal:error("the error handler returned something that is not a response", {
      request_id = req and req.id, detail = tostring(response_or_why),
    })
    return fallback
  end
  return response_or_why
end

local function apply_response_schema(res, schema, where, app, req)
  if res.status < 200 or res.status >= 300 then return res end
  if res.raw then return res end
  if type(res.body) ~= "table" then return res end
  -- An array body is out of scope: `response` describes an object, and a list
  -- schema is a separate decision rather than an oversight.
  if res.body[1] ~= nil then return res end

  local cleaned, failures = validate(res.body, schema, false)
  if failures then
    local detail = {}
    for field, why in pairs(failures) do detail[#detail + 1] = field .. ": " .. why end
    table.sort(detail)
    internal:error("response does not match its schema", {
      at = where, fields = table.concat(detail, "; "),
    })
    return pending_error(
      "response does not match its schema at " .. tostring(where) ..
      ": " .. table.concat(detail, "; "))
  end
  return response(res.status, cleaned, res.headers)
end

local function dispatch(app, req)
  local route, params, owners = app:match(req.method, req.path)

  if not route then
    -- HEAD is served by the GET handler.  RFC 9110 requires HEAD wherever GET
    -- exists, and answering 404 to a HEAD on a live resource is a lie.
    if req.method == "HEAD" then
      route, params, owners = app:match("GET", req.path)
    end

    if not route then
      local allowed = app:methods_for(req.path)

      if #allowed > 0 then
        -- OPTIONS is answered from the routing table itself: no handler has
        -- to be written for a client to discover what a path accepts.
        if req.method == "OPTIONS" then
          local list = { "OPTIONS" }
          for _, verb in ipairs(allowed) do
            list[#list + 1] = verb
            if verb == "GET" then list[#list + 1] = "HEAD" end
          end
          table.sort(list)
          return response(204, nil, { ["allow"] = table.concat(list, ", ") })
        end
        -- The path exists, the method does not.  That is a 405, and it says
        -- what would have worked.
        return akkar.method_not_allowed(allowed)
      end

      return response(404, { error = "no route for " .. req.method .. " " .. req.path })
    end
  end

  req.params = params
  req.route = route.path

  -- A CLIENT ASKING NOT TO BE CHARGED TWICE, when nothing is listening.
  --
  -- `Idempotency-Key` is a request saying "a retry of this must not happen
  -- again". akkar has `akkar.idempotency` and does not install it, which is
  -- the right default -- and it said nothing at all when the header arrived
  -- and no middleware handled it. Porting a payments service, the same key
  -- posted twice created two invoices with two different ids, and the only
  -- evidence anywhere was a row count.
  --
  -- Once per APP -- not per process, so a process serving two apps warns for
  -- each, and so a test can observe it. The guard is checked before the header
  -- is, so after it has fired this costs one boolean read. An app where nobody
  -- sends the header pays one hash lookup on POST and PATCH, a rounding error
  -- against the ~45 us akkar spends per request, and it buys a silent double
  -- charge becoming a log line.
  if not app.__idempotency_warned
     and (req.method == "POST" or req.method == "PATCH")
     and not package.loaded["akkar.idempotency"]
     and req.headers["idempotency-key"] then
    app.__idempotency_warned = true
    internal:warn("a request carried Idempotency-Key and nothing handled it", {
      method = req.method, path = req.path,
      detail = "The client is asking for a safe retry and this server will " ..
               "run the request again. Install the middleware: " ..
               "app:use(require('akkar.idempotency').new{}) -- it needs a " ..
               "shared cache. Warned once per process.",
    })
  end

  -- Declarative validation, before the handler runs.
  local opts = route.opts
  if opts then
    local failures, any = {}, false
    if opts.params then
      local clean, err = validate(params, opts.params, true)
      if err then for k, e in pairs(err) do failures["params." .. k] = e end any = true
      else req.params = clean end
    end
    if opts.query then
      local clean, err = validate(req.query, opts.query, true)
      if err then for k, e in pairs(err) do failures["query." .. k] = e end any = true
      else req.query = clean end
    end
    if opts.body then
      local clean, err = validate(req.body, opts.body, false)
      if err then for k, e in pairs(err) do failures["body." .. k] = e end any = true
      else req.body = clean end
    end
    if any then
      return response(422, { error = "validation failed", fields = failures })
    end
  end

  -- Route-scoped middleware, after the global chain.
  local run = function() return route.handler(req) end
  if opts and opts.before then
    for i = #opts.before, 1, -1 do
      local mw, nxt = opts.before[i], run
      run = function() return mw(req, function() return nxt() end) end
    end
  end

  -- MIDDLEWARE OF A MOUNTED APP.
  --
  -- `app:mount("/private", sub)` used to discard everything `sub:use()`
  -- registered: the route was found through the mount and then run inside the
  -- PARENT's chain. So the shape every framework teaches -- private routes in
  -- a sub-app, auth middleware on it, mount it -- answered 200 with no
  -- credential. No error, no warning, and the app looks correct.
  --
  -- It sits outside the route-scoped middleware and inside the parent's global
  -- chain, which is the order the nesting implies. `owners` is outermost-first
  -- and is only built for a mounted route, so an unmounted request allocates
  -- nothing.
  if owners then
    for i = #owners, 1, -1 do
      local mws = owners[i].middleware
      for j = #mws, 1, -1 do
        local mw, nxt = mws[j], run
        run = function()
          return normalize(mw(req, function(r) if r then req = r end return nxt() end))
        end
      end
    end
  end

  install_watchdog(route.where)
  -- `normalize` runs INSIDE the pcall: a handler returning an invalid value
  -- must become a 500 with a clear log, not escape as an unhandled error.
  local ok, result = pcall(function() return normalize(run()) end)
  remove_watchdog()

  if not ok then
    -- Response-as-error: a deep layer can signal HTTP without threading a
    -- return value back through every frame.
    if is_response(result) then return result end

    -- A FAILURE AFTER THE BUDGET PASSED IS THE DEADLINE, NOT A BUG.
    --
    -- Now that capabilities bound their own I/O by the execution's budget, the
    -- deadline usually arrives as a raised socket timeout rather than as the
    -- controller giving up -- and this pcall catches it before `with_deadline`
    -- ever sees it, so the request would answer 500.
    --
    -- 500 says "akkar has a bug"; 503 says "this took too long". Getting that
    -- backwards sends whoever reads the log hunting for a defect that is not
    -- there, and it is what `spec/abandoned_spec.lua` caught the moment the
    -- database started honouring the budget: it asserted 503 and got 500.
    --
    -- The raise is still logged by the caller, so the cause is not lost.
    local left = execution.remaining()
    if left and left <= 0 then
      return response(503, { error = "request deadline exceeded" })
    end
    -- THE ONE ERROR THAT DID NOT NAME ITS FIX.
    --
    -- Writing the beginner guide surfaced it. A handler doing `req.body.title`
    -- on a request that carried no body raises `attempt to index a nil value
    -- (field 'body')` -- true, useless, and the first thing anybody hits.
    -- Every other message in this project names the mistake and the remedy
    -- (`req.db is not configured; pass db = ... to app:run{}`); this one named
    -- neither.
    --
    -- The hint is added HERE rather than by making `req.body` a guard object,
    -- and the reason is worth recording so nobody 'improves' it later: a guard
    -- is a table, tables are truthy, and `if req.body then` would start taking
    -- the branch it exists to avoid -- then raising inside it. Worse, a route
    -- that DOES declare a body schema passes `req.body` to `validate`, which
    -- would receive a guard instead of nil and raise where it should answer
    -- 422. Improving the message costs nothing and changes no semantics.
    local detail = tostring(result)
    if detail:find("index a nil value (field 'body')", 1, true) then
      detail = detail ..
        "\n  req.body is nil because this request carried no body." ..
        "\n  Declare one on the route -- app:post(path, { body = { ... } }, " ..
        "handler) -- and akkar will answer 422 before your handler runs, " ..
        "instead of raising here."
    end

    internal:error("handler raised", {
      request_id = req.id, at = route.where, detail = detail,
    })
    return pending_error(result)
  end

  if opts and opts.response then
    result = apply_response_schema(result, opts.response, route.where, app, req)
  end
  return result
end

-- ================================================================== pipeline
-- The end of the chain is a parameter.  Normally it is `dispatch`; for a
-- request whose body already failed to parse it is a function returning the
-- 400.  That way middleware sees both cases through one path.
local function build_chain(app, terminal)
  local chain = terminal
  for i = #app.middleware, 1, -1 do
    local mw, next_fn = app.middleware[i], chain
    chain = function(a, req)
      return normalize(mw(req, function(r) return next_fn(a, r or req) end))
    end
  end
  return chain
end

local function chains(app)
  if not app._chain then
    app._chain = build_chain(app, dispatch)
    app._chain_short = build_chain(app, function(_, req) return req.__short end)
  end
  return app._chain, app._chain_short
end

-- `/users/` and `/users` are the same resource.  Answering 404 to one of them
-- is a distinction no client asked for.  The root stays "/".
local function normalize_path(path)
  if path == "" then return "/" end
  if #path > 1 and path:sub(-1) == "/" then
    path = path:gsub("/+$", "")
    if path == "" then return "/" end
  end
  return path
end

-- Headers reach a handler as a plain table with lowercase keys, whether the
-- request came off a socket or from the in-process test client.  Before this,
-- a handler had to write
--   req.headers.authorization or (req.headers.get and req.headers:get "...")
-- which is the framework leaking lua-http into user code.
-- A request id, taken from the client when it sends one so a trace survives
-- across services, generated otherwise.  Not a UUID: this only has to be
-- unique enough to correlate lines within a window, and pulling in a UUID
-- library for that would be a dependency bought with nothing.
-- The generating half moved to `akkar/execution.lua`: every execution has an
-- identity, and only HTTP has an opinion about honouring a caller's header.
-- That split is deliberate -- `execution.id()` cannot be handed a header,
-- because trusting one is a transport decision and belongs here.
local function request_id(headers)
  local given = headers and headers["x-request-id"]
  if given and #given > 0 and #given <= 200 then return given end
  return execution.id()
end

-- W3C Trace Context, which is the same idea as `x-request-id` with a format
-- everything else already speaks:
--
--     traceparent: 00-<32 hex trace id>-<16 hex span id>-<2 hex flags>
--
-- akkar accepts one, exposes it, and passes it on. It does NOT create spans
-- or export them: that is an OpenTelemetry dependency and an adapter, and it
-- belongs behind the same boundary as everything else here.
--
-- Validated rather than trusted. A malformed header is dropped instead of
-- propagated, because forwarding a broken trace id corrupts somebody else's
-- trace as well as this one, and it arrives from the network.
local function trace_context(headers)
  local given = headers and headers["traceparent"]
  if type(given) ~= "string" then return nil end

  local version, trace_id, span_id, flags =
    given:match "^(%x%x)%-(%x+)%-(%x+)%-(%x%x)$"
  if not version then return nil end
  if #trace_id ~= 32 or #span_id ~= 16 then return nil end
  -- All-zero ids are explicitly invalid in the specification.
  if trace_id:match "^0+$" or span_id:match "^0+$" then return nil end
  -- Version ff is forbidden; a version akkar does not know is still
  -- forwarded, which is what the specification asks for.
  if version == "ff" then return nil end

  return {
    traceparent = given,
    trace_id = trace_id,
    span_id = span_id,
    sampled = tonumber(flags, 16) & 0x01 == 1,
    tracestate = headers["tracestate"],
  }
end
akkar.trace_context = trace_context

local function normalize_headers(source)
  local out = {}
  if not source then return out end
  if type(source.get) == "function" then          -- a lua-http headers object
    for name, value in source:each() do
      if name:sub(1, 1) ~= ":" then               -- drop :method, :path, ...
        -- Header values are bytes as far as HTTP is concerned, and akkar puts
        -- them in JSON responses. See `safe_text`.
        local clean = safe_text(value)
        local existing = out[name]
        out[name] = existing and (existing .. ", " .. clean) or clean
      end
    end
  else
    for name, value in pairs(source) do out[name:lower()] = safe_text(value) end
  end
  return out
end

-- ============================================================== client address
--
-- Who the caller IS, which is a different question from what the caller SAYS.
--
-- `akkar.limit` shipped keying its buckets on `X-Forwarded-For`, falling back
-- to `X-Real-IP`, with nothing else available -- because nothing else WAS
-- available: the peer address was never plumbed to `req`. Both of those are
-- client-supplied strings. Any caller could send a fresh one per request and
-- mint a fresh rate-limit bucket each time, which defeats the limiter with a
-- single header.
--
-- So `req.ip` is the address of the socket, always. `X-Forwarded-For` is
-- believed only when the connection came FROM a proxy the application named,
-- and then only as far back as the trusted hops go: walking the list from the
-- right, the first address that is not itself a trusted proxy is the client,
-- and everything to its left is whatever that client chose to send.
local function ipv4_to_int(address)
  local a, b, c, d = address:match "^(%d+)%.(%d+)%.(%d+)%.(%d+)$"
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

--- Is `address` inside `cidr`? IPv4 only, and it says so rather than
--- pretending: an IPv6 peer simply never matches, which fails CLOSED --
--- forwarded headers are ignored rather than believed.
local function in_cidr(address, cidr)
  local base, bits = cidr:match "^([%d%.]+)/(%d+)$"
  if not base then base, bits = cidr, "32" end
  bits = tonumber(bits)
  local a, b = ipv4_to_int(address), ipv4_to_int(base)
  if not a or not b or not bits or bits < 0 or bits > 32 then return false end
  if bits == 0 then return true end
  local mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF
  return (a & mask) == (b & mask)
end
akkar.in_cidr = in_cidr

local function is_trusted(address, trusted)
  if not address or not trusted then return false end
  for _, cidr in ipairs(trusted) do
    if in_cidr(address, cidr) then return true end
  end
  return false
end

--- The client address, given the socket's peer and the forwarded header.
---
--- Exported because it is worth testing directly: the walk is the whole
--- security property, and it is easy to get backwards. Taking the LEFTMOST
--- entry -- which is what most implementations do -- is exactly the spoofable
--- version, since the leftmost entry is whatever the client typed.
local function client_ip(peer, forwarded, trusted)
  if not peer then return nil end
  if not forwarded or not is_trusted(peer, trusted) then return peer end

  local hops = {}
  for hop in tostring(forwarded):gmatch "[^,]+" do
    hops[#hops + 1] = hop:match "^%s*(.-)%s*$"
  end

  for i = #hops, 1, -1 do
    if not is_trusted(hops[i], trusted) then return hops[i] end
  end
  -- Every hop is a trusted proxy: the peer is the best answer there is.
  return peer
end
akkar.client_ip = client_ip

local function parse_query(qs)
  local out = {}
  if not qs or qs == "" then return out end
  for pair in qs:gmatch "[^&]+" do
    local k, val = pair:match "^([^=]*)=?(.*)$"
    if k and k ~= "" then
      -- Percent-decoding turns %C3%28 into bytes that are not text, and a
      -- query value reaches a validation error message and a response.
      out[safe_text(unescape(k))] = safe_text(unescape((val:gsub("+", " "))))
    end
  end
  return out
end
akkar.parse_query = parse_query

-- Rate and concurrency limiting, as middleware rather than core: a limit
-- policy is application knowledge, the same argument as `akkar.cors`.
akkar.limit = require "akkar.limit"

-- The same request twice, charged once. Middleware for the same reason:
-- which requests are idempotent, and for how long, is application knowledge.
akkar.idempotency = require("akkar.idempotency").new

-- The write that vanishes: two clients read, both write, one write is gone
-- with no error anywhere. HTTP has had the answer since 1997.
akkar.etag = require("akkar.etag").new
akkar.etag_of = require("akkar.etag").of

-- Builds `req` and runs the chain.  Shared by the server and the test client,
-- so both travel exactly the same path.
local function handle(app, input)
  -- Before the chains are built, because the selected app has its own.
  local requested_host = input.host
  if requested_host == nil and input.headers then
    requested_host = type(input.headers.get) == "function"
                     and (input.headers:get ":authority" or input.headers:get "host")
                     or input.headers.host or input.headers.Host
  end
  local host_app = app:for_host(requested_host)
  if host_app then app = host_app end

  local normal, short = chains(app)

  -- Body shape is checked here rather than in the wire decoder, because the
  -- test client hands a Lua value over directly and the two paths have to
  -- agree.  A scalar cannot be indexed by field name, so it is rejected with
  -- a message rather than blowing up inside validation.
  -- The wire path already stripped nulls while it had the raw text to scan.
  -- Doing it again here walked every field of every body a second time -- on a
  -- fifty-row body that second walk was measured at about half the cost of the
  -- whole request.  The test client hands over a Lua value with no raw text
  -- behind it, so that path still strips.
  local body = input.stripped and input.body or strip_nulls(input.body)
  if body ~= nil and type(body) ~= "table" then
    input.short = input.short or
      response(400, { error = "request body must be a JSON object or array" })
  end

  -- Request data.
  local request_headers = normalize_headers(input.headers)
  local req = {
    method  = input.method,
    path    = normalize_path(input.path),
    query   = input.query or {},
    body    = body,
    -- THE BYTES AS THEY ARRIVED, and without them a signed webhook cannot be
    -- verified at all.
    --
    -- Every payment provider signs an HMAC over the raw request body. A digest
    -- computed over `req.body` re-encoded is a DIFFERENT digest -- JSON key
    -- order is not defined, whitespace is not preserved, and a number that
    -- arrived as `1.0` comes back as `1`. So a framework that decodes and
    -- discards cannot verify a webhook, and akkar discarded.
    --
    -- Found porting a service whose provider signs with
    -- `hmac_sha256(hex(sha256(secret)), raw)` and whose own test collection
    -- has a case asserting an unsigned delivery is refused.
    --
    -- It costs no allocation: the string was already built to be decoded. What
    -- it costs is RETENTION -- the bytes stay reachable for the life of the
    -- request instead of becoming garbage after the decode. That is bounded by
    -- `body_limit` times the requests in flight, and it is smaller than the
    -- decoded table it sits beside.
    headers = request_headers,
    host    = normalize_host(requested_host),
    id      = request_id(request_headers),
    user    = guard("req.user", "req.user is not set; this route is missing the authentication middleware"),
  }

  -- ASSIGNED AFTER THE CONSTRUCTOR, and only when there is one.
  --
  -- Writing `raw_body = input.raw_body` inside the table above cost **255
  -- bytes on every request**, including the ones with no body at all: a Lua
  -- table constructor sizes its hash part from the number of keys written, nil
  -- values included, and one more key crossed a power-of-two boundary.
  -- `spec/allocation_spec.lua` refused it at 2,655 against a 2,600 ceiling,
  -- which is exactly the regression that ceiling exists to catch.
  --
  -- Out here, a request that carried no body keeps the smaller table and pays
  -- nothing. A request that did carry one pays a rehash it can afford, because
  -- it already allocated the body.
  if input.raw_body then req.raw_body = input.raw_body end

  -- Capabilities, from the closed set, acquired ON FIRST READ.
  --
  -- Eager acquisition was wrong twice over.  A route that never queries still
  -- took a connection out of the pool, so health checks competed with real
  -- work for slots.  Worse, with the database down every route failed --
  -- including the ones that do not touch it -- which defeated the whole point
  -- of `check_capabilities = false`, whose reason to exist is coming up
  -- degraded and still answering `/health/live`.
  --
  -- A capability that was never configured reads as a guard, so the error
  -- says what is missing instead of indexing a nil.
  local to_release = {}
  setmetatable(req, {
    __index = function(self, key)
      -- Parsed on first read, like a capability, and for the same kind of
      -- reason: putting it in the constructor added a ninth field to `req`,
      -- which grew the table's hash part and cost 191 bytes on EVERY request
      -- including the overwhelming majority that carry no trace at all. The
      -- allocation ceiling test caught it.
      --
      -- Only cached when there is something to cache: a nil result leaves the
      -- table exactly as it was, so a request without the header stays free.
      -- Read from the closure over `input` rather than from fields on `req`.
      -- Putting the peer and the proxy list in the constructor added two
      -- fields, grew the table's hash part and cost 392 bytes on EVERY
      -- request -- the same trap `trace` fell into, caught by the same
      -- allocation ceiling.
      if key == "ip" then
        -- `capabilities` IS the config table, so the proxy list is already
        -- reachable without adding a field to anything. Two extra keys on the
        -- test client's input table alone cost 200 bytes a request.
        local settings = input.capabilities or {}
        local address = client_ip(input.peer or settings.peer,
                                  rawget(self, "headers")["x-forwarded-for"],
                                  settings.trusted_proxies)
        if address then rawset(self, "ip", address) end
        return address
      end

      if key == "trace" then
        local parsed = trace_context(rawget(self, "headers"))
        if parsed then rawset(self, "trace", parsed) end
        return parsed
      end

      if not CAPABILITIES[key] then return nil end
      local provided = input.capabilities and input.capabilities[key]
      local value
      if key == "log" then
        -- `log` is the one capability with a default, because diagnostics
        -- that need configuring before they appear are diagnostics nobody
        -- sees.  Bound to the request id here, so a handler writing
        -- `req.log:info(...)` correlates without doing anything.
        value = (provided or internal):with { request_id = self.id }
      elseif provided == nil then
        value = guard("req." .. key,
                      "req." .. key .. " is not configured; pass " ..
                      key .. " = ... to app:run{}")
      elseif callable(provided) then
        value = provided()
        if type(value) == "table" and type(value.release) == "function" then
          to_release[#to_release + 1] = value
        end
      else
        value = provided
      end
      rawset(self, key, value)      -- acquired once per request, not per read
      return value
    end,
  })

  -- Releasing is the framework's job, not the handler's.  It happens on every
  -- exit -- normal return, thrown response, handler error, deadline -- because
  -- a connection that leaks on the error path leaks exactly when load is
  -- highest.
  local function release_all()
    for _, resource in ipairs(to_release) do pcall(function() resource:release() end) end
  end

  -- A request that failed to parse still traverses the chain, so logging
  -- middleware sees the 400.  Middleware returning garbage cannot escape
  -- either: it becomes a 500.
  local chain = input.short and short or normal
  if input.short then req.__short = input.short end

  local ok, res = pcall(function()
    -- `with_deadline` publishes the budget to the coroutine it runs this in,
    -- so every capability the handler touches can read how long it has left.
    -- That is what stops `req.http` from calling the service below with a
    -- fresh ten seconds while this request has milliseconds, and what lets
    -- `req.db` bound its own wire call by the same number.
    local winner, value = with_deadline(input.timeout, function()
      return normalize(chain(app, req))
    end)
    -- The request id and the traceparent are NOT written onto the response.
    --
    -- They used to be: `value.headers["x-request-id"] = req.id`, on whatever
    -- table the handler returned. A handler is free to return a hoisted or
    -- memoised response -- a constant 404, a cached payload -- and then one
    -- table is shared by every request that reaches it, so request A's id was
    -- written into a table request B was also returning. It is the identical
    -- aliasing defect the audit fixed for `release`, left standing for
    -- headers.
    --
    -- Copying the response to stamp it safely costs two tables per request,
    -- and the allocation ceiling measured that at +264 bytes and refused it.
    -- So neither: these travel BESIDE the response, as extra return values,
    -- and each writer puts them on the wire itself. Nothing is mutated, and
    -- the per-request cost is nothing.
    if winner == "TIMEOUT" then
      internal:warn("request deadline exceeded", {
        request_id = req.id, method = req.method, path = req.path,
        timeout_s = input.timeout,
      })
      return response(503, { error = "request deadline exceeded" })
    end
    return value
  end)
  -- A streamed body has not been produced yet, so its capabilities cannot be
  -- released here.  Releasing a database connection at this point would hand
  -- a live cursor to the next request.  The writer calls this instead, once
  -- the last byte is out.
  --
  -- On a COPY, never on the table the handler returned. Writing `release` onto
  -- the handler's own value meant a handler returning a hoisted or memoised
  -- response had request A's closure overwritten by request B: A's connection
  -- was then never released and B's was released twice -- and the second
  -- release found `pool` already cleared and CLOSED a connection sitting in
  -- the pool's idle set. One leaked slot, one poisoned entry, one 500 to an
  -- innocent request, per occurrence.
  if ok and is_response(res) and res.stream then
    local streamed = response(res.status, res.body, res.headers)
    streamed.stream = res.stream
    streamed.content_type = res.content_type
    streamed.raw = res.raw
    -- Composed, not overwritten: middleware may already have deferred work of
    -- its own onto the response, and the concurrency limiter does exactly that.
    local deferred = res.release
    streamed.release = function()
      if deferred then pcall(deferred) end
      release_all()
    end
    res = streamed
  else
    release_all()
  end

  -- Beside the response, never on it. See the note at the stamp site above.
  local trace_parent = req.trace and req.trace.traceparent

  -- HERE, AND ONLY HERE, is where `on_error` runs -- after every capability
  -- has gone back. A 500 raised deep inside the handler travelled out as a
  -- `pending_error` rather than consulting the hook where it was caught, so
  -- both paths reach the application's error handler in the same state.
  if ok and is_response(res) and rawget(res, "__pending") then
    res = internal_error(app, res.__pending.cause, req)
  end

  if not ok then
    if is_response(res) then return res, req.id, trace_parent end
    internal:error("middleware raised", { request_id = req.id, detail = tostring(res) })
    return internal_error(app, res, req), req.id, trace_parent
  end
  return res, req.id, trace_parent
end

-- ==================================================================== server
-- Decodes a request body by content type.
--
-- Form-encoded bodies are handled because an HTML form cannot send JSON, and
-- answering 400 to one was the framework declaring a normal web request
-- malformed.  An unrecognised type gets 415, not 400: the body may be
-- perfectly well formed and simply not something this server reads, and 400
-- would blame the client for the wrong thing.
--
-- Returns (true, value) or (false, { status, message }).
local function decode_body(raw, content_type)
  local kind = (content_type or "application/json"):match "^[^;]*"
  kind = kind:gsub("%s", ""):lower()

  if kind == "" or kind == "application/json" or kind:match "%+json$" then
    local ok, value = pcall(cjson.decode, raw)
    if not ok then return false, { status = 400, message = "invalid JSON body" } end
    return true, strip_nulls_in(raw, value)
  end

  if kind == "application/x-www-form-urlencoded" then
    return true, parse_query(raw)
  end

  if kind == "multipart/form-data" then
    local fields, err = multipart.parse(raw, multipart.boundary(content_type))
    if not fields then return false, { status = 400, message = err } end
    return true, fields
  end

  return false, {
    status = 415,
    message = "unsupported content type '" .. kind ..
              "'; this endpoint reads application/json, " ..
              "application/x-www-form-urlencoded or multipart/form-data",
  }
end

-- Reads the body without ever buffering more than the limit.
--
-- Two checks, because either alone is insufficient: a declared Content-Length
-- is rejected before a single byte is read, and the running total is capped as
-- well, since a chunked body declares no length at all.  `get_body_as_string`
-- has no limit of its own, so calling it on an untrusted request is how a
-- client turns a 5 MB upload into whatever the process can allocate.
local function read_body(stream, request_headers, limit, budget)
  -- `:get` returns NO values when the header is absent, not nil, so it cannot
  -- be passed straight into tonumber() -- that call would receive zero
  -- arguments and raise.  Bind it first.
  local length = request_headers:get "content-length"
  local declared = length and tonumber(length)

  -- A NEGATIVE LENGTH IS MALFORMED, and saying so here is the difference
  -- between blaming the client and blaming the server. Without this, `-5`
  -- passed the size check, reached the chunk reader, failed somewhere inside
  -- lua-http and came back to the caller as a 503 -- akkar reporting its own
  -- unavailability for a header the client typed wrong.
  --
  -- This fixes the ANSWER. The server is saved separately and was not, when
  -- this comment was first written: `akkar.substrate` repairs the two ways a
  -- malformed length takes a lua-http server down -- an unbounded spin in
  -- `shutdown` for a length that is not a number, and an uncaught raise that
  -- exits the process for one that is negative. See that module and
  -- `docs/substrate/lua-http-wedge.md`.
  if declared and declared < 0 then
    return nil, "malformed"
  end

  if declared and declared > limit then
    return nil, "declared"
  end

  -- READING THE BODY HAS ITS OWN BUDGET.
  --
  -- This runs BEFORE `with_deadline` exists -- the handler cannot be given a
  -- body it has not been read yet -- so for as long as it was unbounded, the
  -- request deadline covered everything except the one phase an attacker
  -- controls completely. A client that announces a megabyte and then sends a
  -- byte a minute held a descriptor pair and an in-flight slot for as long as
  -- it liked, and `max_concurrent` was the only thing in its way: slowloris,
  -- against the one part of the request akkar had left without a clock.
  --
  -- The budget is a DEADLINE rather than a per-chunk timeout. Passing the
  -- same timeout to every chunk -- which is what lua-http's own
  -- `get_body_as_string` does -- means a client that sends one byte just
  -- inside the limit, for ever, is never refused.
  -- `> 0` and not merely truthy, because ZERO MEANS OFF here as it does
  -- everywhere else in akkar -- `with_deadline` opens with `if not seconds or
  -- seconds <= 0`. In Lua `0` is true, so `budget and ...` turned "no
  -- deadline" into "a deadline of right now" and answered 408 to every
  -- request, including a GET carrying no body to read. An app configured the
  -- documented way served nothing at all.
  local deadline = budget and budget > 0 and (time.monotime() + budget) or nil

  local parts, total = {}, 0
  while true do
    local remaining
    if deadline then
      remaining = deadline - time.monotime()
      if remaining <= 0 then return nil, "timeout" end
    end

    local chunk, err = stream:get_next_chunk(remaining)
    if chunk == nil then
      -- lua-http's own convention: no chunk and no error is the end of the
      -- body; no chunk WITH an error is a failure, and a timeout is one.
      if err == nil then break end
      return nil, "timeout"
    end

    total = total + #chunk
    if total > limit then return nil, "streamed" end
    parts[#parts + 1] = chunk
  end
  return table.concat(parts)
end

-- ================================================================== shutdown
-- The sequence, and one rule that matters more than the diagram:
--
--   RUNNING -> STOP_ACCEPTING -> DRAINING -> CLOSING -> STOPPED
--
--   A STALLED DRAIN PUBLISHES A DIAGNOSTIC AND CHANGES NO OWNERSHIP.
--
-- When the drain overruns its grace period akkar says so and keeps waiting;
-- it does not force connections closed.  Forcing is what truncates a response
-- mid-write and corrupts what the client already received.  This was learned
-- on an earlier project, where the drain that never finished was one of two
-- defects that killed it.
--- Runs `fn` in the server's own event loop, for the life of the process.
---
--- WHY THIS EXISTS. Until it did, there was no supported way to run a
--- background loop in the same process as `app:run`: the call ends in
--- `s:loop()`, or in a controller wrapping exactly two tasks, and neither is
--- reachable from outside. The cost showed up as a documentation cost, which
--- is how it was found -- the smallest honest example of "the request should
--- not wait for the email" is one process, an in-memory queue and a consumer
--- sharing the loop, and that was not expressible. The guide's first working
--- example needed Redis and a second process: a `docker run` and a third
--- terminal before a beginner sees one job run.
---
---     app:task("emails", function(task)
---       queue:consume(handlers, { should_stop = task.stopping })
---     end)
---
--- `task.stopping` is a function, not a flag, so it can be handed straight to
--- `Queue:consume`, which already takes `should_stop` in exactly that shape.
--- The two were designed apart and fit, which is usually a sign the shape is
--- the right one.
---
--- THIS IS NOT PARALLELISM. One Lua state runs one coroutine at a time, so a
--- task that computes without yielding stops the server for exactly as long
--- as it computes -- the same rule handlers live under, and the blocking
--- watchdog will say so. Tasks are for work that WAITS: a queue, a timer, a
--- poll. Work that burns CPU still belongs in another process.
function App:task(name, fn)
  if type(name) ~= "string" then
    error("akkar: app:task needs a name first -- it is what the logs and the " ..
          "restart counter call this task", 2)
  end
  if type(fn) ~= "function" then
    error("akkar: app:task('" .. name .. "') needs a function", 2)
  end
  self.tasks = self.tasks or {}
  for _, existing in ipairs(self.tasks) do
    if existing.name == name then
      error("akkar: a task named '" .. name .. "' is already registered; " ..
            "two tasks with one name make a log line ambiguous", 2)
    end
  end
  self.tasks[#self.tasks + 1] = { name = name, fn = fn }
  return self
end

--- True once the server has drained and tasks are being asked to finish.
---
--- Deliberately NOT true during draining. A request still in flight may queue
--- work, so a consumer that stopped at STOP_ACCEPTING would leave that work
--- unconsumed and the shutdown would look clean while losing a job. See
--- `App:stop`.
function App:stopping()
  return self.tasks_stopping == true
end

function App:stop(grace)
  if self.state ~= "RUNNING" then return self.state end
  grace = grace or self.shutdown_grace or 10

  self.state = "STOP_ACCEPTING"
  internal:info("shutdown: no longer accepting connections")
  pcall(function() self.server:pause() end)

  self.state = "DRAINING"
  local deadline = time.monotime() + grace
  local warned = false
  while self.in_flight > 0 do
    if time.monotime() > deadline and not warned then
      warned = true
      internal:warn("shutdown stalled; still waiting, nothing is being forced", {
        in_flight = self.in_flight, grace_s = grace,
      })
    end
    cqueues.poll(0.02)
  end
  if warned then internal:info("shutdown: drain completed") end

  -- TASKS STOP AFTER THE DRAIN, NOT BEFORE IT, and the order is the whole
  -- decision.
  --
  -- A request still in flight can enqueue work -- that is what a background
  -- task is usually FOR -- so a consumer told to stop at STOP_ACCEPTING would
  -- leave that work sitting there while the shutdown reported itself clean.
  -- Draining first means nothing new can be enqueued by the time the
  -- consumer is asked to finish, so the queue it leaves behind is only what
  -- was already unfinished.
  --
  -- The wait is bounded by the same grace period, and expiring it is a
  -- warning rather than a kill: `akkar.jobs` is at-least-once with a store
  -- that supports it, so an unacknowledged job comes back on the next
  -- `reap`. Forcing a task mid-item would trade a delay for a duplicate.
  if self.tasks_running and self.tasks_running > 0 then
    self.tasks_stopping = true
    internal:info("shutdown: asking tasks to finish",
                  { tasks = self.tasks_running })
    local task_deadline = time.monotime() + grace
    local said = false
    while self.tasks_running > 0 do
      if time.monotime() > task_deadline and not said then
        said = true
        internal:warn("shutdown: a task is still running and is not being " ..
                      "forced; unacknowledged work returns on the next reap",
                      { tasks = self.tasks_running, grace_s = grace })
        break
      end
      cqueues.poll(0.02)
    end
    if not said then internal:info "shutdown: tasks finished" end
  end
  self.tasks_stopping = true

  self.state = "CLOSING"
  for _, closer in ipairs(self.closers) do pcall(closer) end
  pcall(function() self.server:close() end)

  self.state = "STOPPED"
  internal:info("shutdown: stopped cleanly")
  return self.state
end

function App:run(config)
  config = config or {}

  -- Startup check: an unknown option is a mistake, and a mistake found here
  -- costs a second.  Found in production it costs an incident.
  local allowed = {}
  for k in pairs(SETTINGS) do allowed[k] = true end
  for k in pairs(CAPABILITIES) do allowed[k] = true end
  check_config(config, allowed, "app:run{}")

  if config.check_capabilities ~= false then
    check_capability_contracts(config)
  end

  -- Global-by-default is Lua's sharpest edge on a server: a global written
  -- inside a handler outlives the request and is visible to the next one, in
  -- the same process, for another user.  Strict mode turns that into an error
  -- at the moment it happens.
  --
  -- Opt-in rather than default, because a false positive that takes down a
  -- live server is worse than the bug it was looking for.  Development and
  -- the test suite should turn it on; see `akkar.strict`.
  if config.strict then require("akkar.strict").on() end

  -- REPAIR THE SUBSTRATE BEFORE BINDING A PORT.
  --
  -- One malformed header stops a lua-http server accepting for ever, and a
  -- second one kills the process outright. Both are repaired by
  -- `akkar.substrate`, which explains itself at length and carries the
  -- measurements. Here rather than at require time: importing akkar should
  -- not mutate a third-party library as a side effect, and the substrate
  -- tests need the unpatched behaviour available to compare against.
  --
  -- Opt out with `repair_substrate = false` -- for anyone who would rather
  -- carry the defect than a patched dependency, and so the specs can prove
  -- what happens without it.
  if config.repair_substrate ~= false then
    require("akkar.substrate").apply()
  end

  local port = config.port or 8080
  local host = config.host or "127.0.0.1"
  local body_limit = config.body_limit or akkar.defaults.body_limit
  local timeout    = config.timeout    or akkar.defaults.timeout
  -- An app-supplied logger replaces the framework's own voice, so a service
  -- gets one stream in one format rather than two.
  if config.log then internal = config.log end
  self.shutdown_grace = config.shutdown_grace or akkar.defaults.shutdown_grace
  self.state, self.in_flight, self.closers = "RUNNING", 0, {}

  -- Pools and anything else holding a socket are closed during CLOSING, after
  -- the drain, never before it.
  for name in pairs(CAPABILITIES) do
    local provided = config[name]
    local pool = type(provided) == "table" and provided.pool
    if pool and type(pool.close) == "function" then
      self.closers[#self.closers + 1] = function() pool:close() end
    end
  end

  chains(self)

  -- SO_REUSEPORT is how several processes share one port, which is how akkar
  -- uses a machine: one Lua VM is one core, so capacity is processes.  The
  -- kernel load-balances accepted connections between them, and no proxy is
  -- needed in front.
  --
  -- Without it the second process dies with EADDRINUSE, and a benchmark that
  -- starts N processes silently measures one.  That is not hypothetical: it
  -- is what the first scaling run on a c5.2xlarge actually did.
  -- ================================================== the descriptor ceiling
  --
  -- Every in-flight request holds a `cqueues` controller for its deadline,
  -- and a controller costs exactly two file descriptors. Measured, at the
  -- concurrency that matters:
  --
  --     concurrent      fds     per request
  --     64              134            2.09
  --     256             518            2.02
  --     512            1030            2.01
  --
  -- Against the common default of `ulimit -n 1024`, that puts the wall at
  -- about 500 concurrent requests per process -- and hitting it does not
  -- produce a clean error. `accept` starts failing, every socket operation
  -- starts failing, and the process flails. A machine was lost this way
  -- during a 512-connection sweep.
  --
  -- Pooling the controllers does not help here. The pool serves SEQUENTIAL
  -- reuse; five hundred requests in flight at once need five hundred
  -- controllers whatever its size.
  --
  -- So the ceiling is declared to lua-http, which stops accepting beyond it
  -- and lets the kernel queue instead. Backpressure rather than collapse:
  -- slow is a state a server can be in, out of descriptors is not.
  --
  -- The real fix is not to spend a controller per request at all -- a
  -- `condition` costs zero descriptors and would do the same arbitration.
  -- That is not a drop-in, and the reason is worth writing down: today an
  -- abandoned handler sits in an orphaned controller nothing ever steps, so
  -- it is inert. Move it to the outer controller and it keeps running, wakes
  -- after the 503, and touches a connection that has already gone back to
  -- the pool -- trading a descriptor leak for a data bug.
  local function descriptor_ceiling()
    local limits = io.open "/proc/self/limits"
    if not limits then return nil end
    local soft
    for line in limits:lines() do
      soft = soft or line:match "^Max open files%s+(%d+)"
    end
    limits:close()
    if not soft then return nil end

    -- Two per in-flight request, and leave a third of the budget for the
    -- listening socket, the database pool, the log sink and whatever else
    -- the application opens.
    local ceiling = math.floor(tonumber(soft) * 0.66 / 2)
    return math.max(ceiling, 16)
  end

  local max_concurrent = config.max_concurrent
  if max_concurrent == nil then max_concurrent = descriptor_ceiling() end

  -- PUBLISHED ON THE APP, not merely handed to lua-http. `akkar.limit.shed`
  -- sheds low-priority work at a fraction of this number and reads it from
  -- here; while it was a local, that read returned nil and the shedder could
  -- never fire in any app that did not pass `capacity` by hand -- which is to
  -- say it was dead code in the shape most likely to be deployed. A ceiling
  -- the server enforces and nothing else can read is half a ceiling.
  self.max_concurrent = max_concurrent

  -- TLS WITHOUT MAKING THE APPLICATION IMPORT luaossl.
  --
  -- `ctx` was a whitelisted option passed straight through to lua-http, so
  -- serving HTTPS meant an application constructed a luaossl context by hand
  -- -- and two substrate libraries appeared in its configuration. That is the
  -- boundary this project says it keeps, breached in the one place where
  -- getting it wrong is a security problem rather than an inconvenience.
  --
  -- `tls = { certificate = ..., key = ... }` is answered here instead. `ctx`
  -- stays as the escape hatch for anyone who needs to configure ciphers,
  -- client certificates or anything else akkar has no opinion about -- named
  -- explicitly, so `grep ctx` is the complete list of applications reaching
  -- past the boundary.
  local tls_ctx = config.ctx
  local tls_on  = config.tls and true or false
  if type(config.tls) == "table" and not tls_ctx then
    local ok, context = pcall(function()
      local openssl_ctx = require "openssl.ssl.context"
      local x509 = require "openssl.x509"
      local pkey = require "openssl.pkey"

      local certificate = config.tls.certificate
        or error("akkar: tls needs `certificate` -- a PEM string or a path", 0)
      local key = config.tls.key
        or error("akkar: tls needs `key` -- a PEM string or a path", 0)

      local function pem(value)
        if value:find "-----BEGIN" then return value end
        local file = assert(io.open(value, "r"),
          "akkar: cannot read " .. tostring(value))
        local contents = file:read "a"
        file:close()
        return contents
      end

      local ctx = openssl_ctx.new(config.tls.protocol or "TLS", true)
      ctx:setCertificate(x509.new(pem(certificate)))
      ctx:setPrivateKey(pkey.new(pem(key)))
      return ctx
    end)
    if not ok then
      error("akkar: could not build the TLS context: " .. tostring(context), 0)
    end
    tls_ctx = context
  end

  local s = assert(server.listen {
    host = host, port = port, tls = tls_on, ctx = tls_ctx,
    reuseport = config.reuseport,
    max_concurrent = max_concurrent,
    onstream = function(_, stream)
      self.in_flight = self.in_flight + 1

      -- Held out here because the WRITES BELOW CAN RAISE, and until they were
      -- allowed to raise past a release this was a capability leak on the
      -- most ordinary event a server sees: a client that goes away in the
      -- middle of a body. `write_headers` and the terminating chunk both sit
      -- outside the producer's own pcall, so a dead peer skipped
      -- `res.release()` entirely -- one pool slot per occurrence, held for
      -- the life of the process, and invisible to the suite because the test
      -- client releases on both paths where the server did not.
      local pending_release

      -- A REQUEST WHOSE FRAMING lua-http REFUSES TO PARSE.
      --
      -- `get_headers` raises for a `Content-Length` that is not a number, or
      -- is negative, and letting that raise travel on took the whole SERVER
      -- down: the process stayed alive and the listening socket stayed open,
      -- but nothing accepted again. Measured with one request --
      -- `Content-Length: banana` -- after which `ss` showed a connection
      -- sitting unaccepted in the queue for ever and every later client timed
      -- out. One malformed header, one line, and the server is gone.
      --
      -- Found by `spec/framing_spec.lua`, which exists because the fuzzer
      -- that goes through an HTTP client cannot express a request this wrong.
      --
      -- Answered 400 and closed HERE, before the raise can reach lua-http's
      -- accept loop. The client is told its request was malformed, which is
      -- true and is the whole of what akkar knows about it.
      local got_headers, headers_or_why = pcall(function()
        return assert(stream:get_headers())
      end)

      if not got_headers then
        internal:warn("refusing a request akkar could not frame", {
          detail = tostring(headers_or_why),
        })
        pcall(function()
          local rh = headers.new()
          rh:append(":status", "400")
          rh:append("content-type", "application/json")
          local body = cjson.encode { error = "malformed request" }
          rh:append("content-length", tostring(#body))
          stream:write_headers(rh, false)
          stream:write_chunk(body, true)
        end)
        pcall(stream.shutdown, stream)
        self.in_flight = self.in_flight - 1
        return
      end

      local ok, err = pcall(function()
        local h = headers_or_why
        -- The socket's own idea of who connected. Everything else about the
        -- client's identity is something the client typed.
        local peer
        do
          local ok_peer, _, address = pcall(function() return stream:peername() end)
          if ok_peer then peer = address end
        end
        local target = h:get ":path" or "/"
        local path, qs = target:match "^([^?]*)%??(.*)$"

        local raw, oversize = read_body(stream, h, body_limit, timeout)
        local body, short
        if oversize == "malformed" then
          short = response(400, { error = "malformed request" })
        elseif oversize == "timeout" then
          -- 408, not 503. The deadline that produces a 503 is akkar deciding
          -- the handler took too long; this is the client never finishing the
          -- request it started, which is what 408 is for.
          short = response(408, { error = "timed out reading the request body" })
        elseif oversize then
          short = response(413, { error = "request body exceeds " ..
                                          body_limit .. " bytes" })
        elseif raw and #raw > 0 then
          local decoded, value = decode_body(raw, h:get "content-type")
          if decoded then body = value
          else short = response(value.status or 400, { error = value.message }) end
        end

        local res, request_id, trace_parent = handle(self, {
          method = h:get ":method", path = path, query = parse_query(qs),
          body = body, raw_body = raw, headers = h, timeout = timeout,
          capabilities = config,
          peer = peer,
          short = short, stripped = true,
        })
        -- Nil for anything that is not a stream: dispatch has already run
        -- `release_all` for those. Captured before a single byte goes out.
        pending_release = res.release

        local rh = headers.new()
        rh:append(":status", tostring(res.status))
        if res.headers then
          for name, value in pairs(res.headers) do rh:append(name, value) end
        end
        -- Onto the wire, not onto the handler's table. A handler that set one
        -- of these itself keeps what it chose.
        if request_id and not (res.headers and res.headers["x-request-id"]) then
          rh:append("x-request-id", request_id)
        end
        if trace_parent and not (res.headers and res.headers["traceparent"]) then
          rh:append("traceparent", trace_parent)
        end
        local is_head = h:get ":method" == "HEAD"

        if res.stream then
          -- No content-length, because the length is not known: lua-http
          -- answers with chunked transfer encoding, which is what streaming
          -- means on HTTP/1.1.  A HEAD gets the headers and the producer is
          -- never run -- running it to throw the bytes away would perform the
          -- side effects of a body nobody asked for.
          rh:append("content-type", res.content_type or "application/json")
          stream:write_headers(rh, is_head)

          if not is_head then
            local wrote = false
            local produced, failure = pcall(res.stream, function(chunk)
              if chunk == nil or chunk == "" then return end
              wrote = true
              assert(stream:write_chunk(tostring(chunk), false))
            end)

            if produced then
              stream:write_chunk("", true)          -- the terminating chunk
            else
              -- The status went out with the first byte, so this cannot
              -- become a 500.  Dropping the connection without the terminating
              -- chunk is the only signal left: the client sees a truncated
              -- response instead of a complete-looking lie.
              internal:error("stream producer failed", {
                request_id = request_id,
                wrote_bytes = wrote,
                detail = tostring(failure),
                hint = wrote and "response already committed; connection dropped"
                              or "nothing was written yet, but the status was",
              })
            end
          end

        else
          local payload = res.raw or (res.body and cjson.encode(res.body)) or nil
          if payload then
            rh:append("content-type", res.content_type or "application/json")
            rh:append("content-length", tostring(#payload))
          end
          -- HEAD carries the headers a GET would, including content-length, and
          -- no body.  That is the point of HEAD.
          local send_body = payload ~= nil and not is_head
          stream:write_headers(rh, not send_body)
          if send_body then stream:write_chunk(payload, true) end
        end
      end)

      -- On EVERY path, including the writes raising above.
      if pending_release then pcall(pending_release) end

      if not ok then internal:error("stream failed", { detail = tostring(err) }) end

      -- `shutdown` guarded, and the count decremented behind nothing that can
      -- raise. `App:stop` drains on `while in_flight > 0`, so a single raise
      -- here used to park the shutdown state machine in DRAINING for ever:
      -- the process would refuse to finish stopping, and the diagnostic it
      -- printed would say it was still waiting for a request that had ended.
      pcall(stream.shutdown, stream)
      self.in_flight = self.in_flight - 1
    end,
    onerror = function(_, _, op, e) internal:warn("transport", { op = op, detail = tostring(e) }) end,
  })

  -- THE PORT IS IN THE MESSAGE, because this is the first error a beginner
  -- meets and the bare assert did not name it.
  --
  -- Writing the beginner guide found this: forgetting to stop the previous
  -- server is the most common mistake anybody makes learning this, and what
  -- akkar answered was `init.lua:2051: Address already in use` plus a
  -- traceback -- no port, no suggestion, and a file and line pointing inside
  -- the framework rather than at anything the reader wrote.
  --
  -- Every other error in this project names the mistake and the fix
  -- (`req.db is not configured; pass db = ... to app:run{}`). This one did
  -- not, and it is the one most likely to be somebody's first.
  local listening, listen_error = s:listen()
  if not listening then
    local reason = tostring(listen_error)
    if reason:find("Address already in use", 1, true) then
      error(("akkar: port %s on %s is already in use.\n  Something else is " ..
             "listening there -- most often a server from a previous run " ..
             "that is still going.\n  Stop it, or start this one on another " ..
             "port with app:run { port = %d }")
            :format(tostring(port), tostring(host), tonumber(port) + 1), 0)
    end
    error(("akkar: could not listen on %s:%s -- %s")
          :format(tostring(host), tostring(port), reason), 0)
  end
  local _, bh, bp = s:localname()
  internal:info("listening", {
    url = string.format("%s://%s:%s", config.tls and "https" or "http",
                        bh or host, tostring(bp or port)),
  })
  self.server = s

  -- A TASK THAT RAISES MUST NOT TAKE THE SERVER DOWN, and must not die
  -- quietly either.
  --
  -- Those pull in opposite directions and the second is the one people get
  -- wrong. A supervisor that swallows the error keeps the process up while
  -- the queue behind the dead consumer grows, and nothing says so until
  -- somebody notices the backlog hours later. So: log at error, count it,
  -- and restart with a backoff that caps -- a task failing instantly in a
  -- loop must not become a busy loop that starves the server it was supposed
  -- to run beside.
  --
  -- A task that RETURNS without being asked to stop is also restarted, and is
  -- also a warning. `Queue:consume` returns when its `should_stop` says so,
  -- so a consumer coming back early means its stop condition is wrong, and
  -- silently never running it again would hide that.
  local function supervise(app, task)
    return function()
      app.tasks_running = (app.tasks_running or 0) + 1
      local failures = 0
      while not app.tasks_stopping do
        local ok, err = pcall(task.fn, {
          name = task.name,
          stopping = function() return app.tasks_stopping == true end,
          app = app,
        })
        if app.tasks_stopping then break end

        if ok then
          internal:warn("task returned before shutdown; restarting", {
            task = task.name,
          })
        else
          failures = failures + 1
          app.task_failures = (app.task_failures or 0) + 1
          internal:error("task raised; restarting", {
            task = task.name, detail = tostring(err), failures = failures,
          })
        end

        -- Doubling from 100 ms, capped at 30 s. The cap matters more than the
        -- curve: an unreachable Redis should cost one line every half minute,
        -- not a core.
        local wait = math.min(30, 0.1 * 2 ^ math.min(failures, 8))
        local until_ = time.monotime() + wait
        while time.monotime() < until_ and not app.tasks_stopping do
          cqueues.poll(math.min(0.2, until_ - time.monotime()))
        end
      end
      app.tasks_running = app.tasks_running - 1
    end
  end

  -- The signal task, if one was installed, runs alongside the server rather
  -- than instead of it -- and so does every registered task.
  if self.signal_task or (self.tasks and #self.tasks > 0) then
    local cq = cqueues.new()
    cq:wrap(function() s:loop() end)
    if self.signal_task then cq:wrap(self.signal_task) end
    for _, task in ipairs(self.tasks or {}) do
      internal:info("task started", { task = task.name })
      cq:wrap(supervise(self, task))
    end
    return assert(cq:loop())
  end
  return assert(s:loop())
end

-- =============================================================== test client
-- No socket, no port, no server.  Travels exactly the same chain a real
-- request does, because `handle` is shared.
function App:test(config)
  config = config or {}

  local allowed = { timeout = true, log = true,
                    peer = true, trusted_proxies = true }
  for k in pairs(CAPABILITIES) do allowed[k] = true end
  check_config(config, allowed, "app:test{}")

  chains(self)
  local client = {}
  local function call(method)
    return function(_, path, options)
      options = options or {}
      local p, qs = path:match "^([^?]*)%??(.*)$"
      local res, request_id, trace_parent = handle(self, {
        method = method, path = p,
        query = parse_query(qs),
        body = options.body,
        -- `raw_body` is what a signature is computed over, so a test that
        -- exercises one has to be able to say exactly which bytes arrived.
        -- Passing it explicitly is the honest option: encoding `options.body`
        -- here would produce whichever key order this encoder happens to
        -- choose, and a test asserting on a digest over that would be
        -- asserting on cjson's iteration order.
        raw_body = options.raw_body,
        headers = options.headers or {},
        timeout = options.timeout or config.timeout,
        capabilities = config,
      })
      -- A streamed body is produced here and handed back as `raw`, so a test
      -- asserts on what the client would have received rather than on the
      -- producer function.  The whole body lands in memory, which is the
      -- opposite of the point of streaming and exactly right for a test.
      local raw = res.raw
      if res.stream then
        local chunks = {}
        local ok_stream, failure = pcall(res.stream, function(chunk)
          if chunk ~= nil and chunk ~= "" then chunks[#chunks + 1] = tostring(chunk) end
        end)
        if res.release then res.release() end
        if not ok_stream then
          -- On a real connection this is a truncated response, which a test
          -- client cannot express.  Raising is the closest honest equivalent:
          -- silently returning the partial body would let a broken producer
          -- pass its tests.
          error("akkar: stream producer failed after " .. #chunks ..
                " chunk(s): " .. tostring(failure), 0)
        end
        raw = table.concat(chunks)
      end
      -- A fresh table, carrying what the wire would have carried. Allocating
      -- here is free -- this is a test client -- and returning the handler's
      -- own table would hand a spec the very aliasing the server refuses to
      -- create.
      local seen = {}
      if res.headers then
        for name, value in pairs(res.headers) do seen[name] = value end
      end
      if request_id and seen["x-request-id"] == nil then
        seen["x-request-id"] = request_id
      end
      if trace_parent and seen["traceparent"] == nil then
        seen["traceparent"] = trace_parent
      end

      return { status = res.status, body = res.body, raw = raw, headers = seen }
    end
  end
  for _, m in ipairs { "get", "post", "put", "patch", "delete", "head", "options" } do
    client[m] = call(m:upper())
  end
  return client
end

-- ================================================================ middleware
-- CORS is middleware rather than core, because it is policy: only the
-- application knows which origins it trusts.  What akkar contributes is that
-- the preflight already knows the real Allow list, so the browser is told
-- what the router actually accepts instead of a hardcoded guess.
function akkar.cors(options)
  options = options or {}
  local origin  = options.origin or "*"
  local headers_allowed = options.headers or "content-type, authorization"
  local max_age = tostring(options.max_age or 600)
  local credentials = options.credentials and "true" or nil

  return function(req, next)
    local res = next(req)
    res.headers = res.headers or {}
    res.headers["access-control-allow-origin"] = origin
    if credentials then res.headers["access-control-allow-credentials"] = credentials end
    if req.method == "OPTIONS" then
      res.headers["access-control-allow-methods"] =
        res.headers["allow"] or "GET, POST, PUT, PATCH, DELETE, OPTIONS"
      res.headers["access-control-allow-headers"] = headers_allowed
      res.headers["access-control-max-age"] = max_age
    end
    return res
  end
end

-- Installs SIGTERM and SIGINT handlers that call app:stop.
--
-- Not automatic: a library that installs signal handlers behind an
-- application's back is a library that fights with whatever else the process
-- is doing.  But without this a container stop kills requests mid-flight, so
-- it should be one line rather than an exercise.
function App:handle_signals(signals)
  local ok, signal = pcall(require, "cqueues.signal")
  if not ok then
    internal:warn("cqueues.signal unavailable; signals not handled")
    return self
  end
  signals = signals or { signal.SIGTERM, signal.SIGINT }
  for _, sig in ipairs(signals) do signal.block(sig) end

  local listener = signal.listen(table.unpack(signals))
  local app = self
  self.signal_task = function()
    listener:wait()
    internal:info("signal received")
    app:stop()
  end
  return self
end

-- Exposed so tests can express a JSON null without going through the wire.
-- The serializer's sentinel, reached through the contract rather than lifted
-- out of a dependency. It used to read `cjson.null` -- a C userdata from a
-- library nothing in akkar's API mentions, handed to users as akkar's own
-- value and compared by identity in dispatch. Swapping the JSON library would
-- have changed the identity of a value people were holding.
akkar.null = cjson.null
akkar.json = cjson          -- `cjson` is `akkar.json` here; see that module

-- Marks a table as a JSON array, so an EMPTY one encodes as `[]` not `{}`.
--
--     return { tasks = akkar.array(rows) }
--
-- An empty Lua table is both an empty list and an empty object and the
-- encoder has to guess; it guesses object, so an empty result set answered
-- `{"tasks":{}}` and a frontend calling `.map` on it threw. See
-- `akkar/json.lua` for why this is a marker and not a walk.
akkar.array = cjson.array
akkar.empty_array = cjson.empty_array

-- Exposed so the startup checks can be tested without binding a socket.
akkar.check_capabilities = check_capability_contracts
akkar.log = log
akkar.work = require "akkar.work"
akkar.metrics = require "akkar.metrics"
akkar.strict = require "akkar.strict"

akkar.Response = Response
akkar.guard = guard

-- Exposed because middleware has to tell a thrown response from a raised
-- error, and the alternative was comparing metatables -- the framework's
-- internals leaking into code written against it.
akkar.is_response = is_response
return akkar
