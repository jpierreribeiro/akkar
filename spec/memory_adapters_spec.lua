--[[
The in-memory adapters.

Two claims are worth checking, and they are different claims.

`akkar.cache.memory` is a REAL implementation -- a cache is a table with
expiry, and that is honestly buildable in memory -- so it is tested against
the same contract the Redis adapter answers.

`akkar.db.memory` is a STAND-IN.  It does not execute SQL and does not
pretend to; it matches queries against programmed responses.  What is tested
is that it obeys the adapter contract and the transaction semantics, since
those are what a handler depends on.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar  = require "akkar"
local db     = require "akkar.db.memory"
local cache  = require "akkar.cache.memory"

describe("akkar.cache.memory", function()
  it("stores and reads back", function()
    local c = cache.new()
    assert.is_nil(c:get "missing")
    c:set("k", "v")
    assert.equal("v", c:get "k")
  end)

  it("expires on a ttl, using an injectable clock", function()
    local now = 1000
    local c = cache.new { now = function() return now end }
    c:set("k", "v", 60)

    assert.equal("v", c:get "k")
    assert.equal(60, c:ttl "k")

    now = now + 59
    assert.equal("v", c:get "k")

    now = now + 2
    assert.is_nil(c:get "k")       -- no sleeping in a test
  end)

  it("follows Redis ttl semantics so a test holds against either", function()
    local c = cache.new()
    assert.equal(-2, c:ttl "gone")     -- no such key
    c:set("k", "v")
    assert.equal(-1, c:ttl "k")        -- exists, no expiry
  end)

  it("counts with incr and keeps an existing ttl", function()
    local now = 500
    local c = cache.new { now = function() return now end }
    c:set("hits", "0", 30)
    assert.equal(1, c:incr "hits")
    assert.equal(2, c:incr "hits")
    -- Preserving the ttl is what makes incr usable for a rate limit rather
    -- than only for a counter.
    assert.equal(30, c:ttl "hits")
  end)

  it("counts what del actually removed", function()
    local c = cache.new()
    c:set("a", "1") c:set("b", "2")
    assert.equal(2, c:del("a", "b", "never-existed"))
  end)

  it("refuses a command it does not implement, instead of returning nil", function()
    -- A command genuinely outside the contract. `ZADD` used to stand here and
    -- no longer can: the sorted sets arrived so that `akkar.limit` and
    -- `akkar.idempotency` could run their own scripts without a Redis.
    local c = cache.new()
    local ok, err = pcall(function() return c:command("SUBSCRIBE", "channel") end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "implements the contract, not all of Redis")
  end)

  it("expires with the default clock, not only with an injected one", function()
    -- The clock was called as a METHOD -- `self:now()` -- so the default
    -- `os.time` received the cache table as its date argument and raised
    -- "field 'year' missing in date table". Every expiry test injected a
    -- clock, so the DEFAULT path was never exercised: an application using
    -- `akkar.cache.memory` raised on its first key with a ttl, which is most
    -- of the reason to have a cache at all.
    local c = cache.new()
    assert.equal("OK", c:set("k", "v", 60))
    assert.equal("v", c:get "k")
    assert.is_true(c:ttl "k" > 0)
    assert.equal(1, c:expire("k", 30))
  end)

  it("runs the scripts akkar itself sends", function()
    -- The point of the sorted sets and hashes: not Redis compatibility for
    -- its own sake, but that the modules whose whole logic lives inside EVAL
    -- become testable on a laptop with nothing running.
    local c = cache.new()
    local reply = c:command("EVAL", [[
      redis.call('ZADD', KEYS[1], 10, 'a')
      redis.call('ZADD', KEYS[1], 20, 'b')
      redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', 15)
      return { redis.call('ZCARD', KEYS[1]), tonumber(ARGV[1]) + 1 }
    ]], 1, "spec:zset", "41")

    assert.same({ 1, 42 }, reply)
  end)

  it("lets redis.pcall return the error that redis.call raises", function()
    -- The one thing that distinguishes them, and this fake had `pcall` set to
    -- the very same function as `call`. A script that inspects `.err` and
    -- carries on -- the only reason to reach for `pcall` in the first place --
    -- would pass here and abort against a real Redis.
    local c = cache.new()

    local reply = c:command("EVAL", [[
      local bad = redis.pcall('NOSUCHCOMMAND', KEYS[1])
      if type(bad) == 'table' and bad.err then return 'handled' end
      return 'no error was reported'
    ]], 1, "k")
    assert.equal("handled", reply)

    -- And the other half: `call` must still stop the script.
    local ok = pcall(function()
      return c:command("EVAL", [[
        redis.call('NOSUCHCOMMAND', KEYS[1])
        return 'kept going'
      ]], 1, "k")
    end)
    assert.is_false(ok, "redis.call let the script continue past a failure")
  end)

  it("answers TIME from its own clock, so a script can be moved through time", function()
    local at = 1755000000
    local c = cache.new { now = function() return at end }
    local reply = c:command("TIME")
    assert.equal("1755000000", reply[1])

    at = at + 60
    assert.equal("1755000060", c:command("TIME")[1])
  end)

  it("makes SET NX a claim rather than a write", function()
    local c = cache.new()
    assert.equal("OK", c:command("SET", "k", "1", "NX", "EX", 60))
    assert.is_nil(c:command("SET", "k", "2", "NX", "EX", 60))
    assert.equal("1", c:get "k")
  end)

  it("works as req.cache with no Redis running", function()
    local app = akkar.new()
    app:get("/hit", function(req)
      return { n = req.cache:incr "hits" }
    end)

    local client = app:test { cache = cache.factory() }
    assert.equal(1, client:get("/hit").body.n)
    assert.equal(2, client:get("/hit").body.n)
  end)
end)

describe("akkar.db.memory", function()
  it("answers a programmed query", function()
    local fake = db.new():on("from users where id", { id = 1, name = "ada" })
    assert.equal("ada", fake:one("select id, name from users where id = $1", 1).name)
  end)

  it("returns a list when programmed with one", function()
    local fake = db.new():on("from users", { { id = 1 }, { id = 2 } })
    assert.equal(2, #fake:many "select * from users")
  end)

  it("raises on a query nobody programmed", function()
    local fake = db.new()
    local ok, err = pcall(function() return fake:one "select 1" end)
    -- A test that silently gets nil from an unplanned query is asserting the
    -- wrong thing.
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "no response programmed")
  end)

  it("passes arguments to a function response", function()
    local seen
    local fake = db.new():on("insert into users", function(_, name)
      seen = name
      return { id = 42 }
    end)
    assert.equal(42, fake:one("insert into users (name) values ($1) returning id", "ada").id)
    assert.equal("ada", seen)
  end)

  it("commits and rolls back like the real adapter", function()
    local fake = db.new():on("update", {})
    fake:transaction(function(tx) tx:exec "update x" end)
    assert.is_true(fake.committed)

    fake:reset()
    local ok = pcall(function()
      fake:transaction(function(tx)
        tx:exec "update x"
        error(akkar.not_found "gone")
      end)
    end)
    assert.is_false(ok)
    assert.is_true(fake.rolled_back)
  end)

  it("re-raises a thrown response so response-as-error still works", function()
    local app = akkar.new()
    app:post("/t", function(req)
      return req.db:transaction(function(tx)
        tx:exec "update x"
        error(akkar.conflict "already settled")
      end)
    end)

    local res = app:test { db = db.factory(function(fake) fake:on("update", {}) end) }
      :post("/t", { body = {} })
    assert.equal(409, res.status)
    assert.equal("already settled", res.body.error)
  end)

  it("records what it was asked, for assertions", function()
    local fake = db.new():on("select", {})
    fake:one "select 1"
    fake:one "select 2"
    assert.is_true(fake:received "select 1")
    assert.is_false((fake:received "delete from"))
    assert.equal(2, fake:count "select")
  end)
end)
