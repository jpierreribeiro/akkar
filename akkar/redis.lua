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

local socket = require "cqueues.socket"
local errno  = require "cqueues.errno"
local Pool   = require "akkar.pool"

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

  -- `$-1` is a nil reply.  A header that does not parse is NOT.
  --
  -- Treating both as nil returned successfully from a reply that was never
  -- consumed: the payload stayed in the socket, `broken` was never set,
  -- `in_flight` was cleared, and the reuse predicate below saw a healthy
  -- connection and pooled it.  Demonstrated with one corrupt header:
  --
  --     1st command: value=nil            (reads as a cache miss)
  --     2nd command: value=USER-A-SECRET  (request A's reply)
  --
  -- RESP matches replies to commands by order alone, so one unread reply
  -- hands every later request on that connection somebody else's answer.
  -- A malformed header means the stream is at an offset nobody knows, which
  -- is a transport failure -- the third value stays nil so `command` breaks
  -- the connection rather than returning it to the pool.
  if tag == "$" then
    local length = tonumber(rest)
    if not length or length < -1 or length % 1 ~= 0 then
      return nil, "malformed bulk length '" .. rest .. "'"
    end
    if length == -1 then return nil end
    local data, read_err = sock:read(length + 2)        -- payload plus CRLF
    if not data then return nil, read_err or "truncated bulk reply" end
    -- `sock:read(n)` is not guaranteed to deliver n bytes: at EOF it returns
    -- what it has. Returning that as the value made a truncated reply read as
    -- a complete one -- an `INCR` for `limit.rate` came back 4 instead of 42,
    -- and the rate limit silently did not fire. The trailing CRLF is checked
    -- for the same reason: if it is not there, the length was not the length,
    -- and everything after it is misaligned.
    if #data ~= length + 2 or data:sub(length + 1) ~= CRLF then
      return nil, "truncated bulk reply: wanted " .. (length + 2)
                  .. " bytes, got " .. #data
    end
    return data:sub(1, length)
  end

  if tag == "*" then
    local count = tonumber(rest)
    if not count or count < -1 or count % 1 ~= 0 then
      return nil, "malformed array length '" .. rest .. "'"
    end
    if count == -1 then return nil end                  -- *-1 is a nil array
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
function Redis:command(...)
  if not self.sock then error("redis: connection is closed", 0) end
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

function Redis:expire(key, seconds)
  return self:command("EXPIRE", key, seconds)
end

function Redis:ttl(key)
  return self:command("TTL", key)
end

function Redis:ping()
  return self:command "PING"
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

    -- `socket.connect` only prepares the socket; the handshake happens on the
    -- first use. Bound it here rather than letting a blackholed server -- one
    -- that neither accepts nor refuses -- hold a pool slot for as long as the
    -- kernel will allow, with the coroutine abandoned inside `open` and the
    -- slot gone with it.
    --
    -- Done as an argument to `connect` and NOT as `sock:settimeout`, because a
    -- socket timeout applies to every later read: `jobs.redis` waits on
    -- `BRPOP` for seconds at a time on purpose, and it must not inherit the
    -- connect budget.
    if config.connect_timeout then
      local connected, why = sock:connect(config.connect_timeout)
      if not connected then
        -- `onerror` above hands back a bare errno, which is not a diagnosis
        -- anyone should have to look up at three in the morning.
        error("redis: could not connect: " .. tostring(errno.strerror(why) or why), 0)
      end
    end

    local conn = setmetatable({ sock = sock }, Redis)
    if config.password then conn:command("AUTH", config.password) end
    if config.database then conn:command("SELECT", config.database) end
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
  end, {
    max_lifetime = config.max_lifetime,
    idle_timeout = config.idle_timeout,
    wait_timeout = config.pool_wait_timeout,
    open_timeout = config.connect_timeout and config.connect_timeout * 2 or nil,
  })
  return setmetatable({ pool = pool }, {
    __call = function() return pool:get() end,
  })
end

M.Redis = Redis
return M
