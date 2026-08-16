--[[
akkar.limit — refusing fast instead of accepting slowly.

The study measured this need rather than assuming it. On `/users/42`, holding
the pool fixed and only varying offered concurrency:

    60 pool conns,  50 clients   10,933 req/s   p99    6.79ms
    60 pool conns, 100 clients   10,302 req/s   p99  396.09ms

Throughput flat, tail sixtyfold worse. Past capacity, accepting more work does
not produce more answers -- it produces a queue, and the queue is paid for in
the tail.

The file is in two halves, and the split is not arbitrary.

The INTEGRATION half runs against a real Redis, because the property it tests
is ATOMICITY: the decision is read-then-write, and a fake that cannot race
cannot prove the race was closed.

The LOGIC half runs against `akkar.cache.memory`, which implements enough
Redis -- hashes, sorted sets, `TIME`, `EVAL` -- to execute these scripts in
process. It runs on a machine with no Redis installed, which is the point:
this whole file used to `return` early when Redis was unreachable, so on CI's
no-services job the rate limiter, the concurrency limiter and the shedder were
not tested AT ALL. That is where the fail-closed defect lived. The half that
needs no server is therefore declared BEFORE the reachability guard, and the
guard only skips what genuinely needs a server.

Time moves with `akkar.time.manual` rather than with `cqueues.sleep`. The
clock is handed to the cache instead of installed process-wide with
`time.set`, because process-wide would also move the request deadline, the
watchdog and the metrics uptime -- and the only clock these tests need to move
is the one the limiter's store reads for `TIME`.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local redis   = require "akkar.redis"
local memory  = require "akkar.cache.memory"
local time    = require "akkar.time"
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

local function fixed_key() return "fixed" end

--- A store, and a clock to move it with, that need nothing installed.
local function stored()
  local clock = time.manual { now = 1755000000 }
  return memory.new { now = clock.now }, clock
end

-- ========================================================= the logic half
-- Everything below runs in process, against `akkar.cache.memory`.

describe("the token bucket", function()
  it("allows the burst, then throttles to the refill rate", function()
    local cache = stored()
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 3, cache = cache,
                               key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = cache }

    for i = 1, 3 do
      assert.equal(200, client:get("/").status, "request " .. i .. " of the burst")
    end
    assert.equal(429, client:get("/").status, "the fourth exceeded the burst")
  end)

  it("refills continuously, and never past capacity", function()
    local cache, clock = stored()
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 2, burst = 2, cache = cache,
                               key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = cache }

    assert.equal(200, client:get("/").status)
    assert.equal(200, client:get("/").status)
    assert.equal(429, client:get("/").status, "the bucket is empty")

    clock:advance(0.5)                    -- 2/s means one token per 500 ms
    assert.equal(200, client:get("/").status, "half a second bought one token")
    assert.equal(429, client:get("/").status, "and only one")

    -- An hour idle must not become an hour's worth of credit. A bucket that
    -- accumulated without a ceiling would let a caller vanish for a day and
    -- come back with 172,800 free requests, which is the burst the server was
    -- never sized for.
    clock:advance(3600)
    assert.equal(200, client:get("/").status)
    assert.equal(200, client:get("/").status)
    assert.equal(429, client:get("/").status, "capacity is the ceiling, not the total")
  end)

  it("refuses the second half of a burst that straddles a second boundary", function()
    -- THE DEFECT A FIXED WINDOW HAS AND THIS DOES NOT, written as a sequence.
    --
    -- `INCR key:<floor(now)>` configured at 2/s allows two requests in the
    -- window named `0` and two more in the window named `1`. A caller that
    -- sends at 0.99 s and again at 1.01 s therefore gets FOUR served inside
    -- twenty milliseconds, each one legal by the counter's own reckoning, at
    -- a server sized for two per second.
    --
    -- The bucket meters the rate instead of a tally reset by a clock the
    -- caller can see, so 20 ms of elapsed time buys 0.04 of a token and the
    -- second pair is refused.
    local cache, clock = stored()
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 2, burst = 2, cache = cache,
                               key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = cache }

    clock:advance(0.99)
    assert.equal(200, client:get("/").status)
    assert.equal(200, client:get("/").status)

    clock:advance(0.02)                   -- across the boundary a window resets on
    assert.equal(429, client:get("/").status,
      "a fixed window would have handed this one a fresh allowance")
    assert.equal(429, client:get("/").status)
  end)

  it("counts each caller separately, on the memory store too", function()
    local cache = stored()
    local who = "a"
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 1, cache = cache,
                               key = function() return who end })
    app:get("/", function() return {} end)
    local client = app:test { cache = cache }

    assert.equal(200, client:get("/").status)
    assert.equal(429, client:get("/").status)
    who = "b"
    assert.equal(200, client:get("/").status, "a second caller must be unaffected")
  end)
end)

describe("the quota headers", function()
  it("tells a well-behaved caller what is left before it trips", function()
    local cache = stored()
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 3, cache = cache,
                               key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = cache }

    local first = client:get "/"
    assert.equal("3", first.headers["ratelimit-limit"])
    assert.equal("2", first.headers["ratelimit-remaining"])
    -- ONE token short of full, refilling at one a second -- so the whole
    -- quota is back in a second. `ratelimit-reset` is the wait for the
    -- bucket to be FULL, which is not the wait for the next single token;
    -- conflating them is how a client told to wait 30 seconds sits idle for
    -- 29 of them with credit it already had.
    assert.equal("1", first.headers["ratelimit-reset"])
    assert.is_nil(first.headers["retry-after"],
      "a 200 must not carry an instruction to back off")

    assert.equal("1", client:get("/").headers["ratelimit-remaining"])
    assert.equal("0", client:get("/").headers["ratelimit-remaining"])
  end)

  it("puts the quota and the wait on the 429", function()
    local cache = stored()
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 1, cache = cache,
                               key = fixed_key })
    app:get("/", function() return {} end)
    local client = app:test { cache = cache }

    client:get "/"
    local res = client:get "/"
    assert.equal(429, res.status)
    assert.equal("1", res.headers["ratelimit-limit"])
    assert.equal("0", res.headers["ratelimit-remaining"])
    assert.equal(tostring(res.body.retry_after), res.headers["retry-after"])
    assert.is_true(tonumber(res.headers["retry-after"]) >= 1)
  end)

  it("does not write the headers onto the table the handler returned", function()
    -- The aliasing `akkar/init.lua` refuses to commit, in the one module most
    -- tempted to: a handler may return a HOISTED response -- a constant, a
    -- memoised payload -- and then one table is shared by every request that
    -- reaches it. Stamping `ratelimit-remaining` on it means request B reads
    -- request A's quota, and the bug hides because the number is plausible.
    local cache = stored()
    local hoisted = akkar.response(200, { ok = true })
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 10, burst = 10, cache = cache,
                               key = fixed_key })
    app:get("/", function() return hoisted end)
    local client = app:test { cache = cache }

    assert.equal("9", client:get("/").headers["ratelimit-remaining"])
    assert.equal("8", client:get("/").headers["ratelimit-remaining"])
    assert.is_nil(rawget(hoisted, "headers"),
      "the limiter wrote on the handler's own response")
  end)

  it("leaves a header the application set alone", function()
    local cache = stored()
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 10, burst = 10, cache = cache,
                               key = fixed_key })
    app:get("/", function()
      return akkar.response(200, { ok = true }, { ["ratelimit-remaining"] = "mine" })
    end)
    local client = app:test { cache = cache }

    local res = client:get "/"
    assert.equal("mine", res.headers["ratelimit-remaining"])
    assert.equal("10", res.headers["ratelimit-limit"], "the rest still arrive")
  end)

  it("keeps a 500 travelling to on_error through the copy", function()
    -- The copy carries `__pending`, which is how a handler's raised error
    -- reaches `app:on_error` after the request's capabilities are released.
    -- A copy that dropped it would silently switch the application's error
    -- hook off for every route behind a rate limiter.
    local cache = stored()
    local seen
    local app = akkar.new()
    app:on_error(function(err) seen = tostring(err) return akkar.response(500, { mine = true }) end)
    app:use(akkar.limit.rate { per_second = 10, burst = 10, cache = cache,
                               key = fixed_key })
    app:get("/boom", function() error "handler exploded" end)
    local client = app:test { cache = cache }

    local res = client:get "/boom"
    assert.equal(500, res.status)
    assert.is_true(res.body.mine, "on_error never ran: __pending was lost in the copy")
    assert.is_true(seen:find("handler exploded", 1, true) ~= nil)
  end)
end)

describe("a store that has stopped answering", function()
  --- A cache whose every command raises, the way a refused connection does.
  local function broken()
    return { command = function() error("ECONNREFUSED 127.0.0.1:6379", 0) end }
  end

  it("ALLOWS the request rather than turning a cache outage into an outage", function()
    -- THE DEFECT THIS PINS. `evaluator` sent `EVAL` with no `pcall` around
    -- it, so a store that raised took the middleware with it and `handle`
    -- answered 500 -- to EVERY request, for as long as Redis was away. The
    -- component whose job is to keep a server answering under stress was the
    -- one that stopped it. It fails open now, and counts.
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 1, cache = broken(),
                               key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = broken() }

    for i = 1, 3 do
      assert.equal(200, client:get("/").status,
        "request " .. i .. " was refused because the CACHE was down")
    end
  end)

  it("counts every failure, so an operator can alert on being blind", function()
    local before = akkar.limit.store_failures
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 1, cache = broken(),
                               key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = broken() }

    client:get "/"
    client:get "/"
    assert.equal(before + 2, akkar.limit.store_failures)
  end)

  it("hands the failure to the application", function()
    local errors = 0
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 1, cache = broken(),
                               key = fixed_key,
                               on_store_error = function() errors = errors + 1 end })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = broken() }

    client:get "/"
    assert.equal(1, errors)
  end)

  it("sends no quota headers it cannot vouch for", function()
    -- Failing open means the limiter does not know the remaining quota. A
    -- header saying "9 left" would be invented, and a client pacing itself
    -- against it would be pacing against fiction.
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 1, cache = broken(),
                               key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = broken() }

    local res = client:get "/"
    assert.equal(200, res.status)
    assert.is_nil(res.headers["ratelimit-remaining"])
  end)

  it("treats a reply of the wrong shape as a failure, not as a 500", function()
    -- Reading `reply[1]` off a string raises inside the middleware, and that
    -- error is the same 500 the fail-open work exists to remove -- so a store
    -- that answers something other than an array is a store that failed.
    local before = akkar.limit.store_failures
    local app = akkar.new()
    local nonsense = { command = function() return "OK" end }
    app:use(akkar.limit.rate { per_second = 1, burst = 1, cache = nonsense,
                               key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = nonsense }

    assert.equal(200, client:get("/").status)
    assert.equal(before + 1, akkar.limit.store_failures)
  end)

  it("lets a caller through the concurrency limiter too", function()
    local app = akkar.new()
    app:use(akkar.limit.concurrent { limit = 1, cache = broken(),
                                     key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = broken() }

    assert.equal(200, client:get("/").status)
    assert.equal(200, client:get("/").status)
  end)

  it("counts the acquire ONCE per request, not the release as well", function()
    -- A slot that was never taken is not released. Counting a phantom release
    -- would make the metric describe this module's control flow instead of
    -- the number of times the store failed to answer.
    local before = akkar.limit.store_failures
    local app = akkar.new()
    app:use(akkar.limit.concurrent { limit = 1, cache = broken(),
                                     key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = broken() }

    client:get "/"
    assert.equal(before + 1, akkar.limit.store_failures)
  end)

  it("REFUSES to fail open when no store was ever configured", function()
    -- A different failure wearing the same shape. `req.cache` is the guard
    -- object here, meaning `app:run{}` was never given a cache -- so this
    -- limiter can never limit anything. Allowing quietly would leave an
    -- application believing it is protected forever; that is the mistake
    -- `shed` refuses at construction, and it gets the same answer.
    local before = akkar.limit.store_failures
    local app = akkar.new()
    app:use(akkar.limit.rate { per_second = 1, burst = 1, key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test {}                 -- no cache at all

    assert.equal(500, client:get("/").status)
    assert.equal(before, akkar.limit.store_failures,
      "a missing store is a misconfiguration, not an outage to count")
  end)
end)

describe("the concurrency limiter, without a server", function()
  it("gives the slot back on success and on a raised handler alike", function()
    local cache = stored()
    local app = akkar.new()
    app:use(akkar.limit.concurrent { limit = 1, cache = cache, key = fixed_key })
    app:get("/fine", function() return { ok = true } end)
    app:get("/boom", function() error "handler exploded" end)
    app:get("/missing", function() error(akkar.not_found "no") end)
    local client = app:test { cache = cache }

    assert.equal(200, client:get("/fine").status)
    assert.equal(500, client:get("/boom").status)
    assert.equal(200, client:get("/fine").status, "the slot leaked on the error path")
    assert.equal(404, client:get("/missing").status)
    assert.equal(200, client:get("/fine").status, "the slot leaked on a thrown response")
  end)

  it("sweeps a slot a crashed worker never released", function()
    -- The release is the one call whose failure COSTS something permanent: a
    -- slot held by a request that has already finished. This cache refuses
    -- exactly that one script, which is what a worker killed between acquire
    -- and release looks like from the store's side.
    local inner, clock = stored()
    local dropped = {
      command = function(_, ...)
        for i = 1, select("#", ...) do
          local arg = (select(i, ...))
          if type(arg) == "string" and arg:find("'ZREM',", 1, true) then
            error("connection reset while releasing", 0)
          end
        end
        return inner:command(...)
      end,
    }

    local before = akkar.limit.store_failures
    local app = akkar.new()
    app:use(akkar.limit.concurrent { limit = 1, ttl = 5, cache = dropped,
                                     key = fixed_key })
    app:get("/", function() return { ok = true } end)
    local client = app:test { cache = dropped }

    assert.equal(200, client:get("/").status)
    assert.equal(429, client:get("/").status, "the lost release leaked the slot")
    assert.equal(before + 1, akkar.limit.store_failures,
      "a release that failed is the failure most worth counting")

    clock:advance(6)                       -- past the ttl
    assert.equal(200, client:get("/").status,
      "the sweep never reclaimed the slot; it would be held forever")
  end)

  it("does not write its deferred release onto the handler's response", function()
    -- Same aliasing, and a stream is the response somebody hoists: the
    -- producer closure is the interesting part and the wrapper looks like a
    -- constant. Overwriting `release` on a shared table means request B's
    -- closure replaces request A's -- A's slot is never returned and B's is
    -- returned twice.
    local cache = stored()
    local hoisted = akkar.stream(function(write) write '{"row":1}' end)
    local app = akkar.new()
    app:use(akkar.limit.concurrent { limit = 1, cache = cache, key = fixed_key })
    app:get("/export", function() return hoisted end)
    local client = app:test { cache = cache }

    assert.equal(200, client:get("/export").status)
    assert.is_nil(rawget(hoisted, "release"),
      "the limiter hung its release on the handler's own table")
    assert.equal(200, client:get("/export").status,
      "and the slot still came back once the body was written")
    assert.equal('{"row":1}', client:get("/export").raw)
  end)
end)

-- ==================================================== the integration half
if not reachable() then
  describe("akkar.limit (integration)", function()
    pending("Redis is not reachable on 127.0.0.1:6379; skipping")
  end)
  return
end

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

describe("health checks and the limiter", function()
  -- THE FAILURE MODE WHERE THE PROTECTIVE FEATURE CAUSES THE OUTAGE.
  --
  -- A global rate limiter counts the orchestrator's probes as traffic.
  -- Twelve requests to /health/live inside the window answer 429, Kubernetes
  -- reads a 429 as a failed probe, and it restarts a healthy process -- then
  -- restarts the replacement, because the limiter is shared between them.
  --
  -- Found by someone writing the guide's resilience page, who had to show the
  -- 429 first and then four lines of exemption. A page teaching a workaround
  -- for a default is the default being wrong.
  local akkar  = require "akkar"
  local limit  = require "akkar.limit"
  local memory = require "akkar.cache.memory"

  local function app_with(options)
    local app = akkar.new()
    app:use(limit.rate(options))
    app:get("/health/live", function() return { ok = true } end)
    app:get("/work", function() return { ok = true } end)
    return app
  end

  it("does not throttle a probe into a restart loop", function()
    local shared = memory.new()
    local client = app_with { per_second = 1, burst = 1,
                              cache = shared }:test()

    -- Far more than the burst. Every one must answer 200.
    for i = 1, 20 do
      local res = client:get "/health/live"
      assert.equal(200, res.status,
        ("probe %d answered %d; an orchestrator reads that as a dead process")
        :format(i, res.status))
    end
  end)

  it("still throttles everything else", function()
    -- The exemption must be narrow. A limiter that stopped limiting would be
    -- a worse bug than the one being fixed.
    local shared = memory.new()
    local client = app_with { per_second = 1, burst = 1,
                              cache = shared }:test()

    assert.equal(200, client:get("/work").status)
    local throttled = false
    for _ = 1, 10 do
      if client:get("/work").status == 429 then throttled = true break end
    end
    assert.is_true(throttled, "the limiter stopped limiting ordinary traffic")
  end)

  it("covers the spellings that are actually in the wild", function()
    -- Nobody should have to discover which spelling this module happened to
    -- pick.
    local shared = memory.new()
    local app = akkar.new()
    app:use(limit.rate { per_second = 1, burst = 1, cache = shared })
    for _, path in ipairs { "/health", "/healthz", "/livez", "/readyz" } do
      app:get(path, function() return { ok = true } end)
    end
    local client = app:test()

    for _, path in ipairs { "/health", "/healthz", "/livez", "/readyz" } do
      for _ = 1, 5 do
        assert.equal(200, client:get(path).status, path .. " was throttled")
      end
    end
  end)

  it("can be turned off, and can be replaced", function()
    local shared = memory.new()

    -- Off: the probe is limited like anything else.
    local strict = akkar.new()
    strict:use(limit.rate { per_second = 1, burst = 1, cache = shared,
                            exempt = false })
    strict:get("/health/live", function() return { ok = true } end)
    local client = strict:test()
    client:get "/health/live"
    local hit_429 = false
    for _ = 1, 10 do
      if client:get("/health/live").status == 429 then hit_429 = true break end
    end
    assert.is_true(hit_429, "exempt = false did not turn the exemption off")

    -- Replaced: a different prefix is exempt and the default one is not.
    local other = memory.new()
    local custom = akkar.new()
    custom:use(limit.rate { per_second = 1, burst = 1, cache = other,
                            exempt = { "/internal/" } })
    custom:get("/internal/ping", function() return { ok = true } end)
    for _ = 1, 8 do
      assert.equal(200, custom:test():get("/internal/ping").status)
    end
  end)
end)
