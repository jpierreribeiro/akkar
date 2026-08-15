--[[
akkar.db — the Postgres adapter.

This file exists to enforce the framework's one architectural rule:

    a handler never calls require "pgmoon".

It receives `req.db` and calls `:one`, `:many`, `:exec`, `:transaction`.
Swapping pgmoon for async libpq inside a C host rewrites this file and
nothing else.

Parameters go over the Postgres extended protocol -- pgmoon sends Parse, Bind,
Describe and Execute with typed binding -- so a value is never spliced into SQL
text.  This file used to interpolate `$1` through escape_literal on top of a
library that already did it properly; deleting that was the fix.

The statement is UNNAMED, meaning the parse happens on every call and there is
no server-side plan caching between calls.  That is correct, safe binding; it
is not the same thing as a named prepared statement.
]]

local pgmoon = require "pgmoon"
local Pool   = require "akkar.pool"

local Db = {}
Db.__index = Db

-- pgmoon marks NULL with a sentinel; cjson needs nil.
local function clean(row, null)
  if not row then return nil end
  for k, val in pairs(row) do
    if null ~= nil and val == null then row[k] = nil end
  end
  return row
end

function Db:query(sql, ...)
  local res, err = self.pg:query(sql, ...)
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
  self.in_transaction = true
  local ok, result = pcall(fn, self)
  if not ok then
    local rolled = pcall(function() self:query "rollback" end)
    -- A connection whose rollback failed is in an unknown state.  Marking it
    -- keeps the pool from handing that state to the next request.
    self.in_transaction = not rolled
    self.broken = not rolled
    error(result, 0)          -- preserves response-as-error
  end
  self:query "commit"
  self.in_transaction = false
  return result
end

function Db:close()
  if self.pg then self.pg:disconnect() end
  self.pg = nil
end

-- Returns the connection to the pool it came from.  A connection that is
-- still inside a transaction, or whose rollback failed, is discarded rather
-- than reused: the next request must not inherit an open BEGIN.
function Db:release()
  if self.pool then self.pool:put(self) else self:close() end
end

local M = {}

-- ==================================================================== connect
-- Returns a factory: akkar calls it once per request.  `pool_size = 0` opts
-- out and opens a connection per request, which is what the substrate proof
-- measured and what a one-off script wants.
function M.connect(config)
  local function open()
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

  local size = config.pool_size == nil and 10 or config.pool_size
  if size <= 0 then return open end

  -- What "fit for reuse" means here, and only here: a connection still inside
  -- a transaction, or one whose rollback failed, would hand an open BEGIN to
  -- the next request.
  local pool = Pool.new(open, size, function(conn)
    return not conn.in_transaction and not conn.broken and conn.pg ~= nil
  end)
  -- A callable table rather than a plain function, so the pool can be reached
  -- for shutdown and diagnostics.  Lua functions cannot carry fields.
  return setmetatable({ pool = pool }, {
    __call = function() return pool:get() end,
  })
end

M.Pool = Pool
return M
