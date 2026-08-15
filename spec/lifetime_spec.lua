--[[
Resource lifetime — the class of bug this project keeps producing.

Every entry here was found by an audit that asked one question of every place
that acquires something: who releases it, on which paths, and what happens
when a coroutine is abandoned mid-operation. Each was proved with a running
probe before it was fixed, and each is pinned here so it cannot come back.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local Pool    = require "akkar.pool"
local cqueues = require "cqueues"

describe("the pool", function()
  local function counting_pool(size)
    local opened, closed = 0, 0
    local pool = Pool.new(function()
      opened = opened + 1
      return { close = function() closed = closed + 1 end }
    end, size)
    return pool, function() return opened, closed end
  end

  it("ignores a resource returned twice", function()
    -- Returning the same resource twice put it in `idle` twice, and then two
    -- callers of `get()` received THE SAME OBJECT -- two requests sharing one
    -- connection, which is the worst thing this file can produce.
    local pool = counting_pool(2)
    local one = pool:get()
    pool:put(one)
    pool:put(one)

    assert.equal(1, pool:stats().idle, "the resource was pooled twice")
    local a = pool:get()
    assert.equal(0, pool:stats().idle)
    assert.equal(one, a)
  end)

  it("wakes every waiter, not one", function()
    -- A request whose deadline fires while parked in `get()` is never resumed
    -- but stays registered on the condition, so `signal(1)` could hand the
    -- wakeup to a coroutine that will never take it -- leaving a live waiter
    -- asleep beside an idle connection until some unrelated request happened
    -- to release one.
    local pool = counting_pool(1)
    local held = pool:get()
    local woke = {}

    local cq = cqueues.new()
    for i = 1, 3 do
      cq:wrap(function()
        local got = pool:get()
        woke[#woke + 1] = i
        pool:put(got)
      end)
    end
    cq:wrap(function()
      cqueues.sleep(0.05)
      pool:put(held)                 -- one release, three waiters
    end)
    assert(cq:loop(5))

    assert.equal(3, #woke, "a waiter was left asleep")
  end)

  it("still refuses a resource its predicate rejects", function()
    local pool = Pool.new(function() return { close = function() end } end, 2,
                          function(r) return not r.spoiled end)
    local r = pool:get()
    r.spoiled = true
    pool:put(r)
    assert.equal(0, pool:stats().idle)
    assert.equal(0, pool:stats().live, "the slot was not returned")
  end)
end)

describe("a streamed response", function()
  it("does not have release written onto the handler's own table", function()
    -- A handler returning a hoisted or memoised response had request A's
    -- release closure overwritten by request B: A's connection was never
    -- released, B's was released twice, and the second release CLOSED a
    -- connection already sitting in the pool's idle set.
    local shared = akkar.stream(function(write) write "hello" end)

    local acquired, released = 0, 0
    local fake = {
      one = function() end, many = function() return {} end,
      exec = function() end, transaction = function(_, fn) return fn() end,
      release = function() released = released + 1 end,
    }

    local app = akkar.new()
    app:get("/export", function(req)
      local _ = req.db                       -- acquire something to release
      return shared                          -- the SAME table every request
    end)

    local client = app:test { db = function() acquired = acquired + 1; return fake end }
    client:get "/export"
    client:get "/export"

    assert.equal(2, acquired)
    assert.equal(2, released, "released " .. released .. " times for 2 requests")
    assert.is_nil(rawget(shared, "release"),
                  "the handler's own table was mutated")
  end)

  it("composes deferred work rather than overwriting it", function()
    -- Middleware may defer work of its own onto a streamed response -- the
    -- concurrency limiter does exactly that -- and the framework's release
    -- must not replace it.
    local order = {}
    local app = akkar.new()
    app:use(function(req, nxt)
      local res = nxt(req)
      local deferred = res.release
      res.release = function()
        order[#order + 1] = "middleware"
        if deferred then deferred() end
      end
      return res
    end)
    app:get("/export", function()
      return akkar.stream(function(write) write "x" end)
    end)

    local released = false
    local fake = { one = function() end, many = function() return {} end,
                   exec = function() end, transaction = function(_, f) return f() end,
                   release = function() released = true; order[#order + 1] = "framework" end }
    local app_client = app:test { db = function() return fake end }

    app:get("/export2", function(req) local _ = req.db
      return akkar.stream(function(write) write "x" end) end)
    app_client:get "/export2"

    assert.is_true(released, "the framework's release was dropped")
    assert.equal("middleware", order[1], "middleware ran after the framework")
  end)
end)

describe("the sandbox's string bound", function()
  local vm = require "akkar.vm"

  it("does not escape onto the host", function()
    -- The bound was a process global with a counter that an abandoned
    -- coroutine never decremented, so one timed-out request applied one
    -- tenant's ceiling to the whole process, framework code included.
    vm.eval("return 1", { max_string = 8 })
    assert.equal(1000, #("x"):rep(1000), "the host inherited a sandbox's ceiling")
  end)

  it("does not leak from one tenant to another", function()
    -- The limit was last-writer-wins: a tenant compiling with a generous
    -- ceiling raised it for a tenant who asked for nothing, and a tiny one
    -- broke everybody else.
    vm.eval("return 1", { max_string = 8 })
    local ok, n = vm.eval("return #('x'):rep(1000)", { max_string = 1024 * 1024 })
    assert.is_true(ok)
    assert.equal(1000, n)

    local refused = vm.eval("return #('x'):rep(1000)", { max_string = 512 })
    assert.is_false(refused, "one tenant's generous ceiling raised another's")
  end)
end)
