-- What the route table costs at scale, in both directions, old against new.
--
-- WHY THIS FILE EXISTS. `docs/UNKNOWNS.md` section 6 asks what happens to the
-- router at ten thousand routes and answers "it has only ever seen small
-- shapes". This is that measurement, and it found two costs.
--
--   THE ONE AN ATTACKER PAYS FOR. `App:match` walked the whole route table
--   running a Lua pattern per parameterised route, and on a miss `dispatch`
--   called `App:methods_for` -- to tell a 404 from a 405 -- which walked it
--   again. So a request that matched NOTHING was the most expensive request
--   the router could be asked to answer, and it needs no credential, no body
--   and no query to ask it.
--
--   THE ONE THE OPERATOR PAYS FOR. The duplicate-route check rescanned every
--   registered route on every add, so booting an application was O(routes^2).
--   Nobody can reach that from outside. It still matters, because the reason
--   this project measures boot at all is process-per-tenant density.
--
-- WHY THE BACKLOG'S ANSWER DID NOT COVER THIS. `docs/BACKLOG.md` closed prefix
-- tree routing with a number -- "33 us at 50 routes and 95 us at 200, against
-- roughly 4000 us for one Postgres query. A prefix tree would buy 0.8% of a
-- request" -- and wrote a revisit trigger: past about 500 dynamic routes.
--
-- Both halves of that need saying. The trigger has fired, which is the boring
-- half. The interesting half is that the RATIO was measured against a request
-- that goes to the database, and a 404 does not go to the database. It has no
-- query to be 0.8% of. The router is not 0.8% of a 404, it is essentially all
-- of it, so a comparison against 4000 us of Postgres never described this
-- path -- at any route count. That is the argument for reopening; the route
-- count is only what made it visible.
--
-- MEASURED THIS WAY BECAUSE THE OTHER WAY LIED. A first version built the
-- table, timed a hit, then timed a miss, and reported the miss as 40x the hit.
-- Most of that was the exact-route fast path: `self.exact` answers a literal
-- route from a hash and never reaches the scan at all, so "hit" was measuring
-- a table lookup. The hit below is a PARAMETERISED hit, which is the one that
-- shares a code path with the miss.
--
-- Arms interleaved in one process and the minimum kept, per the rule the rest
-- of the study runs on: a difference below the spread of the run that produced
-- it is not a result. The spread is printed beside every figure.
--
-- The `before` arm is the shipped code as of d1e5d45, kept here rather than
-- described, so the comparison is against the code and not against a memory of
-- it. If `App:match` changes and this file does not, the arms stop being a
-- comparison -- guard it in review.
--
--     lua5.4 bench/study/router-scale.lua
--     ROUTES=200,2000,20000 ROUNDS=5 lua5.4 bench/study/router-scale.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

local ROUNDS = tonumber(os.getenv "ROUNDS") or 5
local ROUTES = {}
for n in (os.getenv "ROUTES" or "500,1000,2000,5000,10000"):gmatch "[^,]+" do
  ROUTES[#ROUTES + 1] = tonumber(n)
end

-- ===================================================================== arms

--- `App:match` as it shipped: a linear scan of every route, with a fresh
--- capture table per parameterised candidate.
local function match_before(app, method, path)
  local hit = app.exact[method .. " " .. path]
  if hit then return hit, {} end
  for _, r in ipairs(app.routes) do
    if r.method == method and #r.names > 0 then
      local captured = { path:match(r.pattern) }
      if captured[1] ~= nil then return r, captured end
    end
  end
  return nil
end

--- `App:methods_for` as it shipped: the second walk of the same table.
local function methods_for_before(app, path)
  local seen, list = {}, {}
  for _, r in ipairs(app.routes) do
    local verb = r.method
    if #r.names == 0 then
      if r.path == path and not seen[verb] then seen[verb] = true; list[#list + 1] = verb end
    elseif path:match(r.pattern) and not seen[verb] then
      seen[verb] = true; list[#list + 1] = verb
    end
  end
  table.sort(list)
  return list
end

--- Registration as it shipped: rescan `routes` looking for a duplicate.
local function duplicate_scan(routes, verb, path)
  for _, r in ipairs(routes) do
    if r.method == verb and r.path == path then return r end
  end
  return nil
end

-- ================================================================ instrument

local function best_of(rounds, iterations, fn)
  local samples = {}
  for _ = 1, rounds do
    fn()                                                          -- warm
    collectgarbage(); collectgarbage()                            -- BETWEEN, not during
    local t0 = os.clock()
    for _ = 1, iterations do fn() end
    samples[#samples + 1] = (os.clock() - t0) / iterations * 1e6  -- us
  end
  table.sort(samples)
  return samples[1], samples[#samples] - samples[1]
end

--- Bytes allocated per call, with the collector stopped. Exact, and the same
--- on every machine -- which is why `spec/router_scale_spec.lua` asserts on
--- this and not on any figure printed here.
local function bytes_per(iterations, fn)
  fn()
  collectgarbage(); collectgarbage(); collectgarbage "stop"
  local before = collectgarbage "count"
  for _ = 1, iterations do fn() end
  local after = collectgarbage "count"
  collectgarbage "restart"
  return (after - before) * 1024 / iterations
end

local function build(n)
  local app = akkar.new()
  local handler = function() return { ok = true } end
  for i = 1, n do app:get("/r" .. i .. "/:id", handler) end
  return app
end

-- ======================================================================= run

print(("%d rounds, minimum kept, spread printed as the floor\n"):format(ROUNDS))

print "A REQUEST THAT MATCHES NOTHING -- match + methods_for, as dispatch calls them"
print "  routes        before      floor         after      floor      ratio"
for _, n in ipairs(ROUTES) do
  local app = build(n)
  local miss = "/nothing/here"
  assert(match_before(app, "GET", miss) == nil and app:match("GET", miss) == nil)

  local iterations = n > 2000 and 20 or 200
  local old, old_floor = best_of(ROUNDS, iterations, function()
    match_before(app, "GET", miss); methods_for_before(app, miss)
  end)
  local new, new_floor = best_of(ROUNDS, iterations * 50, function()
    app:match("GET", miss); app:methods_for(miss)
  end)
  print(("  %6d  %10.1f us  %6.1f  %10.2f us  %6.2f  %8.0fx")
    :format(n, old, old_floor, new, new_floor, old / new))
end

print ""
print "  and the same thing weighed rather than timed, which is exact:"
print "  routes         before          after"
for _, n in ipairs(ROUTES) do
  local app = build(n)
  local miss = "/nothing/here"
  local old = bytes_per(50, function()
    match_before(app, "GET", miss); methods_for_before(app, miss)
  end)
  local new = bytes_per(50, function()
    app:match("GET", miss); app:methods_for(miss)
  end)
  print(("  %6d  %10.0f B  %10.0f B"):format(n, old, new))
end

print ""
print "A PARAMETERISED HIT -- the successful request that shares the same path"
print "  routes        before      floor         after      floor      ratio"
for _, n in ipairs(ROUTES) do
  local app = build(n)
  local hit = "/r" .. (n // 2) .. "/42"                 -- halfway down the table
  assert(app:match("GET", hit) ~= nil)

  local iterations = n > 2000 and 20 or 200
  local old, old_floor = best_of(ROUNDS, iterations, function()
    match_before(app, "GET", hit)
  end)
  local new, new_floor = best_of(ROUNDS, iterations * 50, function()
    app:match("GET", hit)
  end)
  print(("  %6d  %10.1f us  %6.1f  %10.2f us  %6.2f  %8.0fx")
    :format(n, old, old_floor, new, new_floor, old / new))
end

print ""
print "BOOT -- registering the table, where the duplicate check used to rescan"
print "  routes        before          after      ratio"
for _, n in ipairs(ROUTES) do
  -- The `before` arm registers through the shipped path and pays the rescan
  -- beside it, so the two differ by the scan and by nothing else.
  local paths = {}
  for i = 1, n do paths[i] = "/r" .. i .. "/:id" end
  local handler = function() return { ok = true } end

  collectgarbage(); collectgarbage()
  local t0 = os.clock()
  local old_app = akkar.new()
  for i = 1, n do
    duplicate_scan(old_app.routes, "GET", paths[i])
    old_app:get(paths[i], handler)
  end
  local old = os.clock() - t0

  collectgarbage(); collectgarbage()
  t0 = os.clock()
  local new_app = akkar.new()
  for i = 1, n do new_app:get(paths[i], handler) end
  local new = os.clock() - t0

  print(("  %6d  %10.3f s  %10.3f s  %8.1fx"):format(n, old, new, old / new))
end

print ""
print "A ratio is only a result where the gap clears the floor beside it."
print "The boot column has no floor and does not need one: it is one run of a"
print "deterministic loop, and the shape -- 4x per doubling against 2x -- is"
print "the finding rather than any second of it."
