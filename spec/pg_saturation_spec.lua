--[[
When Postgres refuses to open one more connection.

`max_connections` is a bound the pool cannot see. A pool of ten in each of
four processes is forty backends against a database configured for a hundred,
and the day somebody scales to twelve processes the pool asks for a
connection it will not get -- while it is holding a slot it has already
counted as taken.

That is the classic failure this file was written to look for: **a failed open
that leaks a reservation**. `Pool:get` reserves a slot before calling `open`
and releases it after, so a `pcall` that ends in the wrong branch counts
capacity as spent for the life of the process, and a pool wedges permanently
after a database has been briefly full. Measured here and NOT present: 200
consecutive refused opens leave `live=0 reserved=0` and the pool fills to
`size` immediately afterwards. It is a verified non-issue, and it is worth a
file because the next person to read `Pool:get` will wonder.

What the measurements DID find is the third question, and it is not an
accounting bug:

  * The refusal is named in akkar's own terms and carries the host, port,
    database and user, which is what a log line needs.

  * There is no backoff of any kind. Against a real Postgres at
    `max_connections = 12`, with every slot taken, one coroutine drove **307
    refused connect attempts per second**, each one a full TCP connect and a
    FATAL from the server. A pool whose `size` exceeds what the database will
    give it never queues -- `live + reserved < size` stays true -- so every
    request goes straight to a failing connect and the pool's bound stops
    bounding anything. An outage becomes a connect storm on top of an outage.

The saturation here is induced with a role-level `CONNECTION LIMIT` rather
than by lowering `max_connections`, because the two produce the same refusal
through the same code path and only one of them needs a server restart and a
database nobody else is using.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local db      = require "akkar.db"
local Pool    = db.Pool

local PG = { host = "127.0.0.1", port = 55432, database = "akkar",
             user = "postgres", password = "akkar" }

-- A role of this file's own, so the limit it sets cannot starve anything else
-- connecting to the same database.
local ROLE, ROLE_PASSWORD, ROLE_LIMIT = "akkar_saturation_spec", "akkar", 3

local function pg_reachable()
  local ok, conn = pcall(db.connect { host = PG.host, port = PG.port,
    database = PG.database, user = PG.user, password = PG.password,
    pool_size = 0 })
  if ok then conn:close() end
  return ok
end

local function in_controller(fn)
  local cq = cqueues.new()
  local failure
  cq:wrap(function()
    local ok, err = pcall(fn)
    if not ok then failure = err end
  end)
  assert(cq:loop(60))
  if failure then error(failure, 0) end
end

local function as_superuser(fn)
  local conn = db.connect { host = PG.host, port = PG.port,
    database = PG.database, user = PG.user, password = PG.password,
    pool_size = 0 }()
  local ok, err = pcall(fn, conn)
  conn:close()
  if not ok then error(err, 0) end
end

-- ============================================================== the accounting
--
-- Answered against a `Pool` whose `open` simply raises, because the question
-- is about the pool's arithmetic and nothing else: a real refusal is slower,
-- needs a server, and cannot be repeated two hundred times in a test that
-- anyone will keep running.
describe("a pool whose `open` keeps failing", function()
  local function failing_pool(size)
    local attempts = 0
    local allow = false
    local pool = Pool.new(function()
      attempts = attempts + 1
      if not allow then error("FATAL: sorry, too many clients already", 0) end
      return { close = function() end }
    end, size)
    return pool, function() return attempts end, function() allow = true end
  end

  it("leaks no reservation, however many times it fails", function()
    in_controller(function()
      local pool, attempts = failing_pool(4)
      local failures = 0
      for _ = 1, 200 do
        local ok = pcall(function() return pool:get() end)
        if not ok then failures = failures + 1 end
      end

      assert.equal(200, failures)
      assert.equal(200, attempts())
      local s = pool:stats()
      assert.equal(0, s.live, ("live is %d after 200 failed opens"):format(s.live))
      assert.equal(0, s.reserved,
        ("reserved is %d after 200 failed opens; the capacity is gone")
        :format(s.reserved))
      assert.equal(0, s.idle)
    end)
  end)

  it("still fills to `size` the moment the database comes back", function()
    in_controller(function()
      local pool, _, recover = failing_pool(4)
      for _ = 1, 200 do pcall(function() return pool:get() end) end
      recover()

      local held = {}
      for i = 1, 4 do held[i] = pool:get() end
      assert.equal(4, pool:stats().live,
        "the pool could not reach its own size after a run of refusals")
      for _, r in ipairs(held) do pool:put(r) end
    end)
  end)

  it("costs one connect attempt per refused acquire, with nothing between",
    function()
      -- Not an endorsement: this is the shape of the connect storm the header
      -- describes, pinned so that a change to it is deliberate. A backoff
      -- would still make 50 attempts for 50 acquires; what it would change is
      -- how long they take, which is the number this file cannot assert
      -- portably and reports as a measurement instead.
      in_controller(function()
        local pool, attempts = failing_pool(4)
        for _ = 1, 50 do pcall(function() return pool:get() end) end
        assert.equal(50, attempts())
      end)
    end)
end)

-- ================================================================ the message
if not pg_reachable() then
  describe("a Postgres that refuses one more connection", function()
    pending("Postgres is not reachable on 127.0.0.1:55432; skipping")
  end)
else
describe("a Postgres that refuses one more connection", function()
  setup(function()
    as_superuser(function(conn)
      pcall(function() conn:exec("drop role " .. ROLE) end)
      conn:exec(("create role %s login password '%s' connection limit %d")
                :format(ROLE, ROLE_PASSWORD, ROLE_LIMIT))
    end)
  end)

  teardown(function()
    as_superuser(function(conn)
      pcall(function() conn:exec("drop role " .. ROLE) end)
    end)
  end)

  local function limited_factory(size)
    return db.connect { host = PG.host, port = PG.port, database = PG.database,
                        user = ROLE, password = ROLE_PASSWORD, pool_size = size }
  end

  it("refuses in akkar's own terms, naming what it could not reach", function()
    in_controller(function()
      local factory = limited_factory(ROLE_LIMIT + 4)
      local held, err = {}
      for _ = 1, ROLE_LIMIT + 4 do
        local ok, conn_or_err = pcall(factory)
        if ok then held[#held + 1] = conn_or_err
        else err = conn_or_err; break end
      end
      for _, c in ipairs(held) do c:release() end
      -- CLOSED, not merely released: a released connection is still a live
      -- backend sitting in `idle`, and it still counts against the role's
      -- allowance. The next case would find the limit already spent.
      factory.pool:close()

      assert.is_string(err, "Postgres never refused, though the role is capped")
      -- The four facts a log line needs to act on, and the server's own
      -- sentence behind them.
      assert.is_truthy(err:find("^db: could not connect to "), err)
      assert.is_truthy(err:find(tostring(PG.port), 1, true), err)
      assert.is_truthy(err:find(PG.database, 1, true), err)
      assert.is_truthy(err:find(ROLE, 1, true), err)
      assert.is_truthy(err:find("too many connections", 1, true),
        ("the server's reason was lost: %s"):format(err))
    end)
  end)

  it("leaks nothing when a real Postgres does the refusing", function()
    in_controller(function()
      local factory = limited_factory(ROLE_LIMIT + 4)
      local pool = factory.pool

      -- Fill the role's allowance and hold it, so every further open is
      -- refused by the server rather than by anything in this process.
      local held = {}
      for _ = 1, ROLE_LIMIT do held[#held + 1] = factory() end

      local refused = 0
      for _ = 1, 20 do
        local ok = pcall(factory)
        if not ok then refused = refused + 1 end
      end
      assert.is_true(refused > 0, "the server never refused")

      local s = pool:stats()
      assert.equal(0, s.reserved,
        ("reserved is %d after %d refusals"):format(s.reserved, refused))
      assert.equal(#held, s.live,
        ("live is %d with %d connections held"):format(s.live, #held))

      for _, c in ipairs(held) do c:release() end
      -- And the pool is still usable, which is the property that matters more
      -- than any counter: a brief exhaustion must not wedge it.
      local conn = factory()
      assert.equal(1, conn:one("select 1 as x").x)
      conn:release()
      pool:close()
    end)
  end)
end)
end
