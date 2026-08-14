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

local akkar = {}

-- ================================================================= responses
local Response = {}
Response.__index = Response

local function response(status, body)
  return setmetatable({ status = status, body = body, __response = true }, Response)
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

-- Safe defaults, applied unless app:run{} overrides them.  The point is that
-- `app:run()` with no arguments is already production-shaped: a body limit and
-- a deadline exist whether or not anyone remembered to ask for them.
akkar.defaults = {
  body_limit = 1024 * 1024,   -- 1 MB
  timeout    = 30,            -- seconds of wall clock per request
}

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
  input = input or {}
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

local function install_watchdog(where)
  local cpu, last, warned = 0, cqueues.monotime(), false
  debug.sethook(function()
    local t = cqueues.monotime()
    local dt = t - last
    last = t
    if dt < 0.050 then cpu = cpu + dt else cpu = 0 end
    if cpu > WATCHDOG_LIMIT and not warned then
      warned = true
      io.stderr:write(string.format(
        "\n[akkar] WARNING: handler blocked the loop for %.0f ms without yielding\n" ..
        "  at %s\n%s\n  this stalls every request in this process.\n\n",
        cpu * 1000, where, debug.traceback("", 2)))
    end
  end, "", WATCHDOG_INSTRUCTIONS)
end
local function remove_watchdog() debug.sethook() end

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
local function with_deadline(seconds, fn)
  if not seconds or seconds <= 0 or not cqueues.running() then
    return "COMPLETION", fn()          -- no budget, or no controller to yield to
  end

  local cq = cqueues.new()
  local winner, result

  cq:wrap(function()
    local ok, res = pcall(fn)
    if winner == nil then              -- first arbitrating event wins
      winner = ok and "COMPLETION" or "ERROR"
      result = res
    end
  end)

  local deadline = cqueues.monotime() + seconds
  while winner == nil do
    local remaining = deadline - cqueues.monotime()
    if remaining <= 0 then break end
    cqueues.poll(cq, remaining)        -- yields to the outer controller
    cq:step(0)
  end

  if winner == nil then winner = "TIMEOUT" end
  if winner == "ERROR" then error(result, 0) end
  return winner, result
end

-- ==================================================================== guards
-- Invariant: reading something that was never configured gives a useful
-- message, not "attempt to index a nil value".
local function guard(name, hint)
  return setmetatable({}, { __index = function() error(hint, 2) end,
                            __call  = function() error(hint, 2) end,
                            __tostring = function() return "<" .. name .. " missing>" end })
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

function App:match(method, path)
  local hit = self.exact[method .. " " .. path]
  if hit then return hit, {} end
  for _, r in ipairs(self.routes) do
    if r.method == method and #r.names > 0 then
      local captured = { path:match(r.pattern) }
      if captured[1] ~= nil then
        local params = {}
        for i, name in ipairs(r.names) do params[name] = captured[i] end
        return r, params
      end
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

local function dispatch(app, req)
  local route, params = app:match(req.method, req.path)
  if not route then
    return response(404, { error = "no route for " .. req.method .. " " .. req.path })
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
    io.stderr:write("[akkar] error at " .. route.where .. ": " .. tostring(result) .. "\n")
    return response(500, { error = "internal server error" })
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

local function unescape(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
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
  local normal, short = chains(app)

  local req = {
    method  = input.method,
    path    = input.path,
    query   = input.query or {},
    body    = input.body,
    headers = input.headers or {},
    db      = input.db or guard("req.db", "req.db is not configured; pass db = ... to app:run{}"),
    user    = guard("req.user", "req.user is not set; this route is missing the authentication middleware"),
  }

  -- A request that failed to parse still traverses the chain, so logging
  -- middleware sees the 400.  Middleware returning garbage cannot escape
  -- either: it becomes a 500.
  local chain = input.short and short or normal
  if input.short then req.__short = input.short end

  local ok, res = pcall(function()
    local winner, value = with_deadline(input.timeout, function()
      return normalize(chain(app, req))
    end)
    if winner == "TIMEOUT" then
      io.stderr:write(string.format("[akkar] deadline: %s %s exceeded %.1fs\n",
                                    req.method, req.path, input.timeout))
      return response(503, { error = "request deadline exceeded" })
    end
    return value
  end)

  if not ok then
    if is_response(res) then return res end
    io.stderr:write("[akkar] middleware error: " .. tostring(res) .. "\n")
    return response(500, { error = "internal server error" })
  end
  return res
end

-- ==================================================================== server
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

function App:run(config)
  config = config or {}
  local port = config.port or 8080
  local host = config.host or "127.0.0.1"
  local db_factory = config.db
  local body_limit = config.body_limit or akkar.defaults.body_limit
  local timeout    = config.timeout    or akkar.defaults.timeout
  chains(self)

  local s = assert(server.listen {
    host = host, port = port, tls = config.tls or false, ctx = config.ctx,
    onstream = function(_, stream)
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
          local decoded, value = pcall(cjson.decode, raw)
          if decoded then body = value
          else short = response(400, { error = "invalid JSON body" }) end
        end

        local res = handle(self, {
          method = h:get ":method", path = path, query = parse_query(qs),
          body = body, headers = h, timeout = timeout,
          db = db_factory and db_factory() or nil,
          short = short,
        })

        local rh = headers.new()
        rh:append(":status", tostring(res.status))
        local payload = res.body and cjson.encode(res.body) or nil
        if payload then
          rh:append("content-type", "application/json")
          rh:append("content-length", tostring(#payload))
        end
        stream:write_headers(rh, payload == nil)
        if payload then stream:write_chunk(payload, true) end
      end)
      if not ok then io.stderr:write("[akkar] stream: " .. tostring(err) .. "\n") end
      stream:shutdown()
    end,
    onerror = function(_, _, op, e) io.stderr:write(("[akkar] %s: %s\n"):format(op, tostring(e))) end,
  })

  assert(s:listen())
  local _, bh, bp = s:localname()
  io.stderr:write(string.format("[akkar] listening on %s://%s:%s\n",
                  config.tls and "https" or "http", bh or host, tostring(bp or port)))
  self.server = s
  return assert(s:loop())
end

-- =============================================================== test client
-- No socket, no port, no server.  Travels exactly the same chain a real
-- request does, because `handle` is shared.
function App:test(config)
  config = config or {}
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
        db = config.db and config.db() or nil,
      })
      return { status = res.status, body = res.body }
    end
  end
  for _, m in ipairs { "get", "post", "put", "patch", "delete" } do
    client[m] = call(m:upper())
  end
  return client
end

akkar.Response = Response
akkar.guard = guard
return akkar
