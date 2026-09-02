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
  -- PING, not merely connect. `cqueues.socket.connect` builds the socket
  -- lazily and touches the network on first use, so `pcall` around the factory
  -- returns TRUE with nothing listening. This guard was that shape, and it
  -- only looked correct because a developer's machine always has Redis
  -- running -- `spec/jobs_redis_spec.lua` records the same discovery, and CI's
  -- no-services job found this one the same way, on its first run against
  -- this file.
  --
  -- A Postgres guard of the identical shape is fine, which is why they sit
  -- side by side in this suite looking equivalent: pgmoon connects eagerly.
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if not ok then return false end
  local alive = pcall(function() return conn:ping() end)
  conn:close()
  return alive
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

  -- The same failure the fingerprint unit test pins, driven through the real
  -- middleware and a real Redis: a key reused across two requests that differ
  -- ONLY in their query string must not replay the first request's response.
  -- It is a promise about WHICH request this is, and the query is half of that.
  it("does not replay one request's response for another with a different query",
     function()
    in_controller(function()
      local runs = {}
      local app = akkar.new()
      app:use(akkar.idempotency { prefix = prefix(), namespace = idempotency.GLOBAL })
      app:post("/transfers", function(req)
        local to = req.query and req.query.to or "?"
        runs[#runs + 1] = to
        return akkar.created { paid = to }
      end)
      local client = app:test { cache = redis.connect { pool_size = 2 } }
      local key = { ["idempotency-key"] = "reused-across-queries" }

      local first = client:post("/transfers?to=alice",
        { body = { amount = 100 }, headers = key })
      assert.equal(201, first.status)
      assert.equal("alice", first.body.paid)

      -- Same key, same body, DIFFERENT query. Reusing a key for a different
      -- request is a client error, and the module's answer for that is 422 --
      -- never a 200 replaying the other request's stored body.
      local second = client:post("/transfers?to=bob",
        { body = { amount = 100 }, headers = key })

      assert.is_nil(second.headers["idempotent-replay"],
        "bob's request was answered with alice's stored response")
      assert.equal(422, second.status,
        "a key reused for a different query was not caught as a mismatch")
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
        prefix = shared, namespace = "acme", lock_ttl = 1,
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

  it("will not let a handler that lost its claim release the successor",
     function()
    -- The other half of the same ownership question, and the worse half. A
    -- late handler that RAISES releases the key on its way out; unguarded,
    -- that DELETEs the claim its successor is holding, and the next retry
    -- finds a free key and runs the work a THIRD time. On a charge that is a
    -- third charge.
    in_controller(function()
      local shared, quick_runs = prefix(), 0
      local app = akkar.new()
      app:use(akkar.idempotency {
        prefix = shared, namespace = "acme", lock_ttl = 1,
      })
      app:post("/slow", function()
        cqueues.sleep(1.4)                    -- outlives its own claim
        error("the late handler failed", 0)   -- ... and then releases the key
      end)
      app:post("/quick", function()
        quick_runs = quick_runs + 1
        cqueues.sleep(0.6)                    -- still running when /slow fails
        return akkar.created { run = "second" }
      end)

      local client = app:test { cache = redis.connect { pool_size = 6 } }
      local headers = { ["idempotency-key"] = "expiring-2" }
      local results = {}
      local cq = cqueues.new()
      cq:wrap(function()
        results.slow = client:post("/slow", { body = {}, headers = headers })
      end)
      cq:wrap(function()
        cqueues.sleep(1.1)                    -- the claim is gone by now
        results.quick = client:post("/quick", { body = {}, headers = headers })
      end)
      cq:wrap(function()
        cqueues.sleep(1.8)                    -- after /slow raised and released
        results.retry = client:post("/quick", { body = {}, headers = headers })
      end)
      assert(cq:loop(20))

      assert.equal(500, results.slow.status)
      assert.equal("second", results.quick.body.run)
      assert.equal(1, quick_runs,
        "the late release freed the successor's claim and the work ran again")
      assert.is_truthy(results.retry.status == 409
                       or results.retry.headers["idempotent-replay"] == "true",
        "the retry neither waited for nor replayed the successor; it got " ..
        tostring(results.retry.status))
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

  -- `req.path` excludes the query string -- `akkar/init.lua` splits the target
  -- on `?` and hands the query to `req.query`. The fingerprint was built from
  -- method, path and body only, so `POST /transfers?to=alice` and
  -- `POST /transfers?to=bob` with the same body were the SAME request as far
  -- as this module could tell. A client that reuses a key while changing only
  -- the query -- `?to=`, `?dry_run=`, `?account=` -- got the FIRST request's
  -- stored response replayed and its handler never ran: the exact silent wrong
  -- answer the 512-byte truncation once produced, arriving through the half of
  -- the request the fingerprint forgot to read.
  it("does not lose the query string, which names which request this is",
     function()
    local alice = idempotency.fingerprint_of {
      method = "POST", path = "/transfers",
      query = { to = "alice" }, body = { amount = 100 },
    }
    local bob = idempotency.fingerprint_of {
      method = "POST", path = "/transfers",
      query = { to = "bob" }, body = { amount = 100 },
    }
    assert.not_equal(alice, bob,
      "two requests differing only in query string share one fingerprint")
  end)

  -- Order does not make two spellings of one request. A query is a set of
  -- parameters, not a sequence, so `?a=1&b=2` and `?b=2&a=1` are the same
  -- request and must fingerprint the same -- otherwise an honest retry whose
  -- client reordered the parameters would be refused with a 422.
  it("does not depend on query parameter order", function()
    local one = idempotency.fingerprint_of {
      method = "POST", path = "/search",
      query = { a = "1", b = "2" }, body = {},
    }
    local two = idempotency.fingerprint_of {
      method = "POST", path = "/search",
      query = { b = "2", a = "1" }, body = {},
    }
    assert.equal(one, two)
  end)
end)
