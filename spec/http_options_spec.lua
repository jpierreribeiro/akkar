-- Option validation is pure and must not depend on a listening socket.  A
-- typo in `timeout`, `max_body`, or `retries` silently removes a safety bound,
-- so it is a startup/call-site error rather than transport behaviour.

package.path = "./?.lua;./?/init.lua;" .. package.path

local http      = require "akkar.http"
local execution = require "akkar.execution"

describe("akkar.http option names", function()
  it("keeps the shared client's public identity when injected", function()
    local provider = http.connect {}
    local client = provider()
    local record = { capabilities = { http = provider } }
    local carrier = setmetatable({ id = "http-identity" }, {
      __index = function(self, key)
        return execution.acquire(self, record, key)
      end,
    })

    assert.is_true(rawequal(client, carrier.http))
    assert.equal(http.Client, getmetatable(carrier.http))
    assert.is_nil(record.released)
  end)

  it("rejects an unknown connect option and suggests the nearest name", function()
    assert.has_error(function()
      http.connect { timout = 1 }
    end, "unknown http.connect option 'timout'; did you mean 'timeout'?")
  end)

  it("rejects an unknown request option before attempting network I/O", function()
    local client = http.connect {}()
    local attempted = false
    client.attempt = function()
      attempted = true
      return { status = 200, headers = {}, body = "" }
    end

    assert.has_error(function()
      client:get("http://example.test", { max_bdy = 8 })
    end, "unknown HTTP request option 'max_bdy'; did you mean 'max_body'?")
    assert.is_false(attempted)
  end)

  it("accepts every documented connect and request option", function()
    local client = http.connect {
      headers = {}, timeout = 1, max_body = 8, retries = 0,
      retry_backoff = 0, pool_size = 1, reuse = false,
      http_version = 1.1, breaker = nil,
    }()
    client.attempt = function()
      return { status = 200, headers = {}, body = "" }
    end

    local res = client:request("POST", "http://example.test", {
      headers = {}, body = "", timeout = 1, max_body = 8, retries = 0,
      retry_backoff = 0, retry_unsafe = true,
      traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    })
    assert.equal(200, res.status)
  end)

  it("rejects invalid safety bounds when the client is configured", function()
    assert.has_error(function()
      http.connect(false)
    end, "http.connect options must be a table")
    assert.has_error(function()
      http.connect { retries = -1 }
    end, "http.connect option 'retries' must be a non-negative integer")
    assert.has_error(function()
      http.connect { pool_size = 0 }
    end, "http.connect option 'pool_size' must be a positive integer")
    assert.has_error(function()
      http.connect { timeout = "1" }
    end, "http.connect option 'timeout' must be a non-negative finite number")
  end)

  it("rejects invalid per-request values before attempting network I/O", function()
    local client = http.connect {}()
    local attempted = false
    client.attempt = function()
      attempted = true
      return { status = 200, headers = {}, body = "" }
    end

    assert.has_error(function()
      client:get("http://example.test", false)
    end, "HTTP request options must be a table")
    assert.has_error(function()
      client:get("http://example.test", { retries = -1 })
    end, "HTTP request option 'retries' must be a non-negative integer")
    assert.has_error(function()
      client:post("http://example.test", { body = 42 })
    end, "HTTP request option 'body' must be a string or table")
    assert.is_false(attempted)
  end)
end)
