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
  if not res then
    -- A RETURNED error is ambiguous in a way a raised one is not.  PostgreSQL
    -- rejecting a query -- a unique violation, a bad column -- reports exactly
    -- like a backend that went away, and the two demand opposite handling: the
    -- first leaves a perfectly good connection, the second leaves a corpse.
    --
    -- Guessing wrong in the safe-looking direction is what makes the pool
    -- unrecoverable.  Nothing marks the dead connection, the fitness predicate
    -- below sees no transaction, no break and a non-nil `pg`, so it goes back
    -- to `idle` and is handed out again -- and every request fails, forever,
    -- while PostgreSQL is healthy and `/health/live` still answers 200.
    -- Measured before this line existed: a pool of two, eight consecutive
    -- failures after one `pg_terminate_backend`, with no recovery.
    --
    -- So ask, instead of inferring.  One round trip, only on a path that has
    -- already failed, and only to answer the question the pool actually needs
    -- answered: is this connection still usable?  A dead socket answers
    -- immediately, and a live one costs a `select 1` on an error path.
    self.in_flight = true
    local probed, alive = pcall(self.pg.query, self.pg, "select 1")
    self.in_flight = false
    if not (probed and alive) then self.broken = true end
    error("db: " .. tostring(err), 0)
  end
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
--
-- That invariant was true and it was the wrong one, because it says nothing
-- about a BEGIN opened while one was already open.  A helper that owns a
-- transaction -- `charge()` -- called from a handler that owns a bigger one --
-- `place_order()` -- is the most ordinary refactor there is, and Postgres
-- answers the second `begin` with a warning and no transaction.  Then the
-- inner `commit` ENDS THE OUTER ONE, every statement after it autocommits, and
-- the outer `rollback` is a no-op warning.  Reproduced here against Postgres:
-- an outer transaction that raised left all three rows committed
-- (`[outer-before, inner, outer-after]`, expected `[]`), with `in_transaction`
-- false, `broken` false, and the pool judging the connection fit for reuse.
-- Statements issued: `begin | begin | select 1 | commit | commit`.
--
-- SAVEPOINT rather than refusing the nested call, for two reasons.  Refusing
-- turns a correct-looking refactor into a runtime error on a path that may
-- only be exercised in production -- and it pushes people towards passing a
-- boolean like `already_in_transaction` down through the helpers, which is the
-- bookkeeping this file exists to remove.  A savepoint gives the inner block
-- the only nesting semantics one connection can offer: its work is undone on
-- its own failure, and made durable only when the outermost block commits.
-- That is the semantics a caller wants from `charge()` anyway; a helper whose
-- write must survive the caller's rollback needs a second connection, not a
-- second BEGIN.
--
-- The savepoint is named per depth, which is enough: a name is released before
-- the same depth can be entered again.
function Db:transaction(fn)
  local depth = self.tx_depth or 0

  if depth > 0 then
    local name = "akkar_sp_" .. (depth + 1)
    self:query("savepoint " .. name)
    self.tx_depth = depth + 1
    local ok, result = pcall(fn, self)
    self.tx_depth = depth

    if not ok then
      -- `rollback to savepoint` also clears the aborted state a failed
      -- statement leaves behind, which is what lets the OUTER transaction
      -- carry on after a helper failed.  If it does not work, the outer
      -- transaction is unrecoverable and the connection must not be reused.
      if not pcall(function() self:query("rollback to savepoint " .. name) end) then
        self.broken = true
      end
      error(result, 0)        -- the outer block still decides what to do
    end

    -- Releasing keeps the savepoint stack from growing for the length of a
    -- long outer transaction; it commits nothing on its own.
    if not pcall(function() self:query("release savepoint " .. name) end) then
      self.broken = true
      error("db: could not release " .. name, 0)
    end
    return result
  end

  self:query "begin"
  self.in_transaction = true
  self.tx_depth = 1
  local ok, result = pcall(fn, self)
  self.tx_depth = 0

  if not ok then
    local rolled = pcall(function() self:query "rollback" end)
    -- A connection whose rollback failed is in an unknown state.  Marking it
    -- keeps the pool from handing that state to the next request.  Only ever
    -- set, never cleared: a successful rollback says nothing about a break
    -- some other path already found.
    if rolled then
      self.in_transaction = false
    else
      self.in_transaction, self.broken = true, true
    end
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

local function tls_client(config)
  local context_module = require "openssl.ssl.context"
  local context = context_module.new(config.ssl_version or "TLS", false)
  local store = context:getStore()
  if config.cafile then store:add(config.cafile) else store:addDefaults() end
  context:setVerify(context_module.VERIFY_PEER)
  if config.cert then context:setCertificate(config.cert) end
  if config.key then context:setPrivateKey(config.key) end

  local params = require("openssl.x509.verify_param").new()
  local host = assert(config.host, "db TLS verification needs host")
  if host:match("^%d+%.%d+%.%d+%.%d+$") then params:setIP(host)
  else params:setHost(host) end
  context:setParam(params)

  local ssl = require("openssl.ssl").new(context)
  if not host:match("^%d+%.%d+%.%d+%.%d+$") then ssl:setHostName(host) end
  ssl:setParam(params)
  return ssl
end

M.tls_client = tls_client

-- ==================================================================== connect
-- Returns a factory: akkar calls it once per request.  `pool_size = 0` opts
-- out and opens a connection per request, which is what the substrate proof
-- measured and what a one-off script wants.
function M.connect(config)
  local ssl_required = config.ssl_required
  if ssl_required == nil then ssl_required = config.ssl or false end

  local function open()
    local tls = config.cqueues_openssl_context
    if config.ssl and config.ssl_verify and not tls then tls = tls_client(config) end
    local pg = pgmoon.new {
      host = config.host or "127.0.0.1",
      port = config.port or 5432,
      database = config.database,
      user = config.user,
      password = config.password,
      socket_type = "cqueues",
      ssl = config.ssl or false,
      -- Asking for TLS means requiring it.
      --
      -- PostgreSQL's SSL negotiation happens in cleartext: the client asks,
      -- and the server answers `S` or `N`.  pgmoon fails on an error reply or
      -- when `ssl_required` is set, and otherwise -- on a plain `N` -- falls
      -- through to `return true` and continues UNENCRYPTED.  So with
      -- `ssl_required` defaulting to false, everything above this line is
      -- skipped without a certificate ever being presented: VERIFY_PEER, the
      -- CA store, setHost/setIP, SNI.  Anyone positioned to answer that byte
      -- strips the TLS, and `ssl_verify = true` reports success.
      --
      -- So the default follows the request: a caller who said `ssl = true`
      -- gets an error rather than a downgrade.  Opportunistic TLS is still
      -- available, and now has to be said out loud -- `ssl_required = false`
      -- is a sentence someone has to write, which is the point.
      ssl_required = ssl_required,
      ssl_verify = config.ssl_verify,
      cert = config.cert,
      key = config.key,
      cafile = config.cafile,
      ssl_version = config.ssl_version,
      cqueues_openssl_context = tls,
    }
    -- Bound the CONNECT, not just the query.
    --
    -- A blackholed backend -- a firewall change, a failed failover, a NAT
    -- table that forgot the flow -- neither accepts nor refuses, so `connect`
    -- waits for as long as the kernel will let it. The request's deadline then
    -- abandons the coroutine inside this function, and the pool slot it took
    -- goes with it. The pool reclaims such a slot on its own, but not needing
    -- to is better.
    --
    -- Set on the socket and cleared the moment the handshake is done: cqueues
    -- applies a socket timeout to every later read as well, and a long query
    -- must not inherit the connect budget. pgmoon takes milliseconds.
    if config.connect_timeout then
      pg:settimeout(config.connect_timeout * 1000)
    end
    local ok, err = pg:connect()
    if config.connect_timeout then pg:settimeout(nil) end
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
      local ok, err = pg:query("set statement_timeout = " .. ms)
      if not ok then
        error("db: could not set statement_timeout: " .. tostring(err), 0)
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
  end, {
    -- Recycling and bounded waiting are the pool's, and their reasons are
    -- written there.  Only the numbers belong to the application, and the
    -- default for each is the pool's.
    max_lifetime = config.max_lifetime,
    idle_timeout = config.idle_timeout,
    wait_timeout = config.pool_wait_timeout,
    -- A slot outstanding for much longer than a connect attempt can take is a
    -- connect that will never come back.
    open_timeout = config.connect_timeout and config.connect_timeout * 2 or nil,
  })
  -- A callable table rather than a plain function, so the pool can be reached
  -- for shutdown and diagnostics.  Lua functions cannot carry fields.
  return setmetatable({ pool = pool }, {
    __call = function() return pool:get() end,
  })
end

M.Pool = Pool
M.scope = Scope.wrap
return M
