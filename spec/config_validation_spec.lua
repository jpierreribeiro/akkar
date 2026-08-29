--[[
A setting has a value as well as a name, and both can be wrong.

`app:run{}` has checked option NAMES since early on, for a stated reason: a
mistake found at boot costs a second, and found in production costs an
incident. The check stopped at the name, so this passed it:

    app:run { timeout = os.getenv("REQUEST_TIMEOUT") }

and then answered 500 to every request, because the deadline compares a string
to a number and raises -- while the log said `error_kind=string` and nothing
else. Four more started a server that then did not work: `body_limit = -1`,
`port = "not-a-port"`, `max_concurrent = 0`, and `trusted_proxies` as a string
where a list belongs, which trusts no proxy at all while looking configured.

The second half of the file is the protocol. lua-http accepts HTTP/2 unless
told otherwise, so which version the server speaks is now something the
application says rather than something it inherits. What the ceiling does
about a client that puts many requests in one connection is measured next
door, in http2_admission_spec.lua.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local socket  = require "cqueues.socket"

--- The value checks run before anything binds a socket, so `app:run{}` is
--- safe to call here: a bad value raises long before `server.listen`.
local function running_with(config)
  local app = akkar.new()
  app:get("/x", function() return { ok = true } end)
  config.check_capabilities = false
  return function() return app:run(config) end
end

local function refused(config, expected)
  local ok, err = pcall(running_with(config))
  assert.is_false(ok, "app:run{} accepted " .. expected)
  assert.is_truthy(tostring(err):find(expected, 1, true),
                   "wrong message: " .. tostring(err))
end

describe("app:run{} checks what a setting IS, not only that it exists", function()
  it("refuses a timeout that came out of the environment as a string", function()
    -- The original: it booted, and then every request was a 500.
    refused({ timeout = "30" }, "timeout must be a number of seconds")
  end)

  it("refuses a negative body limit", function()
    refused({ body_limit = -1 }, "body_limit must be a positive whole number")
  end)

  it("refuses a body limit that is not whole", function()
    refused({ body_limit = 1.5 }, "body_limit must be a positive whole number")
  end)

  it("refuses a port that is not a port", function()
    refused({ port = "not-a-port" }, "port must be an integer from 0 to 65535")
    refused({ port = 70000 }, "port must be an integer from 0 to 65535")
    refused({ port = -1 }, "port must be an integer from 0 to 65535")
  end)

  it("refuses max_concurrent = 0, which accepts nothing", function()
    refused({ max_concurrent = 0 }, "max_concurrent must be an integer of at least 1")
  end)

  it("refuses trusted_proxies given as a string", function()
    -- A string is not a list, so the walk over it finds no hop and the
    -- forwarded header is believed from nobody -- silently, while the config
    -- says a proxy is trusted.
    refused({ trusted_proxies = "10.0.0.0/8" }, "trusted_proxies must be a LIST")
  end)

  it("refuses a CIDR that could never match anything", function()
    refused({ trusted_proxies = { "10.0.0.0/33" } }, "is not one")
    refused({ trusted_proxies = { "not-an-address" } }, "is not one")
  end)

  it("refuses a non-boolean where a flag belongs", function()
    refused({ reuseport = "yes" }, "reuseport must be true or false")
    refused({ strict = 1 }, "strict must be true or false")
  end)

  it("refuses a read_timeout of zero, which would never read anything", function()
    refused({ read_timeout = 0 }, "read_timeout must be a positive number")
  end)

  it("says what was passed as well as what was wanted", function()
    local _, err = pcall(running_with { timeout = "30" })
    assert.is_truthy(tostring(err):find('got string "30"', 1, true), tostring(err))
  end)

  it("accepts the values the runtime actually supports", function()
    -- Nothing here binds a socket: `akkar.check_settings` is the same
    -- function `app:run{}` calls, exported so the doctor can use it too.
    assert.has_no.errors(function()
      akkar.check_settings({
        host = "0.0.0.0", port = 0, body_limit = 1, timeout = 0.5,
        read_timeout = 15, shutdown_grace = 0, max_concurrent = 1,
        reuseport = true, strict = false, tls = false, http_version = 1.1,
        trusted_proxies = { "10.0.0.0/8", "127.0.0.1" },
      }, "app:run{}")
    end)
  end)

  it("still allows timeout = false, which means no deadline", function()
    assert.has_no.errors(function()
      akkar.check_settings({ timeout = false }, "app:run{}")
    end)
  end)
end)

describe("app:test{} checks the same values", function()
  it("refuses a string timeout rather than 500ing every call", function()
    local app = akkar.new()
    app:get("/x", function() return { ok = true } end)
    local ok, err = pcall(function() return app:test { timeout = "30" } end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("timeout must be a number", 1, true))
  end)
end)

-- ====================================================== the protocol, stated
--
-- The probe is the HTTP/2 client connection preface followed by an empty
-- SETTINGS frame, which is exactly what `curl --http2-prior-knowledge` sends.
-- An h2 server answers with a SETTINGS frame of its own; an HTTP/1.1 server
-- has no idea what it just received and never does.
local PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" .. "\0\0\0\4\0\0\0\0\0"

local function speaks_h2(config)
  local app = akkar.new()
  app:get("/ping", function() return { pong = true } end)

  local reply
  local cq = cqueues.new()
  cq:wrap(function()
    pcall(function()
      config.check_capabilities = false
      config.log = akkar.log.new { level = "error", format = "text",
                                   sink = function() end }
      app:run(config)
    end)
  end)
  cq:wrap(function()
    cqueues.sleep(0.15)
    local s = socket.connect("127.0.0.1", config.port)
    s:setmode("bn", "bn")
    s:settimeout(0.75)
    pcall(function()
      s:write(PREFACE)
      s:flush()
      reply = s:read(9)
    end)
    pcall(function() s:close() end)
    app:stop(1)
  end)
  assert(cq:loop())

  -- A SETTINGS frame: three length bytes, then the type, which is 0x04.
  return reply ~= nil and #reply == 9 and reply:byte(4) == 4
end

describe("which HTTP version the server speaks", function()
  it("is 1.1 by default, because that is what the runtime was written for", function()
    -- It used to be both, on by default, and mentioned in no document.
    assert.is_false(speaks_h2 { port = 8641 })
  end)

  it("is 2 when the application asks for it", function()
    -- Available, deliberately, and bounded when chosen: the ceiling counts
    -- requests rather than connections, and h2 clients are told the number.
    assert.is_true(speaks_h2 { port = 8642, http_version = 2 })
  end)

  it("refuses a version that is not a version", function()
    refused({ http_version = 3 }, "http_version must be 1.0, 1.1 or 2")
    refused({ http_version = "1.1" }, "http_version must be 1.0, 1.1 or 2")
  end)
end)
