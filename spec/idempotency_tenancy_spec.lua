--[[
akkar.idempotency — whose keyspace is it, and how long is the claim held.

The idempotency key is a header the CLIENT chooses. Two things follow, and
both were wrong: the record has to be namespaced by server-resolved identity
or one tenant replays another's stored body, and the in-flight claim has to
outlive the handler or the retry the module exists to absorb runs the work a
second time.

Against a real Redis, because both are properties of the shared record.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar       = require "akkar"
local idempotency = require "akkar.idempotency"
local redis       = require "akkar.redis"
local cqueues     = require "cqueues"

local function reachable()
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if ok then conn:close() end
  return ok
end

if not reachable() then
  describe("akkar.idempotency tenancy (integration)", function()
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

local function prefix() return "akkar:spec:idemns:" .. math.random(1, 1e9) .. ":" end

describe("the keyspace belongs to the server", function()
  it("refuses to be built without a namespace", function()
    -- The README's own first example was `akkar.idempotency { ttl = 86400 }`,
    -- and a tenant sending someone else's key got their 201 back verbatim.
    -- Boot time is the only honest place to find that out.
    local ok, err = pcall(akkar.idempotency, { ttl = 86400 })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("namespace is required", 1, true))
    assert.is_truthy(tostring(err):find("replay another tenant", 1, true))
  end)

  it("takes a constant string as well as a resolver", function()
    in_controller(function()
      local shared, runs = prefix(), 0
      local function app_for(tenant)
        local app = akkar.new()
        app:use(akkar.idempotency { prefix = shared, namespace = tenant })
        app:post("/charges", function()
          runs = runs + 1
          return akkar.created { tenant = tenant, card_last4 = "4242" }
        end)
        return app
      end
      local factory = redis.connect { pool_size = 2 }
      local headers = { ["idempotency-key"] = "the-same-key" }
      local acme = app_for("acme"):test { cache = factory }
                     :post("/charges", { body = {}, headers = headers })
      local evil = app_for("evil"):test { cache = factory }
                     :post("/charges", { body = {}, headers = headers })

      assert.equal("acme", acme.body.tenant)
      assert.equal("evil", evil.body.tenant, "evil replayed acme's response")
      assert.is_nil(evil.headers["idempotent-replay"])
      assert.equal(2, runs)
    end)
  end)

  it("cannot have a record assembled out of two legal values", function()
    -- Joined by a colon, namespace "a:b" + key "c" and namespace "a" + key
    -- "b:c" are the same record: a cross-tenant replay built from values both
    -- tenants are allowed to send.
    in_controller(function()
      local shared, runs = prefix(), 0
      local function app_for(tenant)
        local app = akkar.new()
        app:use(akkar.idempotency { prefix = shared, namespace = tenant })
        app:post("/charges", function()
          runs = runs + 1
          return akkar.created { tenant = tenant }
        end)
        return app
      end
      local factory = redis.connect { pool_size = 2 }
      local first = app_for("a:b"):test { cache = factory }:post("/charges",
        { body = {}, headers = { ["idempotency-key"] = "c" } })
      local second = app_for("a"):test { cache = factory }:post("/charges",
        { body = {}, headers = { ["idempotency-key"] = "b:c" } })

      assert.equal("a:b", first.body.tenant)
      assert.equal("a", second.body.tenant)
      assert.equal(2, runs)
    end)
  end)

  it("says out loud that false is the single-tenant opt-out", function()
    assert.is_false(idempotency.GLOBAL)
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.idempotency { prefix = prefix(), namespace = idempotency.GLOBAL })
      app:post("/charges", function() return akkar.created { ok = true } end)
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local headers = { ["idempotency-key"] = "opt-out-1" }
      assert.equal(201, client:post("/charges", { body = {}, headers = headers }).status)
      assert.equal("true",
        client:post("/charges", { body = {}, headers = headers })
          .headers["idempotent-replay"])
    end)
  end)
end)

describe("the in-flight claim", function()
  it("outlives the thirty-second proxy timeout in the module's own scenario",
     function()
    -- "A proxy times out at thirty seconds while the handler takes
    -- thirty-one" is the opening paragraph. The claim used to expire at
    -- exactly thirty, so the retry found no record, ran the handler again and
    -- carried no `idempotent-replay` for the client to notice with.
    in_controller(function()
      local shared = prefix()
      local observed
      local app = akkar.new()
      app:use(akkar.idempotency { prefix = shared, namespace = "acme" })
      app:post("/charges", function(req)
        local conn = req.cache
        observed = tonumber(conn:command("TTL", shared .. "4:acmeslow-claim"))
        return akkar.created { charged = true }
      end)
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      client:post("/charges", { body = {},
        headers = { ["idempotency-key"] = "slow-claim" } })

      assert.is_truthy(observed, "the claim record was not where it is keyed")
      assert.is_true(observed > 31,
        "the claim expires at " .. tostring(observed) ..
        "s, inside the handler the module's own example describes")
    end)
  end)

  it("will not let a handler that lost its claim overwrite the successor",
     function()
    -- Once the claim expires the key belongs to whoever claimed next. A late
    -- handler that stores anyway replaces a stranger's answer with its own,
    -- and a late release hands a third copy of the work to the next retry.
    in_controller(function()
      local shared = prefix()
      local app = akkar.new()
      app:use(akkar.idempotency {
        prefix = shared, namespace = "acme", running_ttl = 1,
      })
      app:post("/slow", function()
        cqueues.sleep(1.4)                    -- outlives its own claim
        return akkar.created { run = "first" }
      end)
      app:post("/quick", function() return akkar.created { run = "second" } end)

      local client = app:test { cache = redis.connect { pool_size = 4 } }
      local headers = { ["idempotency-key"] = "expiring-1" }
      local results = {}
      local cq = cqueues.new()
      cq:wrap(function()
        results.slow = client:post("/slow", { body = {}, headers = headers })
      end)
      cq:wrap(function()
        cqueues.sleep(1.1)                    -- the claim is gone by now
        results.quick = client:post("/quick", { body = {}, headers = headers })
        cqueues.sleep(0.6)                    -- let the slow one finish
        results.replay = client:post("/quick", { body = {}, headers = headers })
      end)
      assert(cq:loop(20))

      assert.equal("second", results.quick.body.run)
      assert.equal("true", results.replay.headers["idempotent-replay"])
      assert.equal("second", results.replay.body.run,
        "the late handler stored its answer over the record it no longer owned")
    end)
  end)
end)

describe("the fingerprint", function()
  -- Sorting a list of tostring(key) and then indexing the body with it looks
  -- up the string "2" in a table holding the number 2, so a mixed body
  -- fingerprints as `"2":null` and two different requests share one promise
  -- about which request they are.
  it("does not lose a numeric key's value", function()
    local first = idempotency.fingerprint_of {
      method = "POST", path = "/charges", body = { [2] = "ten", note = "n" },
    }
    local second = idempotency.fingerprint_of {
      method = "POST", path = "/charges", body = { [2] = "ninety", note = "n" },
    }
    assert.not_equal(first, second)
  end)
end)
