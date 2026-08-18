--[[
akkar.config — typed configuration, and secrets that cannot be printed.

## The two jobs

Reading configuration is the boring half: a schema declares a type, a default
and whether a value is required, values arrive from a table and from the
environment, and a missing required value fails at startup naming itself --
the way a duplicate route already fails, and for the same reason. A server
that boots without its database URL and discovers it on the first request has
turned a startup error into an incident.

The interesting half is the second one.

## Secrets, redacted BY CONSTRUCTION

"Remember not to log the password" is not a property, it is a hope, and it
loses to the first `log:info("config", config)` somebody writes while
debugging something else. The failure is silent and permanent: the secret is
in a log aggregator, in a backup of that aggregator, and in whatever ticket
somebody pasted the line into.

So a value declared `secret = true` is not stored anywhere a printer can
reach it. The config table holds a **wrapper with nothing in it**; the value
lives in a private table keyed by that wrapper. Everything that prints a Lua
value walks the table it was given, and there is nothing in this one to walk.

What that gives, all of it verified in `spec/config_spec.lua` rather than
asserted here:

    tostring(config.db.password)          -> "[redacted]"      (__tostring)
    string.format("%s", ...)              -> "[redacted]"      (__tostring)
    "url=" .. config.db.password          -> "url=[redacted]"  (__concat)
    tostring(config)                      -> the whole config, secrets masked
    akkar.json.encode(config)             -> the secret is ABSENT
    log:info("boot", { config = config }) -> the secret is ABSENT
    config.db.password:reveal()           -> the real value, on purpose

**One honest limit, stated because the difference matters.** `tostring` and
`..` are metamethods, so those two print `[redacted]`. `cjson` consults no
metamethod at all -- verified: an empty table carrying `__tostring` encodes
as `{}`, not as its `__tostring` -- so nothing can make the serialiser emit
the word `[redacted]` for a wrapper. What it emits instead is `{}`, because
the wrapper genuinely contains nothing. That is a weaker display and an
identical guarantee: the secret is not in the output. Where the word itself is
wanted in a log line, `config:redacted()` returns a plain table with
`"[redacted]"` strings in place of the wrappers.

`debug.getmetatable` still reaches the metatable, and `debug.getupvalue` still
reaches the private store. Nothing in Lua defends against the debug library
and this does not pretend to; it defends against the ordinary act of printing
a table, which is how secrets actually escape.

## Using it

    local config = require("akkar.config").load {
      schema = {
        port = { type = "number", default = 8080 },
        timeout = { type = "duration", default = "30s" },
        database = {
          url      = { type = "string", required = true },
          password = { type = "string", required = true, secret = true },
        },
      },
      values = { port = 3000 },              -- from a file, say
    }

    config.port                  --> 3000
    config.timeout               --> 30      (seconds, always a number)
    config.database.url          --> from DATABASE_URL
    config.database.password     --> a secret; :reveal() for the value

Precedence is **environment, then table, then default**, because the table is
the thing checked into the repository and the environment is the thing the
deploy sets. A deploy that cannot override a checked-in value is a deploy that
needs a commit to change a password.

The environment variable name is derived from the path -- `database.url`
reads `DATABASE_URL` -- and an explicit `env = "PGURL"` wins over the
derivation. `env = false` means this value never comes from the environment.
]]

local bitwise = require "akkar.bitwise"
local M = {}

local REDACTED = "[redacted]"

-- ==================================================================== secrets
--
-- Weak-keyed, so a config that goes out of scope takes its secrets with it
-- rather than pinning them in a table that lives as long as the process.
local values_of = setmetatable({}, { __mode = "k" })

local function is_secret(value)
  return type(value) == "table" and values_of[value] ~= nil
end

local function show(value)
  if is_secret(value) then return REDACTED end
  return tostring(value)
end

local Secret = {}

--- The real value, and the only way to get it.
---
--- A method rather than a field, so that reading the secret is a thing
--- somebody wrote on purpose and a reviewer can grep for.
function Secret:reveal()
  return values_of[self]
end

local SECRET_META = {
  __index    = Secret,
  __tostring = function() return REDACTED end,
  __concat   = function(a, b) return show(a) .. show(b) end,
  __newindex = function()
    error("akkar.config: a secret is immutable", 2)
  end,
  -- Blocks `getmetatable(secret).__index` fishing and blocks `setmetatable`
  -- replacing `__tostring` with something that prints.  The debug library
  -- gets past this; a stray `print` does not, and that is the threat.
  __metatable = "akkar.config: secret",
}

local function wrap_secret(value)
  local box = setmetatable({}, SECRET_META)
  values_of[box] = value
  return box
end

-- ====================================================================== types
local DURATION_UNITS = { ms = 0.001, s = 1, m = 60, h = 3600, d = 86400 }

--- Durations are ALWAYS seconds by the time anything reads them.
---
--- The alternative -- keeping "30s" as a string and parsing at the call site
--- -- is how one place ends up treating it as milliseconds. A configuration
--- type exists so that the ambiguity is resolved once, at boot, loudly.
local function parse_duration(text, where)
  if type(text) == "number" then return text end
  local number, unit = tostring(text):match "^%s*(%d+%.?%d*)%s*(%a*)%s*$"
  if not number then
    error(("akkar.config: %s is not a duration: %q -- write 500ms, 30s, 5m, 2h or 1d")
          :format(where, tostring(text)), 0)
  end
  if unit == "" then return tonumber(number) end       -- a bare number is seconds
  local scale = DURATION_UNITS[unit]
  if not scale then
    error(("akkar.config: %s has unknown duration unit %q -- use ms, s, m, h or d")
          :format(where, unit), 0)
  end
  return tonumber(number) * scale
end

local TRUE  = { ["true"] = true, ["1"] = true, yes = true, on = true }
local FALSE = { ["false"] = true, ["0"] = true, no = true, off = true }

local function parse_boolean(raw, where)
  if type(raw) == "boolean" then return raw end
  local text = tostring(raw):lower()
  if TRUE[text] then return true end
  if FALSE[text] then return false end
  error(("akkar.config: %s is not a boolean: %q -- use true/false, 1/0, yes/no or on/off")
        :format(where, tostring(raw)), 0)
end

local TYPES = {
  string = function(raw, where)
    if type(raw) == "string" then return raw end
    -- Coercing a number to a string here would make `port = 8080` silently
    -- satisfy a `type = "string"` field, and the mismatch would surface
    -- somewhere that concatenates it.  Saying so at boot is cheaper.
    error(("akkar.config: %s must be a string, got %s")
          :format(where, type(raw)), 0)
  end,
  number = function(raw, where)
    if type(raw) == "number" then return raw end
    local n = type(raw) == "string" and tonumber(raw) or nil
    if n then return n end
    error(("akkar.config: %s must be a number, got %q")
          :format(where, tostring(raw)), 0)
  end,
  boolean = parse_boolean,
  duration = parse_duration,
}

-- ===================================================================== typos
-- Levenshtein, the same trick `check_config` in init.lua plays on an unknown
-- route option.  DUPLICATED rather than shared because `nearest` there is a
-- local in a 2,200-line file with no export; unifying them means editing
-- init.lua, which this change is not allowed to do.
local function nearest(word, candidates)
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

-- =============================================================== the container
--
-- Declared keys live OUTSIDE the config tables, in a weak side table, for the
-- same reason the secrets do: anything stored in the table itself is
-- something `cjson.encode` and a logger's deep-walk will find and print.  A
-- config is meant to serialise as its own values and nothing else.
local declared_of = setmetatable({}, { __mode = "k" })

local Config = {}

local function render(node, prefix, lines)
  local keys = {}
  for key in pairs(declared_of[node] or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = rawget(node, key)
    if declared_of[value] then
      render(value, prefix .. key .. ".", lines)
    elseif value ~= nil then
      lines[#lines + 1] = "  " .. prefix .. key .. " = " .. show(value)
    else
      lines[#lines + 1] = "  " .. prefix .. key .. " = <unset>"
    end
  end
  return lines
end

--- A plain table with `"[redacted]"` in place of every secret.
---
--- This is the value to hand a logger or a serialiser when the WORD is
--- wanted. Encoding the config itself is already safe -- the wrapper contains
--- nothing -- it just shows `{}` rather than saying why.
function Config:redacted()
  local out = {}
  for key in pairs(declared_of[self] or {}) do
    local value = rawget(self, key)
    if declared_of[value] then
      out[key] = Config.redacted(value)
    elseif is_secret(value) then
      out[key] = REDACTED
    else
      out[key] = value
    end
  end
  return out
end

local function index(node, key)
  local declared = declared_of[node]
  -- A declared key that was never set reads as nil, not as an error: it is a
  -- legitimate absence.  An UNdeclared key is a typo, and returning nil for a
  -- typo is how `config.databse.url` becomes a nil index three frames away.
  if declared and declared[key] then return nil end
  if Config[key] then return Config[key] end
  local suggestion = declared and nearest(tostring(key), declared)
  error(("akkar.config: no such setting '%s'%s"):format(
          tostring(key),
          suggestion and ("; did you mean '" .. suggestion .. "'?") or ""), 2)
end

--- WHAT THIS CATCHES, AND WHAT IT DOES NOT.
---
--- `__newindex` fires only for a key that is ABSENT from the table, so this
--- catches `config.prot = 8080` -- a typo creating a setting nothing reads,
--- which is the accident worth catching -- and does NOT catch
--- `config.port = 8080` overwriting a value that is already there. Lua offers
--- no write barrier on a present key.
---
--- Making the whole config a proxy over a private store WOULD catch it, and
--- was rejected: the config table would then be empty, and
--- `akkar.json.encode(config)` -- which is how a boot line records what this
--- process actually came up with -- would emit `{}`. A config that cannot be
--- serialised to say what it is loses more than an unenforced immutability
--- claim buys. Stated here rather than asserted as a property the tests would
--- have to pretend to check.
local function newindex(_, key)
  error(("akkar.config: configuration is read-only; '%s' is not a setting " ..
         "and cannot be added after load"):format(tostring(key)), 2)
end

local function seal(table_, declared)
  declared_of[table_] = declared
  return setmetatable(table_, {
    __index    = index,
    __newindex = newindex,
    __tostring = function(self)
      return table.concat(render(self, "", { "akkar.config" }), "\n")
    end,
  })
end

-- ====================================================================== load
local function is_leaf(spec)
  return type(spec) == "table" and type(spec.type) == "string"
end

local LEAF_KEYS = { type = true, default = true, required = true,
                    secret = true, env = true }

local function env_name(path)
  return (path:gsub("%.", "_"):upper())
end

local function resolve(schema, values, env, path, missing, out)
  if values ~= nil and type(values) ~= "table" then
    error(("akkar.config: %s is a section, so its value must be a table, got %s")
          :format(path == "" and "the config" or path, type(values)), 0)
  end
  values = values or {}

  local declared = {}
  for key in pairs(schema) do declared[key] = true end

  -- A typo in the values table is caught here rather than ignored.  A key
  -- nothing reads is indistinguishable from a key nothing honours, and the
  -- second one is a production incident: `{ timout = 1 }` leaves the real
  -- timeout at its default and looks exactly like it worked.
  for key in pairs(values) do
    if not declared[key] then
      local suggestion = nearest(tostring(key), declared)
      error(("akkar.config: unknown setting '%s%s'%s"):format(
              path == "" and "" or (path .. "."), tostring(key),
              suggestion and ("; did you mean '" .. suggestion .. "'?") or ""), 0)
    end
  end

  for key, spec in pairs(schema) do
    local child = path == "" and key or (path .. "." .. key)

    if is_leaf(spec) then
      for option in pairs(spec) do
        if not LEAF_KEYS[option] then
          error(("akkar.config: %s declares unknown option '%s'; use type, " ..
                 "default, required, secret or env"):format(child, tostring(option)), 0)
        end
      end
      local coerce = TYPES[spec.type]
      if not coerce then
        error(("akkar.config: %s has unknown type %q -- use string, number, " ..
               "boolean or duration"):format(child, tostring(spec.type)), 0)
      end

      local variable = spec.env
      if variable == nil then variable = env_name(child) end

      -- `source` names BOTH the setting and where its value came from.  A
      -- message saying only `PGPORT must be a number` leaves the reader
      -- grepping for which setting reads PGPORT; one saying only
      -- `database.port` leaves them editing the file while the environment
      -- keeps overriding it.
      local raw, source
      if variable and env[variable] ~= nil then
        raw, source = env[variable], child .. " (from " .. variable .. ")"
      elseif values[key] ~= nil then
        raw, source = values[key], child
      elseif spec.default ~= nil then
        raw, source = spec.default, child .. " (default)"
      end

      if raw == nil then
        if spec.required then
          missing[#missing + 1] = { path = child, env = variable or false }
        end
      else
        local value = coerce(raw, source)
        out[key] = spec.secret and wrap_secret(value) or value
      end
    else
      if type(spec) ~= "table" then
        error(("akkar.config: %s must be a table -- either a section or a " ..
               "declaration with a `type`"):format(child), 0)
      end
      -- `resolve` seals what it returns, so the section arrives with its own
      -- declared-key set and its own `__tostring` already installed.
      out[key] = resolve(spec, values[key], env, child, missing, {})
    end
  end

  seal(out, declared)
  return out
end

local LOAD_OPTIONS = { schema = true, values = true, env = true }

--- Reads the configuration, or refuses to start.
---
--- EVERY missing required value is reported, not the first one.  Failing on
--- one at a time turns a first deploy into a sequence of restarts, each
--- finding the next thing nobody was told about.
function M.load(options)
  options = options or {}
  for key in pairs(options) do
    if not LOAD_OPTIONS[key] then
      error("akkar.config: unknown option '" .. tostring(key) ..
            "'; use schema, values or env", 2)
    end
  end
  if type(options.schema) ~= "table" then
    error("akkar.config: load needs a schema", 2)
  end

  local env = options.env
  if env == nil then
    env = setmetatable({}, { __index = function(_, name) return os.getenv(name) end })
  end

  local missing = {}
  local ok, result = pcall(resolve, options.schema, options.values, env, "",
                           missing, {})
  -- Raised with level 0 inside, re-raised with level 2 here, so the traceback
  -- points at the caller's `config.load` and not at a line in this file.
  if not ok then error(result, 2) end

  if #missing > 0 then
    local lines = { ("akkar.config: %d required setting%s missing"):format(
                      #missing, #missing == 1 and " is" or "s are") }
    table.sort(missing, function(a, b) return a.path < b.path end)
    for _, entry in ipairs(missing) do
      lines[#lines + 1] = entry.env
        and ("  %s -- set %s in the environment, or values.%s")
            :format(entry.path, entry.env, entry.path)
        or  ("  %s -- set values.%s"):format(entry.path, entry.path)
    end
    error(table.concat(lines, "\n"), 2)
  end

  return result
end

M.REDACTED = REDACTED

--- Whether a value is a secret wrapper.  For a logger or a serialiser that
--- wants to say `[redacted]` rather than emit an empty object.
M.is_secret = is_secret

--- Wraps a value that did not come from a schema -- a token minted at
--- runtime, say -- in the same non-printable box.
M.secret = wrap_secret

return M
