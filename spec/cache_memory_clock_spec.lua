--[[
akkar.cache.memory — the clock, and what happens to the modules above it.

The default clock was invoked as a method, so it received the cache table and
`os.time` was asked to read a date out of it. Every TTL write raised. No spec
caught it because every spec that touches a TTL injects a clock of its own,
which is exactly the shape of a bug that only production finds.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar  = require "akkar"
local memory = require "akkar.cache.memory"

describe("the default clock", function()
  it("writes a TTL without being handed a fake one", function()
    local cache = memory.new()
    assert.equal("OK", cache:set("session:7", "alice", 60))
    assert.equal("alice", cache:get "session:7")
    assert.is_true(cache:ttl "session:7" > 0)
  end)

  it("expires with it too", function()
    local cache = memory.new()
    cache:set("k", "v", 60)
    cache:expire("k", 30)
    assert.is_true(cache:ttl "k" <= 30)
  end)

  it("still takes an injected clock", function()
    local at = 1000
    local cache = memory.new { now = function() return at end }
    cache:set("k", "v", 10)
    assert.equal(10, cache:ttl "k")
    at = 1011
    assert.is_nil(cache:get "k")
  end)
end)

describe("a store that cannot run the scripts", function()
  it("is what akkar.limit.scriptable is for", function()
    assert.is_false(akkar.limit.scriptable(memory.new()))
  end)

  it("makes the rate limiter serve unlimited rather than 500", function()
    -- The README's position, and now the code's: there is no per-process
    -- fallback. The limiter applies its on_error policy and logs.
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 1,
                               key = function() return "user:7" end })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = memory.factory() }
    for i = 1, 4 do
      assert.equal(200, client:get("/").status, "request " .. i)
    end
  end)

  it("makes idempotency refuse rather than run the handler unguarded", function()
    -- Failing open here IS the double charge. 503 says the guarantee is
    -- unavailable; a 500 said nothing and a silent success would be worse.
    local runs = 0
    local app = akkar.new()
    app:use(akkar.idempotency { namespace = false })
    app:post("/charges", function() runs = runs + 1; return akkar.created { ok = true } end)
    local client = app:test { cache = memory.factory() }
    local res = client:post("/charges", { body = {},
      headers = { ["idempotency-key"] = "charge-1" } })

    assert.equal(503, res.status)
    assert.equal(0, runs, "the handler ran with no claim behind it")
    assert.equal("1", res.headers["retry-after"])
  end)
end)
