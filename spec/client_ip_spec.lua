--[[
Who the caller is, which is a different question from what the caller says.

`akkar.limit` shipped keying its rate-limit buckets on `X-Forwarded-For`,
falling back to `X-Real-IP` — both client-supplied strings — because nothing
else was available: the peer address was never plumbed to `req`. Any caller
could send a fresh value per request and mint a fresh bucket each time. A rate
limiter defeated by one header.

It was found by asking what a real admin IP allowlist would need, and
discovering the framework had no answer to give it.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

describe("matching an address against a range", function()
  local inside = akkar.in_cidr

  it("matches inside and refuses outside", function()
    assert.is_true(inside("10.1.2.3", "10.0.0.0/8"))
    assert.is_false(inside("11.1.2.3", "10.0.0.0/8"))
    assert.is_true(inside("192.168.1.7", "192.168.1.0/24"))
    assert.is_false(inside("192.168.2.7", "192.168.1.0/24"))
  end)

  it("treats a bare address as a single host", function()
    assert.is_true(inside("127.0.0.1", "127.0.0.1"))
    assert.is_false(inside("127.0.0.2", "127.0.0.1"))
  end)

  it("handles the degenerate masks", function()
    assert.is_true(inside("8.8.8.8", "0.0.0.0/0"), "/0 is everything")
    assert.is_true(inside("8.8.8.8", "8.8.8.8/32"))
    assert.is_false(inside("8.8.8.9", "8.8.8.8/32"))
  end)

  it("refuses malformed input rather than guessing", function()
    -- Fails CLOSED: an address that cannot be parsed is not trusted, so a
    -- forwarded header from it is ignored rather than believed.
    assert.is_false(inside("not-an-ip", "10.0.0.0/8"))
    assert.is_false(inside("10.1.2.3", "garbage"))
    assert.is_false(inside("999.1.2.3", "10.0.0.0/8"))
    assert.is_false(inside("::1", "10.0.0.0/8"), "IPv6 never matches an IPv4 range")
  end)
end)

describe("deciding the client address", function()
  local client_ip = akkar.client_ip

  it("uses the socket's peer when no proxy is trusted", function()
    -- The whole defect in one assertion: a header must not be able to change
    -- who you are.
    assert.equal("203.0.113.9",
      client_ip("203.0.113.9", "1.2.3.4", nil))
    assert.equal("203.0.113.9",
      client_ip("203.0.113.9", "1.2.3.4", { "10.0.0.0/8" }))
  end)

  it("believes the header only when the connection came from a trusted proxy", function()
    assert.equal("203.0.113.9",
      client_ip("10.0.0.5", "203.0.113.9", { "10.0.0.0/8" }))
  end)

  it("walks the chain from the RIGHT, past every trusted hop", function()
    -- Taking the leftmost entry is what most implementations do, and it is
    -- exactly the spoofable version: the leftmost is whatever the client
    -- typed. Here the client claimed to be 1.2.3.4 and is not.
    assert.equal("203.0.113.9",
      client_ip("10.0.0.5", "1.2.3.4, 203.0.113.9, 10.0.0.7",
                { "10.0.0.0/8" }))
  end)

  it("falls back to the peer when every hop is a trusted proxy", function()
    assert.equal("10.0.0.5",
      client_ip("10.0.0.5", "10.0.0.6, 10.0.0.7", { "10.0.0.0/8" }))
  end)

  it("is nil when there is no socket to ask", function()
    assert.is_nil(client_ip(nil, "1.2.3.4", { "10.0.0.0/8" }))
  end)
end)

describe("req.ip", function()
  local function app_reporting_ip()
    local app = akkar.new()
    app:get("/who", function(req) return { ip = req.ip } end)
    return app
  end

  it("is the peer, not the header", function()
    local client = app_reporting_ip():test { peer = "203.0.113.9" }
    local res = client:get("/who", { headers = { ["x-forwarded-for"] = "1.2.3.4" } })
    assert.equal("203.0.113.9", res.body.ip)
  end)

  it("is the forwarded address when the peer is a trusted proxy", function()
    local client = app_reporting_ip():test {
      peer = "10.0.0.5", trusted_proxies = { "10.0.0.0/8" } }
    local res = client:get("/who", { headers = { ["x-forwarded-for"] = "203.0.113.9" } })
    assert.equal("203.0.113.9", res.body.ip)
  end)

  it("is absent rather than wrong when there is no socket", function()
    local res = app_reporting_ip():test():get "/who"
    assert.is_nil(res.body.ip)
  end)
end)

describe("the rate limiter's identity", function()
  it("cannot be reset by sending a different forwarded header", function()
    -- Before the fix, each of these three requests minted its own bucket and
    -- all three were allowed.
    local redis = require "akkar.redis"
    -- PING, not merely connect: `cqueues.socket.connect` builds the socket
    -- lazily, so the factory succeeds with nothing listening.
    local ok, conn = pcall(redis.connect { pool_size = 0 })
    if not ok then return end
    local alive = pcall(function() return conn:ping() end)
    conn:close()
    if not alive then return end

    local cqueues = require "cqueues"
    local cq = cqueues.new()
    local statuses = {}
    cq:wrap(function()
      local app = akkar.new()
      app:use(akkar.limit.rate {
        per_second = 1, burst = 1,
        prefix = "akkar:spec:ip:" .. math.random(1, 1e9) .. ":",
      })
      app:get("/", function() return { ok = true } end)
      local client = app:test { cache = redis.connect { pool_size = 2 },
                                peer = "203.0.113.9" }

      for i, claimed in ipairs { "1.1.1.1", "2.2.2.2", "3.3.3.3" } do
        statuses[i] = client:get("/", { headers = { ["x-forwarded-for"] = claimed } }).status
      end
    end)
    assert(cq:loop(20))

    assert.equal(200, statuses[1])
    assert.equal(429, statuses[2], "a new header must not mint a new bucket")
    assert.equal(429, statuses[3])
  end)
end)
