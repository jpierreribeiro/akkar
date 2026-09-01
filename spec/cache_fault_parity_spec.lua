--[[
The cache adapter could not break, and a cache that always answers is not one
anybody runs.

`akkar/db/memory.lua` has had `:fail()`, `:hang()` and `:drop()` since the
audit that found seven abandoned-capability defects, and `spec/fault_injection_spec.lua`
is what they bought: the framework's behaviour under a slow or dead backend,
observable on a laptop with nothing installed. `akkar/cache/memory.lua` had
none of it, so every test involving a cache tested the happy path and only the
happy path -- including the tests for `akkar.limit` and `akkar.idempotency`,
whose entire job is to be right when something is wrong.

## What is asserted here, and against what standard

Not that the fake breaks. That a fake's failures are failures the REAL adapter
can produce, which is the rule this project has already paid for twice: Redis
collapsed two identical jobs into one where memory did not, and the database
fake reported a clean rollback where Postgres had silently autocommitted.

So every case below is anchored in `akkar/redis.lua`:

* an ERROR REPLY (`WRONGTYPE`, `OOM`, `READONLY`) leaves the connection
  HEALTHY -- `read_reply` tags it `"reply"` and `Redis:command` skips `broken`
  for exactly that reason;
* a command that is never answered ends at the socket timeout, and a
  timed-out read has left the RESP stream out of step, so the connection is
  broken afterwards;
* a dead transport sets `broken` with `in_flight` still up, which is the pair
  the pool's reuse predicate reads.

The last one is the one that matters most on a cache and least on a database.
RESP matches replies to commands by order and by nothing else, so a poisoned
connection put back in the pool hands the next request somebody else's answer
with no error raised anywhere. Postgres refuses that; Redis cannot.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local memory  = require "akkar.cache.memory"

--- Runs `fn` inside a controller, because a deadline outside one is decoration.
---
--- `with_deadline` in `akkar/init.lua` opens with `not cqueues.running()` and
--- arms nothing, so `app:test { timeout = 0.2 }` called straight from busted
--- applies no deadline at all. The first version of `spec/fault_injection_spec.lua`
--- fell into that trap and asserted a 503 that could never arrive.
local function inside(fn)
  local err
  local cq = cqueues.new()
  cq:wrap(function()
    local ok, why = pcall(fn)
    if not ok then err = why end
  end)
  assert(cq:loop(20))
  if err then error(err, 0) end
end

--- `akkar/redis.lua`'s own reuse predicate, copied verbatim from the pool it
--- builds. Asserting through it rather than through the two fields separately
--- is the point: what a fault has to get right is the answer this function
--- gives, because that is the only thing the pool ever asks.
local function fit_for_reuse(conn)
  return not conn.broken and not conn.in_flight and conn.sock ~= nil
end

--- The memory adapter has no socket, so the predicate's third clause needs a
--- stand-in. Nothing else about it is faked.
local function pooled(cache)
  cache.sock = {}
  return cache
end

describe("a command that fails", function()
  it("raises the reply the server sent, and nothing else", function()
    local cache = memory.new()
      :fail("GET session:7", "WRONGTYPE Operation against a key holding the wrong kind of value")

    local ok, err = pcall(function() return cache:get "session:7" end)
    assert.is_false(ok)
    assert.equal(
      "redis: WRONGTYPE Operation against a key holding the wrong kind of value",
      tostring(err))
  end)

  it("leaves the connection healthy, which is the whole difference from a drop",
    function()
      -- THE DEFECT `akkar/redis.lua` ALREADY FIXED, in that module's own
      -- words: returning `nil, err` for an error reply and a transport
      -- failure alike made every WRONGTYPE destroy the connection, and two of
      -- them took the pool from `live=1 idle=1` to `live=0 idle=0`. A fake
      -- that broke the connection here would certify the opposite behaviour.
      local cache = pooled(memory.new():fail("GET broken", "WRONGTYPE"))

      assert.is_false(pcall(function() return cache:get "broken" end))

      assert.is_nil(cache.broken)
      assert.is_true(fit_for_reuse(cache),
        "an error reply took the connection out of the pool")

      -- And it still works, because the stream is still in step.
      cache:set("fine", "1")
      assert.equal("1", cache:get "fine")
    end)

  it("defaults to a generic ERR, the shape a server uses when it has no code",
    function()
      local cache = memory.new():fail "INCR hits"
      local ok, err = pcall(function() return cache:incr "hits" end)
      assert.is_false(ok)
      assert.equal("redis: ERR command failed", tostring(err))
    end)
end)

describe("a command that hangs", function()
  it("is cut off by the request deadline, and the request still answers", function()
    local cache = memory.new():hang("GET slow", 0.3)
    local app = akkar.new()
    app:get("/slow", function(req) return { v = req.cache:get "slow" } end)

    local client = app:test { cache = function() return cache end, timeout = 0.1 }
    inside(function()
      local started = cqueues.monotime()
      local res = client:get "/slow"
      local waited = cqueues.monotime() - started

      -- The deadline answers, and it blames the server: nothing the caller
      -- sent was wrong.
      assert.equal(503, res.status)
      -- And it answered ON the deadline. Without this the case would pass
      -- just as well against a command that returned instantly.
      assert.is_true(waited < 0.28,
        ("waited %.2fs for a 0.1s deadline"):format(waited))
    end)
  end)

  it("releases the capability it was holding when it was cut off", function()
    -- The class the audit found seven of: acquired, abandoned mid-yield,
    -- never released. One pool slot per timeout is a server that degrades
    -- under exactly the condition that produced the timeouts.
    local acquired, released = 0, 0
    local cache = memory.new():hang("GET slow", 0.3)

    local app = akkar.new()
    app:get("/slow", function(req) return { v = req.cache:get "slow" } end)

    local client = app:test {
      timeout = 0.1,
      cache = function()
        acquired = acquired + 1
        return setmetatable({ release = function() released = released + 1 end },
                            { __index = cache })
      end,
    }
    inside(function() client:get "/slow" end)

    assert.is_true(acquired > 0, "the handler never took a connection")
    assert.equal(acquired, released,
      ("acquired %d, released %d -- a timeout leaked a connection")
      :format(acquired, released))
  end)

  it("leaves in_flight up when the coroutine is abandoned mid-command", function()
    -- THE STATE THAT MAKES THE DESYNC VISIBLE. `akkar/redis.lua` raises
    -- `in_flight` before the write and lowers it after the reply is read, so
    -- a coroutine abandoned in between leaves it up -- and the flag being up
    -- is the only thing that stops the pool handing this connection to
    -- somebody who would then read the reply belonging to it.
    local cache = pooled(memory.new():hang("GET slow", 0.3))
    local app = akkar.new()
    app:get("/slow", function(req) return { v = req.cache:get "slow" } end)

    local client = app:test { cache = function() return cache end, timeout = 0.05 }
    local seen
    local cq = cqueues.new()
    cq:wrap(function() pcall(function() client:get "/slow" end) end)
    -- Read while the command is still outstanding: after the deadline has
    -- fired and before the hang has given up.
    cq:wrap(function()
      cqueues.sleep(0.15)
      seen = fit_for_reuse(cache)
    end)
    assert(cq:loop(20))

    assert.is_false(seen,
      "an abandoned command left the connection looking fit for reuse; the " ..
      "next borrower would have read its reply")
  end)

  it("breaks the connection when it finally gives up", function()
    -- A timed-out read leaves the RESP stream out of step, which is not true
    -- of an error reply. This is the half `:fail` must not have.
    local cache = pooled(memory.new():hang("GET slow", 0.01))

    assert.is_false(pcall(function() return cache:get "slow" end))
    assert.is_true(cache.broken)
    assert.is_false(fit_for_reuse(cache))
  end)
end)

describe("a connection that drops", function()
  it("stays dropped, because a real socket does not recover", function()
    local cache = memory.new():drop "SET orders:1"

    cache:set("other", "fine")                       -- healthy beforehand
    assert.is_false(pcall(function() return cache:set("orders:1", "x") end))

    -- Everything afterwards, not merely the command that matched.
    assert.is_false(pcall(function() return cache:get "other" end),
      "the adapter answered after the connection had been reset")
    assert.is_false(pcall(function() return cache:incr "anything" end))

    -- And only an explicit reset brings it back.
    cache:reset()
    cache:set("other", "fine")
    assert.equal("fine", cache:get "other")
  end)

  it("leaves the pair the pool's reuse predicate reads", function()
    -- Both halves. `broken` alone would be enough for a pool that closes on
    -- it, but `akkar/redis.lua` checks `in_flight` too, and it checks it
    -- because the command was on the wire when the transport died.
    local cache = pooled(memory.new():drop "GET k")

    assert.is_false(pcall(function() return cache:get "k" end))
    assert.is_true(cache.broken)
    assert.is_true(cache.in_flight)
    assert.is_false(fit_for_reuse(cache))
  end)

  it("fails the request without blaming the caller", function()
    local cache = memory.new():drop "GET profile:1"
    local app = akkar.new()
    app:get("/p", function(req) return { v = req.cache:get "profile:1" } end)

    local res = app:test { cache = function() return cache end,
                           log = akkar.log.new { level = "error", sink = function() end } }
      :get "/p"

    -- 5xx, and the range rather than the number, for the reason
    -- `spec/fault_injection_spec.lua` gives: whether a dead connection
    -- deserves 500 or 503 is a separate question, and pinning today's answer
    -- would make a later improvement look like a regression.
    assert.is_true(res.status >= 500,
      "a dropped connection answered " .. tostring(res.status) ..
      ", blaming the caller for the server's socket")
  end)

  it("releases the capability on the way out", function()
    local acquired, released = 0, 0
    local cache = memory.new():drop "GET k"

    local app = akkar.new()
    app:get("/k", function(req) return { v = req.cache:get "k" } end)

    app:test {
      log = akkar.log.new { level = "error", sink = function() end },
      cache = function()
        acquired = acquired + 1
        return setmetatable({ release = function() released = released + 1 end },
                            { __index = cache })
      end,
    }:get "/k"

    assert.equal(acquired, released,
      ("acquired %d, released %d -- a dropped connection leaked its slot")
      :format(acquired, released))
  end)
end)

describe("what a fault is matched against", function()
  it("takes a verb, a key, or both", function()
    local by_verb = memory.new():fail "DEL"
    assert.is_false(pcall(function() return by_verb:del "anything" end))

    local by_key = memory.new():fail "session:7"
    by_key:set("session:8", "fine")
    assert.is_false(pcall(function() return by_key:get "session:7" end))

    local by_both = memory.new():fail "GET session:7"
    assert.equal("OK", by_both:set("session:7", "x"))    -- SET is untouched
    assert.is_false(pcall(function() return by_both:get "session:7" end))
  end)

  it("treats a key with pattern magic in it as text", function()
    -- THE SCAR FROM `akkar/db/memory.lua`, and keys carry it worse than SQL
    -- does. `rate-limit:user-7` read as a Lua pattern is a lazy quantifier
    -- three times over and matches nothing anybody meant, so a `:fail` on it
    -- would silently never fire and the test would pass green having proved
    -- nothing.
    local cache = memory.new():fail "rate-limit:user-7"
    assert.is_false(pcall(function() return cache:incr "rate-limit:user-7" end))

    local percent = memory.new():fail "idem:%s:charge"
    assert.is_false(pcall(function() return percent:get "idem:%s:charge" end))
  end)

  it("still honours a pattern written on purpose", function()
    local cache = memory.new():fail "^GET session:"
    cache:set("session:1", "x")
    assert.is_false(pcall(function() return cache:get "session:1" end))
    assert.is_nil(cache:get "other")     -- a GET that does not match is fine
  end)
end)

describe("a script is one round trip", function()
  it("does not fire a fault programmed on the commands inside it", function()
    -- `EVAL` is one command on a real server however many `redis.call`s the
    -- script makes, and a fault on `GET` that fired for a `GET` the caller
    -- never sent would model a Redis nobody has.
    local cache = memory.new():fail("GET", "WRONGTYPE")
    cache:command("SET", "counter", "41")

    local n = cache:eval([[
      return tonumber(redis.call('GET', KEYS[1])) + 1
    ]], 1, "counter")
    assert.equal(42, n)
  end)

  it("does fire one programmed on EVAL", function()
    local cache = memory.new():fail("EVAL", "OOM command not allowed when used memory > 'maxmemory'")
    local ok, err = pcall(function() return cache:eval("return 1", 0) end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "OOM command not allowed")
  end)

  it("makes the modules that live inside EVAL testable under a fault", function()
    -- The reason this matters beyond tidiness. `akkar.limit` and
    -- `akkar.idempotency` do their whole job inside a script, so until the
    -- cache could break there was no way to see either of them meet a broken
    -- store on a machine with no Redis.
    local app = akkar.new()
    app:use(akkar.idempotency { namespace = false })
    app:post("/charges", function() return akkar.created { ok = true } end)

    local client = app:test {
      cache = function() return memory.new():fail("EVAL", "READONLY You can't write against a read only replica") end,
    }
    local res = client:post("/charges", { body = {},
      headers = { ["idempotency-key"] = "charge-1" } })

    -- 503: the guarantee is unavailable, and saying so is the only safe
    -- answer. Failing open here IS the double charge.
    assert.equal(503, res.status)
  end)
end)

describe("what programming a fault does NOT do", function()
  it("leaves every unprogrammed command doing its real work", function()
    -- The difference from `akkar/db/memory.lua`, and it is the difference
    -- between the two adapters rather than an inconsistency. That one is a
    -- stand-in and every query must be programmed or it raises. This one is a
    -- real implementation, so a fault is an OVERRIDE -- an adapter that
    -- started demanding to be told what `GET` returns would have stopped
    -- being a cache.
    local cache = memory.new():fail "GET locked"

    cache:set("free", "1", 60)
    assert.equal("1", cache:get "free")
    assert.equal(60, cache:ttl "free")
    assert.equal(2, cache:incr "free")
    assert.is_false(pcall(function() return cache:get "locked" end))
  end)

  it("survives a reset, so a scenario is set up once", function()
    -- `akkar/db/memory.lua:reset` does not unprogram its responses either.
    local cache = memory.new():drop "GET k"
    assert.is_false(pcall(function() return cache:get "k" end))

    cache:reset()
    assert.is_nil(cache.broken, "reset left the connection dead")
    assert.is_false(pcall(function() return cache:get "k" end),
      "reset unprogrammed the fault")
  end)

  it("runs the first fault that matches, in the order they were added", function()
    local cache = memory.new():fail("GET", "first"):drop "GET"
    local ok, err = pcall(function() return cache:get "k" end)
    assert.is_false(ok)
    assert.equal("redis: first", tostring(err))
    assert.is_nil(cache.broken, "the second fault ran as well as the first")
  end)
end)
