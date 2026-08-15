--[[
akkar.db — the Postgres adapter.

This file exists to enforce the framework's one architectural rule:

    a handler never calls require "pgmoon".

It receives `req.db` and calls `:one`, `:many`, `:exec`, `:transaction`.
Swapping pgmoon for async libpq inside a C host rewrites this file and
nothing else.

Parameters go over the Postgres extended protocol -- pgmoon sends Parse, Bind,
Describe and Execute with typed binding -- so a value is never spliced into SQL
text.

The types those parameters carry are corrected here: pgmoon declares every Lua
number as `numeric`, which is a cross-type comparison against an integer column
and therefore a sequential scan.  See `serialize_number` below; it is worth
43x on a 10,000-row table.

The statement is UNNAMED, meaning the parse happens on every call and there is
no server-side plan caching between calls.  That is correct, safe binding; it
is not the same thing as a named prepared statement.
]]

local pgmoon = require "pgmoon"
local Pool   = require "akkar.pool"
local Scope  = require "akkar.scope"

local Db = {}
Db.__index = Db

-- Postgres type OIDs for bound parameters.
--
-- THIS IS THE MOST EXPENSIVE LINE OF CODE IN THE PROJECT, by its absence.
--
-- pgmoon types every Lua number as `numeric` (OID 1700).  Comparing an
-- `integer` column against a `numeric` parameter is a cross-type comparison
-- Postgres cannot answer from the index, so it casts the column on every row
-- and falls back to a sequential scan.  Measured on a 10,000-row table:
--
--     $1 numeric   Seq Scan,   Rows Removed by Filter: 10001,  3.287 ms
--     $1 bigint    Index Scan, Index Cond: (id = '42'::bigint), 0.153 ms
--
-- Forty-three times, and it grows with the table.  Every parameterised lookup
-- akkar has ever made against a numeric column has been a full scan.
--
-- Lua integers are 64-bit, so `int8` is the honest type.  Floats stay
-- `float8`; comparing a float to an integer column legitimately cannot use
-- the index, and pretending otherwise would change what the query means.
local INT8, FLOAT8, TEXT, BOOL = 20, 701, 25, 16

local function serialize_number(_, v)
  if math.type(v) == "integer" then return INT8, tostring(v) end
  return FLOAT8, tostring(v)
end

-- ============================================================ buffered reads
--
-- pgmoon asks the socket for five bytes, then for a body, once per protocol
-- message -- and Postgres sends one message per row.  A thousand rows is 2,006
-- socket calls for about 54 KB, averaging 22 bytes each.
--
-- The obvious diagnosis was wrong, and it is worth writing down because it
-- looked so convincing.  pgmoon opens the connection with `setmode("bn", "bn")`
-- -- unbuffered -- which reads as a syscall per call.  Counted with strace, a
-- thousand-row query costs about a hundred read syscalls in the whole process,
-- not two thousand: cqueues buffers internally regardless of the mode.  Asking
-- cqueues for full buffering measured *slower*.
--
-- So the cost is not I/O.  It is 2,006 Lua-level calls and the strings they
-- allocate, measured at 30% of a thousand-row query.  This serves them from one
-- large read instead, which is the only part of that 30% that can be recovered
-- without a driver written in C.
--
-- Installed after `connect()` has returned, never before: the SSL negotiation
-- reads a single byte off the raw socket, and a buffer that swallowed bytes
-- ahead of the handshake would break TLS.
local READ_CHUNK = 65536

local function buffered_receive(sock)
  local buf, pos = "", 1
  return function(_, n)
    -- All three of pgmoon's call sites ask for a fixed count.  Anything else
    -- falls back to the socket rather than guessing, so a future pgmoon that
    -- asks for a line or for everything still works.
    if type(n) ~= "number" or n < 0 then
      if pos <= #buf then
        return nil, "akkar.db: unbuffered read requested with buffered bytes pending"
      end
      return sock:read(n)
    end

    while #buf - pos + 1 < n do
      if pos > 1 then buf, pos = buf:sub(pos), 1 end   -- drop what was consumed
      local chunk, err = sock:read(-READ_CHUNK)        -- up to CHUNK, not exactly
      if not chunk then return nil, err end
      buf = buf .. chunk
    end

    local out = buf:sub(pos, pos + n - 1)
    pos = pos + n
    if pos > #buf then buf, pos = "", 1 end            -- keep it from growing
    return out
  end
end

-- A query may arrive as text with parameters, or as an `akkar.sql` builder.
-- The builder is the safe path, so it must be the convenient one too: a path
-- that is safe but awkward loses to concatenation every time.
local function statement(sql, ...)
  if type(sql) == "table" and sql.build then return sql:build() end
  return sql, ...
end

-- `in_flight` is what makes an abandoned query detectable, and the placement
-- of the two assignments is the entire mechanism.
--
-- When a request's deadline fires, `with_deadline` abandons the handler where
-- it stands. If it stands inside `pg:query`, the coroutine is suspended
-- waiting for rows and **never resumes** -- so the line clearing the flag
-- never runs, and the connection carries the mark for the rest of its life.
--
-- Without it the pool saw nothing wrong: an unread result set sets neither
-- `in_transaction` nor `broken`. The connection went back, and pgmoon refused
-- every subsequent query on it with "connection is busy" -- forever, since
-- nothing ever marked it broken either. Measured: one timed-out query
-- permanently destroyed one pool slot, and a pool of ten died after ten.
--
-- The framework already understood this class of bug. `with_deadline` refuses
-- to pool a controller whose handler was abandoned, and its comment calls it
-- "the same class of bug as a pooled database connection with a transaction
-- still open". The defence was built for the controller and not for the
-- connection it holds.
function Db:query(sql, ...)
  self.in_flight = true
  local ok, res, err = pcall(self.pg.query, self.pg, statement(sql, ...))
  self.in_flight = false

  -- A raised error leaves the protocol at an unknown offset, so the
  -- connection is finished. Only `res == nil` was handled before, and pgmoon
  -- raises rather than returns for a protocol fault.
  if not ok then
    self.broken = true
    error("db: " .. tostring(res), 0)
  end
  if not res then error("db: " .. tostring(err), 0) end
  return res
end

function Db:many(sql, ...)
  local res = self:query(sql, ...)
  if type(res) ~= "table" then return {} end
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

-- ===================================================================== scoping
-- The mechanism lives in `akkar.scope`, at the contract level, so the
-- in-memory adapter scopes identically.  A fake whose safety property differs
-- from the real one is how a test proves the wrong thing.
function Db:scope(column, value)
  return Scope.wrap(self, column, value)
end

-- A no-op that reads as an assertion at the call site, so
-- `grep -rn ':unscoped()'` lists every query that crosses tenants.
function Db:unscoped() return self end

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

    -- Override pgmoon's number serializer per connection, so this fix needs
    -- no fork of the driver.
    pg.type_serializers = setmetatable({ number = serialize_number },
                                       { __index = pg.type_serializers })

    -- Reading in one gulp instead of two calls per row.  `buffered_reads =
    -- false` opts out, because this is the one place akkar reaches into a
    -- dependency's internals and a way back out should not require a fork.
    if config.buffered_reads ~= false and pg.sock and pg.sock.sock then
      pg.sock.receive = buffered_receive(pg.sock.sock)
    end

    -- Tell POSTGRES about the deadline, not just the client.
    --
    -- Abandoning a query and closing its connection frees akkar's pool slot
    -- immediately, but it does not necessarily stop the query: Postgres
    -- notices a gone client when it next tries to write, and a query that
    -- produces no output until it finishes may not try for minutes. Under
    -- load that means a timeout makes the database *busier*, which is the
    -- opposite of what a timeout is for.
    --
    -- Set once per connection rather than per query. Per query would be a
    -- second round trip on a path measured at ~10k requests a second, and it
    -- would buy nothing: akkar's deadline is one number for the whole app, so
    -- the remaining time is never meaningfully different between two requests
    -- of the same shape.
    --
    -- Deliberately NOT `set local`: that is transaction-scoped and would
    -- vanish outside one, which is where most queries run.
    if config.statement_timeout then
      local ms = math.floor(config.statement_timeout * 1000)
      local set, set_err = pg:query("set statement_timeout = " .. ms)
      if not set then
        -- DISCONNECT BEFORE RAISING. The connection is already open and
        -- authenticated at this point, so raising out of `open` left a live
        -- Postgres backend with nothing in this process referencing it. The
        -- pool restores its slot on the error path and the descriptor does
        -- not come back, so a database that fails this one statement --
        -- because `statement_timeout` is not settable for that role, say --
        -- burned a backend per attempt while the pool reported itself
        -- healthy.
        pcall(function() pg:disconnect() end)
        error("db: could not set statement_timeout: " .. tostring(set_err), 0)
      end
    end

    -- `null` was read from `pgmoon.null`, which does not exist -- the module
    -- exports only VERSION, Postgres and new.  So the row-cleaning pass that
    -- used it compared every field against nil and removed nothing, on every
    -- row of every result.  It cost 9% of a single-row query and 24% of a
    -- hundred-row one, which is exactly the shape of the "medium JSON" problem
    -- from the previous framework.  It is gone.
    --
    -- Nothing is lost: pgmoon leaves a SQL NULL out of the row table entirely
    -- unless `convert_null` is set, which akkar does not set.
    return setmetatable({ pg = pg }, Db)
  end

  local size = config.pool_size == nil and 10 or config.pool_size
  if size <= 0 then return open end

  -- What "fit for reuse" means here, and only here: a connection still inside
  -- a transaction would hand an open BEGIN to the next request, one whose
  -- rollback failed is in an unknown state, and one with a query still in
  -- flight has a result set nobody read sitting in its socket.
  --
  -- A rejected connection is closed and its slot freed, so the next request
  -- opens a fresh one. That costs a reconnect on every timed-out query, which
  -- is the right price: the alternative was a pool slot dead until restart.
  local pool = Pool.new(open, size, function(conn)
    return not conn.in_transaction and not conn.broken
       and not conn.in_flight and conn.pg ~= nil
  end)
  -- A callable table rather than a plain function, so the pool can be reached
  -- for shutdown and diagnostics.  Lua functions cannot carry fields.
  return setmetatable({ pool = pool }, {
    __call = function() return pool:get() end,
  })
end

M.Pool = Pool
M.scope = Scope.wrap
return M
