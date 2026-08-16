--[[
What a deadline leaves behind.

When a request's deadline fires, `with_deadline` abandons the handler where it
stands. If it stands inside a query, the coroutine is suspended waiting for a
reply and never resumes -- but the connection it was using goes back to the
pool, because releasing capabilities is the framework's job and it happens on
every exit path.

The framework already understood this class of bug from one side. The comment
in `with_deadline` refuses to pool an abandoned controller and calls it "the
same class of bug as a pooled database connection with a transaction still
open". The defence existed for the controller and not for the connection the
controller was holding.

These tests need real servers, because what is being tested is what a real
protocol does with an unread reply. A fake cannot have that problem, so a fake
cannot prove it is gone.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local akkar   = require "akkar"
local db      = require "akkar.db"
local redis   = require "akkar.redis"

local PG = { host = "127.0.0.1", port = 55432, database = "akkar",
             user = "postgres", password = "akkar" }

local function pg_reachable()
  local ok, conn = pcall(db.connect { host = PG.host, port = PG.port,
    database = PG.database, user = PG.user, password = PG.password, pool_size = 0 })
  if ok then conn:close() end
  return ok
end

local function redis_reachable()
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

--- Runs a body inside a controller, which is where deadlines exist at all.
local function in_controller(fn)
  local cq = cqueues.new()
  local failure
  cq:wrap(function()
    local ok, err = pcall(fn)
    if not ok then failure = err end
  end)
  assert(cq:loop(40))
  if failure then error(failure, 0) end
end

-- ============================================================== Postgres
if not pg_reachable() then
  describe("a query abandoned by the deadline (Postgres)", function()
    pending("Postgres is not reachable on 127.0.0.1:55432; skipping")
  end)
else
describe("a query abandoned by the deadline", function()
  --- pool_size 1 forces the next request onto the same connection, which is
  --- the whole point: with a larger pool the damage hides behind a fresh one.
  local function app_with_pool_of_one()
    local app = akkar.new()
    app:get("/slow", function(req)
      return { who = req.db:one("select pg_sleep(1.0), 'SLOW' as who").who }
    end)
    app:get("/fast", function(req)
      return { who = req.db:one("select 'FAST' as who").who }
    end)
    local factory = db.connect {
      host = PG.host, port = PG.port, database = PG.database,
      user = PG.user, password = PG.password, pool_size = 1,
    }
    return app:test { db = factory, timeout = 0.25 }, factory
  end

  it("does not poison the pool for every request that follows", function()
    -- Before the fix this was 500 "pgmoon: connection is busy", permanently:
    -- one timed-out query destroyed one pool slot for the life of the
    -- process, so a pool of ten died after ten of them.
    in_controller(function()
      local client = app_with_pool_of_one()

      assert.equal(503, client:get("/slow").status)
      cqueues.sleep(1.2)                  -- let Postgres finish sending

      for i = 1, 4 do
        local res = client:get "/fast"
        assert.equal(200, res.status, "request " .. i .. " after the timeout")
        assert.equal("FAST", res.body.who)
      end
    end)
  end)

  it("frees the slot rather than leaking it", function()
    -- A rejected connection is closed AND its slot returned, or the pool
    -- wedges just as badly by a different route.
    in_controller(function()
      local client, factory = app_with_pool_of_one()

      assert.equal(503, client:get("/slow").status)
      cqueues.sleep(1.2)
      assert.equal(200, client:get("/fast").status)

      local stats = factory.pool:stats()
      assert.equal(1, stats.live, "the pool lost or leaked a slot")
    end)
  end)

  it("still reuses a connection that finished its work", function()
    -- The fix must not throw away good connections, or every request pays a
    -- reconnect and the pool stops being a pool.
    in_controller(function()
      local client, factory = app_with_pool_of_one()
      for _ = 1, 5 do assert.equal(200, client:get("/fast").status) end
      assert.equal(1, factory.pool:stats().live)
      assert.equal(1, #factory.pool.idle, "the connection was not kept")
    end)
  end)
end)
end

-- ================================================================= Redis
if not redis_reachable() then
  describe("a command abandoned by the deadline (Redis)", function()
    pending("Redis is not reachable on 127.0.0.1:6379; skipping")
  end)
else
describe("a command abandoned by the deadline", function()
  it("never hands one request's reply to another", function()
    -- RESP matches replies to commands by ORDER and nothing else, so an
    -- unread reply is not an error, it is somebody else's answer.
    --
    -- Before the fix, the request below asked for a key it had just set and
    -- received nil -- the abandoned BLPOP timing out. Then the stream
    -- realigned and everything looked fine again, which is what makes this
    -- the worse of the two: no error anywhere, and unreproducible from a bug
    -- report.
    in_controller(function()
      local setup = redis.connect { pool_size = 0 }()
      setup:set("akkar:abandoned:mine", "MY-OWN-VALUE")
      setup:del "akkar:abandoned:queue"
      setup:close()

      local app = akkar.new()
      app:get("/slow", function(req)
        return { got = req.cache:command("BLPOP", "akkar:abandoned:queue", 2) }
      end)
      app:get("/fast", function(req)
        return { got = req.cache:get "akkar:abandoned:mine" }
      end)

      local client = app:test {
        cache = redis.connect { pool_size = 1 }, timeout = 0.25,
      }

      assert.equal(503, client:get("/slow").status)
      cqueues.sleep(2.2)                  -- let BLPOP time out and reply

      for i = 1, 3 do
        local res = client:get "/fast"
        assert.equal(200, res.status)
        assert.equal("MY-OWN-VALUE", res.body.got,
          "request " .. i .. " received a reply that was not its own")
      end
    end)
  end)
end)
end
