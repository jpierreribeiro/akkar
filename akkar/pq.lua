--[[
akkar.pq — Postgres over libpq, waiting in Lua.

## The split, and why it is here rather than in C

`src/akkar_pq.c` speaks to libpq and never waits. This file waits and never
speaks to libpq. The line between them is the one property this driver exists
to keep.

A C function cannot yield into a cqueues controller without reaching into the
scheduler, and a driver that blocks the event loop while a query runs would be
a far worse trade than the one it is trying to win: `docs/PLAN.md` records
pgmoon yielding at 7.56x out of a possible 8x, and that is the number a
blocking driver would spend. So every wait in this file is a `cqueues.poll`,
in Lua, where it can be read and where the deadline that governs it is the
same `akkar.time` deadline that governs everything else.

What C is for is the other half of the measurement. `docs/PERFORMANCE-STUDY.md`
decomposes the request and finds pgmoon's fetch and row decoding at 85-99% of
it: half the socket layer -- 2,006 reads averaging 22 bytes for a thousand
rows -- and half building one Lua table per row. Those are the two things
libpq and a C loop do without an interpreter in the way.

## The shape of every operation

Send, then drain, then read, and poll between each:

    conn:send_query(sql, params)     -- non-blocking, may buffer
    while conn:flush() == 1 do        -- 1 means "more to write"
      poll for write
    end
    while conn:busy() do              -- busy means "not a whole result yet"
      poll for read
      conn:consume()
    end
    conn:get_result()                 -- repeat until it answers nil

`PQisBusy` is the load-bearing call: it is false only when a COMPLETE result
has arrived, so the loop above never sees a partial row set. That is the
property pgmoon has to reconstruct by hand from message framing, and it is
also where its per-row socket reads come from.
]]

local cqueues = require "cqueues"
local pq      = require "akkar.pq_native"
local time    = require "akkar.time"

local M = {}

local Conn = {}
Conn.__index = Conn

-- How long to wait for one poll before checking the caller's deadline again.
-- Not a timeout in itself: a deadline is the caller's to set, and this only
-- bounds how long the driver sits inside a single `poll` without looking at
-- it. Half a second is short enough to be responsive and long enough that an
-- idle query costs two wakeups a second rather than a hundred.
local POLL_SLICE = 0.5

local function remaining(deadline)
  if not deadline then return POLL_SLICE end
  local left = deadline - time.monotime()
  if left <= 0 then return nil end
  return math.min(left, POLL_SLICE)
end

--- Waits until the connection is readable or writable, or the deadline passes.
local function wait(conn, events, deadline)
  conn.handle:set_events(events)
  local slice = remaining(deadline)
  if not slice then return nil, "timeout" end
  cqueues.poll(conn.handle, slice)
  if deadline and time.monotime() >= deadline then return nil, "timeout" end
  return true
end

--- Opens a connection, yielding through the whole handshake.
---
--- The handshake is polled rather than blocked because it is not free: a TLS
--- connection to a Postgres across an availability zone is several round
--- trips, and a driver that blocks the event loop for them stalls every other
--- request in the process at exactly the moment a pool is growing -- which is
--- the moment there is load.
function M.connect(config, deadline)
  local parts = {}
  local function add(key, value)
    if value ~= nil and value ~= "" then
      -- libpq's conninfo is space separated with single-quoted values, so a
      -- password containing a space or a quote must be escaped or it silently
      -- becomes two settings.
      parts[#parts + 1] = key .. "='" ..
        tostring(value):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
    end
  end

  add("host", config.host or "127.0.0.1")
  add("port", config.port or 5432)
  add("dbname", config.database)
  add("user", config.user)
  add("password", config.password)
  add("application_name", config.application_name or "akkar")
  if config.sslmode then add("sslmode", config.sslmode) end
  if config.connect_timeout then add("connect_timeout", config.connect_timeout) end

  local handle, why = pq.connect_start(table.concat(parts, " "))
  if not handle then return nil, why end

  local conn = setmetatable({ handle = handle }, Conn)

  -- `PQconnectPoll` tells us which way to wait each time, and the first call
  -- must happen before any poll: libpq documents the initial state as
  -- "waiting to write", and polling for read first would wait for bytes that
  -- nobody has been asked to send yet.
  while true do
    local state, err = handle:connect_poll()
    if state == "ok" then break end
    if state == "failed" then
      conn:close()
      return nil, "akkar.pq: " .. tostring(err)
    end
    local ok, timed_out = wait(conn, state, deadline)
    if not ok then
      conn:close()
      return nil, "akkar.pq: connecting timed out (" .. tostring(timed_out) .. ")"
    end
  end

  return conn
end

--- Runs one statement and returns its rows.
---
--- Parameters are BOUND, never spliced: they travel as parameters of the
--- extended protocol with their Postgres type declared, which is the same
--- guarantee `akkar/db.lua` makes and the reason a handler can pass user
--- input without an escaping ritual.
function Conn:query(sql, params, deadline)
  if self.closed then return nil, { message = "akkar.pq: connection is closed" } end

  local ok, err = self.handle:send_query(sql, params)
  if not ok then return nil, { message = err } end

  -- Drain what libpq buffered. `flush` answers 1 while bytes remain, and the
  -- socket has to be writable before trying again or this is a busy loop.
  while true do
    local pending, ferr = self.handle:flush()
    if pending == nil then return nil, { message = ferr } end
    if pending == 0 then break end
    local waited, why = wait(self, "w", deadline)
    if not waited then return nil, { message = "akkar.pq: write timed out", timeout = true, why = why } end
  end

  -- Then read until a COMPLETE result exists. `busy` is false only then, so
  -- nothing below ever sees half a row set.
  local rows, failure
  while true do
    while self.handle:busy() do
      local waited, why = wait(self, "r", deadline)
      if not waited then
        -- A timed-out query is still running on the server, and the
        -- connection now has a result nobody collected. It cannot go back to
        -- the pool: the next borrower would read this query's rows as its
        -- own. `akkar/pool.lua` discards what `release` reports as spoiled.
        self.spoiled = true
        return nil, { message = "akkar.pq: query timed out", timeout = true, why = why }
      end
      local consumed, cerr = self.handle:consume()
      if not consumed then
        self.spoiled = true
        return nil, { message = cerr }
      end
    end

    local result, rerr = self.handle:get_result()
    if result == nil and rerr == nil then break end   -- every result collected
    if result == nil then
      -- Keep draining: libpq requires `PQgetResult` to be called until it
      -- answers nil, and abandoning it mid-way is exactly how a connection
      -- returns to a pool carrying somebody else's rows.
      failure = failure or rerr
    else
      rows = rows or result
    end
  end

  if failure then return nil, failure end
  return rows or {}
end

function Conn:in_transaction()
  if self.closed then return false end
  return self.handle:in_transaction()
end

--- Closes the connection, telling the scheduler first.
---
--- CANCEL BEFORE CLOSE, and the order is not a style choice.
---
--- The controller keeps this descriptor in its pollset from the last wait.
--- `PQfinish` closes it, and the number is immediately available for the
--- kernel to hand to the next socket anyone opens -- so the controller is now
--- polling a descriptor that belongs to somebody else. What that produced
--- while this file was being written was `unable to update event disposition:
--- Bad file descriptor`, which is the loud version; the quiet version is a
--- pool where one connection is woken by another connection's traffic.
---
--- `cqueues.cancel` removes it from the pollset and wakes anything waiting on
--- it, which is exactly the contract needed here.
function Conn:close()
  if self.closed then return end
  self.closed = true
  local fd = self.handle:pollfd()
  if fd and fd >= 0 then pcall(cqueues.cancel, fd) end
  self.handle:close()
end

M.Conn = Conn
M.VERSION = pq.VERSION

return M
