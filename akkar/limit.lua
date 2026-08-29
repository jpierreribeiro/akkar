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

## Whose bucket is it

A bucket name answers three questions, and for a long time it answered only
one. `prefix` was a constant, so two `limit.rate{}` middlewares on different
routes shared one bucket and whichever was tighter silently governed both.
There was no tenant, so in a multi-tenant application tenant A's user 7 spent
tenant B's user 7's allowance. So the key is now, in order:

    <prefix> <this limiter> <tenant> <caller>

length-prefixed, because `user:7` under `acme` and `user:7` under `evil` are
otherwise the same eleven characters. An unnamed limiter is identified by its
own settings; `name` separates two that are configured alike. `namespace` is
the tenant, and a single-tenant application leaves it out.

## When the store is the thing that broke

The script call carried no `pcall`, so a Redis blip answered **500** on every
rate-limited route -- a degraded dependency turned into a total outage of the
routes someone thought worth protecting. `on_error` names the choice instead:
`"open"` (the default) serves the request and logs it, `"closed"` answers 429.

## The limit that must be stated

**These require Redis.** Not "work better with"; require. The bucket is
arithmetic done inside a server-side script so that the read and the write
cannot be interleaved by another process, and `akkar.cache.memory` cannot run
a script at all -- `akkar.limit.scriptable(cache)` answers false for it.

So on the memory adapter a limiter does not degrade to a weaker limit. It
enforces NOTHING, and which way it fails is `on_error`: the default is open,
so `per_second = 1, burst = 1` serves every request it is given, with a
warning in the log. Measured, not inferred.

That is a defensible development default and it is not rate limiting, and the
distinction matters most in the deployment where somebody reaches for the
memory adapter to avoid running Redis. `akkar.limit.scriptable(cache)` is
there to be asked at boot; ask it, rather than discovering the answer from a
bill.
]]

local rand = require "openssl.rand"

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
--
-- A bucket name is assembled out of values several different parties choose,
-- so the pieces are LENGTH-PREFIXED rather than joined by a colon. Plain
-- concatenation makes `user:7` under tenant `acme` and `user:7` under tenant
-- `evil` the same eleven characters, and lets a user id that itself contains
-- a colon spell somebody else's bucket.
local function segment(value)
  value = tostring(value or "")
  return #value .. ":" .. value
end

--- Which tenant's budget this is.
---
--- Without it every tenant's user 7 spends one shared allowance -- the same
--- collision `akkar.scope` exists to remove on the database side. A constant
--- string or a resolver; absent means the application is single-tenant.
local function namespace_for(options, req)
  local namespace = options.namespace
  if namespace == nil then return "" end
  local value = type(namespace) == "function" and namespace(req) or namespace
  value = tostring(value or "")
  if value == "" then
    error("limit: namespace returned an empty value", 0)
  end
  return value
end

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

--- What to do when the STORE is the thing that failed.
---
--- The script call carried no `pcall`, so a Redis blip turned every
--- rate-limited route into a 500 -- converting a degraded dependency into a
--- total outage of exactly the routes someone thought worth protecting.
--- Neither answer is free, so the choice is named: `on_error = "open"` serves
--- the request unlimited (the default, because a limiter is a safeguard and a
--- safeguard that takes the site down is not one), `"closed"` refuses with
--- 429. Either way it is logged, because silently unlimited is how a limiter
--- is discovered to have been off for a week.
local function unavailable(options, req, which, err)
  local log = rawget(req, "log")
  if log then
    log:warn("limit: the store could not answer; " ..
             (options.on_error == "closed" and "refusing" or "serving unlimited"), {
      limiter = which, on_error = options.on_error or "open",
      error = tostring(err), path = req.path,
    })
  end
  return options.on_error == "closed"
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
---
--- `name` separates this limiter's buckets from another's. The default was a
--- constant prefix, so two `limit.rate{}` middlewares mounted on different
--- routes shared one bucket and the tighter configuration silently governed
--- both. Unnamed, a limiter's bucket carries its own settings, which keeps
--- differently-configured limiters apart; two identical ones deliberately
--- kept separate need a `name`.
function M.rate(options)
  options = options or {}
  local per_second = options.per_second or 10
  local burst      = options.burst or per_second
  local cost       = options.cost or 1
  local prefix     = options.prefix or "akkar:rate:"
  local bucket     = options.name
                     or (per_second .. "/" .. burst .. "/" .. cost)
  local run = evaluator(RATE_SCRIPT)     -- holds a SHA, never a connection

  return function(req, next)
    local cache = options.cache or req.cache
    local key = prefix .. segment(bucket)
              .. segment(namespace_for(options, req))
              .. segment(key_for(options, req))
    local ok, reply = pcall(run, cache, { key }, { burst, per_second, cost })
    if not ok or type(reply) ~= "table" then
      if unavailable(options, req, "rate", ok and "malformed reply" or reply) then
        return too_many(options.retry_after_ms or 1000)
      end
      return next(req)
    end
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
  local bucket = options.name or (limit .. "/" .. ttl)
  local acquire = evaluator(CONCURRENT_SCRIPT)
  local release = evaluator(RELEASE_SCRIPT)

  return function(req, next)
    local cache = options.cache or req.cache
    local key = prefix .. segment(bucket)
              .. segment(namespace_for(options, req))
              .. segment(key_for(options, req))

    -- The slot's name is minted HERE, not taken from `req.id`. The ZSET
    -- member is what a release deletes, and `req.id` is a value the caller
    -- can influence: send the id somebody else's in-flight request is
    -- holding and the release frees THEIR slot, letting the caller sit above
    -- the limit while the limiter's own count says it did not. A slot
    -- identity the caller can forge is not a slot identity, whatever the
    -- request id happens to be constrained to today.
    local slot = ("%s-%d"):format(rand.bytes(8):gsub(".", function(char)
      return string.format("%02x", char:byte())
    end), os.time())

    local acquired, reply = pcall(acquire, cache, { key }, { limit, ttl, slot })
    if not acquired or type(reply) ~= "table" then
      if unavailable(options, req, "concurrent",
                     acquired and "malformed reply" or reply) then
        return too_many(options.retry_after_ms or 1000)
      end
      return next(req)
    end
    if tonumber(reply[1]) ~= 1 then
      return too_many(options.retry_after_ms or 1000)
    end

    -- Released on EVERY exit, including a raised response and a handler
    -- error, for the same reason the connection pool releases on every exit:
    -- a slot that leaks on the error path leaks exactly when load is highest.
    local ok, result = pcall(next, req)
    pcall(function() release(cache, { key }, { slot }) end)
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
---       app = app, capacity = 500,
---       critical = function(req) return req.path:match "^/payments" end,
---     })
---
--- Both `app` and `capacity` are required, and that is a correction rather
--- than a preference. The in-flight count lives on the app object, so without
--- `app` this read 0 forever; the ceiling is a server setting that is never
--- published back onto the app, so `app.max_concurrent` was nil and the
--- comparison was skipped anyway. Its own docstring example passed neither,
--- nothing in the repo set them, and there was no spec -- so the shedder as
--- documented shed nothing, under any load, ever. Refusing to be built is the
--- only version of that a team finds out about.
function M.shed(options)
  options = options or {}
  local ceiling  = options.ceiling or 0.8   -- fraction of capacity
  local critical = options.critical or function() return false end
  local app      = options.app
  local capacity = options.capacity

  if type(app) ~= "table" then
    error("limit.shed: app is required -- the in-flight count it sheds on "
       .. "lives on the app object, and without it the shedder reads zero in "
       .. "flight and never sheds. Pass app = app.", 0)
  end
  if type(capacity) ~= "number" or capacity <= 0 then
    error("limit.shed: capacity is required -- how many requests in flight "
       .. "counts as loaded. app:run{ max_concurrent = n } is a server "
       .. "setting and is not readable from the app, so it has to be stated "
       .. "here: capacity = n.", 0)
  end

  return function(req, next)
    local in_flight = app.in_flight or 0
    if in_flight > capacity * ceiling and not critical(req) then
      return too_many(options.retry_after_ms or 1000)
    end
    return next(req)
  end
end

M.RATE_SCRIPT = RATE_SCRIPT
M.CONCURRENT_SCRIPT = CONCURRENT_SCRIPT
return M
