--[[
akkar.storage — checked against AWS's own worked examples.

## Why the vectors are the whole point of this file

A Signature Version 4 implementation has exactly two states: accepted by the
server, and rejected by the server with a message that names the signature and
nothing else. There is no partial credit and no way to tell which state you
are in by reading the code, because a signature computed from a
misunderstanding looks precisely as convincing as a correct one -- sixty-four
hex characters either way.

A hand-written unit test does not help. It is written from the same
understanding as the implementation, so it agrees with whatever the
implementation does. The ONLY thing that catches this class of mistake is a
worked example somebody else published together with the answer.

So all three of AWS's published S3 examples are here, and each is asserted at
three depths -- canonical request, string-to-sign, signature. The depth is not
thoroughness for its own sake: a final-hash comparison tells you that
something is wrong out of a dozen candidate rules, and the canonical request
tells you which one.

  * `GET /test.txt` with `Range` -- AWS S3 API Reference, "Authenticating
    Requests: Using the Authorization Header", Example: GET Object.
  * `PUT /test%24file.text` -- same page, Example: PUT Object.
  * The presigned `GET /test.txt` -- "Authenticating Requests: Using Query
    Parameters", the full worked example.

## What a fake transport covers here, and what it does not

Everything below the signature is deterministic and is tested for real:
encoding, path construction, query canonicalisation, URL assembly, the
mapping from an S3 error document to a returned error value.

One request does leave the process, at the bottom of this file, against
akkar's own test server -- which knows nothing about buckets and answers 404.
Its answer is meaningless on purpose; what it proves is that a complete signed
request is SENDABLE, which a table that records what it was handed cannot say.

**NOT covered: any request to a real object store.** There is no S3, no MinIO
and no credential anywhere here, so what remains unverified is the half a
vector cannot reach -- whether a live store accepts these bytes -- and
specifically: TLS, virtual-host addressing against real DNS, the redirect a
region mismatch produces, multipart upload, and chunked upload signing, which
this module does not implement at all. The vectors make a wrong signature
impossible to ship silently; they do not make an integration test unnecessary.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local storage = require "akkar.storage"
local raw     = require "spec.support.raw_client"

-- ============================================================== the transport

--- A transport that records and answers. Stands in for `akkar.http`'s client.
---
--- It implements `request` because that is the single method `Store:call`
--- reaches for; if that ever grows, this fails loudly rather than silently
--- taking a different path from production.
local function fake_http(answers)
  local calls = {}
  return {
    calls = calls,
    request = function(_, method, url, options)
      calls[#calls + 1] = { method = method, url = url, options = options }
      local answer = answers[#calls] or answers[1]
      if answer == nil then return nil, "no answer configured" end
      if answer.error then return nil, answer.error end
      return { status = answer.status, headers = answer.headers or {},
               body = answer.body or "" }
    end,
  }
end

describe("akkar.storage signing", function()

  -- The credentials AWS uses in its S3 examples. Published, not secret, and
  -- using anything else would make the expected signatures meaningless.
  --
  -- NOTE THE SLASH IN `MDENG/bPxRfi`. AWS ships two example secrets that
  -- differ in exactly that one character -- the general SigV4 test suite uses
  -- `MDENG+bPxRfi`, the S3 pages use `MDENG/bPxRfi` -- and this file was
  -- written with the wrong one first. Every canonical request and every
  -- string-to-sign matched; only the final hash did not, and the difference
  -- was one byte in a forty-character constant.
  --
  -- That is the failure mode this whole file exists for, arriving on
  -- schedule. A signer checked against nothing would have shipped, looked
  -- entirely convincing, and been refused by every server on earth.
  local credentials = {
    access_key = "AKIAIOSFODNN7EXAMPLE",
    secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region = "us-east-1",
    service = "s3",
  }

  it("matches AWS's GET Object example, byte for byte", function()
    local signed = storage.sign({
      method = "GET",
      path = "/test.txt",
      query = nil,
      headers = {
        ["host"] = "examplebucket.s3.amazonaws.com",
        ["range"] = "bytes=0-9",
        ["x-amz-content-sha256"] = storage.EMPTY_SHA256,
        ["x-amz-date"] = "20130524T000000Z",
      },
      payload_hash = storage.EMPTY_SHA256,
      amzdate = "20130524T000000Z",
    }, credentials)

    assert.equal(table.concat({
      "GET",
      "/test.txt",
      "",
      "host:examplebucket.s3.amazonaws.com",
      "range:bytes=0-9",
      "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "x-amz-date:20130524T000000Z",
      "",
      "host;range;x-amz-content-sha256;x-amz-date",
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    }, "\n"), signed.canonical_request)

    assert.equal(table.concat({
      "AWS4-HMAC-SHA256",
      "20130524T000000Z",
      "20130524/us-east-1/s3/aws4_request",
      "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972",
    }, "\n"), signed.string_to_sign)

    assert.equal("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
                 signed.signature)
  end)

  it("matches AWS's PUT Object example, encoded path and signed payload",
     function()
    -- The interesting one. `test$file.text` is signed as
    -- `/test%24file.text`, which is where an encoder that treats `$` as safe
    -- -- or that encodes the `/` along with it -- goes silently wrong.
    local payload = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"

    local signed = storage.sign({
      method = "PUT",
      path = storage.encode_key("/test$file.text"),
      headers = {
        ["content-type"] = "text/plain",
        ["date"] = "Fri, 24 May 2013 00:00:00 GMT",
        ["host"] = "examplebucket.s3.amazonaws.com",
        ["x-amz-content-sha256"] = payload,
        ["x-amz-date"] = "20130524T000000Z",
        ["x-amz-storage-class"] = "REDUCED_REDUNDANCY",
      },
      payload_hash = payload,
      amzdate = "20130524T000000Z",
    }, credentials)

    assert.equal("/test%24file.text", storage.encode_key("/test$file.text"))

    assert.equal(table.concat({
      "PUT",
      "/test%24file.text",
      "",
      "content-type:text/plain",
      "date:Fri, 24 May 2013 00:00:00 GMT",
      "host:examplebucket.s3.amazonaws.com",
      "x-amz-content-sha256:" .. payload,
      "x-amz-date:20130524T000000Z",
      "x-amz-storage-class:REDUCED_REDUNDANCY",
      "",
      "content-type;date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class",
      payload,
    }, "\n"), signed.canonical_request)

    assert.equal(table.concat({
      "AWS4-HMAC-SHA256",
      "20130524T000000Z",
      "20130524/us-east-1/s3/aws4_request",
      "0f10f84734b64a0f7ac71f28a26c6d34d07bc39df988e9e9c39bfc1fc154b6cd",
    }, "\n"), signed.string_to_sign)

    assert.equal("f093977030bf8d8069918f1b3546fd02cf697d43e763c40d58c109a2e197bdac",
                 signed.signature)
  end)

  it("matches AWS's presigned URL example", function()
    local query, signed = storage.presign_query({
      method = "GET",
      path = "/test.txt",
      headers = { host = "examplebucket.s3.amazonaws.com" },
      expires = 86400,
      amzdate = "20130524T000000Z",
    }, credentials)

    assert.equal(table.concat({
      "GET",
      "/test.txt",
      "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host",
      "host:examplebucket.s3.amazonaws.com",
      "",
      "host",
      "UNSIGNED-PAYLOAD",
    }, "\n"), signed.canonical_request)

    assert.equal(table.concat({
      "AWS4-HMAC-SHA256",
      "20130524T000000Z",
      "20130524/us-east-1/s3/aws4_request",
      "3bfa292879f6447bbcda7001decf97f4a54dc650c8942174ae0a9121cf58ad04",
    }, "\n"), signed.string_to_sign)

    assert.equal("aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
                 query["X-Amz-Signature"])
  end)

  it("derives a signing key that is scoped to the day, region and service",
     function()
    -- The chain itself, so that a change to it fails HERE rather than three
    -- vectors later with no indication of which step moved.
    local key = storage.signing_key("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                                    "20130524", "us-east-1", "s3")
    local other = storage.signing_key("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                                      "20130525", "us-east-1", "s3")
    assert.equal(32, #key)
    assert.is_false(key == other)
  end)
end)

describe("akkar.storage encoding", function()
  it("percent-encodes to RFC 3986 and not to form rules", function()
    -- A space is %20 and never `+`; `~` is unreserved; hex is upper case.
    -- Each of these three, on its own, is enough to make every signature
    -- against a real server fail with a message that mentions none of them.
    assert.equal("a%20b", storage.uri_encode "a b")
    assert.equal("~", storage.uri_encode "~")
    assert.equal("%C3%A9", storage.uri_encode "é")
    assert.equal("a%2Fb", storage.uri_encode("a/b", true))
    assert.equal("a/b", storage.uri_encode("a/b", false))
  end)

  it("encodes a key's segments without normalising the path", function()
    -- `a//b` and `a/../b` are DISTINCT KEYS to S3. A URL library that tidies
    -- them signs a path other than the one the caller asked for, and the
    -- object it then fails to find is one that exists.
    assert.equal("a//b", storage.encode_key "a//b")
    assert.equal("a/../b", storage.encode_key "a/../b")
    assert.equal("photos/2024/me%20and%20you.jpg",
                 storage.encode_key "photos/2024/me and you.jpg")
  end)

  it("sorts the canonical query and keeps an = on every parameter", function()
    assert.equal("a=1&b=2&c=", storage.canonical_query { b = "2", a = "1", c = "" })
    assert.equal("x-amz-meta-a%2Fb=c%20d",
                 storage.canonical_query { ["x-amz-meta-a/b"] = "c d" })
  end)

  it("omits a default port from the host it signs", function()
    -- The signed `host` has to be what lua-http actually writes as the
    -- authority, and lua-http drops the port when it is the scheme's default.
    -- Signing `example.com:443` against a request that says `example.com` is
    -- a 403 that names the signature and not the port.
    assert.equal("example.com",
                 storage.authority_of(storage.parse_endpoint "https://example.com"))
    assert.equal("example.com",
                 storage.authority_of(storage.parse_endpoint "https://example.com:443"))
    assert.equal("127.0.0.1:9000",
                 storage.authority_of(storage.parse_endpoint "http://127.0.0.1:9000"))
  end)
end)

describe("akkar.storage requests", function()
  local function store(config)
    config = config or {}
    return storage.connect {
      endpoint = config.endpoint or "http://127.0.0.1:9000",
      bucket = config.bucket or "photos",
      region = "us-east-1",
      access_key = "AKIAIOSFODNN7EXAMPLE",
      secret_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      path_style = config.path_style,
      http = config.http,
    }()
  end

  it("addresses an object path-style by default", function()
    local host, path, url = store():address "a/b c.jpg"
    assert.equal("127.0.0.1:9000", host)
    assert.equal("/photos/a/b%20c.jpg", path)
    assert.equal("http://127.0.0.1:9000/photos/a/b%20c.jpg", url)
  end)

  it("addresses an object virtual-host style when asked", function()
    local host, path, url = store { endpoint = "https://s3.amazonaws.com",
                                    path_style = false }:address "a.jpg"
    assert.equal("photos.s3.amazonaws.com", host)
    assert.equal("/a.jpg", path)
    assert.equal("https://photos.s3.amazonaws.com/a.jpg", url)
  end)

  it("puts an object and sends the signature with it", function()
    local transport = fake_http { { status = 200, headers = { etag = '"abc"' } } }
    local ok, etag = store { http = transport }:put("a.txt", "hello",
                                                    { content_type = "text/plain" })
    assert.is_true(ok)
    assert.equal('"abc"', etag)

    local call = transport.calls[1]
    assert.equal("PUT", call.method)
    assert.equal("http://127.0.0.1:9000/photos/a.txt", call.url)
    assert.equal("hello", call.options.body)
    assert.equal("text/plain", call.options.headers["content-type"])

    -- The payload hash is of the bytes actually sent, and the authorization
    -- names the same headers it signed.
    assert.equal(storage.hex_sha256 "hello",
                 call.options.headers["x-amz-content-sha256"])
    assert.is_truthy(call.options.headers["authorization"]
                     :find("SignedHeaders=content-length;content-type;host;"
                           .. "x-amz-content-sha256", 1, true))

    -- HOST IS SIGNED AND NOT SENT. lua-http writes the authority from the
    -- url, and a second `host` header on the wire is a request most servers
    -- reject outright.
    assert.is_nil(call.options.headers["host"])
  end)

  it("gets an object", function()
    local transport = fake_http { { status = 200, body = "bytes" } }
    local body, res = store { http = transport }:get "a.txt"
    assert.equal("bytes", body)
    assert.equal(200, res.status)
    assert.equal("GET", transport.calls[1].method)
  end)

  it("reports a missing object as an error and not as an empty body", function()
    -- An empty object EXISTS. Returning "" for a key that is not there makes
    -- the two indistinguishable at the call site, which is the one question
    -- a get is asked.
    local transport = fake_http { { status = 404, body = "<Error/>" } }
    local body, why, details = store { http = transport }:get "gone.txt"
    assert.is_nil(body)
    assert.is_string(why)
    assert.equal(404, details.status)
  end)

  it("turns an S3 error document into a returned value", function()
    local transport = fake_http { { status = 403, body =
      "<?xml version=\"1.0\"?><Error><Code>SignatureDoesNotMatch</Code>"
      .. "<Message>The request signature we calculated does not match</Message>"
      .. "</Error>" } }
    local ok, why, details = store { http = transport }:put("a.txt", "x")
    assert.is_nil(ok)
    assert.equal("SignatureDoesNotMatch", details.code)
    assert.equal(403, details.status)
    assert.is_truthy(why:find("SignatureDoesNotMatch", 1, true))
    -- The whole document survives, so a code this module has never heard of
    -- is still in the caller's hands.
    assert.is_truthy(details.body:find("<Error>", 1, true))
  end)

  it("passes a transport failure straight back", function()
    local transport = fake_http { { error = "connection refused" } }
    local ok, why = store { http = transport }:get "a.txt"
    assert.is_nil(ok)
    assert.equal("connection refused", why)
  end)

  it("deletes an object", function()
    local transport = fake_http { { status = 204 } }
    assert.is_true(store { http = transport }:delete "a.txt")
    assert.equal("DELETE", transport.calls[1].method)
  end)

  it("builds a presigned URL without making a request", function()
    local transport = fake_http {}
    local url = store { http = transport }:presign("GET", "a b.txt",
                                                   { expires = 600 })
    assert.equal(0, #transport.calls)   -- no network, on purpose
    assert.is_truthy(url:find("http://127.0.0.1:9000/photos/a%%20b.txt%?"))
    assert.is_truthy(url:find("X-Amz-Algorithm=AWS4-HMAC-SHA256", 1, true))
    assert.is_truthy(url:find("X-Amz-Expires=600", 1, true))
    assert.is_truthy(url:find("X-Amz-Signature=", 1, true))
    -- The credential's slashes are encoded inside the query value.
    assert.is_truthy(url:find("%2Faws4_request", 1, true))
  end)

  it("defaults a presigned URL to fifteen minutes", function()
    -- A presigned URL is a bearer credential in a string that ends up in
    -- logs, referrers and chat history. The only thing bounding the damage is
    -- how long it lasts, so the default is short and stated.
    local url = store { http = fake_http {} }:presign("GET", "a.txt")
    assert.is_truthy(url:find("X-Amz-Expires=900", 1, true))
  end)

  it("refuses to be built without credentials or a bucket", function()
    assert.has_error(function()
      storage.connect { endpoint = "http://x", bucket = "b" }
    end)
    assert.has_error(function()
      storage.connect { endpoint = "http://x", access_key = "a", secret_key = "b" }
    end)
    assert.has_error(function()
      storage.connect { endpoint = "no-scheme", bucket = "b",
                        access_key = "a", secret_key = "b" }
    end)
  end)
end)

--[[
One request that actually leaves the process.

A fake transport proves the signature is right and proves NOTHING about
whether the bytes are sendable: a header lua-http rejects, a `content-length`
written twice, an authorization value containing a character the header
serialiser refuses -- none of those are visible to a table that records what
it was handed.

So one request goes over a real socket to a real server. It is akkar's own
test server rather than an object store, so the ANSWER is meaningless -- it
knows nothing about buckets and says 404. What is being asserted is that a
complete, signed S3 request travels through `akkar.http` and comes back as a
response rather than as an error, which is the one thing a fake cannot say.
]]
describe("akkar.storage over a real socket", function()
  if not raw.available() then
    pending "no Lua interpreter to spawn a server with; skipping"
    return
  end

  local stop, port

  setup(function()
    stop, port = raw.start(8480)
    assert(stop, "the server did not start: " .. tostring(port))
  end)

  teardown(function() if stop then stop() end end)

  it("sends a signed request and reads the answer back", function()
    local err
    local cq = cqueues.new()
    cq:wrap(function()
      local ok, why = pcall(function()
        local store = storage.connect {
          endpoint = "http://127.0.0.1:" .. port,
          bucket = "photos",
          region = "us-east-1",
          access_key = "AKIAIOSFODNN7EXAMPLE",
          secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        }()

        -- 404 with a reason, not a transport failure: the request was
        -- written, accepted, answered and read.
        local body, reason, details = store:get "a/b c.jpg"
        assert.is_nil(body)
        assert.is_string(reason)
        assert.equal(404, details.status)

        -- And a PUT, because that is the path with a body, a payload hash and
        -- a `content-length` -- and the one that used to cost a second per
        -- object to lua-http's `expect: 100-continue`.
        local put_ok, put_why = store:put("a.txt", string.rep("x", 4096))
        assert.is_nil(put_ok)                 -- the test server has no bucket
        assert.is_string(put_why)
        assert.is_truthy(put_why:find("404", 1, true)
                         or put_why:find("HTTP", 1, true))

        store.http:close()
      end)
      if not ok then err = why end
    end)
    assert(cq:loop(30))
    if err then error(err, 0) end
  end)
end)
