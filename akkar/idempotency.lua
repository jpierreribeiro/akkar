--[[
akkar.idempotency — the same request twice, charged once.

## The mistake it removes

A client posts. The response is slow, or the connection drops, or a proxy
times out at thirty seconds while the handler takes thirty-one. The client
does the only sensible thing and retries. The card is charged twice.

This is the most common distributed-systems bug in a JSON API, and it is not
the client's fault: it cannot distinguish "the request never arrived" from
"the response never came back". Only the server can, and only if it remembers.

Today every handler has to solve this individually, which means most will not.

## The shape, and where it lives

Middleware, not core -- the same argument as `akkar.cors`. Which requests are
idempotent, and for how long, is application knowledge.

    app:use(akkar.idempotency { ttl = 86400 })

    POST /charges
    Idempotency-Key: 8f14e45f-ea6e-4b3f-9c2a-1d2f3e4b5a60

The first request with a given key runs and its response is stored. A repeat
gets the stored response back -- the same status, the same body -- without the
handler running again.

## Four cases, and three of them are the interesting ones

**Repeat after completion.** Replays the stored response. The header
`idempotent-replay: true` says it was a replay, because a client that cannot
tell will not know whether its retry did anything.

**Repeat while the first is STILL RUNNING.** Answers **409**. Returning
nothing is wrong and running it twice is worse; 409 tells the client the
request it sent is in progress and to ask again shortly.

**Same key, different body.** Answers **422**. The key is a promise about
*which* request this is. Reusing it for different content is a client bug, and
silently replaying the first response would hide it at exactly the moment it
matters.

**The handler failed.** The key is **released**, not stored. Caching a 500
would mean the retry -- the whole point of the mechanism -- can never succeed.
Only 2xx is remembered.

## What this is not, and the limits worth stating

It is deduplication at the door, not an idempotent handler. If the handler
charges a card and then crashes before returning, the charge happened and
nothing here knows. That is a two-phase problem and needs the payment
processor's own idempotency key underneath this one.

**The guarantee is only as strong as the store.** With `akkar.cache.memory`
the record is per process, so a fleet of six deduplicates six times over --
which is not deduplication. With Redis it is shared and real, and
`akkar.limit.scriptable(cache)` says which one you have.

**A stored response has a size cap.** Beyond it the response is not kept, and
a repeat re-runs the handler. Refusing to store is better than an unbounded
write into a shared cache, and it is stated rather than discovered.
]]

local cjson = require "akkar.json"

local M = {}

-- Claim, replay, or refuse -- decided in one atomic step, because the whole
-- mechanism is read-then-write and the retry that matters is the one arriving
-- while the first request is still running.
-- TWO TTLs, and the difference is the whole point.
--
-- `lock_ttl` bounds the RUNNING record; the full `ttl` is set by STORE_SCRIPT
-- only once there is a stored response to replay.
--
-- With one TTL, a request abandoned mid-flight -- which is what a deadline
-- firing does, and a deadline firing is ordinary -- left the record `running`
-- for the whole day. Every retry then got 409 "already in progress" about a
-- request that had stopped existing, for twenty-four hours, from the module
-- whose entire purpose is to make the retry safe.
--
-- No code around the handler can fix that: an abandoned coroutine runs
-- nothing, so nothing it would have released is ever released. The lock has
-- to expire on its own, and it has to outlive a request rather than a day.
local CLAIM_SCRIPT = [[
local key         = KEYS[1]
local lock_ttl    = tonumber(ARGV[1])
local fingerprint = ARGV[2]

local found = redis.call('HMGET', key, 'state', 'fingerprint', 'status', 'body')
local state = found[1]

if not state then
  redis.call('HSET', key, 'state', 'running', 'fingerprint', fingerprint)
  redis.call('EXPIRE', key, lock_ttl)
  return { 'run' }
end

-- The key is a promise about WHICH request this is.
if found[2] ~= fingerprint then
  return { 'mismatch' }
end

if state == 'running' then
  return { 'running' }
end

return { 'done', found[3], found[4] }
]]

local STORE_SCRIPT = [[
redis.call('HSET', KEYS[1], 'state', 'done', 'status', ARGV[1], 'body', ARGV[2])
redis.call('EXPIRE', KEYS[1], tonumber(ARGV[3]))
return 1
]]

-- A handler that failed must not poison the key: the retry is the point.
local RELEASE_SCRIPT = [[ return redis.call('DEL', KEYS[1]) ]]

-- Reuses the evaluator discipline from `akkar.limit`: the cache handle is
-- passed at call time and never captured, because a captured handle belongs
-- to one request and goes back to the pool when that request ends.
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
      sha = nil
    end
    local reply = cache:command("EVAL", script, table.unpack(argv))
    local ok, digest = pcall(function() return cache:command("SCRIPT", "LOAD", script) end)
    if ok then sha = digest end
    return reply
  end
end

--- A stable summary of the request, so the same key with different content is
--- detectable.
---
--- Not a cryptographic hash: this distinguishes an honest client's retry from
--- an honest client's mistake, and it is not a defence against an attacker who
--- can already choose the key. Method and path are included because the same
--- key on a different route is the same class of error.
--- Serialises a value the same way in every process, for ever.
---
--- CJSON'S KEY ORDER IS NOT STABLE ACROSS PROCESSES, and the fingerprint was
--- built on it.
---
--- Lua tables are hashes, `cjson.encode` walks them in hash order, and the
--- hash seed differs per process. Measured: twelve processes, one identical
--- body, **twelve different fingerprints**.
---
--- What that does in production is precise and bad. A fleet shares one Redis.
--- A client retries -- which is the entire reason this module exists -- the
--- retry lands on a different worker, the fingerprint does not match the
--- stored one, and the module answers **422 "already used for a different
--- request"**. It refuses the honest retry it was written to make safe, and
--- it does so only in a fleet, only sometimes, and never on the developer's
--- single-process machine.
---
--- Found by an agent writing reference documentation who read the encoder and
--- asked whether it was ordered. It was not; the first check ran twelve
--- processes rather than twelve loops, because a single process cannot show
--- this at all.
---
--- Keys are sorted, and sorted by TYPE first so that a table with both
--- numeric and string keys cannot compare a number against a string and
--- raise. Depth is bounded because a fingerprint is not a serialiser and a
--- cyclic body should cost a refusal rather than a stack.
local function canonical(value, depth)
  depth = depth or 0
  if depth > 12 then return '"..."' end

  local kind = type(value)
  if kind == "table" then
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      if ta == "number" or ta == "string" then return a < b end
      return tostring(a) < tostring(b)
    end)

    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("%q", tostring(key)) .. ":" ..
                          canonical(value[key], depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  if kind == "string" then return string.format("%q", value) end
  if kind == "number" then
    -- `7` and `7.0` are the same request. A body that round-trips through
    -- JSON returns whole numbers as floats, so without this a retry could
    -- fail to match itself for that reason alone.
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
      return string.format("%d", value)
    end
    return tostring(value)
  end
  return tostring(value)
end

local function fingerprint_of(req)
  local body = ""
  if req.body ~= nil then
    local ok, encoded = pcall(canonical, req.body)
    body = ok and encoded or tostring(req.body)
  end
  return req.method .. " " .. req.path .. " " .. #body .. ":" ..
         tostring(body:sub(1, 512))
end

M.canonical = canonical

M.fingerprint_of = fingerprint_of

--- Middleware.
---
--- `methods` defaults to the ones that are not already idempotent by HTTP's
--- own definition: GET, HEAD, PUT and DELETE are, POST and PATCH are not.
function M.new(options)
  options = options or {}
  local ttl        = options.ttl or 86400
  -- How long a request may be "in progress" before the claim expires on its
  -- own. It must OUTLIVE a request and it must not outlive the day: sixty
  -- seconds against the 30-second default deadline. Raise it if you raised
  -- `timeout`, because a claim that expires while its request is still
  -- running lets a retry through beside it, which is the double charge this
  -- module prevents.
  local lock_ttl   = options.lock_ttl or 60
  local prefix     = options.prefix or "akkar:idem:"
  local header     = options.header or "idempotency-key"
  local max_bytes  = options.max_bytes or 64 * 1024
  local required   = options.required or false

  local methods = {}
  for _, m in ipairs(options.methods or { "POST", "PATCH" }) do
    methods[m:upper()] = true
  end

  local claim   = evaluator(CLAIM_SCRIPT)
  local store   = evaluator(STORE_SCRIPT)
  local release = evaluator(RELEASE_SCRIPT)

  local akkar = require "akkar"

  return function(req, next)
    if not methods[req.method] then return next(req) end

    local key = req.headers[header]
    if not key or #key == 0 then
      -- Absent by default is allowed: making every POST carry a key would
      -- break every existing client on the day this is switched on.
      if required then
        return akkar.bad_request(
          "this endpoint requires an " .. header .. " header")
      end
      return next(req)
    end
    if #key > 255 then
      return akkar.bad_request(header .. " must be at most 255 characters")
    end

    local cache = options.cache or req.cache
    local record = prefix .. key
    local fingerprint = fingerprint_of(req)

    local verdict = claim(cache, { record }, { lock_ttl, fingerprint })
    local state = verdict[1]

    if state == "mismatch" then
      return akkar.response(422, {
        error = "this " .. header .. " was already used for a different request",
      })
    end

    if state == "running" then
      -- Returning nothing is wrong and running it twice is worse.
      local res = akkar.conflict "a request with this key is already in progress"
      res.headers = { ["retry-after"] = "1" }
      return res
    end

    if state == "done" then
      local status = tonumber(verdict[2]) or 200
      local body = verdict[3]
      local decoded
      if body and #body > 0 then
        local ok, value = pcall(cjson.decode, body)
        decoded = ok and value or nil
      end
      local res = akkar.response(status, decoded)
      -- A client that cannot tell a replay from a fresh execution does not
      -- know whether its retry did anything.
      res.headers = { ["idempotent-replay"] = "true" }
      return res
    end

    -- We hold the claim. Anything that is not a stored 2xx must give it back,
    -- including a handler that raised -- otherwise the retry this exists to
    -- support is refused for the whole TTL.
    local ok, result = pcall(next, req)
    if not ok then
      pcall(function() release(cache, { record }, {}) end)
      error(result, 0)
    end

    -- A streamed response has no body yet: the bytes are produced after this
    -- middleware returns. Storing it recorded `status 200, body ""`, so a
    -- retry replayed an EMPTY 200 for the whole TTL -- including for an export
    -- whose producer died mid-body and left the client a truncated file. The
    -- retry is the entire point of this module, and that made it useless
    -- exactly when it was needed.
    --
    -- Not storable, so the claim goes back and a repeat re-runs the export.
    if result and result.stream then
      pcall(function() release(cache, { record }, {}) end)
      return result
    end

    local status = result and result.status or 200
    if status < 200 or status >= 300 then
      pcall(function() release(cache, { record }, {}) end)
      return result
    end

    local encoded = ""
    if result.body ~= nil then
      local encoded_ok, value = pcall(cjson.encode, result.body)
      encoded = encoded_ok and value or ""
    end

    if #encoded > max_bytes then
      -- Refusing to store beats an unbounded write into a shared cache. The
      -- guarantee is lost for this response and the caller is told so.
      pcall(function() release(cache, { record }, {}) end)
      local log = rawget(req, "log")
      if log then
        log:warn("idempotency: response too large to store", {
          bytes = #encoded, max_bytes = max_bytes, path = req.path,
        })
      end
      return result
    end

    pcall(function() store(cache, { record }, { status, encoded, ttl }) end)
    return result
  end
end

M.CLAIM_SCRIPT = CLAIM_SCRIPT
return M
