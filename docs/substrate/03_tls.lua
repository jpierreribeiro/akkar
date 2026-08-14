--[[
Does TLS work against OpenSSL 3.0.13?

This was the risk marked HIGH in docs/PLAN.md: luaossl against OpenSSL 3.x has
historically been troublesome, and if it fails the substrate choice reopens.

Compiling proves nothing — luaossl compiles with deprecation warnings.  What
proves it is a complete handshake with real traffic on top.

The test starts an HTTPS server with a self-signed certificate and makes a
request against it inside the same cqueues controller.

  setup:
    mkdir -p /tmp/akkar-tls
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout /tmp/akkar-tls/key.pem -out /tmp/akkar-tls/cert.pem \
      -days 2 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1"

  run: lua5.4 docs/substrate/03_tls.lua
]]

local cqueues  = require "cqueues"
local server   = require "http.server"
local request  = require "http.request"
local headers  = require "http.headers"
local http_tls = require "http.tls"
local ssl_ctx  = require "openssl.ssl.context"
local x509     = require "openssl.x509"
local pkey     = require "openssl.pkey"

local PORT = 8443
local DIR  = os.getenv "AKKAR_CERT_DIR" or "/tmp/akkar-tls"

local function read(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read "a"
  f:close()
  return data
end

print(("="):rep(62))
print("TLS against OpenSSL 3.0.13")
print(("="):rep(62))
print()

local server_ctx = http_tls.new_server_context()
server_ctx:setCertificate(x509.new(read(DIR .. "/cert.pem")))
server_ctx:setPrivateKey(pkey.new(read(DIR .. "/key.pem")))
print("server context .......... created")

local client_ctx = http_tls.new_client_context()
client_ctx:setVerify(ssl_ctx.VERIFY_NONE)   -- self-signed certificate
print("client context .......... created (verification off, self-signed cert)")
print()

local cq = cqueues.new()

local s = assert(server.listen {
  host = "127.0.0.1", port = PORT, tls = true, ctx = server_ctx,
  onstream = function(_, stream)
    local h = stream:get_headers()
    local rh = headers.new()
    rh:append(":status", "200")
    rh:append("content-type", "application/json")
    stream:write_headers(rh, false)
    stream:write_chunk('{"tls":true,"path":"' .. (h:get ":path" or "") .. '"}', true)
    stream:shutdown()
  end,
  onerror = function(_, _, op, err)
    io.stderr:write(("[tls] %s: %s\n"):format(op, tostring(err)))
  end,
})
assert(s:listen())
cq:wrap(function() s:loop() end)

local result, failure
cq:wrap(function()
  local ok, err = pcall(function()
    local req = request.new_from_uri("https://127.0.0.1:" .. PORT .. "/hello")
    req.ctx = client_ctx
    req.headers:upsert(":authority", "127.0.0.1")
    local res_headers, stream = assert(req:go(10))

    -- Introspection must happen BEFORE reading the body: once the response
    -- ends the socket may already be closed, and checktls() fails there.
    local tls = stream.connection:checktls()
    local tls_version, cipher = "?", "?"
    if tls then
      pcall(function() tls_version = tls:getVersion() end)
      pcall(function() cipher = tls:getCipherInfo().name end)
    end

    local body = assert(stream:get_body_as_string())
    result = {
      status = res_headers:get ":status", body = body,
      tls_version = tls_version, cipher = cipher, handshake = tls ~= nil,
    }
    stream:shutdown()
  end)
  if not ok then failure = err end
  s:close()
end)

local ok, err = cq:loop(15)
if not ok then failure = failure or err end

print(("="):rep(62))
if result then
  print("handshake ............... COMPLETE")
  print("status .................. " .. tostring(result.status))
  print("body .................... " .. tostring(result.body))
  print("TLS version ............. " .. tostring(result.tls_version) .. "  (772 = TLS 1.3)")
  print("cipher .................. " .. tostring(result.cipher))
  print()
  print("VERDICT: TLS works.  the plan's high risk is cleared.")
else
  print("VERDICT: TLS FAILED")
  print("  " .. tostring(failure))
  print()
  print("  the substrate choice reopens — probably OpenResty or Redbean.")
end
print(("="):rep(62))
os.exit(result and 0 or 1)
