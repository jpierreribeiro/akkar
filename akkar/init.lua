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
  body_limit = true, timeout = true, shutdown_grace = true,
  check_capabilities = true, reuseport = true, strict = true,
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
  local cleaned, failures, any = {}, {}, false
  for field, rule in pairs(schema) do
    local expanded = expand(rule)
    local value = input[field]
    if value == nil and expanded.default ~= nil then value = expanded.default end
    local got, err = check_one(value, expanded, coerce)
    if err then failures[field] = err any = true
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
    local ok, res = pcall(fn)
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

function App:use(fn)
  self.middleware[#self.middleware + 1] = fn
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
local function apply_response_schema(res, schema, where)
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
    return response(500, { error = "internal server error" })
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
  local run = function() return route.handler(req) end
  if opts and opts.before then
    for i = #opts.before, 1, -1 do
      local mw, nxt = opts.before[i], run
      run = function() return mw(req, function() return nxt() end) end
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
    internal:error("handler raised", {
      request_id = req.id, at = route.where, detail = tostring(result),
    })
    return response(500, { error = "internal server error" })
  end

  if opts and opts.response then
    result = apply_response_schema(result, opts.response, route.where)
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
-- A random prefix chosen once per process, then a counter.  Two RNG calls per
-- request bought nothing: within a process a counter cannot collide at all,
-- which is strictly better than hoping two 48-bit draws differ, and across
-- processes the prefix separates them.
local ID_PREFIX = string.format("%08x", math.random(0, 0xffffffff))
local id_counter = 0

local function request_id(headers)
  local given = headers and headers["x-request-id"]
  if given and #given > 0 and #given <= 200 then return given end
  id_counter = id_counter + 1
  return ID_PREFIX .. string.format("%06x", id_counter & 0xffffff)
end

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
    id      = request_id(request_headers),
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
    local winner, value = with_deadline(input.timeout, function()
      return normalize(chain(app, req))
    end)
    if is_response(value) then
      value.headers = value.headers or {}
      value.headers["x-request-id"] = req.id
    end
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
  if ok and is_response(res) and res.stream then
    res.release = release_all
  else
    release_all()
  end

  if not ok then
    if is_response(res) then return res end
    internal:error("middleware raised", { request_id = req.id, detail = tostring(res) })
    return response(500, { error = "internal server error" })
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
local function read_body(stream, request_headers, limit)
  -- `:get` returns NO values when the header is absent, not nil, so it cannot
  -- be passed straight into tonumber() -- that call would receive zero
  -- arguments and raise.  Bind it first.
  local length = request_headers:get "content-length"
  local declared = length and tonumber(length)
  if declared and declared > limit then
    return nil, "declared"
  end

  local parts, total = {}, 0
  for chunk in stream:each_chunk() do
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
  local s = assert(server.listen {
    host = host, port = port, tls = config.tls or false, ctx = config.ctx,
    reuseport = config.reuseport,
    onstream = function(_, stream)
      self.in_flight = self.in_flight + 1
      local ok, err = pcall(function()
        local h = assert(stream:get_headers())
        local target = h:get ":path" or "/"
        local path, qs = target:match "^([^?]*)%??(.*)$"

        local raw, oversize = read_body(stream, h, body_limit)
        local body, short
        if oversize then
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
                request_id = res.headers and res.headers["x-request-id"],
                wrote_bytes = wrote,
                detail = tostring(failure),
                hint = wrote and "response already committed; connection dropped"
                              or "nothing was written yet, but the status was",
              })
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
      end)
      if not ok then internal:error("stream failed", { detail = tostring(err) }) end
      stream:shutdown()
      self.in_flight = self.in_flight - 1
    end,
    onerror = function(_, _, op, e) internal:warn("transport", { op = op, detail = tostring(e) }) end,
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

  local allowed = { timeout = true, log = true }
  for k in pairs(CAPABILITIES) do allowed[k] = true end
  check_config(config, allowed, "app:test{}")

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
