--[[
akkar.idempotency — the same request twice, charged once.

A client cannot distinguish "the request never arrived" from "the response
never came back", so it retries, and the card is charged twice. Only the
server can tell the difference, and only if it remembers.

Against a real Redis, because the case that matters is the retry arriving
while the first request is STILL RUNNING, and a store that cannot race cannot
prove the race was closed.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local redis   = require "akkar.redis"
local cqueues = require "cqueues"

local function reachable()
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if ok then conn:close() end
  return ok
end

if not reachable() then
  describe("akkar.idempotency (integration)", function()
    pending("Redis is not reachable on 127.0.0.1:6379; skipping")
  end)
  return
end

local function in_controller(fn)
  local cq = cqueues.new()
  local failure
  cq:wrap(function()
    local ok, err = pcall(fn)
    if not ok then failure = err end
  end)
  assert(cq:loop(30))
  if failure then error(failure, 0) end
end

local function prefix() return "akkar:spec:idem:" .. math.random(1, 1e9) .. ":" end

--- An app whose handler counts how many times it actually ran.
local function charging_app(opts)
  -- Explicitly single-tenant: these cases are about the mechanism, not about
  -- whose keyspace it is, and the namespace is required rather than defaulted.
  if opts.namespace == nil then opts.namespace = false end
  local runs = 0
  local app = akkar.new()
  app:use(akkar.idempotency(opts))
  app:post("/charges", function(req)
    runs = runs + 1
    return akkar.created { charged = true, run = runs, amount = req.body and req.body.amount }
  end)
  app:post("/fails", function() error "the processor is down" end)
  app:post("/refused", function() return akkar.bad_request "no" end)
  app:get("/read", function() runs = runs + 1; return { runs = runs } end)
  return app, function() return runs end
end

describe("a retried request", function()
  it("runs once and replays the stored response", function()
    in_controller(function()
      local app, runs = charging_app { prefix = prefix() }
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local headers = { ["idempotency-key"] = "charge-41" }

      local first = client:post("/charges", { body = { amount = 10 }, headers = headers })
      local again = client:post("/charges", { body = { amount = 10 }, headers = headers })

      assert.equal(201, first.status)
      assert.equal(201, again.status, "the replay must carry the original status")
      assert.same(first.body, again.body)
      assert.equal(1, runs(), "the handler ran twice")
    end)
  end)

  it("says it was a replay, so the client knows its retry did nothing new", function()
    in_controller(function()
      local app = charging_app { prefix = prefix() }
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local headers = { ["idempotency-key"] = "charge-42" }

      local first = client:post("/charges", { body = {}, headers = headers })
      local again = client:post("/charges", { body = {}, headers = headers })
      assert.is_nil(first.headers["idempotent-replay"])
      assert.equal("true", again.headers["idempotent-replay"])
    end)
  end)

  it("answers 409 while the first one is still running", function()
    -- The case that matters, and the reason this lives in a Redis script.
    -- Returning nothing is wrong and running it twice is worse.
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.idempotency { prefix = prefix(), namespace = false })
      app:post("/slow", function()
        cqueues.sleep(0.3)
        return akkar.created { done = true }
      end)
      local client = app:test { cache = redis.connect { pool_size = 4 } }
      local headers = { ["idempotency-key"] = "slow-1" }

      local results = {}
      local cq = cqueues.new()
      cq:wrap(function() results.first = client:post("/slow", { body = {}, headers = headers }) end)
      cq:wrap(function()
        cqueues.sleep(0.05)                     -- while the first is in flight
        results.second = client:post("/slow", { body = {}, headers = headers })
      end)
      assert(cq:loop(20))

      assert.equal(201, results.first.status)
      assert.equal(409, results.second.status)
      assert.equal("1", results.second.headers["retry-after"])
    end)
  end)

  it("answers 422 when the key is reused for a different request", function()
    -- The key is a promise about WHICH request this is. Replaying the first
    -- response would hide a client bug exactly where it matters most.
    in_controller(function()
      local app = charging_app { prefix = prefix() }
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local headers = { ["idempotency-key"] = "charge-43" }

      assert.equal(201, client:post("/charges", { body = { amount = 10 }, headers = headers }).status)
      local other = client:post("/charges", { body = { amount = 999 }, headers = headers })
      assert.equal(422, other.status)
      assert.is_truthy(other.body.error:find("different request", 1, true))
    end)
  end)
end)

describe("what must not be remembered", function()
  it("releases the key when the handler raised", function()
    -- Caching a 500 means the retry -- the whole point -- can never succeed.
    in_controller(function()
      local app, runs = charging_app { prefix = prefix() }
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local headers = { ["idempotency-key"] = "flaky-1" }

      assert.equal(500, client:post("/fails", { body = {}, headers = headers }).status)
      -- The same key now runs a route that works: the claim must have been
      -- given back, not held for the whole TTL.
      local retry = client:post("/charges", { body = {}, headers = headers })
      assert.equal(201, retry.status)
      assert.equal(1, runs())
    end)
  end)

  it("releases the key on a non-2xx answer", function()
    in_controller(function()
      local app = charging_app { prefix = prefix() }
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local headers = { ["idempotency-key"] = "refused-1" }

      assert.equal(400, client:post("/refused", { body = {}, headers = headers }).status)
      assert.equal(201, client:post("/charges", { body = {}, headers = headers }).status)
    end)
  end)

  it("refuses to store a response past the size cap", function()
    -- Refusing to store beats an unbounded write into a shared cache, and the
    -- consequence -- the guarantee is lost for that response -- is real.
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.idempotency { prefix = prefix(), namespace = false, max_bytes = 64 })
      local runs = 0
      app:post("/big", function()
        runs = runs + 1
        return akkar.created { blob = string.rep("x", 500), run = runs }
      end)
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local headers = { ["idempotency-key"] = "big-1" }

      assert.equal(201, client:post("/big", { body = {}, headers = headers }).status)
      client:post("/big", { body = {}, headers = headers })
      assert.equal(2, runs, "an unstorable response must not be replayed")
    end)
  end)
end)

describe("which requests it touches", function()
  it("isolates the same key across application namespaces", function()
    in_controller(function()
      local shared_prefix = prefix()
      local first_runs, second_runs = 0, 0
      local first = akkar.new()
      first:use(akkar.idempotency {
        prefix = shared_prefix, namespace = function() return "tenant-a" end,
      })
      first:post("/charges", function() first_runs = first_runs + 1; return { tenant = "a" } end)
      local second = akkar.new()
      second:use(akkar.idempotency {
        prefix = shared_prefix, namespace = function() return "tenant-b" end,
      })
      second:post("/charges", function() second_runs = second_runs + 1; return { tenant = "b" } end)
      local factory = redis.connect { pool_size = 2 }
      local headers = { ["idempotency-key"] = "same-client-key" }
      local a = first:test { cache = factory }:post("/charges", { body = {}, headers = headers })
      local b = second:test { cache = factory }:post("/charges", { body = {}, headers = headers })
      assert.equal("a", a.body.tenant)
      assert.equal("b", b.body.tenant)
      assert.equal(1, first_runs)
      assert.equal(1, second_runs)
    end)
  end)

  it("leaves methods that HTTP already defines as idempotent alone", function()
    in_controller(function()
      local app, runs = charging_app { prefix = prefix() }
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local headers = { ["idempotency-key"] = "get-1" }

      client:get("/read", { headers = headers })
      client:get("/read", { headers = headers })
      assert.equal(2, runs(), "a GET must not be deduplicated")
    end)
  end)

  it("passes a request with no key straight through", function()
    -- Requiring a key on every POST would break every existing client the day
    -- this is switched on.
    in_controller(function()
      local app, runs = charging_app { prefix = prefix() }
      local client = app:test { cache = redis.connect { pool_size = 2 } }

      client:post("/charges", { body = {} })
      client:post("/charges", { body = {} })
      assert.equal(2, runs())
    end)
  end)

  it("can demand one when the endpoint needs it", function()
    in_controller(function()
      local app = charging_app { prefix = prefix(), required = true }
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local res = client:post("/charges", { body = {} })
      assert.equal(400, res.status)
      assert.is_truthy(res.body.error:find("idempotency-key", 1, true))
    end)
  end)

  it("refuses an absurdly long key", function()
    in_controller(function()
      local app = charging_app { prefix = prefix() }
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local res = client:post("/charges", {
        body = {}, headers = { ["idempotency-key"] = string.rep("k", 300) } })
      assert.equal(400, res.status)
    end)
  end)
end)
