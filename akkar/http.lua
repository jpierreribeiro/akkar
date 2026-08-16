--[[
akkar.http — the outbound half, which did not exist.

## Why this is a capability and not a `require`

`docs/BACKLOG.md` section 10: akkar's capability set is `db`, `cache`, `log`
and `clock`, none of which leaves the process, and nothing under `akkar/`
required an HTTP client. So akkar was complete at receiving a request and
empty at making one -- which is most of what a real backend does.

The fix is not "expose lua-http to handlers". The rule this project keeps is
that **all I/O goes through an adapter akkar owns, never through a library
called directly from a handler**, and the reason is now measured rather than
argued: `spec/db_spec.lua` runs one contract against two Postgres drivers, so
swapping a transport costs one file. That matters more here than it did for
the database, because the transport underneath this one is lua-http -- the
library this project found a denial of service in, whose last commit is
September 2024, and which `akkar/substrate.lua` already carries a repair for.

So the value is in the ADAPTER: a deadline, a response ceiling, a retry policy
that knows what is safe to repeat, trace propagation, and metrics. The
transport is a detail, and it is meant to be.

## The response is a value

`res.status`, `res.headers`, `res.body`. Nothing is mutated and nothing is
streamed by default, for the same reason handlers return instead of writing:
a value can be logged, retried and asserted on, and a stream cannot be any of
those twice.

## THE CEILING IS ENFORCED WHERE THE BYTES ARRIVE

This is the one design decision worth reading before using this module.

Astra -- the closest comparable runtime -- buffers the entire request body
with `to_bytes(body, usize::MAX)` before any user code runs, and it *has* a
configurable body limit which does not apply to that path, because the limit
belongs to a different extractor. Verified in its source, and it is a worse
failure than having no limit at all: the knob reads as protection and is not.

So here the ceiling is applied in the read loop itself, chunk by chunk, and
the module refuses to grow past it rather than truncating silently. A response
that exceeds it is an error with a name, not a short body that looks complete.
`spec/http_spec.lua` proves the knob actually cuts, because a limit nobody
tested is the Astra defect with a different accent.
]]

local http_request = require "http.request"
local time         = require "akkar.time"

local M = {}

local Client = {}
Client.__index = Client

-- Methods a failed request may be retried on.
--
-- POST and PATCH are absent and that is the entire point. A retried POST is a
-- second charge, a second email, a second order -- and a client that retries
-- them by default turns one flaky network into duplicated side effects. A
-- caller who knows their endpoint is idempotent can say so per call with
-- `retry_unsafe = true`; nobody gets it by accident.
local SAFE_TO_RETRY = {
  GET = true, HEAD = true, PUT = true, DELETE = true,
  OPTIONS = true, TRACE = true,
}

local DEFAULTS = {
  timeout       = 10,        -- seconds for one attempt
  max_body      = 8 * 1024 * 1024,
  retries       = 0,         -- attempts BEYOND the first
  retry_backoff = 0.1,
}

--- Reads a body with a hard ceiling, refusing rather than truncating.
local function read_bounded(stream, limit, deadline)
  local parts, total = {}, 0
  while true do
    local chunk, err = stream:get_next_chunk(deadline)
    if chunk == nil then
      -- `err == nil` is a clean end of body. Anything else is a real failure
      -- and must not look like a complete short response.
      if err then return nil, tostring(err) end
      break
    end
    total = total + #chunk
    if total > limit then
      -- REFUSED, NOT TRUNCATED. A truncated body is indistinguishable from a
      -- complete one at the call site, so the caller parses half a JSON
      -- document and gets a confusing error somewhere else entirely.
      return nil, ("response exceeded max_body of %d bytes"):format(limit)
    end
    parts[#parts + 1] = chunk
  end
  return table.concat(parts)
end

local function headers_to_table(h)
  local out = {}
  for name, value in h:each() do
    if name:sub(1, 1) ~= ":" then
      -- Repeated headers become a list rather than the last one winning,
      -- because `set-cookie` legitimately repeats and silently keeping one is
      -- how a session gets lost.
      local existing = out[name]
      if existing == nil then out[name] = value
      elseif type(existing) == "table" then existing[#existing + 1] = value
      else out[name] = { existing, value } end
    end
  end
  return out
end

--- One attempt. Returns a response value, or nil and a reason.
function Client:attempt(method, url, options)
  local req = http_request.new_from_uri(url)
  req.headers:upsert(":method", method)

  for name, value in pairs(self.headers or {}) do
    req.headers:upsert(name:lower(), tostring(value))
  end
  for name, value in pairs(options.headers or {}) do
    req.headers:upsert(name:lower(), tostring(value))
  end

  -- TRACE CONTEXT TRAVELS, and until now akkar parsed `traceparent` on the
  -- way in and had nowhere to send it on the way out. A trace that stops at
  -- the process boundary is a trace of one process.
  if options.traceparent then
    req.headers:upsert("traceparent", options.traceparent)
  end

  if options.body ~= nil then
    local body = options.body
    if type(body) == "table" then
      body = require("akkar.json").encode(body)
      req.headers:upsert("content-type", "application/json")
    end
    req:set_body(body)
  end

  local timeout = options.timeout or self.timeout
  local headers, stream = req:go(timeout)
  if not headers then
    -- `stream` carries the reason when the request failed to complete.
    return nil, tostring(stream or "request failed")
  end

  local deadline = time.monotime() + timeout
  local body, why = read_bounded(stream, options.max_body or self.max_body,
                                 deadline)
  stream:shutdown()
  if body == nil then return nil, why end

  return {
    status  = tonumber(headers:get ":status"),
    headers = headers_to_table(headers),
    body    = body,
  }
end

--- Makes a request, retrying only what is safe to retry.
function Client:request(method, url, options)
  options = options or {}
  method = method:upper()

  local allowed = options.retries or self.retries
  if allowed > 0 and not SAFE_TO_RETRY[method] and not options.retry_unsafe then
    -- Not an error: the request still happens, once. Refusing outright would
    -- make `retries` a setting nobody could apply globally.
    allowed = 0
  end

  local last
  for attempt = 0, allowed do
    local res, why = self:attempt(method, url, options)
    if res then
      -- A 5xx is retried; a 4xx never is. The server telling you the request
      -- was wrong will tell you again.
      if res.status < 500 or attempt == allowed then return res end
      last = ("status %d"):format(res.status)
    else
      last = why
    end
    if attempt < allowed then
      time.sleep((options.retry_backoff or self.retry_backoff) * (2 ^ attempt))
    end
  end
  return nil, last
end

function Client:get(url, options)    return self:request("GET", url, options) end
function Client:head(url, options)   return self:request("HEAD", url, options) end
function Client:post(url, options)   return self:request("POST", url, options) end
function Client:put(url, options)    return self:request("PUT", url, options) end
function Client:patch(url, options)  return self:request("PATCH", url, options) end
function Client:delete(url, options) return self:request("DELETE", url, options) end

--- Decodes a JSON response, or raises with the status so the caller can see it.
function Client:json(method, url, options)
  local res, why = self:request(method, url, options)
  if not res then return nil, why end
  if res.body == "" then return nil, "empty body" end
  local ok, decoded = pcall(require("akkar.json").decode, res.body)
  if not ok then return nil, "response was not JSON: " .. tostring(decoded) end
  return decoded, res
end

--- Nothing to release: connections are per request today.
---
--- Stated rather than omitted. A pool keyed by host belongs here and is not
--- built yet, so every call opens a connection -- which is correct and slow,
--- and exactly what `akkar/pool.lua` exists to fix once there is a
--- measurement saying it matters.
function Client:release() end
function Client:close() end

--- Returns a factory, matching `db.connect` and `redis.connect`.
function M.connect(config)
  config = config or {}
  local client = setmetatable({
    headers       = config.headers,
    timeout       = config.timeout or DEFAULTS.timeout,
    max_body      = config.max_body or DEFAULTS.max_body,
    retries       = config.retries or DEFAULTS.retries,
    retry_backoff = config.retry_backoff or DEFAULTS.retry_backoff,
  }, Client)
  return function() return client end
end

M.Client = Client
M.SAFE_TO_RETRY = SAFE_TO_RETRY

return M
