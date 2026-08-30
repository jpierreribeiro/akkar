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
local server  = require "http.server"
local headers = require "http.headers"
local cjson   = require "cjson"
local log     = require "akkar.log"
local multipart = require "akkar.multipart"

local akkar = {}

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
  read_timeout   = 30,            -- seconds a client may take to deliver one
                                  -- request: measured from the first byte, so
                                  -- trickling cannot extend it
  http_version   = 1.1,           -- the protocol the rest of this runtime
                                  -- assumes; see `http_version` in App:run
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
-- A capability is infrastructure the framework knows how to inject, guard and
-- fake.  Anything belonging to the application -- a mailer, a payment gateway,
-- a recommendation service -- does not qualify and must be closed over by the
-- handler instead.  Without an admission rule this table grows forever, and
-- every entry becomes permanent: moving `req.db` to `ctx.db` later would force
-- an edit to every handler ever written, which is exactly what the complexity
-- ladder forbids.
local CAPABILITIES = { db = true, cache = true, log = true, clock = true }

-- What each capability must be able to do.  Checked once at startup, so a
-- misconfigured adapter fails at boot the way a duplicate route already does,
-- rather than on whichever request first happens to touch it.
local CONTRACTS = {
  db    = { "one", "many", "exec", "transaction" },
  cache = { "get", "set", "del" },
  log   = { "debug", "info", "warn", "error", "with" },
}

-- The framework's own voice.  Replaced by `app:run { log = ... }`, but present
-- so nothing has to be configured for diagnostics to appear.
local internal = log.new { level = "info", format = "text" }

-- Everything else app:run{} accepts.  Listed so that a typo is an error rather
-- than silence: `app:run { timout = 5 }` used to be ignored, leaving a server
-- running with a 30 s deadline the author believed was 5 s.
local SETTINGS = {
  host = true, port = true, tls = true, ctx = true,
  body_limit = true, timeout = true, shutdown_grace = true, read_timeout = true,
  check_capabilities = true, reuseport = true, strict = true,
  max_concurrent = true, trusted_proxies = true, http_version = true,
}

-- Route options, checked for the same reason: `app:post("/x", { bdy = ... })`
-- silently declaring no schema at all is worse than an error, because the
-- route then accepts anything while looking validated.
local ROUTE_OPTIONS = {
  params = true, query = true, body = true, response = true, responses = true,
  before = true, openapi = true,
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
      consequence = "an abandoned query keeps a backend busy after the 503",
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

local function validator(kind)
  return function(opts)
    opts = opts or {}
    opts.kind = kind
    return opts
  end
end

v.string  = validator "string"
v.integer = validator "integer"
v.number  = validator "number"
v.boolean = validator "boolean"
v.table   = validator "table"
v.object  = validator "object"
v.array   = validator "array"

local SHORTHAND = { string = true, integer = true, number = true,
                    boolean = true, table = true, object = true, array = true }

local function expand(rule)
  if type(rule) == "table" then return rule end
  if type(rule) ~= "string" then
    error("invalid schema rule: " .. type(rule), 0)
  end
  local optional = rule:sub(-1) == "?"
  local kind = optional and rule:sub(1, -2) or rule
  if not SHORTHAND[kind] then
    error("unknown schema type: '" .. rule ..
          "'; use string, integer, number, boolean, table, object, array " ..
          "(with ? for optional)", 0)
  end
  return { kind = kind, optional = optional }
end

local validate, validate_rule

local function prefixed_errors(prefix, errors)
  local out = {}
  for field, why in pairs(errors or {}) do
    local key = field == "" and tostring(prefix) or (tostring(prefix) .. "." .. field)
    out[key] = why
  end
  return out
end

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
    -- `value % 1 ~= 0` reads like an integer test and is not one.  It is a
    -- test for a FRACTIONAL PART, which every large float passes: `1e15` and
    -- `1e308` are both whole and both floats, so `v.integer { min = 1 }`
    -- accepted them and handed a float to code that had been promised an
    -- integer.  Confirmed downstream on this branch -- `?limit=1e1` validated
    -- here and then raised inside the SQL builder, turning an unauthenticated
    -- query string into a 500 -- and these are prices and quantities.
    --
    -- So the value must BE an integer, or convert to one exactly.  The
    -- conversion is what keeps `?limit=10` working when it arrives as the
    -- string "10" and coercion produces a float on some paths.  Anything
    -- from 2^53 up is rejected outright rather than converted: at that
    -- magnitude a float no longer has an integer to be exact about, which is
    -- how cjson turns `9007199254740993` in a body into ...992, and rounding
    -- somebody's amount by one and calling it valid is the worst of the
    -- three outcomes available here.
    if kind == "integer" and math.type(value) ~= "integer" then
      local exact = math.tointeger(value)
      if exact == nil or value >= 9007199254740992.0
                      or value <= -9007199254740992.0 then
        return nil, "expected integer"
      end
      value = exact
    end
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
  elseif kind == "object" then
    if type(value) ~= "table" or value[1] ~= nil then return nil, "expected object" end
    if type(rule.fields) ~= "table" then return nil, "object schema needs fields" end
    local clean, failures = validate_rule(value, rule, coerce)
    if failures then return nil, failures end
    value = clean
  elseif kind == "array" then
    if type(value) ~= "table" then return nil, "expected array" end
    local count = #value
    for key in pairs(value) do
      if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then
        return nil, "expected array"
      end
    end
    if rule.min and count < rule.min then return nil, "min items " .. rule.min end
    if rule.max and count > rule.max then return nil, "max items " .. rule.max end
    if rule.items == nil then return nil, "array schema needs items" end
    local clean, failures = setmetatable({}, cjson.array_mt), {}
    for index, item in ipairs(value) do
      local got, err = check_one(item, expand(rule.items), coerce)
      if err then
        if type(err) == "table" then
          for path, why in pairs(prefixed_errors(index, err)) do failures[path] = why end
        else
          failures[tostring(index)] = err
        end
      else
        clean[index] = got
      end
    end
    if next(failures) then return nil, failures end
    value = clean
  end

  if rule.default ~= nil and value == nil then value = rule.default end
  return value, nil
end

-- Returns (clean_table, nil) or (nil, failures_by_field)
validate_rule = function(input, schema, coerce)
  local expanded = expand(schema)
  if expanded.kind == "object" then
    return validate(input, expanded.fields, coerce)
  end
  local clean, err = check_one(input, expanded, coerce)
  if err then
    if type(err) == "table" then return nil, err end
    return nil, { [""] = err }
  end
  return clean, nil
end

validate = function(input, schema, coerce)
  if type(schema) == "table" and schema.kind then
    return validate_rule(input, schema, coerce)
  end
  -- Defensive: anything that is not a table is treated as absent, so a
  -- surprising body shape becomes a field-level error rather than a 500.
  if type(input) ~= "table" then input = {} end
  local cleaned, failures, any = {}, {}, false
  for field, rule in pairs(schema) do
    local expanded = expand(rule)
    local value = input[field]
    if value == nil and expanded.default ~= nil then value = expanded.default end
    local got, err = check_one(value, expanded, coerce)
    if type(err) == "table" then
      for path, why in pairs(prefixed_errors(field, err)) do failures[path] = why end
      any = true
    elseif err then failures[field] = err any = true
    else cleaned[field] = got end
  end
  if any then return nil, failures end
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
  local cpu, last, warned = 0, cqueues.monotime(), false
  debug.sethook(function()
    local now = cqueues.monotime()
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

-- Forward declaration.  `traced` captures a failing frame's stack for the log
-- and is defined with the rest of the error handling, below; the deadline
-- needs it because the deadline owns the frame that runs the chain.
local traced

-- ================================================================== deadline
-- Wall-clock budget for one request.
--
-- Arbitration follows one rule, learned the expensive way on an earlier
-- project: THE WINNER IS DECIDED BY THE FIRST ARBITRATING EVENT AND A LATE
-- EVENT NEVER OVERTURNS IT.  A handler that finishes at 4.99 s against a 5 s
-- deadline has completed; reporting that as a timeout would discard work that
-- actually happened, which is how this goes wrong silently.
--
-- A nested controller is stepped through `cqueues.poll`, never `loop`, because
-- calling loop() from inside the server's controller would block every other
-- request -- exactly the failure this is meant to prevent.
--
-- HONEST LIMIT: this is cooperative.  It can only fire while the handler is
-- yielding on I/O.  A handler burning CPU in a tight loop is not interrupted
-- by the deadline; that is what the watchdog below reports instead.
local controller_pool = {}
local POOL_LIMIT = 64

local function with_deadline(seconds, fn)
  if not seconds or seconds <= 0 or not cqueues.running() then
    return "COMPLETION", fn()          -- no budget, or no controller to yield to
  end

  -- Controllers are pooled, and speed is only one of three reasons.
  --
  -- Three separate investigations landed on this object.  A fresh
  -- `cqueues.new()` per request cost 25 us of akkar's 34.7 us total overhead;
  -- it contributed to the 2,814 bytes of garbage a trivial request produced;
  -- and each controller holds **exactly 2.00 file descriptors**, confirmed at
  -- three different limits:
  --
  --     ulimit -n 256   ->  126 controllers   (2.03 each)
  --     ulimit -n 1024  ->  510 controllers   (2.01 each)
  --     ulimit -n 4096  -> 2046 controllers   (2.00 each)
  --
  -- Those descriptors came back only when the collector ran, which quietly
  -- tied a hard operating-system limit to the pace of the garbage collector.
  -- Nothing declared that, and no profile would have shown it.
  local cq = table.remove(controller_pool) or cqueues.new()
  local winner, result

  cq:wrap(function()
    -- `traced` and not `pcall`: this frame is the last place the handler's
    -- stack still exists.  The rethrow at the bottom of this function crosses
    -- a coroutine boundary, and a traceback taken there describes the
    -- rethrow, not the failure.
    local ok, res = xpcall(fn, traced)
    if winner == nil then              -- first arbitrating event wins
      winner = ok and "COMPLETION" or "ERROR"
      result = res
    end
  end)

  -- Step before polling.  `wrap` only queues the coroutine, so the handler has
  -- not started yet; polling first made every synchronous request wait on a
  -- descriptor for work that was already ready to run.
  cq:step(0)

  local deadline = cqueues.monotime() + seconds
  while winner == nil do
    local remaining = deadline - cqueues.monotime()
    if remaining <= 0 then break end
    cqueues.poll(cq, remaining)        -- yields to the outer controller
    cq:step(0)
  end

  -- Only an empty controller goes back.  A handler abandoned by the deadline
  -- is still running inside its controller, and reusing that would hand the
  -- next request someone else's unfinished work -- the same class of bug as a
  -- pooled database connection with a transaction still open.
  if cq:empty() and #controller_pool < POOL_LIMIT then
    controller_pool[#controller_pool + 1] = cq
  end

  if winner == nil then winner = "TIMEOUT" end
  if winner == "ERROR" then error(result, 0) end
  return winner, result
end

-- ==================================================================== guards
-- Invariant: reading something that was never configured gives a useful
-- message, not "attempt to index a nil value".
-- A guard is immutable and its identity carries no meaning, so one per name
-- is built once and shared.  Every request was allocating a table, a
-- metatable and three closures to represent the same nothing.
--
-- `__newindex` is what makes sharing safe: without it, `req.user.id = 1` on
-- an unauthenticated request would silently write into an object every other
-- request also holds.  With it, that line says what is actually wrong.
local guards = {}
local function guard(name, hint)
  local existing = guards[name]
  if existing then return existing end

  local fail = function() error(hint, 2) end
  local g = setmetatable({}, {
    __index = fail,
    __call = fail,
    __newindex = fail,
    __tostring = function() return "<" .. name .. " missing>" end,
  })
  guards[name] = g
  return g
end

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

    local pattern, names = compile(path)
    local route = { method = verb, path = path, pattern = pattern, names = names,
                    handler = handler, opts = opts, where = where }
    self.routes[#self.routes + 1] = route
    if #names == 0 then self.exact[verb .. " " .. path] = route end
    return self
  end
end

-- The chain is compiled once, on the first request, and never rebuilt: that is
-- what makes middleware cost a closure per layer rather than a table walk per
-- request.  The consequence is that registering one afterwards does nothing,
-- and it used to do nothing SILENTLY.  An app that called `app:use(auth)` from
-- inside a lazily-required module served every route unauthenticated and said
-- so nowhere.
--
-- A late registration is therefore an error, not a warning.  There is no
-- reading of it that is correct: either the middleware was meant to run, and
-- the process is now serving requests without it, or it was not, and the call
-- is a mistake either way.
function App:use(fn)
  if self._chain then
    error("app:use() was called after the first request; the middleware chain " ..
          "is built once, so this middleware would never run.  Register every " ..
          "middleware before app:run{} or app:test{}.", 2)
  end
  self.middleware[#self.middleware + 1] = fn
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
  for i, name in ipairs(names) do params[name] = unescape(captured[i]) end
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
      local route, params = m.app:match(method, rest)
      if route then return route, params end
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

-- ============================================== responses the framework owns
--
-- A handler is allowed to return a module-level constant.  Nothing forbids it,
-- the "handlers return a value" thesis makes it look free, and it is the
-- obvious thing to write for `/health`:
--
--     local UP = akkar.ok { status = "up" }
--     app:get("/health", function() return UP end)
--
-- The framework then wrote `x-request-id` into that table -- on EVERY request,
-- creating `headers` on it the first time -- and so did every middleware that
-- decorates a response on the way out.  The table is shared, so the writes
-- accumulate on it forever.  Reproduced with a real server and separate TCP
-- connections: a session middleware's `set-cookie` for alice, written onto a
-- hoisted response, was still on that response when an anonymous probe hit the
-- same route.  Correlation ids cross-contaminated the same way -- two
-- responses held by one client were literally the same table, so the second
-- request rewrote the first one's id.
--
-- Commit d1e5d45 fixed exactly this for `release`, by copying.  `headers` is
-- written on every request rather than on streamed ones, so it needed it more.
--
-- The copy is taken once, at the boundary where an application's value first
-- enters the framework -- the handler's return, and a middleware's own
-- short-circuit -- and tagged with the request that owns it, so carrying it
-- back up through a chain of middleware does not copy it again.  A handler
-- returning a plain table costs nothing at all: `normalize` already builds it
-- a fresh response.
local function own(res, token)
  if not is_response(res) then return res end
  if token ~= nil and rawget(res, "__owner") == token then return res end

  local copied = setmetatable({}, Response)
  for key, value in pairs(res) do copied[key] = value end
  if res.headers then
    local hdrs = {}
    for name, value in pairs(res.headers) do hdrs[name] = value end
    copied.headers = hdrs
  end
  copied.__owner = token
  return copied
end

-- =========================================== what the operator sees, only
--
-- `internal_error` keeps the RESPONSE bare on purpose: a Lua error carries
-- file paths, line numbers and sometimes credentials or personal data, and
-- none of that belongs on the wire.  That redaction (commit f1c1388) was then
-- applied to the LOGS as well, which nobody outside the process reads -- and
-- the result was an outage whose entire trace was five lines of
--
--     ERROR stream failed error_kind=string
--
-- The kind of the error and nothing else: not the message, not the file, not
-- the line.  So the two audiences are separated here rather than conflated.
-- The client keeps `{"error": "internal server error"}` and the request id.
-- The operator gets the message and the stack, in the log.
--
-- The traceback has to be captured by a message handler, at the frame that
-- raised, because by the time `pcall` returns the stack is gone.  A
-- response-as-error is control flow rather than a failure and passes through
-- untouched, so `is_response` still recognises it on the other side.
function traced(err)
  if is_response(err) then return err end
  -- Already captured deeper in, at a frame closer to the failure than this
  -- one.  Wrapping it again would bury the real stack under a rethrow.
  if type(err) == "table" and rawget(err, "__traced") then return err end
  return { __traced = true, err = err, stack = debug.traceback(nil, 2) }
end

--- The value the application was given, whether or not `traced` wrapped it.
local function cause_of(result)
  if type(result) == "table" and rawget(result, "__traced") then return result.err end
  return result
end

--- The frames worth printing, on one line.
---
--- Folded onto one line because logfmt and JSON are both one entry per line,
--- and a traceback that breaks that is a traceback no collector reassembles.
--- Cut to the frames nearest the failure because the rest is always the same
--- five layers of akkar, the deadline and the test runner: a log line long
--- enough to be truncated by the collector loses the top of the stack, which
--- is the only part anybody reads.
local TRACEBACK_FRAMES = 6

local function fold_traceback(stack)
  local frames = {}
  for line in stack:gmatch "[^\n]+" do
    line = line:match "^%s*(.-)%s*$"
    if line ~= "" and line ~= "stack traceback:" then
      frames[#frames + 1] = line
      if #frames == TRACEBACK_FRAMES then break end
    end
  end
  return table.concat(frames, " | ")
end

--- Log fields for a failure: the message, and where it came from.
local function diagnosis(result)
  local err = cause_of(result)
  local message
  if type(err) == "string" then message = err
  elseif type(err) == "table" and type(err.message) == "string" then message = err.message
  else message = tostring(err) end

  local fields = { error_kind = type(err), error = message }
  if type(result) == "table" and rawget(result, "__traced") then
    fields.traceback = fold_traceback(result.stack)
  end
  return fields
end

--- `fields` for a failure, plus whatever else the call site wants to say.
local function diagnosis_with(result, extra)
  local fields = diagnosis(result)
  for key, value in pairs(extra) do fields[key] = value end
  return fields
end

-- ======================================= middleware that forgets to return
--
--     app:use(function(req, next) next(req) end)      -- one missing `return`
--
-- The handler ran, its answer was thrown away, and `normalize(nil)` turned
-- that into 204: an empty SUCCESS.  Every signal an operator has said the
-- request was fine -- 2xx in the access log, 2xx in the metrics -- and the
-- client received nothing.  Written into a logging middleware, it blanks
-- every response in the application at once and explains itself nowhere.
--
-- Returning nothing WITHOUT calling `next` is a different thing and stays
-- legal: that is a middleware deciding to answer 204.  Only the pair -- next
-- was called, nothing came back -- has no correct reading, and it becomes a
-- 500 naming where the middleware was defined, because a wrong answer that
-- announces itself is worth more than a wrong answer that does not.
local function forgot_return(mw)
  local info = debug.getinfo(mw, "S")
  error(string.format(
    "middleware defined at %s:%d called next() and returned nothing, so the " ..
    "handler's response was discarded and the client would have received an " ..
    "empty 204.  Middleware must `return next(req)`.",
    info and info.short_src or "?", info and info.linedefined or 0), 0)
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
--- and sometimes credentials or personal data. Raw exception text therefore
--- belongs in neither the response nor routine logs; correlation uses the
--- request id and route location.
local function internal_error(app, err, req)
  local fallback = response(500, { error = "internal server error" })

  local handler = app and app._on_error
  if not handler then return fallback end

  local ok, result = pcall(handler, cause_of(err), req)

  -- `normalize` turns nil into 204, which is the right reading of "the
  -- handler had nothing to add" everywhere except here: answering an empty
  -- SUCCESS to a request that failed would be the worst outcome of the three.
  -- Returning nothing from an error handler means it declined.
  if ok and result == nil then return fallback end

  if not ok then
    internal:error("the error handler itself raised", diagnosis_with(result, {
      request_id = req and req.id,
      hint = "the built-in 500 was sent instead",
    }))
    return fallback
  end

  local valid, response_or_why = pcall(normalize, result)
  if not valid then
    internal:error("the error handler returned something that is not a response",
      diagnosis_with(response_or_why, { request_id = req and req.id }))
    return fallback
  end
  -- The application's error handler may return a hoisted response too, and it
  -- is on the path that runs when things are already going wrong.
  return own(response_or_why, req)
end

local function apply_response_schema(res, schema, where, app, req)
  if res.status < 200 or res.status >= 300 then return res end
  if res.raw then return res end
  if type(res.body) ~= "table" then return res end
  -- Legacy field maps describe objects. Root arrays are validated only when
  -- the route explicitly declares v.array{}, preserving the old behaviour.
  if res.body[1] ~= nil and not (type(schema) == "table" and schema.kind) then
    return res
  end

  local cleaned, failures = validate(res.body, schema, false)
  if failures then
    local detail = {}
    for field, why in pairs(failures) do detail[#detail + 1] = field .. ": " .. why end
    table.sort(detail)
    internal:error("response does not match its schema", {
      at = where, fields = table.concat(detail, "; "),
    })
    return internal_error(app,
      "response does not match its schema at " .. tostring(where) ..
      ": " .. table.concat(detail, "; "), req)
  end
  return response(res.status, cleaned, res.headers)
end

local function dispatch(app, req)
  local route, params = app:match(req.method, req.path)

  if not route then
    -- HEAD is served by the GET handler.  RFC 9110 requires HEAD wherever GET
    -- exists, and answering 404 to a HEAD on a live resource is a lie.
    if req.method == "HEAD" then
      route, params = app:match("GET", req.path)
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
  -- `own` is applied to the HANDLER's value, before any middleware sees it:
  -- this is the innermost point an application's table enters the framework,
  -- and a route middleware decorating a hoisted response is the same leak as
  -- a global one doing it.
  local run = function() return own(route.handler(req), req) end
  if opts and opts.before then
    for i = #opts.before, 1, -1 do
      local mw, nxt = opts.before[i], run
      run = function()
        local reached = false
        local value = mw(req, function() reached = true; return nxt() end)
        if value == nil and reached then forgot_return(mw) end
        return own(value, req)
      end
    end
  end

  install_watchdog(route.where)
  -- `normalize` runs INSIDE the pcall: a handler returning an invalid value
  -- must become a 500 with a clear log, not escape as an unhandled error.
  -- `xpcall` rather than `pcall` for one reason: the traceback only exists
  -- while the failing frame is still on the stack.
  local ok, result = xpcall(function()
    local res = normalize(run())
    -- Whatever produced it -- the handler, `normalize` wrapping a plain
    -- table, a route middleware -- it belongs to this request from here on,
    -- so the global chain above may decorate it without copying again.
    res.__owner = req
    return res
  end, traced)
  remove_watchdog()

  if not ok then
    -- Response-as-error: a deep layer can signal HTTP without threading a
    -- return value back through every frame.
    if is_response(result) then return own(result, req) end
    internal:error("handler raised", diagnosis_with(result, {
      request_id = req.id, at = route.where,
    }))
    return internal_error(app, result, req)
  end

  if opts then
    local declared = opts.responses and
      (opts.responses[result.status] or opts.responses[tostring(result.status)])
    local schema = declared or opts.response
    if schema then
      result = apply_response_schema(result, schema, route.where, app, req)
      result.__owner = req      -- filtering rebuilds it; it is still ours
    end
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
      local reached = false
      local value = mw(req, function(r)
        reached = true
        return next_fn(a, r or req)
      end)
      if value == nil and reached then forgot_return(mw) end
      -- Free when the middleware passed the response through: `own` sees its
      -- own tag and returns the same table.  It copies only when the
      -- middleware short-circuited with a response of its own, which may be
      -- hoisted like any other.
      return own(normalize(value), req)
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
-- ============================================================== request id
--
-- Who the request IS, which is a different question from what the request
-- SAYS -- the same distinction `req.ip` draws sixty lines below, and it used
-- to be drawn the other way here.  `X-Request-Id` was taken verbatim, length
-- checked and otherwise believed, twenty lines above the essay explaining why
-- `X-Forwarded-For` must never be.  Two things came of that, both measured on
-- a running server:
--
--   `akkar.limit` keys a concurrency slot on `req.id`.  Clients all sending
--   `X-Request-Id: x` shared ONE slot between them: peak 46 simultaneous
--   requests against `limit = 2`.  The framework's only admission control,
--   defeated by a constant header.
--
--   Every framework log line carries `request_id=<that string>`, and logfmt
--   separates fields with spaces.  One header --
--   `abc level=error message=DB_DELETED actor=admin` -- wrote four fields
--   into the operator's log, three of them lies.
--
-- So `req.id` is akkar's own: unique by construction, and made of characters
-- no log format can be steered with.  What the client sent survives as
-- `req.client_request_id`, sanitised, and named so that believing it is a
-- decision an application makes rather than one it inherits.  Correlation
-- across services that has to be trusted is what `traceparent` is for, and
-- that one is validated rather than echoed.
--
-- Not a UUID: this only has to be unique enough to correlate lines within a
-- window, and pulling in a UUID library for that would be a dependency bought
-- with nothing.  A random prefix chosen once per process, then a counter.
-- Two RNG calls per request bought nothing: within a process a counter cannot
-- collide at all, which is strictly better than hoping two 48-bit draws
-- differ, and across processes the prefix separates them.
local ID_PREFIX = string.format("%08x", math.random(0, 0xffffffff))
local id_counter = 0

local function request_id()
  id_counter = id_counter + 1
  return ID_PREFIX .. string.format("%06x", id_counter & 0xffffff)
end

-- Letters, digits and the four separators every id scheme in the wild already
-- restricts itself to.  No space and no `=`, which is what makes a logfmt
-- field; no quote, brace or backslash, which is what makes a JSON one.
--
-- Length is capped at a UUID with room to spare, and anything outside the set
-- is DROPPED rather than stripped or truncated: an id sanitised into a
-- different id correlates to the wrong request, which is worse than not
-- correlating at all.
local CLIENT_REQUEST_ID_MAX = 128

local function client_request_id(headers)
  local given = headers and headers["x-request-id"]
  if type(given) ~= "string" then return nil end
  if #given == 0 or #given > CLIENT_REQUEST_ID_MAX then return nil end
  if given:match "^[%w%._:%-]+$" then return given end
  return nil
end
akkar.client_request_id = client_request_id

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
        local existing = out[name]
        out[name] = existing and (existing .. ", " .. value) or value
      end
    end
  else
    for name, value in pairs(source) do out[name:lower()] = value end
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

-- ======================================= what a setting must actually BE
--
-- `check_config` checks the NAME of every option and stops there, and half a
-- check turns out to be worth about half as much:
--
--     app:run { timeout = os.getenv "REQUEST_TIMEOUT" }
--
-- The name is spelled right, so it boots, and every request afterwards is a
-- 500 -- the deadline compares a string to a number and raises -- while the
-- only thing in the log is `error_kind=string`.  Four more passed the same
-- way, each one a server that starts and then does not work:
--
--     body_limit = -1            rejects every body, including empty ones
--     port = "not-a-port"        reaches server.listen as a string
--     max_concurrent = 0         accepts no connection at all
--     trusted_proxies = "10/8"   a string where a list belongs, so the walk
--                                over it finds nothing and no proxy is
--                                trusted -- while the config says one is
--
-- The whole argument for the name check applies unchanged: a mistake found at
-- boot costs a second, and found in production costs an incident.  So the
-- values are checked against what the code that reads them actually needs,
-- and the message says what was passed rather than only what was wanted.
--
-- Each rule returns the expectation when the value is wrong, and nothing when
-- it is fine.  A setting with no rule here is one whose value the framework
-- genuinely cannot judge -- `ctx` is an OpenSSL object, `db` is checked
-- against its contract instead.
local function valid_cidr(cidr)
  local base, bits = cidr:match "^([%d%.]+)/(%d+)$"
  if not base then base, bits = cidr, "32" end
  bits = tonumber(bits)
  return ipv4_to_int(base) ~= nil and bits ~= nil and bits >= 0 and bits <= 32
end

local function seconds(allow_zero)
  local wanted = allow_zero and "a number of seconds, zero or more"
                             or "a positive number of seconds"
  return function(value)
    if type(value) ~= "number" or value ~= value then return wanted end
    if value < 0 or (not allow_zero and value == 0) then return wanted end
  end
end

local SETTING_RULES = {
  host = function(value)
    if type(value) ~= "string" or value == "" then return "a non-empty string" end
  end,
  port = function(value)
    if math.type(value) ~= "integer" or value < 0 or value > 65535 then
      return "an integer from 0 to 65535 (0 asks the kernel for a free port)"
    end
  end,
  body_limit = function(value)
    if math.type(value) ~= "integer" or value < 1 then
      return "a positive whole number of bytes"
    end
  end,
  -- `false` and `0` both mean "no deadline" to `with_deadline`, and an
  -- application that means it should be able to say so.
  timeout = function(value)
    if value == false then return nil end
    if type(value) ~= "number" or value ~= value or value < 0 then
      return "a number of seconds, or false for no deadline"
    end
  end,
  read_timeout   = seconds(false),
  shutdown_grace = seconds(true),
  max_concurrent = function(value)
    if math.type(value) ~= "integer" or value < 1 then
      return "an integer of at least 1 (it is a ceiling on connections)"
    end
  end,
  http_version = function(value)
    if value ~= 1.0 and value ~= 1.1 and value ~= 2 then
      return "1.0, 1.1 or 2"
    end
  end,
  reuseport          = function(value) if type(value) ~= "boolean" then return "true or false" end end,
  strict             = function(value) if type(value) ~= "boolean" then return "true or false" end end,
  check_capabilities = function(value) if type(value) ~= "boolean" then return "true or false" end end,
  tls                = function(value) if type(value) ~= "boolean" then return "true or false" end end,
  log = function(value)
    if type(value) ~= "table" then return "a logger, from akkar.log.new{}" end
  end,
  peer = function(value)
    if type(value) ~= "string" then return "an address, as a string" end
  end,
  trusted_proxies = function(value)
    local list = [[a LIST of CIDR strings, e.g. { "10.0.0.0/8" }]]
    if type(value) ~= "table" then return list end
    if next(value) ~= nil and value[1] == nil then return list end
    for _, cidr in ipairs(value) do
      if type(cidr) ~= "string" then return list end
      -- A CIDR that does not parse matches nothing, so the proxy list looks
      -- configured and trusts no hop -- failing closed, silently, which is
      -- the failure mode this whole section exists to make loud.
      if not valid_cidr(cidr) then
        return "a list of IPv4 CIDRs; '" .. cidr .. "' is not one"
      end
    end
  end,
}

local function describe_value(value)
  if type(value) == "string" then return string.format("string %q", value) end
  return type(value) .. " " .. tostring(value)
end

--- Raises on the first setting whose VALUE the runtime cannot use.
--- Exported so `akkar.doctor` can report the same finding without booting.
local function check_setting_values(config, what)
  for key, value in pairs(config) do
    local rule = SETTING_RULES[key]
    if rule and value ~= nil then
      local expected = rule(value)
      if expected then
        error(string.format("%s: %s must be %s; got %s",
                            what, key, expected, describe_value(value)), 3)
      end
    end
  end
end
akkar.check_settings = check_setting_values

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
    if k and k ~= "" then out[unescape(k)] = unescape((val:gsub("+", " "))) end
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
    headers = request_headers,
    host    = normalize_host(requested_host),
    id      = request_id(),
    user    = guard("req.user", "req.user is not set; this route is missing the authentication middleware"),
  }

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

      -- Lazy for the same reason `trace` and `ip` are, and the reason is the
      -- allocation ceiling: a ninth field in the constructor grows `req`'s
      -- hash part and was measured at 191 bytes on EVERY request, including
      -- the overwhelming majority that never look at it.
      if key == "client_request_id" then
        local given = client_request_id(rawget(self, "headers"))
        if given then rawset(self, "client_request_id", given) end
        return given
      end

      if not CAPABILITIES[key] then return nil end
      local provided = input.capabilities and input.capabilities[key]
      local value
      if key == "log" then
        -- `log` is the one capability with a default, because diagnostics
        -- that need configuring before they appear are diagnostics nobody
        -- sees.  Bound to the request id here, so a handler writing
        -- `req.log:info(...)` correlates without doing anything.
        -- Both ids, when the client sent one worth carrying: `request_id` is
        -- akkar's and is the one a slot or a rate limit may be keyed on,
        -- `client_request_id` is the caller's and is there to join against an
        -- upstream's logs.  Naming them apart is the whole point.
        value = (provided or internal):with {
          request_id = self.id, client_request_id = self.client_request_id,
        }
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

  local ok, res = xpcall(function()
    local winner, value = with_deadline(input.timeout, function()
      return normalize(chain(app, req))
    end)
    if is_response(value) then
      -- Never into a table the application owns.  See `own`: everything
      -- below this line is a write, and a handler is allowed to return the
      -- same constant table to every request there will ever be.
      value = own(value, req)
      value.headers = value.headers or {}
      value.headers["x-request-id"] = req.id
      -- Echoed back so a client can tie the response to the trace it started.
      if req.trace then value.headers["traceparent"] = req.trace.traceparent end
    end
    if winner == "TIMEOUT" then
      internal:warn("request deadline exceeded", {
        request_id = req.id, method = req.method, path = req.path,
        timeout_s = input.timeout,
      })
      return response(503, { error = "request deadline exceeded" })
    end
    return value
  end, traced)
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

  if not ok then
    if is_response(res) then return res end
    internal:error("middleware raised", diagnosis_with(res, {
      request_id = req.id, method = req.method, path = req.path,
    }))
    return internal_error(app, res, req)
  end
  return res
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
local function read_body(stream, request_headers, limit, timeout)
  -- `:get` returns NO values when the header is absent, not nil, so it cannot
  -- be passed straight into tonumber() -- that call would receive zero
  -- arguments and raise.  Bind it first.
  local length = request_headers:get "content-length"
  local declared = length and tonumber(length)
  if declared and declared > limit then
    return nil, "declared"
  end

  -- The body read is bounded for the same reason the header read is: a client
  -- that announces a content-length and then stops holds the request open, and
  -- a read with no deadline turns that into a drain with no end.  The deadline
  -- is absolute -- computed once, before the first chunk -- so a client cannot
  -- extend it by trickling a byte just before each individual wait expires.
  local deadline = timeout and cqueues.monotime() + timeout
  local parts, total = {}, 0
  while true do
    local chunk, err = stream:get_next_chunk(deadline and deadline - cqueues.monotime())
    if chunk == nil then
      -- No chunk and no error is the end of the body.  No chunk WITH an error
      -- is a client that stopped talking, whether it timed out or vanished.
      if err == nil then break end
      return nil, "incomplete"
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
function App:stop(grace)
  if self.state ~= "RUNNING" then return self.state end
  grace = grace or self.shutdown_grace or 10

  self.state = "STOP_ACCEPTING"
  internal:info("shutdown: no longer accepting connections")
  pcall(function() self.server:pause() end)

  self.state = "DRAINING"
  local deadline = cqueues.monotime() + grace
  local warned = false
  while self.in_flight > 0 do
    if cqueues.monotime() > deadline and not warned then
      warned = true
      internal:warn("shutdown stalled; still waiting, nothing is being forced", {
        in_flight = self.in_flight, grace_s = grace,
      })
    end
    cqueues.poll(0.02)
  end
  if warned then internal:info("shutdown: drain completed") end

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
  check_setting_values(config, "app:run{}")

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

  local port = config.port or 8080
  local host = config.host or "127.0.0.1"
  local body_limit   = config.body_limit   or akkar.defaults.body_limit
  local timeout      = config.timeout      or akkar.defaults.timeout
  local read_timeout = config.read_timeout or akkar.defaults.read_timeout
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

  -- ================================================= which protocol, stated
  --
  -- lua-http speaks HTTP/2, and left unsaid it ACCEPTS it: `h2` over ALPN on
  -- TLS, and the prior-knowledge preface in cleartext.  Nothing here asked
  -- for that and nothing in akkar or docs/ mentioned it, so the version is an
  -- explicit setting rather than a capability nobody chose.  1.1 is the
  -- default because it is what the rest of this file was written against.
  local http_version = config.http_version
  if http_version == nil then http_version = akkar.defaults.http_version end

  -- ============================== the ceiling has to count REQUESTS, not
  --                                connections, and now does
  --
  -- `max_concurrent` above is handed to lua-http, which bounds CONNECTIONS.
  -- The descriptor argument it comes from is about REQUESTS: two file
  -- descriptors per request in flight, whichever connection carried it.  One
  -- request per connection is an assumption, and both HTTP versions break it.
  -- Measured here, `max_concurrent = 1`, forty requests, ONE connection:
  --
  --     http_version = 2      peak 40 in flight, 0.33 s   h2 multiplexing
  --     http_version = 1.1    peak 40 in flight, 0.32 s   h1 pipelining
  --
  -- So this was never only an HTTP/2 hole; h2 makes it the ordinary case
  -- rather than something only a pipelining client does.  lua-http will not
  -- close it on either side: the h2 connection ships
  -- `MAX_CONCURRENT_STREAMS = math.huge`, `server.listen` accepts no settings
  -- table to change that (`wrap_socket` passes `nil` verbatim), and the two
  -- places that would enforce a limit both carry the same line --
  -- `-- TODO: check MAX_CONCURRENT_STREAMS`, h2_connection.lua:195 and
  -- h2_stream.lua:149.  Neither the limit we announce nor the one a peer
  -- announces to us is applied by the library.
  --
  -- Two things follow, and both are needed.
  --
  -- ONE, THE GUARANTEE: a gate here, counting requests, because that count is
  -- the only one no peer gets a vote in.  It sits after the header read -- a
  -- half-open socket is not a request yet, see below -- and before the count,
  -- so a refusal costs one small response and no controller, no pool
  -- checkout, no handler.
  --
  -- Refusal, not parking.  A parked request is work the server has accepted
  -- and is not counting, and the drain in App:stop waits on exactly that
  -- count: it would declare itself done with requests still queued, and they
  -- would then run against the pools CLOSING has just closed.  Shedding keeps
  -- the drain honest -- a refused request was never in flight, so it neither
  -- extends a shutdown nor outlives one.
  --
  -- 503 with Retry-After, not an h2 REFUSED_STREAM.  REFUSED_STREAM is the
  -- protocol's own words for "not processed, safe to retry", and it would be
  -- the better answer to a client that then waits -- but nothing in it says
  -- to wait, and a client that ignores our advertised ceiling (lua-http's own
  -- h2 client does; the TODOs above cut both ways) retries into the same wall
  -- at line speed.  A status with a delay in it says the same thing to both
  -- protocols through one code path, and it is a number an operator can see
  -- in the access log and in the metrics middleware.
  --
  -- TWO, THE COURTESY: advertise the number, so an h2 client that honours it
  -- paces itself instead of collecting 503s.  Backpressure rather than
  -- errors, which is the same trade the descriptor ceiling makes with
  -- lua-http a few lines up.  Two honest limits on it.  It goes out on a
  -- connection's FIRST STREAM, since lua-http exposes no per-connection hook,
  -- so the opening burst on a fresh connection is already in the air when it
  -- arrives -- `curl --parallel` was shed exactly this way.  And it is a
  -- PER-CONNECTION cap where the gate is a whole-server one, so it
  -- over-promises to a client holding several connections.  Neither weakens
  -- the bound: both only decide whether a client is told politely or with a
  -- status code.  It is worth the nine bytes because the client that matters
  -- most -- a browser, one connection per origin -- is the case it fits.
  --
  -- Measured, forty requests over ONE connection, `max_concurrent = 1`:
  --
  --                          before            after
  --     http_version = 2     peak 40, 0.33 s   peak 1, 1 x 200, 39 x 503
  --     http_version = 1.1   peak 40, 0.32 s   peak 1, 1 x 200, 39 x 503
  --
  -- and the frame lands: a peer reading `MAX_CONCURRENT_STREAMS = inf` on
  -- connect reads the configured number back after one response.
  local advertised = setmetatable({}, { __mode = "k" })
  local function advertise_ceiling(stream)
    if not max_concurrent then return end
    local conn = stream.connection
    if not conn or conn.version ~= 2 or advertised[conn] then return end
    advertised[conn] = true
    -- The frame is written rather than sent through `conn:settings{}`, which
    -- blocks for the peer's ACK and steps the connection itself -- that is
    -- the server's reader loop's job, and two steppers on one connection is
    -- a race.  A SETTINGS frame is true whether or not it has been ACKed.
    -- If the write fails the gate is still the guarantee, so it is not worth
    -- failing a request over.
    pcall(function()
      conn.stream0:write_settings_frame(false,
        { MAX_CONCURRENT_STREAMS = max_concurrent }, 0, "f")
    end)
  end

  -- A flood is exactly the condition an operator has to hear about and also
  -- exactly the condition that would write a log line per refused request,
  -- so it is said at most once a second, with the running total.
  local shed_total, shed_said = 0, 0
  local function shed(stream)
    shed_total = shed_total + 1
    local now = cqueues.monotime()
    if now - shed_said >= 1 then
      shed_said = now
      internal:warn("at the concurrency ceiling; shedding", {
        max_concurrent = max_concurrent, in_flight = self.in_flight,
        shed_total = shed_total,
      })
    end
    pcall(function()
      local payload = cjson.encode {
        error = "server is at its ceiling of " .. max_concurrent ..
                " requests in flight",
      }
      local rh = headers.new()
      rh:append(":status", "503")
      rh:append("content-type", "application/json")
      rh:append("content-length", tostring(#payload))
      rh:append("retry-after", "1")
      stream:write_headers(rh, false)
      stream:write_chunk(payload, true)
    end)
    pcall(function() stream:shutdown() end)
  end

  -- STOP_ACCEPTING has to mean it at the REQUEST level, not only at accept().
  --
  -- `server:pause()` stops the listener and nothing else, so a client already
  -- holding a connection -- an h2 stream, or a 1.1 keep-alive -- can keep
  -- asking for NEW work while the drain is trying to end.  Each one extends
  -- the drain by its own duration, so an ordinary busy client can hold a
  -- shutdown open indefinitely without doing anything wrong, and a determined
  -- one can hold it open on purpose.  Refusing here is what makes the drain
  -- finite: what is left to wait for is exactly the requests that were already
  -- in flight when the signal arrived.
  --
  -- `connection: close` matters as much as the status.  Without it a
  -- keep-alive client takes the 503 and asks again on the same socket, and the
  -- refusal becomes a loop instead of an ending.
  local drained_total, drained_said = 0, 0
  local function refuse_draining(stream)
    drained_total = drained_total + 1
    local now = cqueues.monotime()
    if now - drained_said >= 1 then
      drained_said = now
      internal:info("shutting down; refusing new requests", {
        state = self.state, in_flight = self.in_flight, refused_total = drained_total,
      })
    end
    pcall(function()
      local payload = cjson.encode { error = "server is shutting down" }
      local rh = headers.new()
      rh:append(":status", "503")
      rh:append("content-type", "application/json")
      rh:append("content-length", tostring(#payload))
      rh:append("retry-after", "1")
      rh:append("connection", "close")
      stream:write_headers(rh, false)
      stream:write_chunk(payload, true)
    end)
    pcall(function() stream:shutdown() end)
  end

  local s = assert(server.listen {
    host = host, port = port, tls = config.tls or false, ctx = config.ctx,
    reuseport = config.reuseport,
    max_concurrent = max_concurrent,
    version = http_version,
    onstream = function(_, stream)
      -- A connection that has not finished its header block is not a request
      -- yet, and counting it as one is what makes a drain unable to end.  One
      -- half-open socket -- a port scanner, a slowloris, a phone that left the
      -- network mid-request -- holds `in_flight` above zero for as long as the
      -- peer's kernel keeps the socket, so every deploy stalls until something
      -- SIGKILLs the process.  That kill truncates whatever else was still
      -- being written, which is the exact corruption the never-force policy in
      -- App:stop exists to prevent: an unbounded read there defeats it here.
      --
      -- So the header read carries a deadline, and the count starts when there
      -- is something to serve.  A connection waiting between keep-alive
      -- requests is not inside this function and was never counted.
      local h = stream:get_headers(read_timeout)
      if not h then
        pcall(function() stream:shutdown() end)
        return
      end

      -- The two halves argued for above: announce the ceiling to this
      -- connection, then hold it.  Under HTTP/1.1 without pipelining the gate
      -- can never fire -- lua-http has already bounded connections to the
      -- same number, and one connection cannot be serving two requests -- so
      -- for the default configuration this is a branch and nothing else.
      -- Before the ceiling, because a server that is going away should say so
      -- rather than report how busy it is.
      if self.state ~= "RUNNING" then
        refuse_draining(stream)
        return
      end

      advertise_ceiling(stream)
      if max_concurrent and self.in_flight >= max_concurrent then
        return shed(stream)
      end
      self.in_flight = self.in_flight + 1
      local ok, err = xpcall(function()
        -- The socket's own idea of who connected. Everything else about the
        -- client's identity is something the client typed.
        local peer
        do
          local ok_peer, _, address = pcall(function() return stream:peername() end)
          if ok_peer then peer = address end
        end
        local target = h:get ":path" or "/"
        local path, qs = target:match "^([^?]*)%??(.*)$"

        local raw, oversize = read_body(stream, h, body_limit, read_timeout)
        local body, short
        if oversize == "incomplete" then
          short = response(408, { error = "request body was not delivered within " ..
                                          read_timeout .. " seconds" })
        elseif oversize then
          short = response(413, { error = "request body exceeds " ..
                                          body_limit .. " bytes" })
        elseif raw and #raw > 0 then
          local decoded, value = decode_body(raw, h:get "content-type")
          if decoded then body = value
          else short = response(value.status or 400, { error = value.message }) end
        end

        local res = handle(self, {
          method = h:get ":method", path = path, query = parse_query(qs),
          body = body, headers = h, timeout = timeout,
          capabilities = config,
          peer = peer,
          short = short, stripped = true,
        })

        local rh = headers.new()
        rh:append(":status", tostring(res.status))
        if res.headers then
          for name, value in pairs(res.headers) do rh:append(name, value) end
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
            local produced, failure = xpcall(res.stream, traced, function(chunk)
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
              internal:error("stream producer failed", diagnosis_with(failure, {
                request_id = res.headers and res.headers["x-request-id"],
                wrote_bytes = wrote,
                hint = wrote and "response already committed; connection dropped"
                              or "nothing was written yet, but the status was",
              }))
            end
          end

          if res.release then res.release() end
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
      end, traced)
      -- This is the outermost frame a request has, so it is the last place
      -- anything can be said about a failure at all.  Saying only
      -- `error_kind=string` here is what made a live outage produce five
      -- identical lines and no cause.
      if not ok then internal:error("stream failed", diagnosis(err)) end
      -- The count is given back whatever the close does.  It was only the
      -- drain's business before; now it is also the ceiling's, and a count
      -- leaked by a raising `shutdown` would shrink the ceiling permanently
      -- and stall every deploy after it.  lua-http closes the stream itself
      -- when `onstream` returns, so nothing is left open by this.
      pcall(function() stream:shutdown() end)
      self.in_flight = self.in_flight - 1
    end,
    onerror = function(_, _, op, e) internal:warn("transport", diagnosis_with(e, { op = op })) end,
  })

  assert(s:listen())
  local _, bh, bp = s:localname()
  internal:info("listening", {
    url = string.format("%s://%s:%s", config.tls and "https" or "http",
                        bh or host, tostring(bp or port)),
  })
  self.server = s

  -- The signal task, if one was installed, runs alongside the server rather
  -- than instead of it.
  if self.signal_task then
    local cq = cqueues.new()
    cq:wrap(function() s:loop() end)
    cq:wrap(self.signal_task)
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
  -- The same value check the server does.  A test client configured with a
  -- string timeout would otherwise 500 every call and say `error_kind=string`,
  -- which is the production failure reproduced in a place nobody debugs.
  check_setting_values(config, "app:test{}")

  chains(self)
  local client = {}
  local function call(method)
    return function(_, path, options)
      options = options or {}
      local p, qs = path:match "^([^?]*)%??(.*)$"
      local res = handle(self, {
        method = method, path = p,
        query = parse_query(qs),
        body = options.body,
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
      return { status = res.status, body = res.body, raw = raw,
               headers = res.headers or {} }
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
akkar.null = cjson.null

-- Exposed so the startup checks can be tested without binding a socket.
akkar.check_capabilities = check_capability_contracts
akkar.log = log
akkar.work = require "akkar.work"
akkar.metrics = require "akkar.metrics"
akkar.strict = require "akkar.strict"

akkar.Response = Response
akkar.guard = guard
return akkar
