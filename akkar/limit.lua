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

## Three limiters here, against the four Stripe published

The taxonomy is right, so it is followed. The heading used to say "four" and
then list three, which is the kind of small lie that makes a reader stop
trusting the rest of a comment, so it says what is here:

    akkar.limit.rate         how many requests per second may this caller make
    akkar.limit.concurrent   how many AT ONCE may this caller have in flight
    akkar.limit.shed         drop low-priority work when the system is loaded

The second is the one our measurement argued for and the one most frameworks
lack. A caller making ten requests a second is fine; the same caller holding
fifty open connections against a pool of twenty is the p99 above.

The fourth -- the fleet-wide WORKER UTILISATION shedder -- is deliberately
absent, and `M.shed` says so at the point where somebody would look for it:
it needs to know how many workers across the whole fleet are busy, and akkar
has no such number. Shipping an approximation of it under the same name would
be worse than not having it, because it would be trusted.

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

## When the store is unreachable, the request is ALLOWED

This module used to do the opposite, and it was the worst defect in it.

Every decision here is a round trip to Redis, and every round trip can fail.
The code ran that round trip unprotected -- `evaluator` sends `EVAL` with no
`pcall` around it -- so a refused connection, a timeout, a `LOADING` reply
during a replica promotion, or a `MISCONF` while Redis could not fork for its
own snapshot all came out as a raised Lua error. That error left the
middleware, and `handle` turned it into **500 for every request in the
fleet**. The rate limiter, whose entire purpose is to keep a server answering
when something is wrong, was the thing that stopped it answering.

Read the trade honestly, because it is a trade. Failing open means that
during a cache outage a caller can exceed its quota, and that is a real cost:
if the limiter is the only thing standing between a scraper and the database,
the scraper gets through for the length of the outage. Failing closed means
that during a cache outage **nobody** gets through -- a total outage caused by
a dependency that was never on the critical path for answering a request.
The second failure is larger than the first by the whole size of the traffic,
so the store's opinion is treated as advice: when it cannot be obtained, the
request proceeds.

Silence is the part that would make this dangerous, so it is not silent:

  * every failed store call increments `akkar.limit.store_failures`, a
    process-wide count an operator can scrape and alert on -- "limiter blind"
    is exactly the condition worth paging for, since it is the window in which
    the configured limits are not being enforced;
  * the first failure of an outage is logged at warn, and one is logged again
    each time the store recovers and fails afresh. Logging every request would
    bury the log under precisely the traffic the limiter was meant to be
    counting, which is the same reasoning `shed` uses for its `warned` flag;
  * `on_store_error = function(err, req) ... end` hands the failure to the
    application, for a Sentry breadcrumb or a counter of its own.

A store that was never configured is a DIFFERENT failure and is not treated
this way -- see `usable` below.
]]

local M = {}

--- How many store calls have failed, process-wide, since this process
--- started.
---
--- Process-wide rather than per-middleware because that is the number an
--- operator wants: "is anything in this process failing to reach the limiter's
--- store". A fleet aggregates it the same way it aggregates every other
--- counter, by scraping each process.
---
--- Deliberately a plain field rather than a `metrics` registration:
--- `akkar.metrics` has counters only for requests and gauges only for named
--- values, and reaching into it from here would couple a limiter to a metrics
--- module it does not otherwise need. An application that wants this on
--- `/metrics` reads the field into a gauge in one line.
M.store_failures = 0

-- ===================================================================== token
-- The classic token bucket, and the reason it is the classic: it allows a
-- burst up to the bucket size while holding the long-run average at the
-- refill rate.
--
-- WHY NOT A FIXED-WINDOW COUNTER, with the arithmetic rather than the slogan.
-- A fixed window is `INCR key:<floor(now)>` with an expiry, and it is four
-- lines shorter than this script. It is also wrong at both ends.
--
-- It permits TWICE the configured limit across a boundary. Configure 100 per
-- second: a caller sends 100 requests at t = 0.999, which fills the window
-- named `0`, then 100 more at t = 1.001, which fills the fresh window named
-- `1`. Two hundred requests landed inside two milliseconds and every one of
-- them was inside the limit as the counter understands it. The server that
-- was sized for 100/s just took 200 in the interval that matters, which is
-- the interval short enough to queue. `spec/limit_spec.lua` pins exactly this
-- sequence against the bucket and shows the second half refused.
--
-- It also refuses legitimate work at the other end: a caller who spent its
-- window at t = 0.1 waits 900 ms doing nothing, while the window it is
-- waiting for sits idle. A bucket refills continuously, so the same caller
-- resumes as soon as it has earned a token -- and the two properties are the
-- same property, because a bucket meters the RATE rather than a tally that
-- happens to be reset by a clock the caller can see.
--
-- The whole decision is one `EVAL`. Read-then-write across the network is
-- the classic lost update: two processes both read 99, both decide there is
-- room, both write 100, and 101 requests were served. Redis runs a script
-- with nothing interleaved, so the read and the write cannot be separated by
-- another caller's read.
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

-- The fourth value is how long until the bucket is FULL again, which is what
-- `RateLimit-Reset` means: the moment the caller's whole quota is back. It is
-- not the same number as `retry_after`, which is the wait for the ONE token
-- this request wanted, and a client told the second when it asked for the
-- first waits far longer than it needed to.
local reset = (capacity - tokens) / refill

return { allowed, math.floor(tokens), math.floor(retry_after * 1000),
         math.floor(reset * 1000) }
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

-- ================================================================ fail open
--
-- TWO FAILURES THAT LOOK IDENTICAL FROM HERE, and telling them apart is the
-- whole of this section.
--
-- One is "the store broke": a connection refused, a timeout, `LOADING` during
-- a failover. It is transient, it is not the application's fault, and the
-- answer is to allow the request and shout -- see the header comment.
--
-- The other is "there is no store": `app:run{}` was never given a `cache`, so
-- `req.cache` is the GUARD object, whose whole job is to raise a message
-- telling you which option is missing. Failing open on THAT would mean an
-- application that believes it is rate limited, is not, and never finds out;
-- the limiter would be a decoration installed in good faith. It is the same
-- class of mistake `shed` refuses at construction time, and it gets the same
-- treatment: raise, loudly, with the fix in the message.
--
-- The guard cannot be recognised by looking at it -- reading ANY field raises,
-- including the one you would test -- so the probe is the read itself, inside
-- `pcall`. A real cache answers `type(cache.command) == "function"`; the
-- guard raises before answering; a nil cache is false without raising.
local function usable(cache)
  local ok, yes = pcall(function()
    return type(cache) == "table" and type(cache.command) == "function"
  end)
  return ok and yes == true
end

local function no_cache_at_all(where)
  error("akkar.limit." .. where .. " has no cache to count in: pass " ..
        "`cache = ...` to app:run{} (or `cache = ...` in the limiter's own " ..
        "options). A limiter with no store cannot limit anything, and " ..
        "quietly allowing every request would hide that.", 0)
end

--- Runs one limiter script, and ALLOWS the request when the store cannot
--- answer.
---
--- Returns the reply, or nil when the store failed. Every caller reads a nil
--- as "allow": that is the fail-open decision, made in one place so no
--- limiter can forget it.
---
--- `state` is the middleware instance's own table, and it holds nothing but
--- the "have I already complained about this outage" flag. Kept per instance
--- rather than per module so two limiters with two different stores each get
--- to report their own.
local function attempt(run, cache, keys, args, options, req, state, where)
  if not usable(cache) then no_cache_at_all(where) end

  local ok, reply = pcall(run, cache, keys, args)

  -- A reply of the wrong SHAPE is counted as a failure too, and this is not
  -- defensive decoration. `akkar.redis` raises on an error reply, so the
  -- shape is right whenever the call succeeded -- but a `SCRIPT FLUSH`
  -- racing an `EVALSHA`, or an adapter somebody else wrote, can hand back
  -- something that is not an array. Reading `reply[1]` off a string raises
  -- inside the middleware, and that error is a 500: the exact failure this
  -- whole section exists to stop, reintroduced one line further down.
  if ok and type(reply) == "table" then
    state.blind = false
    return reply
  end
  if ok then reply = "store answered " .. type(reply) .. ", expected an array" end

  M.store_failures = M.store_failures + 1

  if not state.blind then
    state.blind = true
    -- `req.log` always exists -- it is the one capability with a default --
    -- so this cannot be the thing that raises while reporting that something
    -- raised.
    local logged = pcall(function()
      req.log:warn("rate limiter store is unreachable; ALLOWING requests", {
        limiter = where,
        detail  = tostring(reply),
        effect  = "configured limits are not being enforced until this clears",
        store_failures = M.store_failures,
      })
    end)
    if not logged then state.blind = false end   -- try again next request
  end

  if options.on_store_error then
    pcall(options.on_store_error, reply, req)
  end

  return nil
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

--- True when the store is shared across every process that talks to it.
---
--- The question `scriptable` used to stand in for. It stopped standing in for
--- it when `akkar.cache.memory` learned to run scripts -- which it did so
--- that these limiters could be tested without a Redis, and which does not
--- make its counters any less per-process.
---
--- This is the one to check before believing a limit is a limit. With a
--- per-process store, a fleet of six enforces six times what was configured:
--- a useful development default, and not rate limiting.
function M.shared(cache)
  if not cache then return false end
  if cache.per_process then return false end
  return scriptable(cache)
end

-- ================================================================ middleware
--
-- WHOSE BUCKET IS IT. A bucket name answers three questions, and for a long
-- time it answered only one. `prefix` was a constant default, so two
-- `limit.rate{}` middlewares mounted on different routes shared one bucket
-- and whichever was tighter silently governed both. There was no tenant
-- component either, so in a multi-tenant application tenant `acme`'s user 7
-- spent tenant `evil`'s user 7's allowance. The key is now, in order:
--
--     <prefix> <this limiter> <tenant> <caller>
--
-- and the pieces are LENGTH-PREFIXED rather than joined by a colon, because
-- several different parties choose them. Plain concatenation makes tenant
-- `acme` + caller `user:7` and tenant `ac` + caller `me:user:7` the same
-- eleven characters, and lets a caller id that itself contains a colon spell
-- somebody else's bucket.
local function segment(value)
  value = tostring(value or "")
  return #value .. ":" .. value
end

--- Which tenant's budget this is.
---
--- Without it every tenant's user 7 spends one shared allowance -- the same
--- collision `akkar.scope` exists to remove on the database side. A constant
--- string or a resolver; absent means the application is single-tenant.
---
--- An empty resolution raises rather than falling back to the shared bucket:
--- a namespace that silently resolves to "" is the multi-tenant collision
--- coming back at exactly the moment the resolver stopped working.
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

--- The whole bucket name, assembled once so the two limiters cannot drift.
local function bucket_key(prefix, bucket, options, req)
  return prefix .. segment(bucket)
                .. segment(namespace_for(options, req))
                .. segment(key_for(options, req))
end

-- ========================================================== response metadata
--
-- A limit a client cannot see is a limit it can only discover by tripping.
-- The three quota headers let a well-behaved caller pace itself and stop
-- before the 429, which is worth more to both sides than the 429 is.
--
-- The names are the IETF draft's (`draft-ietf-httpapi-ratelimit-headers`) and
-- not the `X-RateLimit-` spelling several APIs still ship, because RFC 6648
-- deprecated the `X-` convention in 2012 and an unprefixed name is what a
-- future client library will look for. Lowercase, because that is how every
-- other header in this framework is written and HTTP/2 requires it on the
-- wire anyway.
--
--     ratelimit-limit        the bucket's capacity -- the largest burst
--     ratelimit-remaining    tokens left after this request
--     ratelimit-reset        seconds until the bucket is full again
--
-- `retry-after` is separate and is only sent on a refusal, per RFC 9110: it
-- is an instruction, and sending one alongside a 200 would be telling a
-- client to back off from a request that just succeeded.
local function quota_headers(limit, remaining, reset_ms)
  return {
    ["ratelimit-limit"]     = tostring(limit),
    ["ratelimit-remaining"] = tostring(math.max(0, remaining or 0)),
    ["ratelimit-reset"]     = tostring(math.max(0, math.ceil((reset_ms or 0) / 1000))),
  }
end

--- Returns a response carrying `extra` headers. NEVER the same table.
---
--- akkar handlers RETURN responses, and the framework refuses to write on
--- what they returned: `akkar/init.lua` explains, at the point where it
--- declines to stamp the request id, that a handler is free to return a
--- hoisted or memoised value -- a constant 404, a cached payload -- and that
--- one table is then shared by every request that reaches it. Writing
--- `ratelimit-remaining` onto it means request A's remaining quota is read by
--- request B, off by however many requests happened in between, and the bug
--- is invisible because the header is *plausible*. The same aliasing bit this
--- module once already, on `release`.
---
--- So this copies, and it copies the whole response rather than only status
--- and body:
---
---   * `stream` and its friends, or a streamed export would arrive as an
---     empty 200 the moment a rate limiter was installed in front of it;
---   * `release`, which is the deferred work `M.concurrent` and the framework
---     hang off a streamed response -- dropping it leaks a pool slot;
---   * `__pending`, which is how a handler's raised error travels out to
---     `app:on_error` after the request's capabilities are released. A copy
---     that forgot it would silently switch off every application's error
---     hook for any route behind a limiter.
---
--- A header the response already carries WINS. The framework does the same
--- with `x-request-id` and `traceparent`: a value the application set
--- deliberately is the one it meant, and quietly replacing it is how
--- middleware becomes untrustworthy.
---
--- READ THROUGH THE METATABLE, not around it. These were `rawget` calls, and
--- what `next(req)` returns is no longer always a plain table: `akkar/init.lua`
--- hands middleware a copy-on-write VIEW of the response, so that decorating
--- it cannot write on a response the handler hoisted. A view carries none of
--- these fields raw, so `rawget` read nil for every one of them and this
--- built a response with no status and no body. `akkar.Response` declares no
--- methods, so for a plain response the two spellings are the same read.
local function copy_of(res, extra)
  local headers = {}
  for name, value in pairs(extra or {}) do headers[name] = value end
  local existing = res.headers
  if existing then
    for name, value in pairs(existing) do headers[name] = value end
  end

  local copy = require("akkar").response(res.status, res.body, headers)
  copy.stream       = res.stream
  copy.content_type = res.content_type
  copy.raw          = res.raw
  copy.release      = res.release
  copy.__pending    = res.__pending
  return copy
end

local function with_headers(res, extra)
  if type(res) ~= "table" or not extra then return res end
  return copy_of(res, extra)
end

local function too_many(retry_after_ms, extra)
  local seconds = math.max(1, math.ceil((retry_after_ms or 1000) / 1000))
  local res = require("akkar").response(429, {
    error = "too many requests",
    retry_after = seconds,
  })
  -- `Retry-After` is the difference between a client that backs off and a
  -- client that hammers a server which is already saying no.
  local headers = { ["retry-after"] = tostring(seconds) }
  for name, value in pairs(extra or {}) do
    if headers[name] == nil then headers[name] = value end
  end
  res.headers = headers
  return res
end

--- Requests per second, with a burst.
---
---     app:use(akkar.limit.rate { per_second = 10, burst = 20 })
---
--- `headers = false` suppresses the `ratelimit-*` metadata, for a service
--- that would rather not publish its quota. It is on by default because a
--- client that cannot see the limit cannot respect it.
---
--- `namespace` is the tenant whose budget this is -- a constant string or a
--- resolver called with the request; a single-tenant application leaves it
--- out. `name` separates two limiters that are configured alike but meant to
--- be counted apart.
function M.rate(options)
  options = options or {}
  local per_second = options.per_second or 10
  local burst      = options.burst or per_second
  local cost       = options.cost or 1
  local prefix     = options.prefix or "akkar:rate:"
  -- Unnamed, a limiter's bucket carries its own settings, which is what keeps
  -- a one-per-second limiter on /reset out of a hundred-per-second limiter's
  -- allowance. Two limiters deliberately configured alike but meant to be
  -- counted apart need a `name`.
  local bucket     = options.name
                     or (per_second .. "/" .. burst .. "/" .. cost)
  local announce   = options.headers ~= false
  local run = evaluator(RATE_SCRIPT)     -- holds a SHA, never a connection
  local state = {}                       -- outage flag; never a connection

  -- HEALTH CHECKS ARE EXEMPT BY DEFAULT, and this is a defect being fixed
  -- rather than a convenience being added.
  --
  -- A global rate limiter counts the orchestrator's probes along with
  -- everybody else's traffic. Twelve requests to `/health/live` inside the
  -- window answer 429; Kubernetes reads a 429 as a failed probe, and it
  -- restarts a process that was perfectly healthy -- then does it again to the
  -- replacement, because the limiter is shared. The protective feature causes
  -- the outage.
  --
  -- Found by someone writing the guide's resilience page, who had to show the
  -- 429 first and then four lines of exemption. A page teaching a workaround
  -- for the framework's default is the framework getting the default wrong.
  --
  -- Prefix match rather than an exact list, because `/health/live`,
  -- `/health/ready` and `/healthz` are all in the wild and nobody should have
  -- to discover which spelling this module happened to pick. `exempt = false`
  -- turns it off; `exempt = { "/internal/" }` replaces the list.
  local exempt = options.exempt
  if exempt == nil then exempt = { "/health", "/healthz", "/livez", "/readyz" } end

  local function is_exempt(path)
    if exempt == false or type(path) ~= "string" then return false end
    for _, prefix_ in ipairs(exempt) do
      if path:sub(1, #prefix_) == prefix_ then return true end
    end
    return false
  end

  return function(req, next)
    -- Before the store is touched at all: an exempt path must not cost a
    -- round trip either, since a probe every second against a shared Redis is
    -- a load nobody asked for.
    if is_exempt(req.path) then return next(req) end

    local cache = options.cache or req.cache
    local reply = attempt(run, cache, { bucket_key(prefix, bucket, options, req) },
                          { burst, per_second, cost }, options, req, state,
                          "rate")

    -- nil is the store failing, and the answer is to serve the request. No
    -- quota headers go out with it: the numbers are unknown, and inventing a
    -- remaining count would be a lie a well-behaved client would then pace
    -- itself against.
    if reply == nil then return next(req) end

    local remaining = tonumber(reply[2]) or 0
    if tonumber(reply[1]) ~= 1 then
      -- The refusal carries the quota too. A 429 is the request most likely
      -- to be read by a human debugging their client.
      return too_many(tonumber(reply[3]),
                      announce and quota_headers(burst, remaining, tonumber(reply[4])))
    end

    local res = next(req)
    if not announce then return res end
    return with_headers(res, quota_headers(burst, remaining, tonumber(reply[4])))
  end
end

--- How many requests one caller may have IN FLIGHT at once.
---
--- This is the one the study argued for. A caller making ten requests a
--- second is fine; the same caller holding fifty open against a pool of
--- twenty is a p99 of 396ms for everybody.
---
---     app:use(akkar.limit.concurrent { limit = 5 })
---
--- Takes `name` and `namespace` on the same terms as `M.rate`.
function M.concurrent(options)
  options = options or {}
  local limit  = options.limit or 10
  local ttl    = options.ttl or 30      -- a slot cannot be held longer
  local prefix = options.prefix or "akkar:concurrent:"
  local bucket = options.name or (limit .. "/" .. ttl)
  local acquire = evaluator(CONCURRENT_SCRIPT)
  local release = evaluator(RELEASE_SCRIPT)
  local state = {}

  return function(req, next)
    local cache = options.cache or req.cache
    local key = bucket_key(prefix, bucket, options, req)
    local reply = attempt(acquire, cache, { key }, { limit, ttl, req.id },
                          options, req, state, "concurrent")

    -- The store is down: serve, and do not try to release a slot that was
    -- never taken. Releasing anyway would be a second failed call per
    -- request, doubling the counter for one outage and making the metric
    -- describe the code rather than the world.
    if reply == nil then return next(req) end

    if tonumber(reply[1]) ~= 1 then
      -- No `ratelimit-*` here, on purpose. Those headers describe a quota
      -- that refills with TIME, and a concurrency slot does not: it comes
      -- back when one of this caller's own in-flight requests finishes, which
      -- may be sooner or very much later than any number this middleware
      -- could put in `ratelimit-reset`. `retry-after` is a hint and is
      -- honest as one; a remaining-quota count would be a measurement, and it
      -- would be wrong.
      return too_many(options.retry_after_ms or 1000)
    end

    -- Released on EVERY exit, including a raised response and a handler
    -- error, for the same reason the connection pool releases on every exit:
    -- a slot that leaks on the error path leaks exactly when load is highest.
    --
    -- A release that FAILS is counted, and it is the failure worth counting
    -- most. The acquire failing costs a moment of unlimited traffic; the
    -- release failing costs a SLOT, held by a request that has already
    -- finished, and a limiter that keeps losing slots eventually refuses
    -- everything -- strictly worse than no limiter at all. The `ZREMRANGE`
    -- sweep in the acquire script bounds the damage at one TTL, so this
    -- raises no error; it only makes sure the operator can see it happening.
    local function give_back()
      local ok = pcall(function() release(cache, { key }, { req.id }) end)
      if not ok then M.store_failures = M.store_failures + 1 end
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
    --
    -- ON A COPY, never on the table the handler returned. This line used to
    -- be `result.release = ...`, which is precisely the aliasing the
    -- framework refuses to commit two files away: `akkar/init.lua` copies the
    -- response before hanging `release` on it, and says why -- a handler
    -- returning a hoisted or memoised value hands every request the SAME
    -- table, so request B's closure overwrites request A's and A's slot is
    -- never given back while B's is given back twice. A streamed export is
    -- exactly the handler somebody hoists, because the producer closure is
    -- the interesting part and the response wrapper looks like a constant.
    if ok and type(result) == "table" and result.stream then
      -- Through the metatable, for the reason `copy_of` records: what came
      -- back from `next` may be a copy-on-write view of the response.
      local deferred = result.release
      local streamed = copy_of(result)
      streamed.release = function()
        if deferred then pcall(deferred) end
        give_back()
      end
      return streamed
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

  -- REFUSED AT CONSTRUCTION rather than degraded into a no-op. Given neither
  -- an app to read nor an explicit capacity, this middleware cannot ever shed,
  -- and an installed shedder that never sheds is the exact failure it exists
  -- to prevent -- discovered under the load it was supposed to survive. The
  -- framework's habit is to make the misconfiguration loud at boot, the way a
  -- duplicate route and an unknown `run{}` option already are.
  if not options.capacity and not options.app then
    error("akkar.limit.shed needs `app = app`, so it can read the in-flight " ..
          "count and the concurrency ceiling, or an explicit `capacity`. " ..
          "With neither it can never shed.", 2)
  end

  local warned = false

  return function(req, next)
    local app = options.app
    local in_flight = app and app.in_flight or 0
    local capacity  = options.capacity or (app and app.max_concurrent)

    -- An app whose ceiling could not be derived -- `max_concurrent` unset and
    -- `/proc/self/limits` unreadable, which is every platform that is not
    -- Linux -- reaches here with no capacity. Say so once. Saying it per
    -- request would bury the log under the load being shed.
    if not capacity then
      if not warned then
        warned = true
        req.log:warn("shed is installed but has no capacity to measure against", {
          hint = "pass capacity = N, or run on a platform where the descriptor "
              .. "ceiling can be read, or set app:run { max_concurrent = N }",
        })
      end
      return next(req)
    end

    if in_flight > capacity * ceiling and not critical(req) then
      return too_many(options.retry_after_ms or 1000)
    end
    return next(req)
  end
end

M.RATE_SCRIPT = RATE_SCRIPT
M.CONCURRENT_SCRIPT = CONCURRENT_SCRIPT
return M
