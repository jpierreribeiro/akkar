--[[
The seam that makes abandonment testable without Postgres.

## Why this file exists

The defect class this project keeps finding is not "a query failed". It is: a
capability was acquired, the coroutine was abandoned mid-yield, and the
release never ran. Seven of those were found by hand in one audit, and every
one of them lived on a path where something YIELDED and then never came back.

`akkar/db/memory.lua` could only make a query RAISE, which returns
immediately and therefore cannot stage abandonment at all. So the only way to
make a query slow was a real `pg_sleep`, which is why `spec/abandoned_spec.lua`
is `pending` on every machine without Docker -- the tests that cover the worst
class of defect are the ones that do not run.

`:hang(pattern, seconds)` and `:drop(pattern)` close that. What is asserted
here is not the fakes; it is what the FRAMEWORK does when a query behaves that
way, which is the thing that was previously unobservable.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local memory  = require "akkar.db.memory"

--- Runs `fn` inside a controller, and NOTHING here works without it.
---
--- `with_deadline` in `akkar/init.lua` opens with `not cqueues.running()` and
--- returns without arming anything, because there is no controller to yield
--- to. So `app:test { timeout = 0.2 }` called straight from busted applies no
--- deadline at all: the handler runs to completion and the timeout is
--- decoration.
---
--- That is correct behaviour and a trap for tests. The first version of this
--- file fell into it and asserted a 503 that could never arrive, which is the
--- same shape as the skip guards this suite once had that never checked
--- anything. A deadline test that does not run inside a controller is testing
--- the absence of a deadline.
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

describe("a query that hangs", function()
  it("is cut off by the request deadline, and the request still answers", function()
    local fake = memory.new():hang("from slow", 5)
    local app = akkar.new()
    app:get("/slow", function(req)
      return { rows = req.db:many "select * from slow" }
    end)

    local client = app:test { db = function() return fake end, timeout = 0.2 }
    inside(function()
      local started = cqueues.monotime()
      local res = client:get "/slow"
      local waited = cqueues.monotime() - started

      -- The deadline is what answers, and it blames the server rather than
      -- the caller: nothing the client sent was wrong.
      assert.equal(503, res.status)
      -- And it answered on the DEADLINE, not after the query finished. Without
      -- this the test would pass just as well against a five second wait.
      assert.is_true(waited < 2,
        ("waited %.2fs for a 0.2s deadline"):format(waited))
    end)
  end)

  it("releases the capability it was holding when it was cut off", function()
    -- THE PROPERTY THE AUDIT FOUND SEVEN VIOLATIONS OF, now checkable with
    -- nothing running. A deadline that fires while a query is in flight must
    -- still release: the alternative is one pool slot lost per timeout, which
    -- is a server that degrades under exactly the condition that produced the
    -- timeouts in the first place.
    local acquired, released = 0, 0
    local fake = memory.new():hang("from slow", 5)

    local app = akkar.new()
    app:get("/slow", function(req)
      return { rows = req.db:many "select * from slow" }
    end)

    local client = app:test {
      timeout = 0.2,
      db = function()
        acquired = acquired + 1
        return setmetatable({ release = function() released = released + 1 end },
                            { __index = fake })
      end,
    }
    inside(function() client:get "/slow" end)

    assert.is_true(acquired > 0, "the handler never took a connection")
    assert.equal(acquired, released,
      ("acquired %d, released %d -- a timeout leaked a connection")
      :format(acquired, released))
  end)

  it("does not take the server down with it", function()
    local fake = memory.new():hang("from slow", 5):on("from fast", { { id = 1 } })
    local app = akkar.new()
    app:get("/slow", function(req) return { rows = req.db:many "select * from slow" } end)
    app:get("/fast", function(req) return { rows = req.db:many "select * from fast" } end)

    local client = app:test { db = function() return fake end, timeout = 0.2 }
    inside(function() client:get "/slow" end)

    local after = client:get "/fast"
    assert.equal(200, after.status,
      "the server stopped answering after one hung query")
  end)
end)

describe("a connection that drops", function()
  it("fails the request without blaming the caller", function()
    local fake = memory.new():drop "from users"
    local app = akkar.new()
    app:get("/users", function(req)
      return { users = req.db:many "select * from users" }
    end)

    local client = app:test { db = function() return fake end }
    local res = client:get "/users"

    -- 5xx, and the range rather than the number on purpose. What must hold is
    -- that akkar does not blame the caller for a socket the caller never
    -- touched; whether a dead connection deserves 500 or 503 is a separate
    -- question with a separate argument, and pinning today's answer as if it
    -- were the intended one would make a later improvement look like a
    -- regression.
    assert.is_true(res.status >= 500,
      "a dropped connection answered " .. tostring(res.status) ..
      ", blaming the caller for the server's socket")
  end)

  it("stays dropped, because a real socket does not recover", function()
    -- The distinction `:fail` cannot express. A failed QUERY leaves a healthy
    -- connection that goes back to the pool; a dropped CONNECTION must never
    -- go back, and a fake that answered again after a reset by peer would let
    -- a pool pass a dead socket around while the suite went green.
    local fake = memory.new():drop("from users"):on("from other", { { id = 1 } })

    local ok = pcall(function() return fake:many "select * from users" end)
    assert.is_false(ok)

    local again = pcall(function() return fake:many "select * from other" end)
    assert.is_false(again,
      "the adapter answered after the connection had been reset")

    -- And only an explicit reset brings it back.
    fake:reset()
    assert.equal(1, fake:many("select * from other")[1].id)
  end)

  it("releases the capability on the way out", function()
    local acquired, released = 0, 0
    local fake = memory.new():drop "from users"

    local app = akkar.new()
    app:get("/users", function(req) return { users = req.db:many "select * from users" } end)

    local client = app:test {
      db = function()
        acquired = acquired + 1
        return setmetatable({ release = function() released = released + 1 end },
                            { __index = fake })
      end,
    }
    client:get "/users"

    assert.equal(acquired, released,
      ("acquired %d, released %d -- a dropped connection leaked its slot")
      :format(acquired, released))
  end)
end)
