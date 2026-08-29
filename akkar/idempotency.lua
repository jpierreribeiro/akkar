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

    app:use(akkar.idempotency {
      ttl = 86400,
      namespace = function(req) return req.tenant.id end,
    })

    POST /charges
    Idempotency-Key: 8f14e45f-ea6e-4b3f-9c2a-1d2f3e4b5a60

The first request with a given key runs and its response is stored. A repeat
gets the stored response back -- the same status, the same body -- without the
handler running again.

**`namespace` is not optional, and that is the point.** The key is a header
the CLIENT chooses, so a single global keyspace means tenant `evil` sends
tenant `acme`'s key and is handed acme's stored 201 verbatim -- customer
email, card last four, all of it -- with `idempotent-replay: true` on it. The
namespace is what makes the keyspace the server's. Construction raises without
one; `namespace = false` is the explicit "this application is single-tenant"
opt-out, written down rather than inherited. `akkar.scope` refuses a nil tenant
id for the same reason.

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

**The guarantee is only as strong as the store, and one store cannot give it
at all.** The claim is a Redis script, and `akkar.cache.memory` has no `EVAL`.
There is no per-process fallback: on a store that cannot run the script every
idempotent request is answered **503**, because the alternative -- running the
handler with no claim -- is the double charge this module exists to prevent,
and it would happen without a word. `akkar.limit.scriptable(cache)` answers
this before the first request rather than after it. **Idempotency requires
Redis.**

**A stored response has a size cap.** Beyond it the response is not kept, and
a repeat re-runs the handler. Refusing to store is better than an unbounded
write into a shared cache, and it is stated rather than discovered.
]]

local cjson = require "cjson"
local digest = require "openssl.digest"
local rand   = require "openssl.rand"

local M = {}

--- The explicit "this application really is single-tenant" opt-out, so that
--- one global keyspace over a client-chosen header value is something a team
--- wrote down rather than something it inherited.
M.GLOBAL = false

-- Claim, replay, or refuse -- decided in one atomic step, because the whole
-- mechanism is read-then-write and the retry that matters is the one arriving
-- while the first request is still running.
--
-- The claim carries a token nobody else can guess. Without it, a handler that
-- outlived its claim would DELETE the claim of the retry that replaced it, and
-- store its own answer over a record that is no longer about its request.
local CLAIM_SCRIPT = [[
local key         = KEYS[1]
local ttl         = tonumber(ARGV[1])
local fingerprint = ARGV[2]
local token       = ARGV[3]

local found = redis.call('HMGET', key, 'state', 'fingerprint', 'status', 'body')
local state = found[1]

if not state then
  redis.call('HSET', key, 'state', 'running', 'fingerprint', fingerprint,
             'token', token)
  redis.call('EXPIRE', key, ttl)
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

-- Stores only under the token this request claimed with. A 0 back means the
-- claim expired mid-handler and someone else now owns the key -- which is the
-- double execution this module exists to prevent, so the caller is told rather
-- than left to overwrite a stranger's record.
local STORE_SCRIPT = [[
if redis.call('HGET', KEYS[1], 'token') ~= ARGV[4] then return 0 end
redis.call('HSET', KEYS[1], 'state', 'done', 'status', ARGV[1], 'body', ARGV[2])
redis.call('EXPIRE', KEYS[1], tonumber(ARGV[3]))
return 1
]]

-- A handler that failed must not poison the key: the retry is the point. Token
-- guarded, so a late release cannot free the claim of the request that
-- replaced it and hand a third copy of the work to the next retry.
local RELEASE_SCRIPT = [[
if redis.call('HGET', KEYS[1], 'token') ~= ARGV[1] then return 0 end
return redis.call('DEL', KEYS[1])
]]

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

local function is_array(value)
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count, maximum = count + 1, math.max(maximum, key)
  end
  return count == maximum
end

-- cjson follows Lua's hash iteration order for objects. Canonicalize object
-- keys so semantically identical JSON produces the same fingerprint across
-- processes, while preserving array order.
local function canonical_json(value)
  if type(value) ~= "table" then return cjson.encode(value) end
  local parts = {}
  if is_array(value) then
    for index = 1, #value do parts[index] = canonical_json(value[index]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  -- Sorted by the key's JSON spelling, indexed by the key itself: sorting a
  -- list of `tostring(key)` and then reading `value[key]` off it looks up the
  -- string "2" in a table holding the number 2, so a mixed body fingerprinted
  -- as `"2":null` and two different requests shared one fingerprint.
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = cjson.encode(tostring(key)) .. ":" .. canonical_json(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function sha256(value)
  local hash = assert(digest.new "sha256")
  assert(hash:update(value))
  return (hash:final():gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

--- A stable, full-body summary of the request. Method and path are included
--- because the same key on another route is a client error too.
local function fingerprint_of(req)
  local body = ""
  if req.body ~= nil then
    local ok, encoded = pcall(canonical_json, req.body)
    body = ok and encoded or tostring(req.body)
  end
  return req.method .. " " .. req.path .. " " .. #body .. ":" .. sha256(body)
end

M.fingerprint_of = fingerprint_of

--- Middleware.
---
--- `methods` defaults to the ones that are not already idempotent by HTTP's
--- own definition: GET, HEAD, PUT and DELETE are, POST and PATCH are not.
function M.new(options)
  options = options or {}
  local ttl        = options.ttl or 86400
  -- The claim has to outlive the handler. It used to expire at 30 seconds,
  -- which is the module's own motivating scenario exactly -- "a proxy times
  -- out at thirty seconds while the handler takes thirty-one" -- so the claim
  -- was gone by the time the retry arrived and the card was charged twice,
  -- with `idempotent-replay` on neither answer. Fifteen minutes outlasts any
  -- handler the request deadline has not already killed, and still frees a
  -- claim stranded by a crashed process the same afternoon rather than a day
  -- later.
  local running_ttl = options.running_ttl or math.min(ttl, 900)
  local prefix     = options.prefix or "akkar:idem:"
  local header     = options.header or "idempotency-key"
  local max_bytes  = options.max_bytes or 64 * 1024
  local required   = options.required or false
  local namespace  = options.namespace
  local seal       = options.seal
  local open       = options.open

  -- The record is `prefix .. key` over a header the CLIENT chooses. With one
  -- global keyspace, tenant `evil` sends tenant `acme`'s key and is handed
  -- acme's stored 201 verbatim -- customer_email, card_last4 and all -- with
  -- `idempotent-replay: true`. The namespace is what makes the keyspace the
  -- server's rather than the caller's, so it is not optional; `akkar.scope`
  -- raises on a nil tenant id for the same reason, and this is the same bug.
  if namespace == nil then
    error("idempotency: namespace is required. The idempotency key comes from "
       .. "the client, so without a server-resolved namespace one tenant can "
       .. "replay another tenant's stored response body. Pass "
       .. "namespace = function(req) return req.tenant.id end, or "
       .. "namespace = false to state that this application is single-tenant "
       .. "and one global keyspace is intended.", 0)
  end
  if namespace ~= false and type(namespace) ~= "function"
     and type(namespace) ~= "string" then
    error("idempotency: namespace must be a function(req), a constant string, "
       .. "or false", 0)
  end

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
    local scoped = ""
    if namespace then
      scoped = type(namespace) == "function" and namespace(req) or namespace
      scoped = tostring(scoped or "")
      if scoped == "" then
        error("idempotency: namespace returned an empty value", 0)
      end
      if #scoped > 255 then
        error("idempotency: namespace must be at most 255 characters", 0)
      end
    end
    -- Length-prefixed rather than joined by a colon: the namespace and the key
    -- are both caller-influenced strings, and `"a:b" .. ":" .. "c"` and
    -- `"a" .. ":" .. "b:c"` are the same record -- a cross-tenant replay
    -- assembled out of two legal values.
    local record = prefix .. #scoped .. ":" .. scoped .. key
    local fingerprint = fingerprint_of(req)
    local token = (rand.bytes(16):gsub(".", function(char)
      return string.format("%02x", char:byte())
    end))

    -- A store that cannot answer is not a reason to run the handler. The
    -- claim call carried no `pcall`, so `akkar.cache.memory` -- which has no
    -- EVAL and says so -- turned every idempotent route into a 500, and a
    -- Redis blip did the same. Neither is the per-process deduplication the
    -- docstring used to promise.
    --
    -- Unlike `akkar.limit`, there is no fail-open here and there should not
    -- be: serving the request unguarded is exactly the double charge this
    -- module exists to prevent, and it would happen silently. 503 says the
    -- guarantee is unavailable, which a client can retry against.
    local claimed, verdict = pcall(claim, cache, { record },
                                   { running_ttl, fingerprint, token })
    if not claimed or type(verdict) ~= "table" then
      local log = rawget(req, "log")
      if log then
        log:error("idempotency: the store could not answer; refusing rather "
               .. "than running the handler unguarded", {
          error = tostring(verdict), path = req.path,
        })
      end
      local res = akkar.response(503, {
        error = "idempotency is unavailable; the request was not run",
        hint = "retry with the same " .. header,
      })
      res.headers = { ["retry-after"] = "1" }
      return res
    end
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
      if body and open then
        local opened, clear = pcall(open, body)
        if not opened or type(clear) ~= "string" then
          error("idempotency: stored response authentication failed", 0)
        end
        body = clear
      end
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
      pcall(function() release(cache, { record }, { token }) end)
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
      pcall(function() release(cache, { record }, { token }) end)
      return result
    end

    local status = result and result.status or 200
    if status < 200 or status >= 300 then
      pcall(function() release(cache, { record }, { token }) end)
      return result
    end

    local encoded = ""
    if result.body ~= nil then
      local encoded_ok, value = pcall(cjson.encode, result.body)
      encoded = encoded_ok and value or ""
    end

    local stored_body = encoded
    if seal then
      local sealed, value = pcall(seal, encoded)
      if not sealed or type(value) ~= "string" then
        -- Keep the claim in `running` rather than store a secret in cleartext
        -- or release a successfully executed operation for duplicate replay.
        local log = rawget(req, "log")
        if log then log:error("idempotency: response sealing failed") end
        return result
      end
      stored_body = value
    end

    if #stored_body > max_bytes then
      -- Refusing to store beats an unbounded write into a shared cache. The
      -- guarantee is lost for this response and the caller is told so.
      pcall(function() release(cache, { record }, { token }) end)
      local log = rawget(req, "log")
      if log then
        log:warn("idempotency: response too large to store", {
          bytes = #stored_body, max_bytes = max_bytes, path = req.path,
        })
      end
      return result
    end

    local stored, held = pcall(function()
      return store(cache, { record }, { status, stored_body, ttl, token })
    end)
    local log = rawget(req, "log")
    if not stored then
      if log then log:error("idempotency: response store failed; durable handler recovery required") end
    elseif tonumber(held) == 0 and log then
      -- The claim was gone by the time the handler finished, so this response
      -- is not stored and the retry that already ran is a second execution.
      -- Silence here is how a double charge stays invisible.
      log:error("idempotency: the in-flight claim expired before the handler "
             .. "returned; the operation may have run twice", {
        path = req.path, running_ttl_s = running_ttl,
      })
    end
    return result
  end
end

M.CLAIM_SCRIPT = CLAIM_SCRIPT
return M
