--[[
akkar.limit — whose bucket, whose slot, and what happens when Redis is down.

A limiter is three decisions, and the first two were being made by accident.
The bucket name was a constant, so two limiters on different routes shared one
allowance and two tenants' user 7 shared another. The slot name was `req.id`,
which is not the limiter's to choose. And the script call carried no `pcall`,
so a Redis blip answered 500 on every route someone thought worth protecting.

Against a real Redis, because these are all properties of the shared key.
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
  describe("akkar.limit keys (integration)", function()
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

local function prefix() return "akkar:spec:limitkey:" .. math.random(1, 1e9) .. ":" end

--- One route, one limiter, one caller -- so the only thing under test is the
--- key the limiter builds.
local function app_with(limiter)
  local app = akkar.new()
  app:use(limiter)
  app:get("/", function() return { ok = true } end)
  return app
end

describe("which bucket a rate limiter spends", function()
  it("is not shared with a differently configured limiter", function()
    -- Both middlewares defaulted to `prefix .. "user:7"`, so a limiter of one
    -- per second on /reset and a limiter of a hundred on /search were one
    -- bucket, and the tighter one silently governed both.
    in_controller(function()
      local shared, caller = prefix(), function() return "user:7" end
      local factory = redis.connect { pool_size = 2 }
      local tight = app_with(akkar.limit.rate {
        per_second = 1, burst = 1, prefix = shared, key = caller })
      local loose = app_with(akkar.limit.rate {
        per_second = 100, burst = 100, prefix = shared, key = caller })

      assert.equal(200, tight:test { cache = factory }:get("/").status)
      assert.equal(200, loose:test { cache = factory }:get("/").status,
        "the loose limiter was refused out of the tight limiter's bucket")
    end)
  end)

  it("separates two identical limiters that are named apart", function()
    in_controller(function()
      local shared, caller = prefix(), function() return "user:7" end
      local factory = redis.connect { pool_size = 2 }
      local function one(name)
        return app_with(akkar.limit.rate {
          per_second = 1, burst = 1, prefix = shared, name = name, key = caller })
      end
      assert.equal(200, one("checkout"):test { cache = factory }:get("/").status)
      assert.equal(200, one("search"):test { cache = factory }:get("/").status)
      assert.equal(429, one("search"):test { cache = factory }:get("/").status,
        "a named bucket must still be a bucket")
    end)
  end)

  it("is not shared between two tenants' user 7", function()
    in_controller(function()
      local shared, caller = prefix(), function() return "user:7" end
      local factory = redis.connect { pool_size = 2 }
      local function tenant(id)
        return app_with(akkar.limit.rate { per_second = 1, burst = 1,
          prefix = shared, namespace = id, key = caller })
      end
      assert.equal(200, tenant("acme"):test { cache = factory }:get("/").status)
      assert.equal(200, tenant("evil"):test { cache = factory }:get("/").status,
        "evil spent acme's allowance")
      assert.equal(429, tenant("acme"):test { cache = factory }:get("/").status)
    end)
  end)

  it("cannot have a bucket assembled out of two legal values", function()
    -- Concatenated, tenant "ac" + caller "me:user:7" and tenant "acme" +
    -- caller "user:7" are the same key.
    in_controller(function()
      local shared = prefix()
      local factory = redis.connect { pool_size = 2 }
      local function limiter(ns, caller)
        return app_with(akkar.limit.rate { per_second = 1, burst = 1,
          prefix = shared, namespace = ns, key = function() return caller end })
      end
      assert.equal(200,
        limiter("acme", "user:7"):test { cache = factory }:get("/").status)
      assert.equal(200,
        limiter("ac", "me:user:7"):test { cache = factory }:get("/").status)
    end)
  end)
end)

describe("when the store cannot answer", function()
  --- A cache handle that is down in exactly the way a Redis blip is down.
  local function broken()
    return { command = function() error("connection reset by peer", 0) end }
  end

  it("does not turn a Redis blip into a 500 on every limited route", function()
    in_controller(function()
      local app = app_with(akkar.limit.rate { prefix = prefix(),
        cache = broken(), key = function() return "user:7" end })
      local res = app:test { cache = redis.connect { pool_size = 1 } }:get "/"
      assert.equal(200, res.status,
        "the limiter answered " .. res.status .. " because its store was down")
    end)
  end)

  it("refuses instead, when the application asks it to", function()
    in_controller(function()
      local app = app_with(akkar.limit.rate { prefix = prefix(),
        cache = broken(), on_error = "closed",
        key = function() return "user:7" end })
      assert.equal(429, app:test { cache = redis.connect { pool_size = 1 } }:get("/").status)
    end)
  end)

  it("holds the same line for the concurrency limiter", function()
    in_controller(function()
      local app = app_with(akkar.limit.concurrent { limit = 1, prefix = prefix(),
        cache = broken(), key = function() return "user:7" end })
      assert.equal(200, app:test { cache = redis.connect { pool_size = 1 } }:get("/").status)
    end)
  end)
end)

describe("the slot a concurrency limiter hands out", function()
  it("is one slot per request even when the request id repeats", function()
    -- `req.id` was the ZSET member, so two in-flight requests carrying one id
    -- ZADD the same member and occupy ONE slot between them: the limiter's
    -- own count disagrees with how many requests it is actually holding.
    in_controller(function()
      local shared = prefix()
      local factory = redis.connect { pool_size = 0 }
      local function held(cache)
        return akkar.limit.concurrent { limit = 5, prefix = shared,
          cache = cache, key = function() return "user:7" end }
      end
      local observed
      local cq = cqueues.new()
      for _ = 1, 2 do
        cq:wrap(function()
          held(factory())({ id = "the-same-id", path = "/" }, function()
            cqueues.sleep(0.5)
            return { status = 200 }
          end)
        end)
      end
      cq:wrap(function()
        cqueues.sleep(0.2)                       -- both are in flight now
        local watcher = factory()
        local keys = watcher:command("KEYS", shared .. "*")
        observed = {
          keys = #keys,
          held = keys[1] and tonumber(watcher:command("ZCARD", keys[1])),
          members = keys[1] and watcher:command("ZRANGE", keys[1], 0, -1) or {},
        }
        watcher:close()
      end)
      assert(cq:loop(20))

      assert.equal(1, observed.keys, "the two requests are on one bucket")
      assert.equal(2, observed.held,
        "two in-flight requests held " .. tostring(observed.held) .. " slot(s)")
      for _, member in ipairs(observed.members) do
        assert.not_equal("the-same-id", member,
          "the slot is named after a value the caller supplied")
      end
    end)
  end)
end)

describe("the load shedder", function()
  it("refuses to be built without the app it sheds on", function()
    -- Its own docstring example passed neither `app` nor `capacity`, nothing
    -- in the repo set them, and there was no spec: the shedder as documented
    -- shed nothing, under any load, ever.
    local ok, err = pcall(akkar.limit.shed, { critical = function() return false end })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("app is required", 1, true))
  end)

  it("refuses to be built without a capacity to be loaded against", function()
    local ok, err = pcall(akkar.limit.shed, { app = { in_flight = 0 } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("capacity is required", 1, true))
  end)

  it("sheds once the app is past the ceiling", function()
    local app = { in_flight = 0 }
    local middleware = akkar.limit.shed { app = app, capacity = 10, ceiling = 0.8 }
    local served = function() return { status = 200 } end

    app.in_flight = 8
    assert.equal(200, middleware({ path = "/search" }, served).status)
    app.in_flight = 9
    assert.equal(429, middleware({ path = "/search" }, served).status)
  end)

  it("carries the critical work through anyway", function()
    local app = { in_flight = 500 }
    local middleware = akkar.limit.shed {
      app = app, capacity = 10,
      critical = function(req) return req.path:match "^/payments" ~= nil end,
    }
    local served = function() return { status = 200 } end
    assert.equal(200, middleware({ path = "/payments/7" }, served).status)
    assert.equal(429, middleware({ path = "/search" }, served).status)
  end)
end)
