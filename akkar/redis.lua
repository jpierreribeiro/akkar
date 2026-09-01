--[[
akkar.redis — the Redis adapter, speaking RESP2 over a cqueues socket.

Written rather than depended upon, and that needs justifying.

No non-blocking Redis client exists for Lua 5.4 on cqueues.  Every
`lua-resty-*` client needs OpenResty's cosockets, `lua-hiredis` blocks, and
`lredis` is not packaged for 5.4.  A blocking client would pass every
functional test in this file and still be wrong: it would stall the event loop
on each command, serialising every request in the process.  That is the exact
failure the watchdog exists to report, and it is not one to ship on purpose.

RESP2 is small enough that writing it is cheaper than the risk.  A command is
an array of bulk strings; a reply is one of five things.

This is the second adapter, and it is where "akkar owns the contract,
libraries implement it" stops being a slogan: the pool it uses is the same
`akkar.pool` the Postgres adapter uses, and neither knows about the other.
]]

local socket    = require "cqueues.socket"
local Pool      = require "akkar.pool"
local execution = require "akkar.execution"

local Redis = {}
Redis.__index = Redis

local CRLF = "\r\n"

-- ================================================================== protocol
-- A command is an array of bulk strings.  Encoding it as such -- rather than
-- joining with spaces -- is what makes a value containing a newline or a space
-- harmless, the same reason parameters are bound rather than spliced in SQL.
local function encode(...)
  local parts = { "*" .. select("#", ...) .. CRLF }
  for i = 1, select("#", ...) do
    local arg = tostring((select(i, ...)))
    parts[#parts + 1] = "$" .. #arg .. CRLF .. arg .. CRLF
  end
  return table.concat(parts)
end

-- Reads one reply.  Recursive, because arrays nest.
--
-- Returns (value, nil) or (nil, error).  A Redis error reply is an error the
-- caller should see, not a transport failure, so it comes back as a value in
-- the second slot rather than raising here.
local function read_reply(sock)
  local line, err = sock:read "*L"
  if not line then return nil, err or "connection closed" end
  line = line:gsub("\r?\n$", "")

  local tag, rest = line:sub(1, 1), line:sub(2)

  if tag == "+" then return rest end
  -- The third value says WHICH KIND of failure this is. An error reply is the
  -- server answering normally with bad news -- WRONGTYPE, NOSCRIPT -- and the
  -- stream is perfectly in step afterwards. A read failure is not. Returning
  -- `nil, err` for both made every application-level error destroy the
  -- connection: measured, two WRONGTYPE replies took the pool from
  -- `live=1 idle=1` to `live=0 idle=0`, reconnecting each time.
  if tag == "-" then return nil, rest, "reply" end
  if tag == ":" then return tonumber(rest) end

  -- A HEADER THAT DOES NOT PARSE IS A PROTOCOL FAILURE, NOT A NIL REPLY.
  --
  -- `$-1` is the nil reply and it parses; `$xx` does not, and the two were
  -- collapsed into the same `return nil`. That is the desync above read from
  -- the other end: the call returned successfully, so `broken` was never set,
  -- `in_flight` was cleared, the body stayed unread in the socket, and the
  -- reuse predicate then judged the connection healthy and pooled it. The
  -- next borrower's first `GET` read a nil (a cache miss that never was) and
  -- its second read somebody else's value.
  --
  -- Reported as an error the stream cannot be trusted after, which is what
  -- `command` turns into `broken = true`.
  if tag == "$" then
    local length = tonumber(rest)
    if not length then return nil, "malformed bulk length '" .. rest .. "'" end
    if length < 0 then return nil end                   -- $-1 is a nil reply
    local data, read_err = sock:read(length + 2)        -- payload plus CRLF
    if not data then return nil, read_err or "truncated bulk reply" end
    -- AND THE LENGTH IS CHECKED, NOT TRUSTED. `sock:read(n)` is a request for
    -- n bytes, not a promise of them: an EOF part-way through hands back what
    -- arrived, and `data:sub(1, length)` then padded the hole with silence --
    -- an `INCR` for `limit.rate` reading 4 where the wire carried 42, a rate
    -- limit quietly not firing. If the CRLF is not exactly where the header
    -- said it would be, the header was not the truth and everything after it
    -- is misaligned.
    if #data < length + 2 or data:sub(length + 1) ~= CRLF then
      return nil, "truncated bulk reply"
    end
    return data:sub(1, length)
  end

  if tag == "*" then
    local count = tonumber(rest)
    if not count then return nil, "malformed array length '" .. rest .. "'" end
    if count < 0 then return nil end                    -- *-1 is a nil array
    local out = {}
    for i = 1, count do
      local value, item_err = read_reply(sock)
      if item_err then return nil, item_err end
      out[i] = value
    end
    return out
  end

  return nil, "unexpected RESP tag '" .. tag .. "'"
end

Redis._encode = encode          -- exposed for tests; not part of the contract
Redis._read_reply = read_reply

-- =================================================================== commands
-- The window between the write and the read is the dangerous one, and it is
-- marked rather than hoped about.
--
-- RESP has no request ids: replies are matched to commands purely by order.
-- So a connection abandoned after the write and before the read carries a
-- reply that belongs to somebody else, and the next request to use it reads
-- that reply as its own answer. Demonstrated with a `BLPOP` and a deadline
-- below it: the following request asked for a key it had just set and
-- received `nil` -- the abandoned `BLPOP` timing out.
--
-- That is worse than the equivalent on Postgres, where pgmoon refuses with
-- "connection is busy". Here nothing refuses, the stream realigns after one
-- request, and what is left is a single wrong answer with no error anywhere:
-- silent, transient, and unreproducible from a bug report.
--
-- `in_flight` stays set because the coroutine is abandoned before the line
-- that clears it, which is exactly what makes the state visible to the pool.
--- Refuses when the execution that borrowed this connection is over, and
--- bounds the socket by whatever the execution has left.
---
--- `akkar/db.lua` has had this since the deadline became a budget; `cache`
--- did not, and it is the only releasable capability that did not. That gap
--- is exactly the one `spec/abandoned_inertness_spec.lua` was written to
--- expose: a handler abandoned by its deadline still holds its cache, and if
--- it ever woke -- which is what removing the per-request controller would
--- allow -- it would write into a connection already lent to somebody else.
---
--- A handler abandoned mid-`sleep` carries a NEGATIVE remaining budget, which
--- is what makes this check work at all: `execution.begin` set the deadline
--- inside the handler's own coroutine and `execution.finish` never ran,
--- because the handler never resumed. Measured: a forced resume reads
--- `remaining()` of -0.55 s.
local function bound_by_execution(self)
  local left = execution.remaining()
  if not left then return end
  if left <= 0 then
    -- Refusing rather than sending, for the same reason db.lua gives: a
    -- command dispatched with no time to read its reply is the exact shape
    -- that poisons a pool slot, and Redis does the work either way.
    error("redis: the request deadline passed before the command was sent", 0)
  end
  if self.sock then pcall(self.sock.settimeout, self.sock, left) end
end

function Redis:command(...)
  if not self.sock then error("redis: connection is closed", 0) end
  bound_by_execution(self)
  -- Marked BEFORE the write, not after.
  --
  -- `sock:write` yields whenever the send buffer fills, so a deadline landing
  -- there abandons the coroutine with the command half on the wire -- and the
  -- old placement left every reuse predicate satisfied. The next request's
  -- command was then swallowed as payload of the unfinished one. Measured
  -- with a 300 MiB value and a 20 ms deadline: the following request got no
  -- reply and burned its own deadline.
  self.in_flight = true

  local ok, err = self.sock:write(encode(...))
  if not ok then
    self.broken = true
    error("redis: write failed: " .. tostring(err), 0)
  end

  local value, reply_err, kind = read_reply(self.sock)
  self.in_flight = false

  if reply_err then
    -- Only a PROTOCOL failure leaves the stream out of step. An error reply
    -- is the server answering, and the connection is still perfectly usable.
    if kind ~= "reply" then self.broken = true end
    error("redis: " .. tostring(reply_err), 0)
  end
  return value
end

--- Returns the value, or nil when the key is absent.  Never a sentinel: the
--- cjson null sentinel leaking into handlers was a real defect once already.
function Redis:get(key)
  return self:command("GET", key)
end

--- `ttl` is in seconds and optional.
function Redis:set(key, value, ttl)
  if ttl then return self:command("SET", key, value, "EX", ttl) end
  return self:command("SET", key, value)
end

function Redis:del(...)
  return self:command("DEL", ...)
end

function Redis:incr(key)
  return self:command("INCR", key)
end

--- Adds observations to a Redis HyperLogLog.
--- Returns 1 when at least one internal register changed, 0 otherwise.
function Redis:pfadd(key, ...)
  return self:command("PFADD", key, ...)
end

--- Estimates the cardinality of one HyperLogLog, or the union of several.
function Redis:pfcount(...)
  return self:command("PFCOUNT", ...)
end

--- Merges source HyperLogLogs into `destination` and returns "OK".
function Redis:pfmerge(destination, ...)
  return self:command("PFMERGE", destination, ...)
end

function Redis:expire(key, seconds)
  return self:command("EXPIRE", key, seconds)
end

function Redis:ttl(key)
  return self:command("TTL", key)
end

function Redis:ping()
  return self:command "PING"
end

--- Sets how long a read may wait, in seconds.
---
--- Needed because one command is legitimately slower than all the others:
--- `BRPOP key N` blocks IN THE SERVER for up to N seconds, so a socket
--- timeout below N would kill a wait that is working exactly as intended.
--- The blocking caller raises the timeout around its own command and puts it
--- back afterwards; everything else runs under the connection's default.
--- Passing nothing puts the connection's own default back, so a caller that
--- raised it cannot accidentally leave the socket unbounded.
function Redis:settimeout(seconds)
  if self.sock then self.sock:settimeout(seconds or self.timeout or 5) end
  return self
end

function Redis:close()
  if self.sock then pcall(function() self.sock:close() end) end
  self.sock = nil
end

function Redis:release()
  if self.pool then self.pool:put(self) else self:close() end
end

-- ==================================================================== connect
local M = {}

function M.connect(config)
  config = config or {}

  local function open()
    local sock, err = socket.connect {
      host = config.host or "127.0.0.1",
      port = config.port or 6379,
    }
    if not sock then error("redis: could not connect: " .. tostring(err), 0) end
    -- Without this a command would block the loop while waiting, which is the
    -- whole thing this adapter exists to avoid.
    sock:setmode("bn", "bn")
    sock:onerror(function(_, _, why) return why end)

    -- A READ HAD NO BOUND AT ALL. `read_reply` waited exactly as long as the
    -- server took, and the only thing above it was the request deadline --
    -- which a background worker does not have. So a Redis that accepted the
    -- connection and then stopped answering parked a `Queue:consume` worker
    -- for ever, with no error, no log line and no way to tell it apart from
    -- an idle queue.
    --
    -- A timed-out read also leaves the RESP stream out of step, and that is
    -- already handled: `read_reply` returns no `kind` for a transport
    -- failure, so `command` marks the connection broken and the pool's reuse
    -- predicate closes it rather than handing the next request a reply that
    -- belongs to somebody else.
    sock:settimeout(config.timeout or 5)

    local conn = setmetatable({ sock = sock, timeout = config.timeout or 5 }, Redis)

    -- CLOSE THE SOCKET BEFORE RAISING. AUTH and SELECT run on a connection
    -- that is already open, and raising out of `open` left it with nothing in
    -- this process referencing it. The pool restores its slot on the error
    -- path; the descriptor does not come back. A wrong password therefore
    -- leaked one socket per attempt, for as long as something kept retrying
    -- -- which is exactly what a pool under load does.
    local ok, err_setup = pcall(function()
      if config.password then conn:command("AUTH", config.password) end
      if config.database then conn:command("SELECT", config.database) end
    end)
    if not ok then
      pcall(function() conn:close() end)
      error(err_setup, 0)
    end

    return conn
  end

  local size = config.pool_size == nil and 10 or config.pool_size
  if size <= 0 then return open end

  -- Fit for reuse means the stream is still in step: a connection whose reply
  -- was truncated would give the next request someone else's answer.
  -- A command whose reply was never read leaves the connection holding
  -- somebody else's answer, and RESP has no way for the next request to
  -- notice. Rejected here means closed and the slot freed.
  local pool = Pool.new(open, size, function(conn)
    return not conn.broken and not conn.in_flight and conn.sock ~= nil
  end)
  return setmetatable({ pool = pool }, {
    __call = function() return pool:get() end,
  })
end

M.Redis = Redis
return M
