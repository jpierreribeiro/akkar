-- Private configuration vocabulary and validation; no request-path state.
local bitwise = require "akkar.bitwise"
local ipv4_to_int = require("akkar.internal.http_input").ipv4_to_int

local SETTINGS = {
  host = true, port = true, tls = true, ctx = true,
  body_limit = true, header_limit = true, header_count_limit = true,
  json_depth_limit = true, timeout = true, shutdown_grace = true,
  check_capabilities = true, reuseport = true, strict = true,
  max_concurrent = true, trusted_proxies = true, read_timeout = true,
  write_timeout = true,
  socket_buffer = true, gc = true,
  cpu_limit = true, h2c = true, websocket_idle_timeout = true,
  websocket_max_message = true, websocket_max_connections = true,
  h2_max_concurrent_streams = true,
}

-- Route options, checked for the same reason: `app:post("/x", { bdy = ... })`
-- silently declaring no schema at all is worse than an error, because the
-- route then accepts anything while looking validated.
local ROUTE_OPTIONS = {
  params = true, query = true, body = true, response = true, before = true,
  -- `response` describes the success body whatever its status. `responses`
  -- names one schema per status, for the route that answers 201 with a shape
  -- its 200 does not have -- enforced AND documented from the same table.
  responses = true,
  -- Documentation the schemas cannot carry, because it is not validation:
  -- a summary, a security requirement, a header the client must send.
  openapi = true,
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
  if best_distance <= math.max(2, bitwise.idiv(#word, 3)) then return best end
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

local function flag(value)
  if type(value) ~= "boolean" then return "true or false" end
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
  header_limit = function(value)
    if math.type(value) ~= "integer" or value < 1 then
      return "a positive whole number of bytes"
    end
  end,
  header_count_limit = function(value)
    if math.type(value) ~= "integer" or value < 1 then
      return "a positive whole number of fields"
    end
  end,
  json_depth_limit = function(value)
    if math.type(value) ~= "integer" or value < 1 then
      return "a positive whole nesting depth"
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
  write_timeout  = seconds(false),
  shutdown_grace = seconds(true),
  max_concurrent = function(value)
    if math.type(value) ~= "integer" or value < 1 then
      return "an integer of at least 1 (it is a ceiling on connections)"
    end
  end,
  reuseport          = flag,
  strict             = flag,
  check_capabilities = flag,
  -- Cleartext h2, which costs a preface sniff on every connection including
  -- the h1 ones -- so it is a decision, and a decision made with a string is
  -- not one.
  h2c                = flag,
  -- Not `flag`: this tree answers `tls = { certificate = ..., key = ... }`
  -- itself, so a table is the ordinary way to serve HTTPS.  What is inside it
  -- is checked where the context is built, which is where the failure can say
  -- which PEM did not parse.
  tls = function(value)
    if type(value) ~= "boolean" and type(value) ~= "table" then
      return "true, false, or { certificate = ..., key = ... }"
    end
  end,
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
--- Exported so a caller that must not bind a port -- `akkar.doctor`, a
--- deployment preflight -- can report the same finding without booting.
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

return { settings = SETTINGS, route_options = ROUTE_OPTIONS,
         check_names = check_config, check_values = check_setting_values }
