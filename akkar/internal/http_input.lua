-- Private HTTP input normalization. Public aliases remain on akkar.
local execution = require "akkar.execution"
local bitwise = require "akkar.bitwise"
local text = require "akkar.text"

local function safe_text(value)
  if type(value) ~= "string" then return value end
  if utf8.len(value) then return value end

  -- U+FFFD per invalid byte, which is what every other decoder does and what
  -- makes the result inspectable rather than merely legal.
  local out, i, n = {}, 1, #value
  while i <= n do
    local ok = utf8.len(value, i, i)
    if ok then
      local _, stop = utf8.offset(value, 2, i), nil
      stop = (_ or (n + 1)) - 1
      out[#out + 1] = value:sub(i, stop)
      i = stop + 1
    else
      out[#out + 1] = "\239\191\189"      -- U+FFFD
      i = i + 1
    end
  end
  return table.concat(out)
end

local function unescape(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function normalize_path(path)
  if path == "" then return "/" end
  if #path > 1 and path:sub(-1) == "/" then
    path = path:gsub("/+$", "")
    if path == "" then return "/" end
  end
  return path
end

-- Headers reach a handler as a plain table with lowercase keys, whether the
-- request came off a socket or from the in-process test client.  Before this,
-- a handler had to write
--   req.headers.authorization or (req.headers.get and req.headers:get "...")
-- which is the framework leaking lua-http into user code.
-- A request id, taken from the client when it sends one so a trace survives
-- across services, generated otherwise.  Not a UUID: this only has to be
-- unique enough to correlate lines within a window, and pulling in a UUID
-- library for that would be a dependency bought with nothing.
-- The generating half moved to `akkar/execution.lua`: every execution has an
-- identity, and only HTTP has an opinion about honouring a caller's header.
-- That split is deliberate -- `execution.id()` cannot be handed a header,
-- because trusting one is a transport decision and belongs here.
--- One header out of whatever shape the transport handed us.
---
--- `request_id` and nothing else needs a header BEFORE `req` exists, and it
--- needs exactly one. Normalising all of them to answer that was most of what
--- made a browser-shaped request expensive: 12% of its CPU spent copying
--- headers, on the overwhelming majority of requests that never read one.
---
--- Two shapes, because `app:test` passes a plain table and the server passes a
--- lua-http headers object, and `normalize_headers` has always handled both.
local function one_header(source, name)
  if not source then return nil end
  if type(source.get) == "function" then return source:get(name) end
  for key, value in pairs(source) do
    if key:lower() == name then return value end
  end
  return nil
end

-- `req.id` is akkar's own, always.
--
-- It used to be whatever arrived in `x-request-id`, length-checked and nothing
-- else, and three things read it. `akkar.limit.concurrent` uses it as the ZSET
-- member for a slot, so every caller sending one constant header collapsed onto
-- a single member and the ceiling stopped counting -- measured at peak 46
-- against a limit of 2. `akkar.log` writes it into a logfmt line, which
-- separates fields with spaces, so one header wrote four fields into the
-- operator's log with three of them invented. And it is echoed back on the
-- response.
--
-- So it is unique by construction now, and made of characters no log format can
-- be steered with. What the caller sent survives as `req.client_request_id`,
-- validated, and named so that trusting it is a decision an application makes
-- rather than one it inherits. Correlation that has to be trusted across
-- services is what `traceparent` is for, and that one is parsed rather than
-- echoed.
local function request_id(_headers)
  return execution.id()
end

-- Length is capped at a UUID with room to spare, and anything outside the set
-- is DROPPED rather than stripped or truncated: an id sanitised into a
-- different id correlates to the wrong request, which is worse than not
-- correlating at all.
local CLIENT_REQUEST_ID_MAX = 128

local function client_request_id(headers)
  local given = headers and headers["x-request-id"]
  if type(given) ~= "string" then return nil end
  if #given == 0 or #given > CLIENT_REQUEST_ID_MAX then return nil end
  if given:match "^[%w%._:%-]+$" then return given end
  return nil
end

--- The same rule, against raw transport headers rather than a normalised copy.
---
--- Kept separate rather than folded into `request_id`, because `request_id` is
--- exported and `spec/` calls it with a plain normalised table.
local function request_id_from(_source)
  return execution.id()
end

-- W3C Trace Context, which is the same idea as `x-request-id` with a format
-- everything else already speaks:
--
--     traceparent: 00-<32 hex trace id>-<16 hex span id>-<2 hex flags>
--
-- akkar accepts one, exposes it, and passes it on. It does NOT create spans
-- or export them: that is an OpenTelemetry dependency and an adapter, and it
-- belongs behind the same boundary as everything else here.
--
-- Validated rather than trusted. A malformed header is dropped instead of
-- propagated, because forwarding a broken trace id corrupts somebody else's
-- trace as well as this one, and it arrives from the network.
local function trace_context(headers)
  local given = headers and headers["traceparent"]
  if type(given) ~= "string" then return nil end

  local version, trace_id, span_id, flags =
    given:match "^(%x%x)%-(%x+)%-(%x+)%-(%x%x)$"
  if not version then return nil end
  if #trace_id ~= 32 or #span_id ~= 16 then return nil end
  -- All-zero ids are explicitly invalid in the specification.
  if trace_id:match "^0+$" or span_id:match "^0+$" then return nil end
  -- Version ff is forbidden; a version akkar does not know is still
  -- forwarded, which is what the specification asks for.
  if version == "ff" then return nil end

  return {
    traceparent = given,
    trace_id = trace_id,
    span_id = span_id,
    sampled = bitwise.band(tonumber(flags, 16), 0x01) == 1,
    tracestate = headers["tracestate"],
  }
end

--- Turns whatever carried the headers into a plain lowercase table.
---
--- DUPLICATE VALUES ARE COLLECTED AND JOINED ONCE. The line this replaced was
--- `out[name] = existing and (existing .. ", " .. clean) or clean`, which
--- builds a NEW string of the whole accumulation on every repeat of a name --
--- the textbook quadratic string build, and quadratic in a number an
--- unauthenticated peer chooses.
---
--- Measured on this box, with 4,000-byte values arriving over h2:
---
---     1,000 duplicates      2.5 s
---     4,000 duplicates     32.2 s
---     8,000 duplicates    111.4 s
---    16,000 duplicates    364.0 s      from a 20,008-byte header block
---
--- None of it yields, so it is the whole process, not one request. `req.headers`
--- is lazy, but `req.ip` reads it and `akkar/limit.lua` reads `req.ip` in the
--- default rate-limit key, so the ordinary path arrives here.
---
--- The h2 header-count cap in `hpack` is what stops that block being decoded at
--- all, and is the fix that matters for the attack. This is the other half: a
--- bound and a quadratic together are a bound on how bad the bound may be
--- wrong, and 100 duplicates should not cost what 100 duplicates cost here.
---
--- The single-value case -- every header appearing once, which is every real
--- request -- still writes straight into `out` and allocates no table.
local function normalize_headers(source)
  local out = {}
  if not source then return out end
  if type(source.get) == "function" then          -- a lua-http headers object
    local repeated                                -- name -> {value, ...}, lazily
    for name, value in source:each() do
      if name:sub(1, 1) ~= ":" then               -- drop :method, :path, ...
        -- Header values are bytes as far as HTTP is concerned, and akkar puts
        -- them in JSON responses. See `safe_text`.
        local clean = safe_text(value)
        local existing = out[name]
        if existing == nil then
          out[name] = clean
        else
          repeated = repeated or {}
          local parts = repeated[name]
          if parts == nil then
            parts = { existing, clean }
            repeated[name] = parts
          else
            parts[#parts + 1] = clean
          end
        end
      end
    end
    if repeated then
      for name, parts in pairs(repeated) do
        out[name] = table.concat(parts, ", ")
      end
    end
  else
    for name, value in pairs(source) do out[name:lower()] = safe_text(value) end
  end
  return out
end
-- Exported for the same reason `safe_text`, `client_ip`, `parse_query` and
-- `trace_context` are: it is reachable from a request only through a live
-- server, and its cost is the thing under test. `spec/http2_spec.lua` measures
-- it directly.

-- ============================================================== client address
--
-- Who the caller IS, which is a different question from what the caller SAYS.
--
-- `akkar.limit` shipped keying its buckets on `X-Forwarded-For`, falling back
-- to `X-Real-IP`, with nothing else available -- because nothing else WAS
-- available: the peer address was never plumbed to `req`. Both of those are
-- client-supplied strings. Any caller could send a fresh one per request and
-- mint a fresh rate-limit bucket each time, which defeats the limiter with a
-- single header.
--
-- So `req.ip` is the address of the socket, always. `X-Forwarded-For` is
-- believed only when the connection came FROM a proxy the application named,
-- and then only as far back as the trusted hops go: walking the list from the
-- right, the first address that is not itself a trusted proxy is the client,
-- and everything to its left is whatever that client chose to send.
local function ipv4_to_int(address)
  local a, b, c, d = address:match "^(%d+)%.(%d+)%.(%d+)%.(%d+)$"
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

--- Is `address` inside `cidr`? IPv4 only, and it says so rather than
--- pretending: an IPv6 peer simply never matches, which fails CLOSED --
--- forwarded headers are ignored rather than believed.
local function in_cidr(address, cidr)
  local base, bits = cidr:match "^([%d%.]+)/(%d+)$"
  if not base then base, bits = cidr, "32" end
  bits = tonumber(bits)
  local a, b = ipv4_to_int(address), ipv4_to_int(base)
  if not a or not b or not bits or bits < 0 or bits > 32 then return false end
  if bits == 0 then return true end
  local mask = bitwise.band(bitwise.lshift(0xFFFFFFFF, 32 - bits), 0xFFFFFFFF)
  return bitwise.band(a, mask) == bitwise.band(b, mask)
end

local function is_trusted(address, trusted)
  if not address or not trusted then return false end
  for _, cidr in ipairs(trusted) do
    if in_cidr(address, cidr) then return true end
  end
  return false
end

--- The client address, given the socket's peer and the forwarded header.
---
--- Exported because it is worth testing directly: the walk is the whole
--- security property, and it is easy to get backwards. Taking the LEFTMOST
--- entry -- which is what most implementations do -- is exactly the spoofable
--- version, since the leftmost entry is whatever the client typed.
local function client_ip(peer, forwarded, trusted)
  if not peer then return nil end
  if not forwarded or not is_trusted(peer, trusted) then return peer end

  local hops = {}
  for hop in tostring(forwarded):gmatch "[^,]+" do
    -- `text.trim`, not `^%s*(.-)%s*$`: this trims a hop out of a header
    -- THE CLIENT SENT, and the pattern's cost tracked the string's
    -- length rather than the whitespace. Ten kilobytes in one
    -- `X-Forwarded-For` cost 515 us against 83 us for a whole request.
    hops[#hops + 1] = text.trim(hop)
  end

  for i = #hops, 1, -1 do
    if not is_trusted(hops[i], trusted) then return hops[i] end
  end
  -- Every hop is a trusted proxy: the peer is the best answer there is.
  return peer
end

local function parse_query(qs)
  local out = {}
  if not qs or qs == "" then return out end
  for pair in qs:gmatch "[^&]+" do
    local k, val = pair:match "^([^=]*)=?(.*)$"
    if k and k ~= "" then
      -- Percent-decoding turns %C3%28 into bytes that are not text, and a
      -- query value reaches a validation error message and a response.
      out[safe_text(unescape(k))] = safe_text(unescape((val:gsub("+", " "))))
    end
  end
  return out
end

return {
  normalize_path = normalize_path,
  one_header = one_header,
  request_id = request_id,
  client_request_id = client_request_id,
  request_id_from = request_id_from,
  trace_context = trace_context,
  normalize_headers = normalize_headers,
  ipv4_to_int = ipv4_to_int,
  in_cidr = in_cidr,
  client_ip = client_ip,
  parse_query = parse_query,
  safe_text = safe_text,
  unescape = unescape,
}
