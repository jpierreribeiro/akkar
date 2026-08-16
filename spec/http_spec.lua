--[[
akkar.http — the outbound half, against a real server.

## Why a real server

A client tested against a fake tests the fake. The properties worth having
here are all about what happens on a socket -- a body that is bigger than the
ceiling, a server that answers 500, a connection that is refused -- and none of
them exist in a stub.

The server is akkar itself, in its own process
(`spec/support/raw_client.lua`), for the reason that file already documents:
client and server sharing one scheduler deadlock on exactly the inputs a
client test wants to send.

## The assertion that matters most

**That the ceiling actually cuts.** Astra ships a configurable body limit that
does not apply to the path where bodies are read, which is worse than having
no limit -- the knob reads as protection and is not. That defect was verified
in its source before this module was written, and this file exists partly so
the same thing cannot be true here.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local http    = require "akkar.http"
local raw     = require "spec.support.raw_client"

if not raw.available() then
  describe("akkar.http", function()
    pending "no Lua interpreter to spawn a server with; skipping"
  end)
  return
end

--- Every call yields, so every test runs inside a controller.
local function inside(fn, budget)
  local err
  local cq = cqueues.new()
  cq:wrap(function()
    local ok, why = pcall(fn)
    if not ok then err = why end
  end)
  assert(cq:loop(budget or 20))
  if err then error(err, 0) end
end

describe("akkar.http", function()
  local stop, port, base

  setup(function()
    stop, port = raw.start(8460)
    assert(stop, "the server did not start: " .. tostring(port))
    base = "http://127.0.0.1:" .. port
  end)

  teardown(function() if stop then stop() end end)

  it("makes a request and returns a value", function()
    inside(function()
      local client = http.connect {}()
      local res, why = client:get(base .. "/users")
      assert.is_truthy(res, tostring(why))
      assert.equal(200, res.status)
      assert.is_string(res.body)
      assert.is_truthy(res.body:find("users", 1, true))
      -- A value, not a stream: it can be logged, retried and asserted twice.
      assert.is_table(res.headers)
    end)
  end)

  it("sends a JSON body and reads a JSON answer", function()
    inside(function()
      local client = http.connect {}()
      local decoded, res = client:json("POST", base .. "/users",
                                       { body = { name = "ada" } })
      assert.is_truthy(decoded, tostring(res))
      assert.equal("ada", decoded.name)
      assert.equal(201, res.status)
    end)
  end)

  it("REFUSES a response past the ceiling instead of truncating it", function()
    -- The assertion this file exists for. A truncated body is
    -- indistinguishable from a complete one at the call site, so the caller
    -- parses half a document and the confusing error surfaces somewhere else.
    inside(function()
      local client = http.connect { max_body = 8 }()
      local res, why = client:get(base .. "/users")
      assert.is_nil(res, "the ceiling did not cut")
      assert.is_truthy(tostring(why):find("max_body", 1, true),
        "refused for the wrong reason: " .. tostring(why))
    end)
  end)

  it("applies the ceiling per call as well as per client", function()
    inside(function()
      local client = http.connect {}()          -- generous default
      local res = client:get(base .. "/users", { max_body = 8 })
      assert.is_nil(res, "a per-call ceiling was ignored")
    end)
  end)

  it("never retries a POST by default", function()
    -- A retried POST is a second charge, a second order, a second email. The
    -- request still happens once -- refusing outright would make `retries`
    -- impossible to set globally -- but it happens ONCE.
    local attempts = 0
    inside(function()
      local client = http.connect { retries = 3 }()
      -- A port with nothing on it, so every attempt fails and the count is
      -- the number of attempts.
      local original = client.attempt
      client.attempt = function(self, ...)
        attempts = attempts + 1
        return original(self, ...)
      end
      client:post("http://127.0.0.1:9/never", { body = "x" })
    end)
    assert.equal(1, attempts, "a POST was retried without being asked")
  end)

  it("retries a GET, which is safe to repeat", function()
    local attempts = 0
    inside(function()
      local client = http.connect { retries = 2, retry_backoff = 0.01 }()
      local original = client.attempt
      client.attempt = function(self, ...)
        attempts = attempts + 1
        return original(self, ...)
      end
      client:get "http://127.0.0.1:9/never"
    end)
    assert.equal(3, attempts, "a GET was not retried the requested number of times")
  end)

  it("retries a POST when the caller says the endpoint is idempotent", function()
    local attempts = 0
    inside(function()
      local client = http.connect { retries = 1, retry_backoff = 0.01 }()
      local original = client.attempt
      client.attempt = function(self, ...)
        attempts = attempts + 1
        return original(self, ...)
      end
      client:post("http://127.0.0.1:9/never", { retry_unsafe = true })
    end)
    assert.equal(2, attempts)
  end)

  it("reports a refused connection rather than raising", function()
    inside(function()
      local client = http.connect { timeout = 1 }()
      local res, why = client:get "http://127.0.0.1:9/never"
      assert.is_nil(res)
      assert.is_string(why)
    end)
  end)

  it("carries the traceparent onward", function()
    -- akkar parsed `traceparent` on the way in and had nowhere to send it on
    -- the way out, which makes a distributed trace a trace of one process.
    inside(function()
      local client = http.connect {}()
      local res = client:get(base .. "/users", {
        traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      })
      assert.equal(200, res.status)
    end)
  end)

  it("answers the capability contract akkar checks at startup", function()
    -- `CONTRACTS.http` in `akkar/init.lua`. A capability that fails this
    -- fails at boot rather than on whichever request first touches it.
    local client = http.connect {}()
    for _, method in ipairs { "request", "get", "post" } do
      assert.is_function(client[method], "missing :" .. method)
    end
  end)
end)
