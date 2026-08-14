--[[
akkar.db — the Postgres adapter.

This file exists to enforce the framework's one architectural rule:

    a handler never calls require "pgmoon".

It receives `req.db` and calls `:one`, `:many`, `:exec`, `:transaction`.
Swapping pgmoon for async libpq inside a C host rewrites this file and
nothing else.

Known limitations, deliberate for now:
  - one connection per request, no pool;
  - `$1` is interpolated through pgmoon's escape_literal rather than sent
    over the extended protocol.  Safe against injection, but real prepared
    statements are the right answer.
]]

local pgmoon = require "pgmoon"

local Db = {}
Db.__index = Db

local function bind(pg, sql, ...)
  local n = select("#", ...)
  if n == 0 then return sql end
  local args = { ... }
  -- Substitute $n down from the highest, so $10 does not become $1 then "0".
  for i = n, 1, -1 do
    local value = args[i]
    local literal
    if value == nil then literal = "NULL"
    else literal = pg:escape_literal(value) end
    sql = sql:gsub("%$" .. i, (literal:gsub("%%", "%%%%")))
  end
  return sql
end

-- pgmoon marks NULL with a sentinel; cjson needs nil.
local function clean(row, null)
  if not row then return nil end
  for k, val in pairs(row) do
    if null ~= nil and val == null then row[k] = nil end
  end
  return row
end

function Db:query(sql, ...)
  local res, err = self.pg:query(bind(self.pg, sql, ...))
  if not res then error("db: " .. tostring(err), 0) end
  return res
end

function Db:many(sql, ...)
  local res = self:query(sql, ...)
  if type(res) ~= "table" then return {} end
  for i = 1, #res do clean(res[i], self.null) end
  return res
end

function Db:one(sql, ...)
  local rows = self:many(sql, ...)
  return rows[1]
end

function Db:exec(sql, ...)
  return self:query(sql, ...)
end

-- Closure-scoped transaction: commit at the end, rollback on any error.
-- There is no path where a BEGIN stays open because someone forgot.
function Db:transaction(fn)
  self:query "begin"
  local ok, result = pcall(fn, self)
  if not ok then
    pcall(function() self:query "rollback" end)
    error(result, 0)          -- preserves response-as-error
  end
  self:query "commit"
  return result
end

function Db:close()
  if self.pg then self.pg:disconnect() end
end

local M = {}

-- Returns a factory: each request calls it and gets its own connection.
function M.connect(config)
  return function()
    local pg = pgmoon.new {
      host = config.host or "127.0.0.1",
      port = config.port or 5432,
      database = config.database,
      user = config.user,
      password = config.password,
      socket_type = "cqueues",
    }
    local ok, err = pg:connect()
    if not ok then error("db: could not connect: " .. tostring(err), 0) end
    return setmetatable({ pg = pg, null = pgmoon.null }, Db)
  end
end

return M
