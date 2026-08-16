--[[
akkar.storage — object storage over HTTP, S3-compatible.

## Why this is here and not a dependency

A backend that accepts uploads has to put them somewhere, and "somewhere" is
an object store on every deployment target this project has: S3, R2, B2,
Spaces, MinIO, Garage. They all speak the same dialect of HTTP, so the choice
was one more C library and one more thing to build in Docker, or the four
requests written out over `akkar.http`. This file is the second, and it adds
no dependency at all: the transport is `akkar.http` and the arithmetic is
`akkar.crypto`, both of which were already here.

## AWS Signature Version 4 is the whole difficulty

Everything else in this file is a URL and a verb. The signature is a
canonicalisation with a dozen rules, and getting any one of them wrong
produces a signature that looks exactly as convincing as a correct one and
that no server will accept. There is no way to tell the two apart by
inspection, and a unit test written from the same misunderstanding as the code
agrees with it enthusiastically.

**So it is checked against AWS's own published worked examples**, all three of
them, and not only on the final signature: `spec/storage_spec.lua` asserts the
canonical request and the string-to-sign byte for byte as well, because those
are where the mistakes are and a final-hash-only test says "wrong" without
saying where.

  * GET with a `Range` header, `examplebucket/test.txt`, signature
    `f0e8bdb8...` -- exercises a signed empty payload and header ordering.
  * PUT of `test$file.text` -- exercises URI-encoding inside a path (the `$`
    must become `%24` and the `/` must NOT), a real payload hash, and six
    signed headers including one with an RFC 1123 date in it.
  * The presigned GET, signature `aeeed9bb...` -- exercises the canonical
    query string, percent-encoding of the slashes inside `X-Amz-Credential`,
    and `UNSIGNED-PAYLOAD`.

## The rules that are easiest to get wrong, named

**The path is encoded but not normalised.** For S3 specifically, `a//b` and
`a/../b` are distinct keys and must be signed as written. Every path SEGMENT
is percent-encoded; the separators are not.

**Encoding is RFC 3986, not `application/x-www-form-urlencoded`.** A space is
`%20` and never `+`, `~` is left alone, and the hex digits are UPPER case.
Lowercase hex produces a signature mismatch and no explanation.

**The query string is sorted by encoded key**, and every parameter carries an
`=` even when its value is empty.

**Header values are trimmed and their internal runs of spaces collapsed**, and
the signed-header list is sorted, lowercase, and semicolon-joined -- and it
must list exactly the headers that are actually sent. A header added by the
transport after signing invalidates the signature; that is why `host` is
computed here, the same way lua-http computes `:authority`, rather than left
to be filled in later.

**The payload hash is of the bytes on the wire**, and `UNSIGNED-PAYLOAD` for a
presigned URL, because the body of a future upload is not knowable now.

## Presigned URLs

The feature most people actually want, and the one that needs no network: a
URL that lets a browser upload or download directly, for a bounded time,
without the object ever passing through this process. `presign` makes no
request and can be called on a machine with no route to the store at all.

## Errors are values

Every call returns `value, nil` or `nil, reason`. S3 reports failure as an XML
document, and the `<Code>` element is pulled out of it with a pattern rather
than a parser -- deliberately, because adding an XML parser to read one
element would be a dependency to read one element. The full body is kept in
the returned error table for anything the code does not cover.
]]

local crypto = require "akkar.crypto"
local http   = require "akkar.http"
local time   = require "akkar.time"

local M = {}

local ALGORITHM = "AWS4-HMAC-SHA256"

-- The hash of the empty string. Named because it appears in every signature
-- of every request that has no body, and a literal that long in three places
-- is a literal that will be mistyped in one of them.
local EMPTY_SHA256 =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

M.EMPTY_SHA256 = EMPTY_SHA256
M.UNSIGNED = "UNSIGNED-PAYLOAD"

-- ================================================================== encoding

--- RFC 3986 percent-encoding, as SigV4 defines it.
---
--- Not `x-www-form-urlencoded`: a space is `%20`, never `+`. `~` is unreserved
--- and must be left alone -- older encoders escape it, and that alone is
--- enough to make every signature wrong. The hex is upper case because the
--- canonical form says so and a server comparing strings does not forgive.
local function uri_encode(text, encode_slash)
  return (tostring(text):gsub("[^%w%-%_%.%~]", function(c)
    if c == "/" and not encode_slash then return "/" end
    return ("%%%02X"):format(c:byte())
  end))
end

M.uri_encode = uri_encode

--- Encodes an object key as a canonical S3 path.
---
--- NOT NORMALISED. `a//b` and `a/./b` are different objects to S3, so
--- collapsing them -- which every generic URL library does -- would sign a
--- path other than the one requested. Only the segments are encoded.
local function encode_key(key)
  local parts = {}
  for segment in tostring(key):gmatch "[^/]*" do
    parts[#parts + 1] = uri_encode(segment, true)
  end
  return table.concat(parts, "/")
end

M.encode_key = encode_key

--- The canonical query string: sorted, encoded, and every key carrying an `=`.
---
--- `pairs()` order is undefined in Lua, so a table is sorted here; a caller
--- who needs duplicate keys or a fixed order passes a list of `{name, value}`
--- pairs instead, which is sorted the same way.
local function canonical_query(query)
  if query == nil then return "" end
  if type(query) == "string" then return query end

  local pairs_out = {}
  for key, value in pairs(query) do
    if type(key) == "number" and type(value) == "table" then
      pairs_out[#pairs_out + 1] = { uri_encode(value[1], true),
                                    uri_encode(value[2], true) }
    else
      pairs_out[#pairs_out + 1] = { uri_encode(key, true),
                                    uri_encode(value, true) }
    end
  end

  table.sort(pairs_out, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)

  local parts = {}
  for i, pair in ipairs(pairs_out) do
    -- The `=` is present even for an empty value. AWS's canonical form says
    -- so, and a parameter written bare signs differently from one written
    -- `name=`.
    parts[i] = pair[1] .. "=" .. pair[2]
  end
  return table.concat(parts, "&")
end

M.canonical_query = canonical_query

-- ================================================================= the signer

local function hex_sha256(data)
  return crypto.to_hex(crypto.sha256(data or ""))
end

M.hex_sha256 = hex_sha256

--- Lowercased, trimmed, space-collapsed, sorted headers plus their name list.
local function canonical_headers(headers)
  local names = {}
  local values = {}
  for name, value in pairs(headers) do
    local lower = name:lower()
    -- Trimmed AND collapsed. RFC 7230 lets a sender put any run of whitespace
    -- between a header's tokens, and the canonical form has exactly one
    -- space, so a value copied verbatim from a header the caller wrote by
    -- hand signs differently from the same value seen by the server.
    local clean = tostring(value):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    names[#names + 1] = lower
    values[lower] = clean
  end
  table.sort(names)

  local lines = {}
  for i, name in ipairs(names) do
    lines[i] = name .. ":" .. values[name]
  end
  -- The block ends with a newline of its own, and then the blank line that
  -- separates it from the signed-header list is the join below. Two newlines
  -- in a row, and neither is optional.
  return table.concat(lines, "\n") .. "\n", table.concat(names, ";")
end

M.canonical_headers = canonical_headers

--- The canonical request, exactly as AWS defines it.
function M.canonical_request(request)
  local headers, signed = canonical_headers(request.headers)
  return table.concat({
    request.method,
    request.path,
    canonical_query(request.query),
    headers,
    signed,
    request.payload_hash,
  }, "\n"), signed
end

--- The four-step signing key. Each step's OUTPUT is the next step's KEY.
---
--- The chain is what makes a leaked signature useless tomorrow, in another
--- region, for another service: a key derived for `20130524/us-east-1/s3`
--- cannot sign anything else. The literal `AWS4` prefix on the secret is part
--- of it and is not a typo.
function M.signing_key(secret, date, region, service)
  local k = crypto.hmac("AWS4" .. secret, date)
  k = crypto.hmac(k, region)
  k = crypto.hmac(k, service)
  return crypto.hmac(k, "aws4_request")
end

--- Signs a request. Returns a table; nothing here touches the network.
---
--- `amzdate` is accepted directly so that a test can pin the clock to the one
--- in AWS's published example. Without that the vectors are unusable, and a
--- signer with no vector is a signer nobody has checked.
function M.sign(request, credentials)
  local amzdate = request.amzdate
                  or os.date("!%Y%m%dT%H%M%SZ", request.timestamp or time.now())
  local date = amzdate:sub(1, 8)
  local region = credentials.region or "us-east-1"
  local service = credentials.service or "s3"
  local scope = ("%s/%s/%s/aws4_request"):format(date, region, service)

  local creq, signed = M.canonical_request(request)
  local sts = table.concat({
    ALGORITHM, amzdate, scope, hex_sha256(creq),
  }, "\n")

  local key = M.signing_key(credentials.secret_key, date, region, service)
  local signature = crypto.to_hex(crypto.hmac(key, sts))

  return {
    amzdate = amzdate,
    scope = scope,
    signed_headers = signed,
    canonical_request = creq,
    string_to_sign = sts,
    signature = signature,
    credential = credentials.access_key .. "/" .. scope,
    authorization = ("%s Credential=%s/%s, SignedHeaders=%s, Signature=%s")
                    :format(ALGORITHM, credentials.access_key, scope, signed,
                            signature),
  }
end

--- The query parameters of a presigned URL, signature included.
---
--- Split out from `presign` so the vector test can drive it with a fixed
--- clock and a bare host, with no client and no endpoint anywhere in sight.
function M.presign_query(request, credentials)
  local amzdate = request.amzdate
                  or os.date("!%Y%m%dT%H%M%SZ", request.timestamp or time.now())
  local date = amzdate:sub(1, 8)
  local region = credentials.region or "us-east-1"
  local service = credentials.service or "s3"
  local scope = ("%s/%s/%s/aws4_request"):format(date, region, service)

  local _, signed = canonical_headers(request.headers)

  local query = {}
  for name, value in pairs(request.query or {}) do query[name] = value end
  query["X-Amz-Algorithm"] = ALGORITHM
  query["X-Amz-Credential"] = credentials.access_key .. "/" .. scope
  query["X-Amz-Date"] = amzdate
  query["X-Amz-Expires"] = tostring(request.expires or 3600)
  query["X-Amz-SignedHeaders"] = signed
  -- A temporary credential's token is a QUERY parameter here and a header in
  -- the signed-header form. Putting it in the wrong one is a 403 that reads
  -- like a clock problem.
  if credentials.session_token then
    query["X-Amz-Security-Token"] = credentials.session_token
  end

  local signature = M.sign({
    method = request.method,
    path = request.path,
    query = query,
    headers = request.headers,
    -- The body of an upload that has not happened yet cannot be hashed, so
    -- the signature covers everything except it. That is the trade a
    -- presigned PUT makes and it is worth stating: the URL authorises writing
    -- SOMETHING to that key, not writing a particular thing.
    payload_hash = M.UNSIGNED,
    amzdate = amzdate,
  }, credentials)

  query["X-Amz-Signature"] = signature.signature
  return query, signature
end

-- ================================================================ the endpoint

--- Splits `https://host:port/prefix` into its parts.
local function parse_endpoint(endpoint)
  local scheme, rest = endpoint:match "^(%a[%w+.-]*)://(.*)$"
  if not scheme then return nil, "the endpoint needs a scheme: " .. endpoint end
  local authority, path = rest:match "^([^/]+)(.*)$"
  if not authority then return nil, "the endpoint needs a host: " .. endpoint end
  local host, port = authority:match "^(.-):(%d+)$"
  host = host or authority
  port = tonumber(port) or (scheme == "https" and 443 or 80)
  return { scheme = scheme, host = host, port = port,
           prefix = (path == "/" and "" or path) or "" }
end

--- The authority exactly as lua-http will put it on the wire.
---
--- IT MUST MATCH, because `host` is a signed header. lua-http omits the port
--- when it is the default for the scheme, so signing `host:443` against a
--- request that says `host` is a 403 whose message names the signature and
--- not the cause. Computed here rather than read back from the transport,
--- since there is nothing to read it back from until the request is gone.
local function authority_of(endpoint)
  if (endpoint.scheme == "https" and endpoint.port == 443)
     or (endpoint.scheme == "http" and endpoint.port == 80) then
    return endpoint.host
  end
  return ("%s:%d"):format(endpoint.host, endpoint.port)
end

-- =================================================================== the store

local Store = {}
Store.__index = Store

--- Where an object lives: its host, its canonical path, and its URL.
---
--- Two addressing styles, and the default is the one that works everywhere.
--- Virtual-host style (`bucket.example.com`) is what AWS prefers and what
--- MinIO, Garage and a bucket whose name contains a dot all fail at, since
--- the first needs DNS entries nobody made and the last breaks TLS hostname
--- matching. Path style is one string concatenation and no surprises.
function Store:address(key)
  local endpoint = self.endpoint
  local host, path

  if self.path_style then
    host = authority_of(endpoint)
    path = ("%s/%s/%s"):format(endpoint.prefix, uri_encode(self.bucket, true),
                               encode_key(key))
  else
    host = self.bucket .. "." .. authority_of(endpoint)
    path = ("%s/%s"):format(endpoint.prefix, encode_key(key))
  end

  -- A single leading slash however the pieces fell out. A path of `//bucket`
  -- is a different canonical request from `/bucket`, and since the path is
  -- signed unnormalised the difference is a 403 rather than a redirect.
  path = "/" .. path:gsub("^/+", "")

  return host, path, ("%s://%s%s"):format(endpoint.scheme, host, path)
end

--- The `<Code>` an S3 error document carries, and the whole body besides.
---
--- A pattern rather than an XML parser. Reading one element is not worth a
--- dependency, and the body is returned untouched alongside so that anything
--- this does not understand is still in the caller's hands rather than
--- discarded on the way past.
local function s3_error(res)
  local code = res.body and res.body:match "<Code>%s*(.-)%s*</Code>"
  local message = res.body and res.body:match "<Message>%s*(.-)%s*</Message>"
  return {
    status = res.status,
    code = code,
    message = message,
    body = res.body,
  }, ("%s: %s"):format(code or ("HTTP " .. tostring(res.status)),
                       message or "the store refused the request")
end

--- Signs and sends one request.
function Store:call(method, key, options)
  options = options or {}
  local host, path, url = self:address(key)

  local body = options.body
  local payload_hash = body and hex_sha256(body) or EMPTY_SHA256

  local headers = {
    ["host"] = host,
    ["x-amz-content-sha256"] = payload_hash,
  }
  for name, value in pairs(options.headers or {}) do
    headers[name:lower()] = tostring(value)
  end
  if self.session_token then
    headers["x-amz-security-token"] = self.session_token
  end
  if body then
    headers["content-length"] = tostring(#body)
  end

  local signed = M.sign({
    method = method,
    path = path,
    query = options.query,
    headers = headers,
    payload_hash = payload_hash,
  }, self)
  headers["x-amz-date"] = signed.amzdate
  headers["authorization"] = signed.authorization
  -- `host` is removed from what is SENT and kept in what was SIGNED: lua-http
  -- writes the authority itself from the url, and a second `host` header on
  -- the wire is a request most servers reject outright.
  headers["host"] = nil

  local target = url
  local query = canonical_query(options.query)
  if query ~= "" then target = target .. "?" .. query end

  local res, why = self.http:request(method, target, {
    headers = headers, body = body, timeout = options.timeout,
    max_body = options.max_body,
  })
  if not res then return nil, why end
  return res
end

-- ===================================================================== the API

--- Stores an object. Returns `true, etag` or `nil, reason, details`.
function Store:put(key, body, options)
  options = options or {}
  assert(type(body) == "string", "akkar.storage: a body must be a string")

  local headers = {}
  for name, value in pairs(options.headers or {}) do headers[name] = value end
  headers["content-type"] = options.content_type
                            or headers["content-type"] or "application/octet-stream"

  local res, why = self:call("PUT", key, { headers = headers, body = body,
                                           timeout = options.timeout })
  if not res then return nil, why end
  if res.status < 200 or res.status >= 300 then
    local details, message = s3_error(res)
    return nil, message, details
  end
  return true, res.headers and res.headers["etag"]
end

--- Fetches an object. Returns `body, response` or `nil, reason, details`.
---
--- A missing object is an ERROR VALUE and not an empty body, because an empty
--- object is a thing that exists and telling the two apart at the call site is
--- the entire question a `get` is asked.
function Store:get(key, options)
  options = options or {}
  local res, why = self:call("GET", key, options)
  if not res then return nil, why end
  if res.status == 404 then
    return nil, "no such object: " .. tostring(key), { status = 404 }
  end
  if res.status < 200 or res.status >= 300 then
    local details, message = s3_error(res)
    return nil, message, details
  end
  return res.body, res
end

--- Deletes an object. Idempotent, because S3 is: deleting what is not there
--- answers 204, and a caller that has to special-case that is a caller that
--- will forget to.
function Store:delete(key, options)
  local res, why = self:call("DELETE", key, options)
  if not res then return nil, why end
  if res.status < 200 or res.status >= 300 then
    local details, message = s3_error(res)
    return nil, message, details
  end
  return true
end

--- True when the object exists, plus its headers.
function Store:head(key, options)
  local res, why = self:call("HEAD", key, options)
  if not res then return nil, why end
  if res.status == 404 then return false end
  if res.status < 200 or res.status >= 300 then
    local details, message = s3_error(res)
    return nil, message, details
  end
  return true, res.headers
end

--- A URL that works on its own for `expires` seconds. Makes no request.
---
--- The default of fifteen minutes is deliberately short. A presigned URL is a
--- bearer credential in a string that will end up in a log, a referrer header
--- and somebody's chat history, and the only thing limiting the damage is how
--- long it lasts. AWS's own ceiling is seven days; nothing here defaults near
--- it.
function Store:presign(method, key, options)
  options = options or {}
  local host, path, url = self:address(key)

  local query = M.presign_query({
    method = (method or "GET"):upper(),
    path = path,
    query = options.query,
    headers = { host = host },
    expires = options.expires or 900,
    timestamp = options.timestamp,
    amzdate = options.amzdate,
  }, self)

  return url .. "?" .. canonical_query(query)
end

--- Returns a factory, matching `db.connect`, `redis.connect` and
--- `http.connect`.
---
--- The HTTP client is shared and injectable. Shared because the pool lives on
--- it and a fresh client per call would be a fresh pool per call; injectable
--- because a spec needs a transport it can watch, and because an application
--- that already has a client should not open a second set of sockets to the
--- same machine.
function M.connect(config)
  config = config or {}
  assert(config.endpoint, "akkar.storage: an endpoint is required")
  assert(config.bucket, "akkar.storage: a bucket is required")
  assert(config.access_key and config.secret_key,
         "akkar.storage: access_key and secret_key are required")

  local endpoint, why = parse_endpoint(config.endpoint)
  assert(endpoint, why)

  local store = setmetatable({
    endpoint = endpoint,
    bucket = config.bucket,
    region = config.region or "us-east-1",
    service = config.service or "s3",
    access_key = config.access_key,
    secret_key = config.secret_key,
    session_token = config.session_token,
    -- Path style by default: see `Store:address`. The one thing every
    -- S3-compatible server agrees on.
    path_style = config.path_style ~= false,
    http = config.http or http.connect {
      timeout = config.timeout or 30,
      -- Objects are bigger than API responses, and akkar.http refuses rather
      -- than truncating past its ceiling -- so a default sized for JSON would
      -- turn a large download into an error with a confusing name.
      max_body = config.max_body or 64 * 1024 * 1024,
    }(),
  }, Store)

  return function() return store end
end

M.Store = Store
M.parse_endpoint = parse_endpoint
M.authority_of = authority_of

return M
