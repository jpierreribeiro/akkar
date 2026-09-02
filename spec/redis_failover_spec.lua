--[[
What akkar does when its Redis stops being a primary.

`docs/UNKNOWNS.md` §3 names "a Redis failover, or a replica promoted
mid-request" as a class no lens had been pointed at. This is that lens.

Three conditions were induced against a real Redis first, and the numbers in
the comments below are from those runs, not from reasoning:

  docker pause akkar-fix-redis        TCP accepted, nothing ever answered
  redis-cli REPLICAOF localhost 1     every write answered `-READONLY`
  redis-cli REPLICAOF NO ONE          recovery

The tests themselves run against `akkar.cache.memory`, and that is a decision
rather than a convenience. `spec/cache_fault_parity_spec.lua` already argues
it: the fake's faults are defined in `akkar/redis.lua`'s own terms, so a test
written against them is a test about the adapter's contract instead of about
one server's uptime. The two faults used here are the two the real conditions
produce, and the mapping was CHECKED against the real server rather than
assumed:

  `:fail("SET", "READONLY ...")`  raises, leaves `broken` unset, leaves the
                                 stream in step.  Real Redis on a replica:
                                 `broken=nil`, and a `GET` on the SAME
                                 connection immediately afterwards returned
                                 the right value.
  `:hang("SET", n)`              raises after a wait, leaves `broken` set.
                                 Real Redis under `docker pause`: raised at
                                 5.005 s with `broken=true`.

The hang is 0.05 s here rather than the 5 s a real socket timeout costs,
because what is under test is which side of the failure the request comes out
on, and the seconds are the part already measured.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar    = require "akkar"
local auth     = require "akkar.auth"
local session  = require "akkar.session"
local limit    = require "akkar.limit"
local memory   = require "akkar.cache.memory"
local remember = require "akkar.cache_remember"
local redis    = require "akkar.redis"

local SECRET = ("k"):rep(40)

--- A store that is up, and a promoted replica: reads fine, every write
--- `-READONLY`. The message is Redis 7's own, verbatim off the wire.
local READONLY = "READONLY You can't write against a read only replica."

local function replica()
  local cache = memory.new {}
  for _, verb in ipairs { "SET", "SETEX", "DEL", "INCR", "EVAL", "EVALSHA" } do
    cache:fail(verb, READONLY)
  end
  return cache
end

--- A store that accepts the connection and never answers -- `docker pause`.
local function frozen()
  local cache = memory.new {}
  for _, verb in ipairs { "GET", "SET", "SETEX", "DEL", "INCR", "EVAL", "EVALSHA" } do
    cache:hang(verb, 0.05)
  end
  return cache
end

-- ============================================================= the adapter

describe("a socket failure names itself", function()
  -- THE LINE AN OPERATOR READS AT THREE IN THE MORNING SAID `110`.
  --
  -- `sock:onerror` returned cqueues' raw errno and `command` concatenated it,
  -- so the rate limiter's degradation warning -- whose entire job is to
  -- announce that the limits are not being enforced -- came out as
  --
  --   WARN rate limiter store is unreachable; ALLOWING requests
  --        detail="redis: 110" ...
  --
  -- measured under `docker pause akkar-fix-redis`. 110 is ETIMEDOUT and 111
  -- is ECONNREFUSED, and those are two different incidents: one is a Redis
  -- that is alive and not answering, the other is a Redis that is gone.
  local name_error = redis.Redis._name_error

  it("says ETIMEDOUT rather than 110", function()
    local named = name_error(110)
    assert.is_true(named:find("ETIMEDOUT", 1, true) ~= nil,
      "a frozen store still reports a bare errno: " .. tostring(named))
  end)

  it("says ECONNREFUSED rather than 111", function()
    assert.is_true(name_error(111):find("ECONNREFUSED", 1, true) ~= nil)
  end)

  it("keeps the number, which is what a search of errno(3) matches", function()
    -- The name is for the human; the number is for the grep. Losing either
    -- trades one reader for the other.
    assert.is_true(name_error(110):find("110", 1, true) ~= nil
                or name_error(110):find("timed out", 1, true) ~= nil)
  end)

  it("passes a message that is already a string through untouched", function()
    -- `onerror` is called for every socket failure, not only the errno ones.
    assert.equal("already words", name_error "already words")
  end)
end)

-- ======================================================== the rate limiter
-- The claim `akkar/limit.lua` makes about itself, checked under a HANG rather
-- than only under the refusal `spec/limit_spec.lua` uses. A limiter that
-- fails open on a refused connection and hangs on a frozen one is fail-closed
-- for latency, which is the outage it exists to prevent.

describe("the rate limiter when its store has been promoted or frozen", function()
  local function app_with(cache)
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 1, cache = cache,
                               key = function() return "fixed" end })
    app:get("/", function() return { ok = true } end)
    return app:test { cache = cache }
  end

  it("ALLOWS requests when every write comes back -READONLY", function()
    -- The sharp case. A `-READONLY` is a perfectly healthy connection
    -- returning an error, so a client that only handles socket failures reads
    -- it as something else entirely. Against the real server this was
    -- measured as three 200s with `store_failures` going 1, 2, 3.
    local client = app_with(replica())
    local before = limit.store_failures
    for i = 1, 3 do
      assert.equal(200, client:get("/").status,
        "request " .. i .. " was refused because the store was READ-ONLY, not "
        .. "because the caller was over its limit")
    end
    assert.is_true(limit.store_failures > before,
      "a -READONLY was not counted as a store failure at all")
  end)

  it("ALLOWS requests when the store hangs rather than refusing", function()
    local client = app_with(frozen())
    local before = limit.store_failures
    assert.equal(200, client:get("/").status)
    assert.is_true(limit.store_failures > before)
  end)

  it("SAYS SO, once per outage, naming the effect", function()
    -- A limiter silently failing open is a security control that has turned
    -- itself off with nobody informed. Two properties, and both matter: the
    -- line exists, and there is ONE of it -- logging every request would bury
    -- it under precisely the traffic the limiter was meant to be counting.
    local lines = {}
    local recorder = {
      warn  = function(_, msg, fields) lines[#lines + 1] = { msg = msg, fields = fields } end,
      error = function() end, info = function() end, debug = function() end,
    }
    local cache = replica()
    local app = akkar.new()
    app:use(function(req, next) req.log = recorder return next(req) end)
    app:use(akkar.limit.rate { per_second = 1, burst = 1, cache = cache,
                               key = function() return "fixed" end })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = cache }

    for _ = 1, 4 do client:get "/" end

    assert.equal(1, #lines,
      "the limiter logged " .. #lines .. " times for one outage")
    assert.is_true(lines[1].msg:find("unreachable", 1, true) ~= nil)
    assert.equal("open", lines[1].fields.on_error)
    assert.is_true(lines[1].fields.effect:find("not being enforced", 1, true) ~= nil,
      "the log line does not say what the operator has to act on")
    assert.is_true(tostring(lines[1].fields.detail):find("READONLY", 1, true) ~= nil,
      "the reason was lost: detail was " .. tostring(lines[1].fields.detail))
  end)
end)

-- ============================================================== the session
-- THE DEFECT §3 WAS WRITTEN TO FIND.

describe("a session whose store went read-only", function()
  local function app_with(cache)
    local charges = 0
    local mgr = session.new { secret = SECRET }
    local app = akkar.new()
    app:use(auth.middleware { sessions = mgr, optional = true })
    app:post("/charge", function(req)
      charges = charges + 1
      req.session:set("charges", charges)
      return akkar.response(201, { charged = charges })
    end)
    return app:test { cache = cache }, function() return charges end
  end

  it("does not turn a finished 201 into a 500", function()
    -- MEASURED BEFORE THE FIX, against a real Redis made a replica of a dead
    -- master:
    --
    --   POST /charge on replica: status=500  handler ran? true
    --   traceback: akkar/redis.lua:186 <- session.lua:214 commit
    --              <- auth.lua:253 <- init.lua chain
    --
    -- and under `docker pause`, the same 500 at 5.01 s. The commit runs AFTER
    -- the handler, so its failure destroys work that already succeeded, and
    -- the only correct thing a client can do with a 500 is send it again. A
    -- promoted replica therefore turns every non-idempotent POST in the fleet
    -- into a duplicate.
    local client, charges = app_with(replica())
    local res = client:post("/charge", { body = {} })
    assert.equal(201, res.status,
      "the store failed on the way out and took the finished response with it")
    assert.equal(1, charges(), "the handler ran exactly once")
    assert.is_true(res.body.charged == 1)
  end)

  it("does not hand out a cookie for state that was never written", function()
    -- The other way this could have been fixed, and why it was not. Issuing
    -- the `Set-Cookie` anyway would give the browser a correctly signed id
    -- the store has never heard of; the next request would look it up, miss,
    -- and be handed a fresh empty session under a cookie that verifies. That
    -- is a login that appears to work and silently does not.
    local client = app_with(replica())
    local res = client:post("/charge", { body = {} })
    assert.is_nil(res.headers["set-cookie"],
      "a cookie was issued for a session the store refused to save")
  end)

  it("counts the failure, so an operator can alert on it", function()
    local before = auth.session_write_failures
    local client = app_with(replica())
    client:post("/charge", { body = {} })
    assert.equal(before + 1, auth.session_write_failures)
  end)

  it("logs it at error, saying the user will look logged out", function()
    -- Failing open on a rate limiter degrades a control. Failing open on a
    -- session write degrades the USER'S OWN STATE -- their login did not
    -- take -- so it is one level louder than the limiter's warn.
    local lines = {}
    local recorder = {
      error = function(_, msg, fields) lines[#lines + 1] = { msg = msg, fields = fields } end,
      warn  = function() end, info = function() end, debug = function() end,
    }
    local cache = replica()
    local mgr = session.new { secret = SECRET }
    local app = akkar.new()
    app:use(function(req, next) req.log = recorder return next(req) end)
    app:use(auth.middleware { sessions = mgr, optional = true })
    app:post("/charge", function(req) req.session:set("x", 1) return { ok = true } end)
    local client = app:test { cache = cache }

    client:post("/charge", { body = {} })

    assert.equal(1, #lines, "the session write failed silently")
    assert.is_true(lines[1].msg:find("NOT saved", 1, true) ~= nil)
    assert.is_true(lines[1].fields.effect:find("logged out", 1, true) ~= nil)
    assert.is_true(tostring(lines[1].fields.detail):find("READONLY", 1, true) ~= nil)
  end)

  it("does the same when the store hangs instead of refusing", function()
    local client, charges = app_with(frozen())
    assert.equal(201, client:post("/charge", { body = {} }).status)
    assert.equal(1, charges())
  end)

  it("still answers when there is nothing to commit", function()
    -- The path that must not change: a request that touches no session state
    -- gets no cookie and no log line whether the store is well or not.
    local before = auth.session_write_failures
    local cache = replica()
    local mgr = session.new { secret = SECRET }
    local app = akkar.new()
    app:use(auth.middleware { sessions = mgr, optional = true })
    app:get("/read", function() return { ok = true } end)
    local client = app:test { cache = cache }

    local res = client:get "/read"
    assert.equal(200, res.status)
    assert.is_nil(res.headers["set-cookie"])
    assert.equal(before, auth.session_write_failures,
      "a request that never wrote a session was counted as a failed write")
  end)
end)

-- ======================================================== the cache filler

describe("a cache fill whose write-back is refused", function()
  it("returns the value it already paid for", function()
    -- MEASURED BEFORE THE FIX, real Redis on a replica:
    --
    --   GET /report on replica: status=500  produce() ran? true
    --   traceback: akkar/cache_remember.lua:80 set
    --
    -- The expensive half -- the database round trip this module exists to
    -- coalesce -- had already succeeded. A read-only replica serves `get`
    -- perfectly, so the cache keeps hitting and only the fills fail; instead
    -- the first miss after a failover took down every route that fills a key.
    local produced = 0
    local r = remember.wrap(replica())
    local value = r:remember("k", 60, function()
      produced = produced + 1
      return "expensive-" .. produced
    end)
    assert.equal("expensive-1", value)
    assert.equal(1, produced)
  end)

  it("counts the fill it could not cache", function()
    local before = remember.write_failures
    local r = remember.wrap(replica())
    r:remember("k2", 60, function() return "v" end)
    assert.equal(before + 1, remember.write_failures)
    assert.is_true(tostring(remember.last_write_error):find("READONLY", 1, true) ~= nil)
  end)

  it("still raises when the READ fails, because that answer is not in hand", function()
    -- The asymmetry is the point. A failed write has a value to return; a
    -- failed read has nothing, and inventing a miss would be worse than
    -- saying so -- `remember` would then run `produce` for every request
    -- during the outage with no coalescing to show for it.
    local r = remember.wrap(frozen())
    local ok, err = pcall(function()
      return r:remember("k3", 60, function() return "v" end)
    end)
    assert.is_false(ok)
    assert.is_true(tostring(err):find("redis:", 1, true) ~= nil)
  end)

  it("does not swallow a failure in produce itself", function()
    local r = remember.wrap(replica())
    local ok, err = pcall(function()
      return r:remember("k4", 60, function() error("the database said no", 0) end)
    end)
    assert.is_false(ok)
    assert.equal("the database said no", tostring(err))
  end)
end)

-- ========================================================== the job worker
-- The one that outlives the incident.

describe("a background worker whose store was promoted", function()
  local jobs = require "akkar.jobs"

  --- The minimum store `akkar.jobs` accepts, with a switch on the read.
  --- Nothing here needs Redis: the defect is in the consume loop, and what a
  --- store does when it cannot answer is raise, which this does exactly.
  local function store()
    local items, down = {}, false
    return {
      go_down = function(self) down = true end,
      come_back = function(self) down = false end,
      enqueue = function(_, _, encoded) items[#items + 1] = encoded return #items end,
      depth   = function() return #items end,
      dequeue = function()
        if down then error("redis: " .. READONLY, 0) end
        return table.remove(items, 1)
      end,
    }
  end

  it("keeps consuming after the store comes back, instead of exiting", function()
    -- MEASURED BEFORE THE FIX, against a real Redis made a replica of a dead
    -- master while a worker was consuming:
    --
    --   worker on a promoted replica: survived=false turns=1
    --   err=redis: READONLY You can't write against a read only replica.
    --
    -- One turn. `Queue:pop` was the only store call in the loop still made
    -- bare -- `_maybe_reap` and `settle` are both wrapped, and both say in
    -- their own comments that a blip in the store must not unwind the worker
    -- -- so the discipline covered the chores and missed the trunk.
    --
    -- The consequence outlives the failover. Nothing in akkar restarts a
    -- consume loop, so when the promotion ends the queue keeps filling and no
    -- worker in the fleet is reading it, with the last log line being an
    -- unhandled error from minutes ago.
    local st = store()
    local q = jobs.new(st, "q", { delivery = "at_most_once" })
    q:push("hello", {})

    local ran, turns = 0, 0
    local stats = q:consume({ hello = function() ran = ran + 1 end }, {
      timeout = 0, idle = 0.001, store_backoff = 0.001,
      should_stop = function()
        turns = turns + 1
        if turns == 1 then st:go_down() end
        if turns == 4 then st:come_back() q:push("hello", {}) end
        return turns > 8
      end,
    })

    assert.equal(2, ran,
      "the worker did not survive the outage: it consumed " .. ran ..
      " jobs where the store was only unreachable in the middle")
    assert.equal(2, stats.handled)
  end)

  it("says so once, not once per turn", function()
    local lines = {}
    local log = {
      error = function(_, msg, fields) lines[#lines + 1] = { msg = msg, fields = fields } end,
      warn = function() end, info = function() end, debug = function() end,
    }
    local st = store()
    local q = jobs.new(st, "q", { delivery = "at_most_once" })
    st:go_down()

    local turns = 0
    q:consume({}, {
      timeout = 0, idle = 0.001, store_backoff = 0.001, log = log,
      should_stop = function() turns = turns + 1 return turns > 5 end,
    })

    assert.equal(1, #lines,
      "the worker logged " .. #lines .. " times for one outage")
    assert.is_true(lines[1].msg:find("not consuming", 1, true) ~= nil)
    assert.is_true(tostring(lines[1].fields.detail):find("READONLY", 1, true) ~= nil)
  end)
end)

-- ============================================================ idempotency
-- A verified non-issue, kept because a non-issue with a measurement is a
-- result and because the NEXT person to change `akkar/idempotency.lua` needs
-- to know this is deliberate rather than accidental.

describe("the idempotency guard when the store went read-only", function()
  it("fails CLOSED with 503 and a retry-after, not open and not 500", function()
    -- Failing open on a double-charge guard IS the double charge, so this one
    -- goes the other way from the limiter -- and says which, rather than
    -- raising a bare 500 the client cannot act on. Confirmed identically
    -- against the real server: `status=503 retry-after=1`.
    local cache = replica()
    local app = akkar.new()
    app:use(akkar.idempotency { namespace = "spec" })
    app:post("/pay", function() return akkar.response(201, { paid = true }) end)
    local client = app:test { cache = cache }

    local res = client:post("/pay", {
      body = {}, headers = { ["idempotency-key"] = "key-1" },
    })
    assert.equal(503, res.status)
    assert.equal("1", res.headers["retry-after"])
    assert.is_true(res.body.error:find("unavailable", 1, true) ~= nil)
  end)
end)
