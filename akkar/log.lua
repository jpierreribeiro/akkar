--[[
akkar.log — structured logging.

Two formats, because the two audiences want opposite things.  A machine
grepping production wants one JSON object per line.  A person watching a
terminal wants to read it without a parser.  Making that a choice rather than
a compromise is cheaper than either audience losing.

The part that earns its keep is `:with`.  A logger bound to a request id is
handed to the handler as `req.log`, so correlation is a property of the
logger rather than something every call site has to remember to pass.  A rule
nobody has to follow is worth more than a rule everybody has to.

Output goes to stderr by default, so nothing needs configuring to work.
]]

local cjson = require "cjson"

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }

local Logger = {}
Logger.__index = Logger

-- Values that survive a JSON round-trip.  Anything else is stringified rather
-- than silently dropped, because a log line that quietly loses a field is
-- worse than an ugly one.
local function safe(value)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then return value end
  if kind == "nil" then return nil end
  if kind == "table" then
    local out = {}
    for k, v in pairs(value) do out[tostring(k)] = safe(v) end
    return out
  end
  return tostring(value)
end

local function merge(into, from)
  if not from then return into end
  for key, value in pairs(from) do into[key] = safe(value) end
  return into
end

-- logfmt separates fields with a space, so a value that CONTAINS one ends its
-- field and starts another. Written raw, any value reachable from a request --
-- a name, a search term, a user agent -- forged fields: an email of
-- `a@b.test role=admin tenant=other` arrived at the log store as three fields,
-- two of them invented by the caller. A newline forged a whole line, which is
-- worse: it invents an event that never happened, at whatever level it likes.
--
-- Text is the DEFAULT format, so this was on by default. Values that are
-- plainly safe are still written bare, because the point of logfmt is that a
-- person can read it.
local SAFE = "^[%w_%-%.:/@+]+$"

local function escape(text)
  return (text:gsub("[\\\"]", "\\%0")
              :gsub("%c", function(char)
                if char == "\n" then return "\\n" end
                if char == "\r" then return "\\r" end
                if char == "\t" then return "\\t" end
                return string.format("\\x%02x", char:byte())
              end))
end

local function field_value(value)
  local text = type(value) == "table" and cjson.encode(value) or tostring(value)
  if text:match(SAFE) then return text end
  return '"' .. escape(text) .. '"'
end

-- A key with a space or an `=` in it forges just as well as a value does, and
-- keys arrive from `bind` and from caller-supplied field tables.
local function field_key(key)
  key = tostring(key)
  if key:match(SAFE) then return key end
  return (key:gsub("[^%w_%-%.:/@+]", "_"))
end

local function format_text(entry)
  -- The message is positional rather than quoted, so it cannot carry its own
  -- `key=value` ambiguity away -- but a newline in it would still end the
  -- line, so control characters go.
  local parts = { string.format("%-5s %s", entry.level:upper(),
                                escape(tostring(entry.message))) }
  local keys = {}
  for key in pairs(entry) do
    if key ~= "level" and key ~= "message" and key ~= "time" then keys[#keys + 1] = key end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = field_key(key) .. "=" .. field_value(entry[key])
  end
  return table.concat(parts, " ")
end

function Logger:log(level, message, fields)
  if LEVELS[level] < LEVELS[self.level] then return end

  local entry = { level = level, message = message, time = os.time() }
  merge(entry, self.bound)
  merge(entry, fields)

  local line = self.format == "json" and cjson.encode(entry) or format_text(entry)
  self.sink(line .. "\n")
end

for level in pairs(LEVELS) do
  Logger[level] = function(self, message, fields) self:log(level, message, fields) end
end

--- Returns a logger carrying `fields` on every line it writes.
--- This is what makes `req.log` correlate without the caller doing anything.
function Logger:with(fields)
  local bound = {}
  merge(bound, self.bound)
  merge(bound, fields)
  return setmetatable({
    level = self.level, format = self.format, sink = self.sink, bound = bound,
  }, Logger)
end

local M = {}

function M.new(options)
  options = options or {}
  local level = options.level or "info"
  if not LEVELS[level] then
    error("akkar.log: unknown level '" .. tostring(level) ..
          "'; use debug, info, warn or error", 2)
  end
  return setmetatable({
    level  = level,
    format = options.format or "text",
    sink   = options.sink or function(line) io.stderr:write(line) end,
    bound  = {},
  }, Logger)
end

M.Logger = Logger
M.LEVELS = LEVELS
return M
