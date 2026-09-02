--[[
The router's cost as a SHAPE, not as a millisecond.

WHY THIS FILE EXISTS. Two defects, one in each direction of the route table.

  1. A request that matched nothing paid for every route that existed, twice.
     `App:match` walked the whole table running a Lua pattern per parameterised
     route, and `dispatch` then called `App:methods_for` on the miss -- to tell
     a 404 from a 405 -- which walked it again. Measured on this laptop with
     `bench/study/router-scale.lua`:

         routes    boot     match+methods_for per 404
            500   0.029 s              0.54 ms
          1,000   0.096 s              1.08 ms
          2,000   0.358 s              2.38 ms
          5,000   2.329 s              8.37 ms
         10,000   9.912 s             19.04 ms

     19 ms of blocking CPU is about 50 requests a second of 404 capacity on a
     single-threaded loop. No credential, no body, no query -- the cheapest
     request an attacker can send is the most expensive one to answer.

  2. The `boot` column is the second defect: the duplicate-route check rescanned
     every existing route on every add, so registration was O(routes^2). Nobody
     can reach it from outside, which makes it the cheaper half; but the reason
     this project measures boot at all is process-per-tenant density, and ten
     seconds is not a rounding error.

WHY NEITHER CASE ASSERTS A MILLISECOND. Rule 4 of the performance study:
timing belongs in a benchmark against a noise floor, allocation is exact and
machine-independent. A wall-clock ceiling here would be a number that fails on
a loaded laptop and passes on a quiet one, and it would be edited until it
meant nothing. Both cases below assert an exact quantity instead, and both
assert the SHAPE -- what happens when the route count doubles -- because the
shape is the defect. 19 ms is what this laptop happened to show; O(routes) is
what was wrong.

  - The 404 is measured in BYTES. `App:match` built `{ path:match(r.pattern) }`
    -- a fresh table -- for every parameterised route it tried, so allocation
    per 404 tracked the route count exactly: 72 bytes per route, 720 KB at ten
    thousand. That is the linear scan, weighed rather than timed.

  - Registration is measured in VM INSTRUCTIONS, counted with a debug hook.
    Nothing else in the suite does this, and the justification is the same one
    the allocation ceiling makes: the count is exact and identical on every
    machine, which a clock is not. Verified deterministic -- the same route
    count gives the same tick count on repeated runs, every time.

WHAT THE FIX WAS. Routes are grouped by SKELETON -- segment count plus which
positions are literal -- and looked up by hash; the duplicate check reads a
table instead of rescanning. `akkar/init.lua` has the argument, including why
it is deliberately not a prefix tree. After:

         routes    boot     match+methods_for per 404
            500   0.009 s             0.012 ms
          1,000   0.025 s             0.010 ms
          2,000   0.059 s             0.014 ms
          5,000   0.161 s             0.027 ms
         10,000   0.286 s             0.055 ms

PROVED TO FAIL. Both cases were run with the linear scan and the rescanning
duplicate check restored, in a copy of the tree: the byte case reported 19,823
bytes at 250 routes against 289,823 at 4,000, and the instruction case reported
3.93x against a ceiling of 2.60. The five correctness cases passed under BOTH,
which is what they are for -- they guard the answers, not the fix.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

--- `n` routes, all parameterised, with distinct literal first segments.
local function app_with(n)
  local app = akkar.new()
  local handler = function() return { ok = true } end
  for i = 1, n do app:get("/r" .. i .. "/:id", handler) end
  return app
end

describe("what a request that matches nothing costs", function()
  --- Bytes allocated per 404, through `app:test` so that the measurement is
  --- of `dispatch` -- which calls `App:match` AND `App:methods_for` -- rather
  --- than of one half of it.
  ---
  --- The collector is stopped for the same reason `spec/allocation_spec.lua`
  --- stops it: with it running, `collectgarbage "count"` answers live memory,
  --- which is flat however much a request allocates.
  local function bytes_per_404(client, n)
    collectgarbage(); collectgarbage()
    collectgarbage "stop"
    local before = collectgarbage "count"
    for _ = 1, n do client:get "/nothing/here" end
    local after = collectgarbage "count"
    collectgarbage "restart"
    return (after - before) * 1024 / n
  end

  it("does not grow with the number of routes", function()
    local few  = app_with(250):test()
    local many = app_with(4000):test()
    bytes_per_404(few, 50)                      -- warm the chain, not the count
    bytes_per_404(many, 50)

    local small = bytes_per_404(few, 400)
    local large = bytes_per_404(many, 400)

    -- SIXTEEN TIMES THE ROUTES, and what a 404 costs must not notice.
    --
    -- Measured with the linear scan: 19,823 bytes at 250 routes and 289,823 at
    -- 4,000 -- a difference of 270,000, which is 72 bytes per route and one
    -- capture table per route to go with it. With the index: 1,826 and 1,826.
    -- Not close -- EQUAL, and equal again on three consecutive runs.
    --
    -- The bound is 2,000 rather than 10 because the point is the SHAPE. A
    -- future change that costs a fixed extra table per 404 is somebody's
    -- decision to argue about; one that costs a table per ROUTE is the defect
    -- coming back, and nothing between those two numbers can hide in it.
    assert.is_true(math.abs(large - small) < 2000,
      string.format("a 404 costs %.0f bytes at 250 routes and %.0f at 4,000, "
                    .. "a difference of %.0f: the miss is walking the route "
                    .. "table again", small, large, large - small))
  end)

  it("still answers 404, 405 and OPTIONS off the same table", function()
    -- The index changes which routes are compared and must change no answer.
    -- Without this the case above passes for a router that returns nothing.
    local app = akkar.new()
    app:get("/users/:id", function() return { ok = true } end)
    app:post("/users/:id", function() return { ok = true } end)
    local client = app:test()

    assert.equal(200, client:get("/users/7").status)
    assert.equal(404, client:get("/nothing/here").status)

    local wrong_method = client:delete "/users/7"
    assert.equal(405, wrong_method.status)
    assert.equal("GET, POST", wrong_method.headers.allow)

    assert.same({ "GET", "POST" }, app:methods_for "/users/7")
    assert.same({}, app:methods_for "/nothing/here")
  end)

  it("still resolves an ambiguity by registration order", function()
    -- `/users/:id` and `/users/:name` compile to the same pattern, and the
    -- first one registered is the one that answers. That is a documented
    -- semantic -- `akkar doctor` reports on it -- and it is exactly what a
    -- prefix tree would have quietly changed, because a tree answers in tree
    -- order. The index carries `route.order` so that it does not.
    local app = akkar.new()
    app:get("/users/:id",   function(req) return { by = "id",   v = req.params.id } end)
    app:get("/users/:name", function(req) return { by = "name", v = req.params.name } end)
    assert.equal("id", app:test():get("/users/x").body.by)

    local reversed = akkar.new()
    reversed:get("/users/:name", function(req) return { by = "name" } end)
    reversed:get("/users/:id",   function(req) return { by = "id" } end)
    assert.equal("name", reversed:test():get("/users/x").body.by)
  end)

  it("still matches a route whose literal segments contain pattern magic", function()
    -- The index compares literal segments as bytes and the pattern compares
    -- them escaped, so the two have to agree about what a literal IS.
    local app = akkar.new()
    app:get("/v1.0/a+b/:id", function(req) return { id = req.params.id } end)
    local client = app:test()
    assert.equal("7", client:get("/v1.0/a+b/7").body.id)
    assert.equal(404, client:get("/v1x0/a+b/7").status)   -- `.` is not any byte
    assert.equal(404, client:get("/v1.0/ab/7").status)    -- `+` is not "one or more"
  end)

  it("still matches through a mount, and through a mount inside a mount", function()
    -- Each app has an index of its own, and a mounted lookup runs inside the
    -- parent's. The scratch buffers `buckets` uses are module-level, so this
    -- is the case that says the parent has finished reading them before the
    -- child overwrites them.
    local inner = akkar.new()
    inner:get("/leaf/:id", function(req) return { id = req.params.id } end)
    local middle = akkar.new()
    middle:mount("/inner", inner)
    local outer = akkar.new()
    outer:get("/top/:id", function(req) return { id = req.params.id } end)
    outer:mount("/middle", middle)

    local client = outer:test()
    assert.equal("9", client:get("/top/9").body.id)
    assert.equal("3", client:get("/middle/inner/leaf/3").body.id)
    assert.equal(404, client:get("/middle/inner/leaf").status)
    assert.same({ "GET" }, outer:methods_for "/middle/inner/leaf/3")
  end)
end)

describe("what registering a route costs", function()
  --- VM instructions executed while registering `n` routes.
  ---
  --- A count hook every 1,000 instructions, which is exact for pure Lua and
  --- the same on every machine -- unlike a clock, and unlike allocation, which
  --- cannot see this defect at all: the duplicate scan compares strings and
  --- allocates nothing, so it is invisible to the instrument the rest of this
  --- file uses. The paths are built BEFORE the hook is armed, so the count is
  --- registration and not string concatenation.
  local function ticks_to_register(n)
    local app = akkar.new()
    local handler = function() return { ok = true } end
    local paths = {}
    for i = 1, n do paths[i] = "/r" .. i .. "/:id" end

    local ticks = 0
    debug.sethook(function() ticks = ticks + 1 end, "", 1000)
    for i = 1, n do app:get(paths[i], handler) end
    debug.sethook()
    return ticks
  end

  it("grows with the number of routes and not with its square", function()
    local single = ticks_to_register(2000)
    local double = ticks_to_register(4000)
    local ratio  = double / single

    -- Twice the routes must cost about twice as much. Quadratic costs four
    -- times, and the measured figures say so without any ambiguity:
    --
    --     routes    rescanning    indexed
    --      1,000         2,602          181
    --      2,000        10,394          363     2.01x
    --      4,000        40,869          726     2.00x
    --                     3.93x
    --
    -- The ceiling is 2.60: far enough above 2.0 that table growth and hash
    -- collisions have room, and far enough below 4.0 that the rescan cannot
    -- come back through it. Deterministic -- the same count twice in a row
    -- gives the same number of ticks, which is why this is assertable at all.
    assert.is_true(ratio < 2.60,
      string.format("registering 4,000 routes cost %.2fx registering 2,000 "
                    .. "(%d ticks against %d); a linear registration costs "
                    .. "about 2x and a quadratic one about 4x",
                    ratio, double, single))
  end)

  it("still refuses a duplicate, naming both sites", function()
    -- The duplicate check is what was rescanning, so this is the invariant the
    -- speed-up had to keep. Both file:line pairs must still be in the message.
    local app = akkar.new()
    app:get("/dup", function() return { ok = true } end)
    local ok, err = pcall(function()
      app:get("/dup", function() return { ok = true } end)
    end)
    assert.is_false(ok)
    assert.is_truthy(err:match "duplicate route: GET /dup")
    assert.is_truthy(err:match "already registered at .*router_scale_spec%.lua:%d+")
    assert.is_truthy(err:match "duplicated at .*router_scale_spec%.lua:%d+")

    -- A duplicate differs from a route that merely SHARES a skeleton, and the
    -- index groups those together: `/a/:x` and `/a/:y` are one bucket and two
    -- legal routes, and so are the same path under two methods.
    local fine = akkar.new()
    fine:get("/a/:x", function() return { ok = true } end)
    fine:get("/a/:y", function() return { ok = true } end)
    fine:post("/a/:x", function() return { ok = true } end)
    assert.equal(3, #fine.routes)
  end)

  it("leaves nothing behind when a registration raises", function()
    -- The index is written at the end of a successful registration. A route
    -- refused for a bad schema must not be findable afterwards, or the failure
    -- becomes a route nobody declared.
    local app = akkar.new()
    assert.is_false(pcall(function()
      app:get("/broken/:id", { params = { id = "not-a-type" } },
              function() return { ok = true } end)
    end))
    assert.equal(404, app:test():get("/broken/7").status)
    assert.same({}, app:methods_for "/broken/7")

    -- And the path is still free, so the failure did not also register it.
    app:get("/broken/:id", { params = { id = "integer" } },
            function(req) return { id = req.params.id } end)
    assert.equal(200, app:test():get("/broken/7").status)
  end)
end)
