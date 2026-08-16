--[[
HTTPS, and the boundary it used to breach.

`tls` and `ctx` were whitelisted options passed straight through to lua-http,
so serving HTTPS meant the application built a luaossl context by hand -- two
substrate libraries in application configuration, in the one place where
getting it wrong is a security problem rather than an inconvenience. And the
option had NO TEST AT ALL: `app:run { tls = ... }` was documented and never
once exercised.

akkar answers `tls = { certificate = ..., key = ... }` itself now. `ctx`
survives as the named escape hatch, so `grep ctx` is the complete list of
applications reaching past the boundary.

Skipped when luaossl or the openssl command line is missing, the same way the
Teal spec skips: needing a certificate authority to run the suite would be
worse than the gap it closes.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

local function have(module)
  return (pcall(require, module))
end

local function openssl_cli()
  local pipe = io.popen "openssl version 2>/dev/null"
  if not pipe then return false end
  local out = pipe:read "a"
  pipe:close()
  return out and out:find "OpenSSL" ~= nil
end

if not (have "openssl.ssl.context" and openssl_cli()) then
  describe("akkar over TLS", function()
    pending "luaossl or the openssl command line is missing; skipping"
  end)
  return
end

local cqueues = require "cqueues"
local request = require "http.request"
local tls     = require "http.tls"
local ssl_ctx = require "openssl.ssl.context"

--- A throwaway self-signed pair, made per run and left in /tmp.
local function certificate_pair()
  local dir = os.tmpname()
  os.remove(dir)
  os.execute("mkdir -p " .. dir)
  local key, cert = dir .. "/key.pem", dir .. "/cert.pem"
  local ok = os.execute(
    ("openssl req -x509 -newkey rsa:2048 -nodes -keyout %s -out %s " ..
     "-days 1 -subj /CN=localhost >/dev/null 2>&1"):format(key, cert))
  if not ok then return nil end
  return cert, key, dir
end

describe("akkar over TLS", function()
  it("serves HTTPS from a certificate and a key, with no luaossl in sight", function()
    local cert, key, dir = certificate_pair()
    assert.is_truthy(cert, "could not create a self-signed certificate")

    local PORT = 8387
    local app = akkar.new()
    app:get("/secure", function() return { encrypted = true } end)

    local status, body
    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run {
          port = PORT, check_capabilities = false,
          -- The whole point: paths, not a context object.
          tls = { certificate = cert, key = key },
          log = akkar.log.new { level = "error", sink = function() end },
        }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.4)
      pcall(function()
        local req = request.new_from_uri("https://127.0.0.1:" .. PORT .. "/secure")
        -- Self-signed: the test is that the handshake happens and the body
        -- arrives, not that a throwaway certificate chains to a real CA.
        local client = tls.new_client_context()
        client:setVerify(ssl_ctx.VERIFY_NONE)
        req.ctx = client
        req.headers:upsert(":authority", "localhost")

        local headers, stream = req:go(10)
        if headers then
          status = tonumber(headers:get ":status")
          body = stream:get_body_as_string(5)
        end
      end)
      cqueues.sleep(0.1)
      app:stop(2)
    end)
    assert(cq:loop(30))

    os.execute("rm -rf " .. dir)

    assert.equal(200, status, "the TLS handshake or the request failed")
    assert.is_truthy(body and body:find("encrypted", 1, true))
  end)

  it("says what is missing rather than failing inside luaossl", function()
    local app = akkar.new()
    app:get("/", function() return { ok = true } end)

    local ok, err = pcall(function()
      app:run { port = 8386, check_capabilities = false,
                tls = { certificate = "-----BEGIN CERTIFICATE-----\nnonsense\n" },
                log = akkar.log.new { level = "error", sink = function() end } }
    end)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("tls needs `key`", 1, true),
      "expected a message naming the missing field, got: " .. tostring(err))
  end)
end)
