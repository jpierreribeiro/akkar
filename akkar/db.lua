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
-- For the execution's remaining budget. Requires only cqueues and akkar.time,
-- so no cycle back to here.
local execution = require "akkar.execution"

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

--- Bounds the next wire call by whatever the execution has left.
---
--- Until this existed, a request deadline did not stop a query. It abandoned
--- the coroutine waiting for the reply while the database kept working --
--- which `warn_unbounded_statements` warns about at boot, in those words, and
--- which is why `statement_timeout` had to be configured separately and by
--- hand to mean anything.
---
--- pgmoon's cqueues socket takes MILLISECONDS and divides by a thousand
--- before handing seconds to cqueues, so the conversion happens here rather
--- than being rediscovered at each call site.
---
--- Nothing happens when there is no budget: the connection keeps whatever
--- timeout it was configured with, and an application that never sets
--- `app:run { timeout = ... }` sees no change at all.
---
--- Returns true when a deadline was actually imposed on the socket, which is
--- what tells a transport failure from a plain query error afterwards.
local function bound_by_execution(self)
  local left = execution.remaining()
  if not left then return false end
  if left <= 0 then
    -- Refusing here rather than sending. A query dispatched with no time to
    -- read its reply is the exact shape that poisons a pool slot, and the
    -- database would do the work regardless of whether anyone reads it.
    error("db: the request deadline passed before the query was sent", 0)
  end
  pcall(self.pg.settimeout, self.pg, left * 1000)
  return true
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
  local bounded = bound_by_execution(self)
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
  -- A driver that knows its connection is unusable is believed. The C driver
  -- sets this when a query timed out with its result still in flight; pgmoon
  -- has no equivalent and the flag is simply absent there.
  if self.pg and self.pg.spoiled then self.broken = true end

  -- TWO FAILURES THAT LOOK ALIKE AND MUST NOT BE TREATED ALIKE.
  --
  -- Postgres answering `ERROR: canceling statement due to statement timeout`
  -- is a QUERY error: the reply was read in full and the connection is clean.
  -- `spec/db_spec.lua` states the consequence of getting this wrong -- "if a
  -- cancelled query cost a reconnect, every slow query would pay for one and
  -- the pool would stop being a pool".
  --
  -- Our own socket timing out is a TRANSPORT error: the reply is still coming,
  -- the protocol is at an unknown offset, and the connection is finished. It
  -- surfaces as `receive_message: failed to get type: 110` -- errno 110 is
  -- ETIMEDOUT.
  --
  -- The discriminator is the budget, not the message text. We only ever set a
  -- socket timeout because the execution had a deadline, so a failure caused
  -- by that timeout cannot happen before the deadline. Matching on a driver's
  -- internal wording would work today and break on the next pgmoon release.
  --
  -- Why this matters now: while the only way to lose a query was the deadline
  -- abandoning the coroutine, `in_flight` stayed set and the pool rejected the
  -- connection on its own. Once the socket started honouring the budget the
  -- failure began arriving as a RETURN -- `in_flight` cleared on the way out,
  -- the connection looked fit, and it went back to the pool with an unread
  -- reply on the wire. Caught by `spec/abandoned_spec.lua`, which is the test
  -- written for the first door this defect came through.
  if not res then
    if bounded and execution.remaining() and execution.remaining() <= 0 then
      self.broken = true
    end
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
-- RETURNING A 4xx FROM INSIDE COMMITS. This is the expensive trap in this
-- module and it is written here because it cost somebody an afternoon to find.
--
--     req.db:transaction(function(tx)
--       tx:exec("insert into ...")
--       if bad then return akkar.bad_request "no" end   -- COMMITS the insert
--     end)
--
-- The closure returned, so the transaction succeeded, so it committed -- and
-- the 400 travels up as the handler's response. The row is written and the
-- caller is told their request was rejected, which is the worst of both.
-- Confirmed against a real database while writing the beginner guide: a row
-- landed from a request that answered 400.
--
-- `error(akkar.bad_request "no")` is the form that rolls back, and it is the
-- form the rest of akkar already uses -- response-as-error exists precisely so
-- a deep layer can signal HTTP without threading a return value through every
-- frame. It is not caught here; `pcall` sees the raise, the rollback runs, and
-- the response is re-raised for the handler chain to answer with.
--
-- This is NOT changed to treat a returned 4xx as a rollback, and the reason is
-- that the change would be a guess about intent: a closure can legitimately
-- return a 4xx after work that should persist -- recording the rejected
-- attempt is the ordinary example. A rule that reads the status code would
-- silently discard those writes instead, which is the same defect pointing the
-- other way and harder to see.
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

-- ================================================================ the C driver
--
-- `akkar.pq` presents a different surface from pgmoon -- `query(sql, params,
-- deadline)` against `query(sql, ...)` -- so it enters through a shim that
-- speaks pgmoon's shape. Everything above this line is then untouched: `Db`,
-- the transaction, the scope wrapper and the pool never learn which driver is
-- underneath, which is the claim `docs/PLAN.md` makes about the adapter
-- boundary and the first chance to check it rather than assert it.
--
-- OPT-IN, and the default stays pgmoon on purpose. A driver becomes the
-- default by proving itself, not by being newer, and the proof is
-- `spec/db_spec.lua` running the same contract against both. Flipping the
-- default is a separate commit with that evidence behind it.
local function pq_open(config)
  local ok, pq = pcall(require, "akkar.pq")
  if not ok then
    -- THE MESSAGE NAMES THE INSTALL, not a script in a checkout.
    --
    -- It used to say "build it with src/build.sh", which is only useful to
    -- somebody who already has the repository cloned. Anyone who installed
    -- akkar from luarocks has the Lua half of this driver and not the C half,
    -- and telling them to run a shell script they do not have is how a
    -- supported option reads as a broken one.
    error("db: driver 'pq' needs the C module akkar.pq_native, which is a " ..
          "separate rock:\n" ..
          "    luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir)\n" ..
          "  PQ_INCDIR is needed on Debian and Ubuntu, where libpq-fe.h " ..
          "lives in /usr/include/postgresql.\n" ..
          "  From a checkout, src/build.sh does the same thing. Or drop the " ..
          "'driver' option and use the default pgmoon driver.\n  " ..
          tostring(pq), 0)
  end

  local conn, why = pq.connect(config)
  if not conn then error("db: could not connect: " .. tostring(why), 0) end

  -- `statement_timeout` for the same reason the pgmoon path sets it: closing
  -- a connection frees akkar's slot but does not stop the query, so without
  -- this a timeout makes the database busier rather than quieter.
  if config.statement_timeout then
    local ms = math.floor(config.statement_timeout * 1000)
    local set, set_err = conn:query("set statement_timeout = " .. ms)
    if not set then
      -- Close before raising, exactly as the pgmoon path learned to: the
      -- connection is authenticated by now, so raising out of `open` would
      -- leave a live Postgres backend that nothing references while the pool
      -- restored its slot.
      pcall(function() conn:close() end)
      error("db: could not set statement_timeout: " ..
            tostring(set_err and set_err.message or set_err), 0)
    end
  end

  return {
    conn = conn,
    --- pgmoon's signature: rows, or nil plus a message.
    query = function(self, sql, ...)
      -- `table.pack` and its `n` kept intact: a lone nil parameter is a SQL
      -- NULL, and `#` cannot count it. See the note in `pq_send_query`.
      local params
      if select("#", ...) > 0 then params = table.pack(...) end
      local rows, err = self.conn:query(sql, params)
      if rows then return rows end

      -- A TIMED-OUT QUERY POISONS ITS CONNECTION and the driver says so. The
      -- result is still coming, so the next borrower would read this query's
      -- rows as its own -- the identical defect `in_flight` was added to
      -- catch on the pgmoon path, where an unread result set left the
      -- connection refusing everything for the rest of its life.
      if self.conn.spoiled then self.spoiled = true end
      return nil, err and err.message or "query failed"
    end,
    disconnect = function(self) self.conn:close() end,
  }
end

local M = {}

-- ==================================================================== connect
-- Returns a factory: akkar calls it once per request.  `pool_size = 0` opts
-- out and opens a connection per request, which is what the substrate proof
-- measured and what a one-off script wants.
function M.connect(config)
  local function open()
    if config.driver == "pq" then
      return setmetatable({ pg = pq_open(config) }, Db)
    end
    if config.driver ~= nil and config.driver ~= "pgmoon" then
      error("db: unknown driver '" .. tostring(config.driver) ..
            "'; expected 'pgmoon' or 'pq'", 0)
    end

    local pg = pgmoon.new {
      host = config.host or "127.0.0.1",
      port = config.port or 5432,
      database = config.database,
      user = config.user,
      password = config.password,
      socket_type = "cqueues",
    }
    -- THE MESSAGE BELOW NEVER APPEARED, and that was the point of writing it.
    --
    -- `pg:connect()` does not return `nil, err` when the server is not there.
    -- pgmoon RAISES, from inside its cqueues socket layer, so this line was
    -- unreachable and what a developer actually saw was a bare traceback out
    -- of `pgmoon/cqueues.lua:18` -- no host, no port, no hint that a database
    -- was involved at all.
    --
    -- Found by someone writing the beginner guide, who stopped Postgres to
    -- show what happens and got a stack trace pointing into a dependency.
    -- That is the worst possible first encounter with a framework: the thing
    -- that failed is your `docker run`, and the thing on screen is somebody
    -- else's source file.
    --
    -- So the call is wrapped, and both shapes -- raised and returned -- end
    -- in the same message, which names what was being connected to.
    local ok, err = pcall(function() return pg:connect() end)
    if ok and err == nil then ok = false end     -- `false, reason` from pgmoon
    if not ok then
      local reason = tostring(err)
      -- The connection refused case is worth naming on its own, because it is
      -- almost always a database that is not running rather than one that is
      -- misconfigured, and those have different fixes.
      local hint = reason:find("refused", 1, true)
        and "\n  Nothing is listening there. Is the database running?"
        or ""
      error(("db: could not connect to %s:%s (database %q, user %q) -- %s%s")
            :format(tostring(config.host or "127.0.0.1"),
                    tostring(config.port or 5432),
                    tostring(config.database or "?"),
                    tostring(config.user or "?"),
                    reason, hint), 0)
    end

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
