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

describe("a response the handler reuses", function()
  it("is never stamped with the request that happened to return it", function()
    -- `x-request-id` and the traceparent were written onto whatever table the
    -- handler returned. A handler may return a hoisted or memoised response
    -- -- a constant 404, a cached payload -- and then one table is shared by
    -- every request that reaches it, so request A's id landed in a table
    -- request B was also returning. Identical in shape to the `release`
    -- aliasing the audit fixed, and left standing for headers.
    --
    -- Copying the response to stamp it safely measured +264 bytes per
    -- request and the allocation ceiling refused it. So nothing is stamped:
    -- the id travels beside the response and each writer puts it on the wire.
    local shared = akkar.ok { cached = true }
    local app = akkar.new()
    app:get("/cached", function() return shared end)

    local client = app:test {}
    local first  = client:get "/cached"
    local second = client:get "/cached"

    assert.is_truthy(first.headers["x-request-id"])
    assert.is_truthy(second.headers["x-request-id"])
    assert.are_not.equal(first.headers["x-request-id"],
                         second.headers["x-request-id"],
                         "two requests were handed one id")

    assert.is_nil(shared.headers,
      "the id was written into the table the handler keeps returning")
  end)

  it("lets a handler keep a header it set itself", function()
    local app = akkar.new()
    app:get("/mine", function()
      local res = akkar.ok { ok = true }
      res.headers = { ["x-request-id"] = "chosen-by-the-handler" }
      return res
    end)

    local res = app:test({}):get "/mine"
    assert.equal("chosen-by-the-handler", res.headers["x-request-id"])
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

describe("the sandbox's run state", function()
  local vm = require "akkar.vm"

  -- A chunk is COMPILED ONCE AND RUN MANY TIMES -- that is the whole reason
  -- `compile` and `run` are separate calls -- so anything a run mutates on a
  -- per-chunk table is shared with every other run of that chunk. Two tenants
  -- executing the same published spec are the ordinary case, not the exotic
  -- one.
  --
  -- Both runs below use ONE compiled chunk. `pause` is the only exposed host
  -- function and it yields, which is what lets the two runs interleave -- the
  -- same way a real sandbox interleaves when it touches anything doing I/O.
  local SOURCE = [[
    local rounds, nap = ...
    pause(nap)
    local ok = pcall(function()
      local n = 0
      for _ = 1, rounds do n = n + 1 end
      return n
    end)
    return ok
  ]]

  it("does not let one run's overrun raise inside another", function()
    -- `exceeded` and `reason` lived on the table `compile` created, so a
    -- tenant that exhausted its budget set a flag the sandbox's own `pcall`
    -- reads -- and the NEXT tenant's `pcall`, on the same chunk, then refused
    -- to return normally and died with a stranger's message.
    local chunk = assert(vm.compile(SOURCE, {
      expose = { pause = function(s) cqueues.sleep(s) end },
    }))

    local greedy_ok, thrifty_ok, thrifty_report
    local cq = cqueues.new()
    cq:wrap(function()
      -- Exhausts its budget shortly after waking.
      greedy_ok = vm.run(chunk, { instructions = 2000, check_every = 200 },
                         5000000, 0.02)
    end)
    cq:wrap(function()
      -- Wakes later, does almost nothing, and must be unaffected.
      local ok, _, report = vm.run(chunk, { instructions = 10e6 }, 10, 0.12)
      thrifty_ok, thrifty_report = ok, report
    end)
    assert(cq:loop(10))

    assert.is_false(greedy_ok, "the greedy run should have hit its budget")
    assert.is_true(thrifty_ok,
      "a neighbour's overrun reached into this run's pcall and raised")
    assert.is_nil(thrifty_report.exceeded,
      "this run reported a budget it never exceeded")
  end)

  -- THE OTHER HALF IS NOT PINNED, AND THIS IS WHY.
  --
  -- `run` also used to clear `exceeded` on entry, which reads like the mirror
  -- defect: a tenant starting a run wipes the flag of a sibling already over
  -- its budget, and that sibling's `pcall` goes back to swallowing the
  -- overrun. Fresh state per run closes it by construction.
  --
  -- No probe demonstrates it, and it was not written down as fixed without
  -- one. Between the hook raising and the sandbox's `pcall` reading the flag
  -- there is no yield, so no sibling can be scheduled inside that window: a
  -- run that has set the flag either raises straight out of the chunk or is
  -- already inside the check. The clearing was wrong to write and appears not
  -- to have been reachable. Both statements are worth keeping.
end)
