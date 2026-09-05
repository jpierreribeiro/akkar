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
September 2024, and which `akkar/vendor/http/h1_stream.lua` already carries a
repair for.

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

## THE POOL, AND THE TWO DEFECTS FOUND WHILE BUILDING IT

Connections are now pooled per `scheme://host:port`, over `akkar/pool.lua` --
the same pool the database and Redis use, not a second one. Reaching for the
existing pool is not tidiness: `akkar/pool.lua` carries three properties that
took real failures to learn (a slot is RESERVED before `open` yields, `put` is
idempotent, `reap` recovers slots from abandoned coroutines), and a second
pool written here would have had to learn all three again.

The key is derived from the PARSED uri, not from the url string, so
`http://x/a` and `http://x:80/b` share a pool and `http://x` and `https://x`
never do. A pool shared across hosts is not a performance bug, it is a request
sent to the wrong server.

Reaching the pool meant leaving `request:go()`, which opens its own connection
and hard-wires `connection:onidle(connection.close)`. Driving the stream by
hand instead uncovered two defects in the code this file already shipped, both
now measured and both fixed here:

**The body read had no timeout at all.** `read_bounded` passed
`time.monotime() + timeout` to `stream:get_next_chunk`, which takes a RELATIVE
timeout, not an absolute deadline. So the argument was not "one second", it
was "monotime seconds" -- seconds since boot, days on any machine that has
been up a while. Proven directly against a server that sends its headers and
then five bytes of a hundred-byte body and stalls: with `timeout = 1` the
first chunk arrived, and the second call never returned. `timeout` bounded the
connect and the headers and left the body unbounded, which is precisely the
budget a slow-loris server needs to hold a handler for ever.

**Every body over 1 KiB paid a fixed second.** `request:set_body` appends
`expect: 100-continue` for any body longer than 1024 bytes, and lua-http then
waits `expect_100_timeout` (one second) for a `100 Continue` that most servers
never send. Measured against akkar's own server: a 10-byte body answered
`201` in 0.002 s, a 2000-byte body answered **408 in 1.005 s** -- the wait
outlived the server's own read timeout, so the large upload did not merely
crawl, it FAILED. `akkar.storage` puts objects through this path, so it would
have been a second per object and an error on any server with a one-second
read timeout. The body is now framed with `content-length` and sent directly;
no `expect` header is generated.

## Reuse is checked before the connection is handed out, not after

A pooled connection the peer closed while it was idle answers nothing: the
write succeeds (it is buffered) and the read returns `Broken pipe`. Verified
exactly that way here before the check was written.

The check is that a connection sitting idle must have NOTHING readable on it.
Anything readable is either a stale response body (the stream desynchronised)
or the peer's FIN; neither is usable for the next request, so both are the
same answer. It costs one zero-timeout poll and no read.

`socket:eof("r")` is not that check and was tried first: it stayed FALSE on a
socket whose peer had exited, because cqueues only learns about the FIN once a
read goes looking for it. A check that never fires is worse than no check,
since it reads like protection.

## WHAT IT IS WORTH, MEASURED

`spec/http_pool_spec.lua` prints these on every run, and they are printed
whether or not they flatter the pool. Three hundred sequential GETs on
loopback, best of five interleaved runs:

    against a bare socket server   0.492 -> 0.241 ms/req   2.04x
    against akkar's own server     0.743 -> 0.671 ms/req   1.11x

The two numbers say different things and one alone would mislead. The second
is a whole akkar request -- routing, schema, JSON -- and the connection is a
small share of it. The first is a socket answering a fixed string, so nearly
all of what is left IS the connection: **about 0.25 ms per request on
loopback**, which is what one TCP handshake and one close cost here.

**That is the WEAKEST case for pooling, and it is the only one measured.**
Loopback has no round trip worth the name and no TLS. A real endpoint over a
network adds an RTT to the handshake and a TLS one adds two more plus the
certificate work -- so the saving there is larger by an amount this file has
not measured and therefore does not claim. Pooling is on by default on the
strength of the loopback number alone, which is the honest floor.
]]

local http_request = require "akkar.vendor.http.request"
local http_client  = require "akkar.vendor.http.client"
local http_util    = require "akkar.vendor.http.util"
local cqueues      = require "cqueues"
local dns_config   = require "cqueues.dns.config"
local dns_packet   = require "cqueues.dns.packet"
local dns_resolvers = require "cqueues.dns.resolvers"
local Pool         = require "akkar.pool"
local time         = require "akkar.time"
-- For the execution's remaining budget. `akkar.execution` requires only
-- cqueues and akkar.time, so this adds no cycle.
local execution    = require "akkar.execution"
local describe     = require("akkar.errno").describe
-- Requires only akkar.time, so this adds no cycle either.
local breaker      = require "akkar.breaker"

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
  pool_size     = 8,         -- live connections per scheme://host:port
}

-- Public option names are closed sets. A typo in `timeout`, `max_body`, or
-- `retries` does not merely configure the client differently: it silently
-- removes a resource bound or a failure policy while looking correct. Keep
-- the names beside the defaults and check them before any network work.
local CONNECT_OPTIONS = {
  headers = true, timeout = true, max_body = true, retries = true,
  retry_backoff = true, pool_size = true, reuse = true,
  http_version = true, breaker = true,
}

local REQUEST_OPTIONS = {
  headers = true, body = true, timeout = true, max_body = true,
  retries = true, retry_backoff = true, retry_unsafe = true,
  traceparent = true,
}

local function finite_number(value)
  return type(value) == "number" and value == value
         and value > -math.huge and value < math.huge
end

local function non_negative_number(value)
  return finite_number(value) and value >= 0
end

local function non_negative_integer(value)
  return non_negative_number(value) and value % 1 == 0
end

local function positive_integer(value)
  return non_negative_integer(value) and value > 0
end

local CONNECT_VALUES = {
  headers = { "a table", function(value) return type(value) == "table" end },
  timeout = { "a non-negative finite number", non_negative_number },
  max_body = { "a non-negative integer", non_negative_integer },
  retries = { "a non-negative integer", non_negative_integer },
  retry_backoff = { "a non-negative finite number", non_negative_number },
  pool_size = { "a positive integer", positive_integer },
  reuse = { "a boolean", function(value) return type(value) == "boolean" end },
  http_version = { "a finite number", finite_number },
  breaker = { "a table", function(value) return type(value) == "table" end },
}

local REQUEST_VALUES = {
  headers = CONNECT_VALUES.headers,
  body = { "a string or table", function(value)
    return type(value) == "string" or type(value) == "table"
  end },
  timeout = CONNECT_VALUES.timeout,
  max_body = CONNECT_VALUES.max_body,
  retries = CONNECT_VALUES.retries,
  retry_backoff = CONNECT_VALUES.retry_backoff,
  retry_unsafe = { "a boolean", function(value)
    return type(value) == "boolean"
  end },
  traceparent = { "a string", function(value)
    return type(value) == "string"
  end },
}

local function nearest(word, candidates)
  if type(word) ~= "string" then return nil end
  local best, best_distance = nil, math.huge
  for candidate in pairs(candidates) do
    local previous = {}
    for j = 0, #candidate do previous[j] = j end
    for i = 1, #word do
      local current = { [0] = i }
      for j = 1, #candidate do
        local cost = word:sub(i, i) == candidate:sub(j, j) and 0 or 1
        current[j] = math.min(previous[j] + 1, current[j - 1] + 1,
                              previous[j - 1] + cost)
      end
      previous = current
    end
    if previous[#candidate] < best_distance then
      best, best_distance = candidate, previous[#candidate]
    end
  end
  if best_distance <= math.max(2, math.floor(#word / 3)) then return best end
end

local function check_options(options, allowed, values, what)
  if type(options) ~= "table" then
    error(("%s options must be a table"):format(what), 3)
  end
  for key, value in pairs(options) do
    if not allowed[key] then
      local suggestion = nearest(key, allowed)
      error(("unknown %s option '%s'%s"):format(
        what, tostring(key),
        suggestion and ("; did you mean '" .. suggestion .. "'?") or ""), 3)
    end
    local rule = values[key]
    if rule and not rule[2](value) then
      error(("%s option '%s' must be %s"):format(what, key, rule[1]), 3)
    end
  end
end

--- Seconds left before `deadline`, or nil when there is no deadline.
---
--- Every lua-http call below takes a RELATIVE timeout. Handing one an
--- absolute deadline is the defect this module shipped with -- see the header
--- -- so the conversion happens in one named place rather than at six call
--- sites where the next person has to notice which kind of number it is.
local function remaining(deadline)
  if not deadline then return nil end
  return deadline - time.monotime()
end

-- ======================================================================== DNS

-- Built lazily: an application whose outbound endpoints are IP literals never
-- needs to read resolver configuration or create a DNS pool.
local resolver_pool

local function resolver()
  if resolver_pool then return resolver_pool end

  local config = dns_config.stub()
  local search = {}
  for _, suffix in ipairs(config:getsearch()) do
    -- systemd-resolved commonly writes `search .`. cqueues treats it as a
    -- suffix to try and waits attempts*timeout before returning a definitive
    -- NXDOMAIN it already received. Remove ONLY the root marker: Kubernetes
    -- and corporate search domains keep working for short service names.
    if suffix ~= "." and suffix ~= "" then search[#search + 1] = suffix end
  end
  config:setsearch(search)
  resolver_pool = dns_resolvers.new(config)
  return resolver_pool
end

local function dns_answer(host, kind, timeout)
  if timeout <= 0 then return nil, "timed out" end
  local answer, why = resolver():query(host, kind, nil, timeout)
  if not answer then return nil, tostring(describe(why) or "resolver failure") end

  local flags = answer:flags()
  local rcode = dns_packet.rcode[flags.rcode] or tostring(flags.rcode)
  if flags.rcode ~= dns_packet.rcode.NOERROR then return nil, rcode end

  local addresses = {}
  for record in answer:grep { section = "answer", type = kind } do
    addresses[#addresses + 1] = record:addr()
  end
  return addresses
end

--- Resolves one host without allowing DNS and connect to each spend the whole
--- timeout independently. A records are the common path; AAAA is queried when
--- no A address exists, preserving IPv6-only services without doubling every
--- connection's DNS traffic.
local function resolve_host(host, deadline)
  if http_util.is_ip(host) then return { host } end

  local addresses, why = dns_answer(host, "A", remaining(deadline))
  if not addresses then
    return nil, ("DNS lookup for '%s' failed: %s"):format(host, why)
  end
  if #addresses > 0 then return addresses end

  addresses, why = dns_answer(host, "AAAA", remaining(deadline))
  if not addresses then
    return nil, ("DNS lookup for '%s' failed: %s"):format(host, why)
  end
  if #addresses > 0 then return addresses end
  return nil, ("DNS lookup for '%s' returned no A or AAAA records"):format(host)
end

--- Reads a body with a hard ceiling, refusing rather than truncating.
local function read_bounded(stream, limit, deadline)
  local parts, total = {}, 0
  while true do
    local left = remaining(deadline)
    if left and left <= 0 then
      -- A NAMED TIMEOUT, not a hang. Before this, the deadline was passed
      -- straight through as if it were a timeout and the read waited for
      -- monotime seconds -- so a server that sent headers and then stopped
      -- held the coroutine until the process died.
      return nil, "timed out reading the response body"
    end
    local chunk, err = stream:get_next_chunk(left)
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

-- ==================================================================== pooling

-- The connect timeout belongs to the CALL, and `Pool.new` takes an `open`
-- that receives no arguments -- so a timeout captured when the pool was
-- created would be the first caller's timeout for ever after.
--
-- `Pool:get` runs `open` with `pcall` in the very coroutine that called it, so
-- the calling coroutine is an exact key. Weak, because an abandoned coroutine
-- must not keep an entry alive; that is the same reasoning `Pool.opening`
-- documents, and for the same reason.
local CONNECT_TIMEOUT = setmetatable({}, { __mode = "k" })

local Connection = {}
Connection.__index = Connection

--- True when this connection is fit to carry the next request.
---
--- See the header for why `socket:eof("r")` is not this test. The rule is that
--- an idle client connection must have nothing to read: a byte waiting on it
--- is either a response nobody asked for or the peer's FIN, and a request
--- written on top of either one is a request that gets no answer.
function Connection:alive()
  local conn = self.conn
  if not conn then return false end
  local sock = conn.socket
  -- lua-http drops the socket itself when the response said `Connection:
  -- close`, so a nil socket here is the ordinary end of a keep-alive-less
  -- exchange rather than an anomaly.
  if not sock then return false end

  local fd = sock:pollfd()
  if not fd then return false end

  -- A bare table with `pollfd` and `events` is a pollable object as far as
  -- cqueues is concerned; polling the SOCKET object directly does not work
  -- here, because an idle lua-http socket advertises no events and so is
  -- never reported ready even when its peer has gone. Measured both ways.
  local probe = { pollfd = fd, events = "r" }
  return cqueues.poll(probe, 0) ~= probe
end

function Connection:close()
  local conn = self.conn
  self.conn = nil
  if conn then pcall(function() conn:close() end) end
end

--- The pool for one origin, created on first use.
function Client:pool_for(key, host, port, tls)
  local pool = self.pools[key]
  if pool then return pool end

  pool = Pool.new(function()
    local timeout = CONNECT_TIMEOUT[coroutine.running()] or self.timeout
    local deadline = time.monotime() + timeout
    local addresses, resolution_error = resolve_host(host, deadline)
    if not addresses then error(resolution_error, 0) end

    local conn, err
    for _, address in ipairs(addresses) do
      local left = remaining(deadline)
      if left <= 0 then
        err = "connection deadline expired"
        break
      end
      conn, err = http_client.connect({
        -- `host` remains the URL hostname for SNI and certificate checking;
        -- `address` is only what the socket dials. The request and pool key
        -- likewise retain the hostname, so DNS cannot rewrite authority.
        host = host, address = address, port = port, tls = tls,
        version = self.http_version,
      }, left)
      if conn then break end
    end
    -- `Pool:get` expects `open` to raise, and treats the raise as a slot that
    -- must be given back -- so returning nil here would wedge the pool.
    --
    -- NAMED, NOT NUMBERED. `http_client.connect` hands back cqueues' raw errno
    -- on a socket failure, and `tostring` on that produced a reason of `32` --
    -- the whole message, in the log line and in the 502 the caller sees.
    -- `spec/dns_failure_spec.lua` caught it: a lookup that fails somewhere with
    -- no resolver reports a number nobody can act on. `akkar.errno.describe`
    -- passes an already-worded message through untouched, so this only ever
    -- adds a name where there was none.
    if not conn then
      error(("connection to '%s' failed: %s")
            :format(host, tostring(describe(err) or "could not connect")), 0)
    end
    return setmetatable({ conn = conn, key = key }, Connection)
  end, self.pool_size, function(resource)
    return self.reuse and not resource.broken and resource:alive()
  end)

  self.pools[key] = pool
  return pool
end

-- How many times to take a dead connection out of the idle set before giving
-- up. Bounded rather than `while true`: a peer that closes every connection
-- the instant it is idle would otherwise spin here for ever, and a bounded
-- loop turns that into an error with a name.
local MAX_STALE = 4

--- A connection for `key`, guaranteed to have looked alive a moment ago.
function Client:acquire(key, host, port, tls, timeout)
  local pool = self:pool_for(key, host, port, tls)
  local co = coroutine.running()
  CONNECT_TIMEOUT[co] = timeout

  for _ = 1, MAX_STALE do
    local ok, resource = pcall(pool.get, pool)
    CONNECT_TIMEOUT[co] = nil
    if not ok then return nil, tostring(resource) end

    if not resource.handed_out then
      -- Straight out of `open`, so there is nothing to check and a poll on it
      -- would only cost a syscall. It is reported as NOT reused, because a
      -- brand-new connection that fails has failed for a real reason and
      -- repeating the request would only repeat it.
      resource.handed_out = true
      return resource, false
    end
    if resource:alive() then return resource, true end

    -- Give it back so the PREDICATE rejects it: that closes the socket and
    -- decrements `live` through the one accounting path pool.lua has. Closing
    -- it here instead would leak the slot, which is the defect `Pool:put`
    -- already documents from the other direction.
    self.stale_reused = self.stale_reused + 1
    resource.broken = true
    pool:put(resource)
    CONNECT_TIMEOUT[co] = timeout
  end

  CONNECT_TIMEOUT[co] = nil
  return nil, ("the pool for %s kept returning connections the peer had closed")
              :format(key)
end

--- One exchange on an already-acquired connection.
---
--- Returns the response value, or nil and a reason; the second return says
--- whether the connection may go back to the idle set.
local function transact(resource, req, body, deadline, limit)
  local conn = resource.conn
  local stream = conn and conn:new_stream()
  -- `new_stream` returns nil once the socket is gone, which is the race the
  -- liveness probe cannot close: the peer may send its FIN between the poll
  -- and the write.
  if not stream then return nil, "the pooled connection was closed", false end

  local ok, err = stream:write_headers(req.headers, body == nil,
                                       remaining(deadline))
  if not ok then
    stream:shutdown()
    return nil, tostring(err or "could not send the request"), false
  end

  if body then
    local wrote, why = stream:write_body_from_string(body, remaining(deadline))
    if not wrote then
      stream:shutdown()
      return nil, tostring(why or "could not send the body"), false
    end
  end

  local headers, reason
  repeat
    headers, reason = stream:get_headers(remaining(deadline))
    if not headers then
      stream:shutdown()
      return nil, tostring(reason or "no response"), false
    end
    -- A 1xx is informational and another set of headers follows it. `101` is
    -- the exception: it is final, and it is a protocol switch this client
    -- does not do, so it is handed back to the caller as-is rather than
    -- looped on for ever.
    local status = headers:get ":status"
  until status:sub(1, 1) ~= "1" or status == "101"

  local text, why = read_bounded(stream, limit, deadline)
  if text == nil then
    stream:shutdown()
    -- A body that was cut short leaves the stream part-read, so the
    -- connection is desynchronised and must not be reused whatever the
    -- headers said.
    return nil, why, false
  end

  stream:shutdown()

  return {
    status  = tonumber(headers:get ":status"),
    headers = headers_to_table(headers),
    body    = text,
  }, nil, true
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

  local body = options.body
  if body ~= nil then
    if type(body) == "table" then
      body = require("akkar.json").encode(body)
      req.headers:upsert("content-type", "application/json")
    end
    -- `content-length` set here rather than through `request:set_body`,
    -- WHICH ALSO APPENDS `expect: 100-continue` ABOVE 1024 BYTES. See the
    -- header: that header cost a measured 1.005 s and a 408 on a body of two
    -- thousand bytes, against akkar's own server.
    req.headers:upsert("content-length", ("%d"):format(#body))
  else
    body = nil
  end

  -- The key comes from the parsed uri: `req.host`, `req.port` and `req.tls`
  -- are what lua-http will actually dial, so two urls that reach the same
  -- origin share a pool and two that do not cannot.
  -- BOUNDED BY THE EXECUTION, not only by this client's own default.
  --
  -- `DEFAULTS.timeout` is ten seconds. Without this line a request that has
  -- 200 ms of its budget left calls the service below it with ten -- so the
  -- caller gives up, the connection is dropped, and the callee keeps working
  -- on an answer nobody will read. That is the cascading-failure pattern the
  -- Google SRE book names, and gRPC's answer to it is exactly this: the
  -- remaining budget travels with the call.
  --
  -- `options.timeout` still wins as a CEILING, not as a floor: asking for
  -- thirty seconds inside a five-second request gets five. A caller cannot
  -- widen a budget it did not set.
  local timeout = execution.bounded(options.timeout or self.timeout)
  local scheme = req.tls and "https" or "http"
  local key = ("%s://%s:%d"):format(scheme, req.host, req.port)
  local limit = options.max_body or self.max_body

  -- THE BREAKER IS CONSULTED BEFORE ANYTHING IS DIALLED, and a refusal
  -- returns here having spent nothing: no connection, no slot, none of the
  -- execution's budget. That is the gap the deadline leaves open -- it bounds
  -- what one call to a dead service costs, and this is what stops the next
  -- thousand calls from each paying it.
  local guard = self:breaker_for(key)
  if guard then
    local allowed, why = guard:allow()
    if not allowed then return nil, why end
  end

  local repeatable = SAFE_TO_RETRY[method] or options.retry_unsafe
  local res, why = self:exchange(key, req, body, timeout, limit, repeatable)

  if guard then
    -- A 5xx is the dependency failing and a 4xx is the dependency working,
    -- which is the same line `request` draws for retries. A transport error
    -- (nil) is a failure whatever the reason says.
    if res and res.status < 500 then guard:success() else guard:failure() end
  end
  return res, why
end

--- The breaker for `key`, or nil when this client has none.
---
--- One shared instance covers every origin; a configuration table builds one
--- per origin on first use, keyed exactly as the pools are, so a dead host
--- trips its own breaker and not its neighbours'.
function Client:breaker_for(key)
  if self.breaker then return self.breaker end
  if not self.breaker_config then return nil end
  local found = self.breakers[key]
  if not found then
    found = breaker.new(self.breaker_config)
    self.breakers[key] = found
  end
  return found
end

--- The pool loop: a connection, one exchange, and at most one repeat.
function Client:exchange(key, req, body, timeout, limit, repeatable)
  -- TWICE AT MOST, AND ONLY FOR A REUSED CONNECTION.
  --
  -- The liveness probe cannot be atomic with the write, so a connection can
  -- die in the gap. Retrying that on a fresh connection is what every mature
  -- client does, and it is what makes pooling safe to turn on by default --
  -- but only when repeating the request is safe, because a POST that reached
  -- the server before the socket broke has already had its effect. The same
  -- rule as `SAFE_TO_RETRY`, applied to a different failure.
  for try = 1, 2 do
    local deadline = time.monotime() + timeout
    local resource, reused = self:acquire(key, req.host, req.port, req.tls,
                                          timeout)
    if not resource then return nil, tostring(reused) end

    local res, why, keep = transact(resource, req, body, deadline, limit)
    resource.broken = not keep
    resource.pool:put(resource)

    if res then return res end
    if not (reused and repeatable and try == 1) then return nil, why end
    self.retried_stale = self.retried_stale + 1
  end
end

--- Makes a request, retrying only what is safe to retry.
function Client:request(method, url, options)
  if options == nil then options = {} end
  check_options(options, REQUEST_OPTIONS, REQUEST_VALUES, "HTTP request")
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
      -- Refused by the breaker: nothing was dialled, and dialling again after
      -- a backoff would only be refused again until the cooldown passes --
      -- which is measured in seconds, not in this request's budget. So the
      -- refusal is the answer, at once, and the budget is left for the caller.
      if why == breaker.OPEN then return nil, why end
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

--- Nothing to release per request: `attempt` returns the connection to its
--- pool on every path, including the failing ones.
---
--- Kept as a no-op rather than deleted, because `req.http` is handed to
--- handlers the way `req.db` is, and a capability whose release is the
--- caller's to remember is a capability that leaks. Here there is nothing to
--- remember, and saying so is cheaper than making the next reader check.
function Client:release() end

--- Closes every pooled connection. Idempotent.
function Client:close()
  for key, pool in pairs(self.pools) do
    pool:close()
    self.pools[key] = nil
  end
end

--- What the pools are doing, per origin.
---
--- Per ORIGIN rather than one total, for the reason `Pool:stats` gives about
--- `live` and `reserved`: a single number cannot say whether one host is
--- saturated or every host is idle, and those want opposite responses.
function Client:stats()
  local out = { stale_reused = self.stale_reused,
                retried_stale = self.retried_stale, origins = {},
                breakers = {} }
  for key, pool in pairs(self.pools) do out.origins[key] = pool:stats() end
  if self.breaker then
    out.breakers["*"] = self.breaker:stats()
  else
    for key, guard in pairs(self.breakers) do out.breakers[key] = guard:stats() end
  end
  return out
end

--- Returns a factory, matching `db.connect` and `redis.connect`.
function M.connect(config)
  if config == nil then config = {} end
  check_options(config, CONNECT_OPTIONS, CONNECT_VALUES, "http.connect")
  local client = setmetatable({
    headers       = config.headers,
    timeout       = config.timeout or DEFAULTS.timeout,
    max_body      = config.max_body or DEFAULTS.max_body,
    retries       = config.retries or DEFAULTS.retries,
    retry_backoff = config.retry_backoff or DEFAULTS.retry_backoff,
    pool_size     = config.pool_size or DEFAULTS.pool_size,
    -- `reuse = false` is a connection per request through the SAME code path,
    -- not a second path. The predicate rejects every connection, so the pool
    -- closes each one on return and the next call opens a fresh one. One
    -- transport to test, and the old behaviour is still reachable for anyone
    -- who has a proxy that mishandles keep-alive.
    reuse         = config.reuse ~= false,
    -- Left nil on purpose: lua-http then negotiates. Pinning 1.1 is available
    -- for a peer that mis-advertises h2.
    http_version  = config.http_version,
    -- `breaker = breaker.new{...}` is one breaker for the whole client, which
    -- is right when the client talks to one service. A plain table of
    -- breaker options is one breaker PER ORIGIN, built on first use, which is
    -- right when it talks to several and one of them going down must not
    -- take the others off the air with it.
    breaker       = breaker.is(config.breaker) and config.breaker or nil,
    breaker_config = (type(config.breaker) == "table"
                      and not breaker.is(config.breaker)) and config.breaker
                     or nil,
    breakers      = {},
    pools         = {},
    stale_reused  = 0,
    retried_stale = 0,
  }, Client)
  return execution.shared(function() return client end)
end

M.Client = Client
M.SAFE_TO_RETRY = SAFE_TO_RETRY

return M
