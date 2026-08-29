--[[
akkar.etag — the write that vanishes.

## The mistake it removes

Two clients read the same record. Both edit it. Both save. The second write
overwrites the first, and **nothing anywhere reports an error**: the first
client saw a 200, the second saw a 200, and one person's work is gone. It is
found weeks later, if ever, and it is unreproducible.

HTTP has had the answer since 1997 and almost nobody turns it on. A response
carries an `ETag`; a conditional write sends `If-Match` with the tag it read;
the server refuses with **412** when the record has moved on. The second client
is told, immediately, instead of silently winning.

## The shape

    app:use(akkar.etag { require_on = { "PUT", "PATCH", "DELETE" } })

    GET  /documents/7          ->  200, ETag: "a3f1c9..."
    PUT  /documents/7          ->  428   (no If-Match, and this route demands one)
    PUT  /documents/7
      If-Match: "stale-value"  ->  412
    PUT  /documents/7
      If-Match: "a3f1c9..."    ->  200

**428 is the line between a feature and an invariant.** Without it, a client
that simply forgets the header races silently and the whole mechanism is
optional in practice. With it, forgetting is an error with a name -- `428
Precondition Required` exists for exactly this and says so in RFC 6585.

`If-None-Match` is honoured too, which is the cheap half: a client that
already has the current version gets **304** and no body.

## Where the tag comes from

The response body, hashed after the `response` schema has filtered it -- so
the tag describes exactly the bytes the client received, by construction,
rather than something adjacent to them.

## The limit, stated plainly

**A body-derived ETag is not a row version.** Two edits that produce the same
body are indistinguishable, so an A-then-B-then-A sequence can let a stale
write through. A client reading via a cache may hold a tag for a version it
never actually saw.

The strong form is a version column the database increments, compared inside
the same transaction as the write. That belongs to the application, because
only the application knows which column that is. What this gives you is the
transport half, correct and free, and it is a great deal better than nothing --
which is what almost every JSON API has today.
]]

local cjson = require "cjson"

local M = {}

-- FNV-1a, 64-bit, in Lua's native integers.
--
-- Not a cryptographic hash and it does not need to be: an ETag identifies a
-- version to a cooperating client, and a client that can choose the tag can
-- already choose the body. What it must be is FAST, since it runs on every
-- response, and STABLE, since a tag that varies between processes would make
-- every conditional request fail behind a load balancer.
local FNV_OFFSET = 0xcbf29ce484222325
local FNV_PRIME  = 0x100000001b3

local function fnv1a(s)
  local hash = FNV_OFFSET
  for i = 1, #s do
    hash = hash ~ s:byte(i)
    hash = hash * FNV_PRIME
  end
  return string.format("%016x", hash)
end

M.fnv1a = fnv1a

--- A table is an array only if its keys are exactly 1..n. `value[1] ~= nil`
--- was not that test: `{ [1] = "row", status = "draft", owner = "alice" }`
--- took the array branch, serialised to `["row"]`, and every other key
--- vanished from the tag while cjson sent all of them to the client. Two
--- bodies differing only in `status` hashed identically, so `If-Match`
--- accepted a stale write and `If-None-Match` answered 304 for content that
--- had changed -- in the module whose whole subject is the write that
--- vanishes.
local function is_array(value)
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count, maximum = count + 1, math.max(maximum, key)
  end
  return count == maximum
end

--- Canonical JSON, so the tag does not change when nothing did.
---
--- `pairs()` has no defined order in Lua, so encoding the same table twice can
--- produce different bytes and therefore different tags -- which would make
--- every conditional request fail intermittently, on one process, for no
--- visible reason. Keys are sorted.
local function canonical(value)
  local kind = type(value)
  if kind ~= "table" then
    return cjson.encode(value)
  end

  if is_array(value) then                             -- array or empty
    local parts = {}
    for i = 1, #value do parts[i] = canonical(value[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  -- Sorted by the key's JSON spelling, but indexed by the key itself: sorting
  -- a list of `tostring(k)` and then reading `value[k]` off it looked up the
  -- string "2" in a table holding the number 2 and emitted `"2":null`, which
  -- is a second way for a change to leave the tag alone.
  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local parts = {}
  for i, k in ipairs(keys) do
    parts[i] = cjson.encode(tostring(k)) .. ":" .. canonical(value[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

M.canonical = canonical

--- The tag for a body. Quoted, because RFC 7232 says an entity-tag is a quoted
--- string and a bare one is silently ignored by well-behaved clients.
function M.of(body)
  if body == nil then return nil end
  local ok, encoded = pcall(canonical, body)
  if not ok then return nil end
  return '"' .. fnv1a(encoded) .. '"'
end

--- `If-Match: "a", "b"` is a list, and `*` means "any current version".
local function matches(header, tag)
  if header == "*" then return true end
  for candidate in header:gmatch '[^,]+' do
    candidate = candidate:match "^%s*(.-)%s*$"
    -- A weak validator (W/"x") is not usable for a conditional WRITE, per
    -- RFC 7232: it promises semantic equivalence, not byte equality.
    if candidate == tag then return true end
  end
  return false
end

M.matches = matches

--- Middleware.
---
--- `require_on` lists the methods that must carry `If-Match`. Empty by
--- default, because switching this on for every existing client at once would
--- break all of them; naming the methods is how a team opts in deliberately.
function M.new(options)
  options = options or {}
  local akkar = require "akkar"

  local required = {}
  for _, m in ipairs(options.require_on or {}) do required[m:upper()] = true end

  local safe = { GET = true, HEAD = true }

  return function(req, next)
    local method = req.method
    local if_match = req.headers["if-match"]
    local if_none = req.headers["if-none-match"]

    -- The precondition is checked BEFORE the handler runs, so a refused write
    -- never reaches the database. Checking afterwards would mean the write
    -- happened and then we told the client it did not.
    if not safe[method] then
      if required[method] and not if_match then
        return akkar.response(428, {
          error = "this request requires an if-match header",
          hint = "read the resource first and send the etag it returned",
        })
      end

      if if_match then
        -- The current tag comes from reading the resource the same way a GET
        -- would. `current` is supplied by the application because only it
        -- knows how to fetch the thing being written.
        local current = options.current and options.current(req)
        local tag = current ~= nil and M.of(current) or nil
        if not tag or not matches(if_match, tag) then
          return akkar.response(412, {
            error = "the resource has changed since you read it",
          })
        end
      end
    end

    local res = next(req)

    -- Tag every successful response with a body, so the next conditional
    -- request has something to send.
    if res and res.status and res.status >= 200 and res.status < 300
       and res.body ~= nil then
      local tag = M.of(res.body)
      if tag then
        res.headers = res.headers or {}
        res.headers["etag"] = tag

        -- The cheap half: a client that already holds this version gets 304
        -- and no body at all.
        if safe[method] and if_none and matches(if_none, tag) then
          local not_modified = akkar.response(304, nil)
          not_modified.headers = { ["etag"] = tag }
          return not_modified
        end
      end
    end

    return res
  end
end

return M
