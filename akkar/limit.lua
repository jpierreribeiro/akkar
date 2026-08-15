--[[
akkar.limit — refusing fast instead of accepting slowly.

## The measurement that asked for this

The performance study measured `/users/42` at four configurations, changing
only how much concurrency was offered against a fixed pool:

    pool 10 (60 conns)   50 clients    10,933 req/s   p99    6.79ms
    pool 10 (60 conns)  100 clients    10,302 req/s   p99  396.09ms
    pool 30 (180 conns) 100 clients    10,923 req/s   p99   13.58ms
    pool 30 (180 conns) 200 clients     9,859 req/s   p99   51.12ms

Throughput is **flat**. Every configuration serves about eleven thousand
requests a second, and the only thing extra concurrency buys is queue -- which
the tail pays for, sixtyfold. A server past its capacity does not get faster by
accepting more; it gets slower at answering the work it already took.

So the honest response to load beyond capacity is to **refuse it immediately**,
and that is what this module does. It is the same conclusion Stripe published,
arrived at here from our own numbers rather than from theirs.

## Four limiters, and they answer different questions

Following the shape of Stripe's rate limiters, because the taxonomy is right:

    akkar.limit.rate         how many requests per second may this caller make
    akkar.limit.concurrent   how many AT ONCE may this caller have in flight
    akkar.limit.shed         drop low-priority work when the system is loaded

The second is the one our measurement argued for and the one most frameworks
lack. A caller making ten requests a second is fine; the same caller holding
fifty open connections against a pool of twenty is the p99 above.

## Why the algorithm lives in Redis

Every one of these is read-then-write: read the count, decide, write it back.
Between the read and the write, another process can do the same, and both
conclude there is room. The result is a limit that is not a limit.

Redis executes a script atomically -- nothing runs between the fetch and the
store -- so the decision happens where the state is. akkar sends these as
`EVAL`, and the scripts are **Lua**, which means a Lua framework's rate
limiter is written in the language it is already written in.

## The limit that must be stated

These are only as strong as the store behind them. With `akkar.cache.memory`
the counters are **per process**, so a fleet of six processes enforces six
times the configured limit. That is a useful development default and it is
not rate limiting. With Redis it is shared and real.

`akkar.limit` says which one it is at boot rather than leaving it to be
discovered under load.
]]

local M = {}

-- ===================================================================== token
-- The classic token bucket, and the reason it is the classic: it allows a
-- burst up to the bucket size while holding the long-run average at the
-- refill rate. A fixed window does neither -- it permits twice the limit
-- across a window boundary and refuses legitimate bursts inside one.
--
-- Timestamps come from Redis (`TIME`) rather than from the caller, so a
-- client with a wrong clock, or six processes with slightly different ones,
-- cannot move the window.
local RATE_SCRIPT = [[
local key      = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill   = tonumber(ARGV[2])   -- tokens per second
local cost     = tonumber(ARGV[3])

local now = redis.call('TIME')
now = tonumber(now[1]) + tonumber(now[2]) / 1000000

local bucket = redis.call('HMGET', key, 'tokens', 'at')
local tokens = tonumber(bucket[1])
local at     = tonumber(bucket[2])

if tokens == nil then
  tokens = capacity
  at = now
end

-- Refill for the elapsed time, never above capacity.
local elapsed = math.max(0, now - at)
tokens = math.min(capacity, tokens + elapsed * refill)

local allowed = 0
local retry_after = 0
if tokens >= cost then
  tokens = tokens - cost
  allowed = 1
else
  retry_after = (cost - tokens) / refill
end

redis.call('HMSET', key, 'tokens', tokens, 'at', now)
-- Expire once the bucket would be full again: an idle caller costs nothing,
-- and a key that never expires is a memory leak with a respectable name.
redis.call('EXPIRE', key, math.ceil(capacity / refill) + 1)

return { allowed, math.floor(tokens), math.floor(retry_after * 1000) }
]]

-- =============================================================== concurrent
-- A sorted set of in-flight request ids scored by when they started.
--
-- The expiry is what makes this survivable. A handler that dies without
-- releasing its slot would hold it forever, and a limiter that leaks slots
-- eventually refuses everything -- strictly worse than no limiter. Entries
-- older than the TTL are dropped on every acquire, so a lost release costs
-- one slot for one TTL rather than for the life of the process.
local CONCURRENT_SCRIPT = [[
local key     = KEYS[1]
local limit   = tonumber(ARGV[1])
local ttl     = tonumber(ARGV[2])
local id      = ARGV[3]

local now = redis.call('TIME')
now = tonumber(now[1]) + tonumber(now[2]) / 1000000

redis.call('ZREMRANGEBYSCORE', key, '-inf', now - ttl)
local count = redis.call('ZCARD', key)

if count >= limit then
  return { 0, count }
end

redis.call('ZADD', key, now, id)
redis.call('EXPIRE', key, math.ceil(ttl) + 1)
return { 1, count + 1 }
]]

local RELEASE_SCRIPT = [[
redis.call('ZREM', KEYS[1], ARGV[1])
return redis.call('ZCARD', KEYS[1])
]]

-- ====================================================================== eval
--
-- `EVALSHA` first, `EVAL` on a miss. Sending the whole script every request
-- would put a kilobyte on the wire for a decision measured in microseconds.
--
-- The cache handle is passed in at CALL time and never captured. Capturing it
-- was the first version, and it is the same defect this project just fixed in
-- `akkar.db`: the handle belongs to one request, goes back to the pool when
-- that request ends, and every later request then issues commands down a
-- connection somebody else owns. On Redis that interleaves two conversations
-- on one socket, which is exactly the RESP desynchronisation the abandoned-
-- connection fix was about. A concurrency test caught it by serving one
-- request where two were allowed.
local function evaluator(script)
  local sha
  return function(cache, keys, args)
    local argv = { #keys }
    for _, k in ipairs(keys) do argv[#argv + 1] = k end
    for _, a in ipairs(args) do argv[#argv + 1] = a end

    if sha then
      local ok, reply = pcall(function()
        return cache:command("EVALSHA", sha, table.unpack(argv))
      end)
      if ok then return reply end
      sha = nil                       -- flushed, or a different server
    end

    local reply = cache:command("EVAL", script, table.unpack(argv))
    local ok, digest = pcall(function() return cache:command("SCRIPT", "LOAD", script) end)
    if ok then sha = digest end
    return reply
  end
end

--- True when the store can run scripts at all.
---
--- `akkar.cache.memory` cannot, and rather than silently degrading to a
--- per-process counter that looks like a limit, the caller is told which one
--- it is getting.
local function scriptable(cache)
  local ok = pcall(function() return cache:command("EVAL", "return 1", "0") end)
  return ok
end

M.scriptable = scriptable

-- ================================================================ middleware
local function key_for(options, req)
  if options.key then return options.key(req) end
  -- The default is the authenticated caller when there is one and the client
  -- address otherwise. Never the path: limiting per path lets one caller
  -- exhaust every route in turn.
  -- `req.user` is never nil: an app with no authentication middleware gets a
  -- GUARD object there, whose whole job is to raise a useful message when
  -- read. `rawget` returns the guard, `type()` says table, and `.id` then
  -- raises -- so the default key function blew up on every request in every
  -- app without auth, which is most of them. No test caught it because every
  -- earlier test supplied its own `key`.
  local ok, id = pcall(function()
    local user = req.user
    return type(user) == "table" and user.id or nil
  end)
  if ok and id then return "user:" .. tostring(id) end

  -- `req.ip` is the SOCKET's peer, and honours `X-Forwarded-For` only when the
  -- connection came from a proxy the application named in
  -- `app:run { trusted_proxies = ... }`.
  --
  -- This used to read the header directly, which meant any caller could send
  -- a fresh value per request and mint a fresh bucket each time -- a rate
  -- limiter defeated by one header. Found by asking what a real admin IP
  -- allowlist would need and discovering the framework had no answer.
  return "ip:" .. tostring(req.ip or "unknown")
end

local function too_many(retry_after_ms)
  local seconds = math.max(1, math.ceil((retry_after_ms or 1000) / 1000))
  local res = require("akkar").response(429, {
    error = "too many requests",
    retry_after = seconds,
  })
  -- `Retry-After` is the difference between a client that backs off and a
  -- client that hammers a server which is already saying no.
  res.headers = { ["retry-after"] = tostring(seconds) }
  return res
end

--- Requests per second, with a burst.
---
---     app:use(akkar.limit.rate { per_second = 10, burst = 20 })
function M.rate(options)
  options = options or {}
  local per_second = options.per_second or 10
  local burst      = options.burst or per_second
  local cost       = options.cost or 1
  local prefix     = options.prefix or "akkar:rate:"
  local run = evaluator(RATE_SCRIPT)     -- holds a SHA, never a connection

  return function(req, next)
    local cache = options.cache or req.cache
    local reply = run(cache, { prefix .. key_for(options, req) },
                      { burst, per_second, cost })
    if tonumber(reply[1]) ~= 1 then
      return too_many(tonumber(reply[3]))
    end
    return next(req)
  end
end

--- How many requests one caller may have IN FLIGHT at once.
---
--- This is the one the study argued for. A caller making ten requests a
--- second is fine; the same caller holding fifty open against a pool of
--- twenty is a p99 of 396ms for everybody.
---
---     app:use(akkar.limit.concurrent { limit = 5 })
function M.concurrent(options)
  options = options or {}
  local limit  = options.limit or 10
  local ttl    = options.ttl or 30      -- a slot cannot be held longer
  local prefix = options.prefix or "akkar:concurrent:"
  local acquire = evaluator(CONCURRENT_SCRIPT)
  local release = evaluator(RELEASE_SCRIPT)

  return function(req, next)
    local cache = options.cache or req.cache
    local key = prefix .. key_for(options, req)
    local reply = acquire(cache, { key }, { limit, ttl, req.id })
    if tonumber(reply[1]) ~= 1 then
      return too_many(options.retry_after_ms or 1000)
    end

    -- Released on EVERY exit, including a raised response and a handler
    -- error, for the same reason the connection pool releases on every exit:
    -- a slot that leaks on the error path leaks exactly when load is highest.
    local function give_back()
      pcall(function() release(cache, { key }, { req.id }) end)
    end

    local ok, result = pcall(next, req)

    -- A STREAM HAS NOT WRITTEN A BYTE WHEN THIS RETURNS. The producer runs
    -- later, on the server's write path, and it holds the database connection
    -- for as long as the client takes to read. Releasing the slot here left
    -- streams as the one shape this module did not limit -- precisely the
    -- scenario it was built from, since a slow reader on an export is exactly
    -- the caller who should be counted.
    --
    -- So the release is DEFERRED onto the response, and COMPOSED rather than
    -- overwritten: another middleware may already have deferred work of its
    -- own, and akkar's dispatch composes ours with `release_all` in turn.
    -- The TTL on the slot remains the backstop for a body nobody ever reads.
    if ok and type(result) == "table" and result.stream then
      local deferred = result.release
      result.release = function()
        if deferred then pcall(deferred) end
        give_back()
      end
      return result
    end

    give_back()
    if not ok then error(result, 0) end
    return result
  end
end

--- Sheds work by declared priority when the system is loaded.
---
--- Deliberately NOT the fleet-wide worker-utilisation shedder: that needs to
--- know how many workers across the fleet are busy, and akkar has no such
--- number. What it has is its own in-flight count, which is honest and local.
---
---     app:use(akkar.limit.shed {
---       critical = function(req) return req.path:match "^/payments" end,
---     })
function M.shed(options)
  options = options or {}
  local ceiling  = options.ceiling or 0.8   -- fraction of max_concurrent
  local critical = options.critical or function() return false end

  return function(req, next)
    local app = options.app
    local in_flight = app and app.in_flight or 0
    local capacity  = options.capacity or (app and app.max_concurrent)

    if capacity and in_flight > capacity * ceiling and not critical(req) then
      return too_many(options.retry_after_ms or 1000)
    end
    return next(req)
  end
end

M.RATE_SCRIPT = RATE_SCRIPT
M.CONCURRENT_SCRIPT = CONCURRENT_SCRIPT
return M
