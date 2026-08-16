--[[
akkar.limit — refusing fast instead of accepting slowly.

The study measured this need rather than assuming it. On `/users/42`, holding
the pool fixed and only varying offered concurrency:

    60 pool conns,  50 clients   10,933 req/s   p99    6.79ms
    60 pool conns, 100 clients   10,302 req/s   p99  396.09ms

Throughput flat, tail sixtyfold worse. Past capacity, accepting more work does
not produce more answers -- it produces a queue, and the queue is paid for in
the tail.

These run against a real Redis because the property under test is atomicity:
the decision is read-then-write, and a fake that cannot race cannot prove the
race was closed.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local redis   = require "akkar.redis"
local cqueues = require "cqueues"

local function reachable()
  -- PING, not merely connect. `cqueues.socket.connect` builds the socket
  -- lazily and touches the network on first use, so `pcall` around the
  -- factory returns TRUE with nothing listening -- every Redis skip guard in
  -- this suite was decorative, and only looked correct because a developer's
  -- machine always had Redis running. CI's no-services job found it on its
  -- first run.
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if not ok then return false end
  local alive = pcall(function() return conn:ping() end)
  conn:close()
  return alive
end

if not reachable() then
  describe("akkar.limit (integration)", function()
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

--- A fresh prefix per test, so one test's counters never decide another's.
local function prefix() return "akkar:spec:" .. math.random(1, 1e9) .. ":" end

describe("the rate limiter", function()
  it("allows the burst and then refuses", function()
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.limit.rate { per_second = 1, burst = 3, prefix = prefix(),
                                 key = function() return "fixed" end })
      app:get("/", function() return { ok = true } end)
      local client = app:test { cache = redis.connect { pool_size = 1 } }

      for i = 1, 3 do
        assert.equal(200, client:get("/").status, "request " .. i .. " of the burst")
      end
      assert.equal(429, client:get("/").status, "the fourth exceeded the burst")
    end)
  end)

  it("says how long to wait, so a client can back off", function()
    -- A 429 without Retry-After is a server telling a client to stop and not
    -- telling it when to resume, which produces a client that hammers.
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.limit.rate { per_second = 1, burst = 1, prefix = prefix(),
                                 key = function() return "fixed" end })
      app:get("/", function() return {} end)
      local client = app:test { cache = redis.connect { pool_size = 1 } }

      client:get "/"
      local res = client:get "/"
      assert.equal(429, res.status)
      assert.is_true(res.body.retry_after >= 1)
      assert.equal(tostring(res.body.retry_after), res.headers["retry-after"])
    end)
  end)

  it("refills over time rather than resetting on a window edge", function()
    -- A fixed window permits twice the limit across its boundary. A bucket
    -- refills continuously, so this waits and gets exactly what it earned.
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.limit.rate { per_second = 20, burst = 1, prefix = prefix(),
                                 key = function() return "fixed" end })
      app:get("/", function() return {} end)
      local client = app:test { cache = redis.connect { pool_size = 1 } }

      assert.equal(200, client:get("/").status)
      assert.equal(429, client:get("/").status)
      cqueues.sleep(0.2)                     -- 20/s means one token per 50ms
      assert.equal(200, client:get("/").status)
    end)
  end)

  it("counts each caller separately", function()
    in_controller(function()
      local who = "a"
      local app = akkar.new()
      app:use(akkar.limit.rate { per_second = 1, burst = 1, prefix = prefix(),
                                 key = function() return who end })
      app:get("/", function() return {} end)
      local client = app:test { cache = redis.connect { pool_size = 1 } }

      assert.equal(200, client:get("/").status)
      assert.equal(429, client:get("/").status)
      who = "b"
      assert.equal(200, client:get("/").status, "a second caller must be unaffected")
    end)
  end)
end)

describe("the concurrency limiter", function()
  it("refuses a caller already holding its limit in flight", function()
    -- The one the study argued for: a caller making ten requests a second is
    -- fine, and the same caller holding fifty open against a pool of twenty
    -- is the 396ms tail.
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.limit.concurrent { limit = 2, prefix = prefix(),
                                       key = function() return "fixed" end })
      app:get("/slow", function() cqueues.sleep(0.4); return { ok = true } end)
      local client = app:test { cache = redis.connect { pool_size = 4 } }

      local statuses = {}
      local cq = cqueues.new()
      for i = 1, 4 do
        cq:wrap(function() statuses[i] = client:get("/slow").status end)
      end
      assert(cq:loop(20))

      local answered, refused = 0, 0
      for _, s in pairs(statuses) do
        if s == 200 then answered = answered + 1 else refused = refused + 1 end
      end
      assert.equal(2, answered, "exactly the limit should be served")
      assert.equal(2, refused, "the rest should be refused, not queued")
    end)
  end)

  it("releases the slot when the handler finishes", function()
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.limit.concurrent { limit = 1, prefix = prefix(),
                                       key = function() return "fixed" end })
      app:get("/", function() return { ok = true } end)
      local client = app:test { cache = redis.connect { pool_size = 2 } }

      for i = 1, 5 do
        assert.equal(200, client:get("/").status,
          "sequential request " .. i .. " -- the slot was not released")
      end
    end)
  end)

  it("releases the slot when the handler raises", function()
    -- A slot that leaks on the error path leaks exactly when load is highest.
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.limit.concurrent { limit = 1, prefix = prefix(),
                                       key = function() return "fixed" end })
      app:get("/boom", function() error "handler exploded" end)
      app:get("/fine", function() return { ok = true } end)
      local client = app:test { cache = redis.connect { pool_size = 2 } }

      assert.equal(500, client:get("/boom").status)
      assert.equal(200, client:get("/fine").status, "the slot leaked on the error path")
    end)
  end)

  it("holds the slot until a streamed body has finished writing", function()
    -- The defect this pins was CLAIMED as fixed by commit d1e5d45 and never
    -- was: that commit's message says "The release joins the deferred chain",
    -- and `akkar/limit.lua` is not in its diff. The release stayed where it
    -- was, immediately after the handler returned.
    --
    -- A streamed response has produced nothing at that point. The body is
    -- written afterwards, on the write path, holding a pool connection for as
    -- long as the reader takes -- so a caller could hold unlimited concurrent
    -- exports while the limiter counted none of them. Streams were the one
    -- shape the concurrency limiter did not limit.
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.limit.concurrent { limit = 1, prefix = prefix(),
                                       key = function() return "fixed" end })
      app:get("/export", function()
        return akkar.stream(function(write)
          for i = 1, 3 do
            write('{"row":' .. i .. "}")
            cqueues.sleep(0.12)
          end
        end)
      end)
      app:get("/fine", function() return { ok = true } end)
      local client = app:test { cache = redis.connect { pool_size = 4 } }

      local during
      local cq = cqueues.new()
      cq:wrap(function() client:get "/export" end)
      cq:wrap(function()
        cqueues.sleep(0.1)          -- the producer is mid-body here
        during = client:get("/fine").status
      end)
      assert(cq:loop(20))

      assert.equal(429, during,
        "the slot was free while the body was still being written")
      assert.equal(200, client:get("/fine").status,
        "the deferred release never gave the slot back")
    end)
  end)

  it("releases the slot when a response is thrown on purpose", function()
    in_controller(function()
      local app = akkar.new()
      app:use(akkar.limit.concurrent { limit = 1, prefix = prefix(),
                                       key = function() return "fixed" end })
      app:get("/missing", function() error(akkar.not_found "no") end)
      app:get("/fine", function() return { ok = true } end)
      local client = app:test { cache = redis.connect { pool_size = 2 } }

      assert.equal(404, client:get("/missing").status)
      assert.equal(200, client:get("/fine").status)
    end)
  end)
end)

describe("what the store can honour", function()
  it("knows Redis can run the scripts", function()
    in_controller(function()
      local conn = redis.connect { pool_size = 0 }()
      assert.is_true(akkar.limit.scriptable(conn))
      conn:close()
    end)
  end)

  it("knows the memory cache runs scripts but is not shared", function()
    -- `scriptable` used to answer both questions at once, and stopped the
    -- moment the memory cache learned to run scripts -- which it did so these
    -- limiters could be tested without a Redis. Running the script and being
    -- one counter per process are now separate answers, because only the
    -- second one decides whether a limit is a limit: a fleet of six with a
    -- counter each enforces six times what was configured.
    local memory = require("akkar.cache.memory").new()
    assert.is_true(akkar.limit.scriptable(memory))
    assert.is_false(akkar.limit.shared(memory))
  end)

  it("knows a real Redis is shared", function()
    in_controller(function()
      local conn = redis.connect { pool_size = 0 }()
      assert.is_true(akkar.limit.shared(conn))
      conn:close()
    end)
  end)
end)
