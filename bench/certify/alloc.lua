--[[
Bytes allocated per request.

Why this file exists, and why it is not a timing benchmark:

An earlier project of the owner's proved twice that a symbol's share of a
profile is NOT the gain from removing it.  Pre-sizing a buffer held 10.7% of
that profile and measured -2.6% of ceiling.  An RTTI cache held 6.86% and
regressed p99 by 17.8%.  Timing is noisy enough that a real improvement and a
real regression can both hide inside it.

**Allocation is not noisy.**  It is deterministic, machine-independent, and
identical across runs to the byte.  So this is where a regression assertion
can actually live, while timing lives in a recorded comparison.

That project reached the same conclusion and put its gate on allocation counts
for exactly this reason.

## What it measures, and the trap in measuring it

Bytes allocated per request through `app:test()` -- the same middleware,
validation and dispatch chain a real request travels, with no socket and no
database.  The GC is stopped during measurement, so the number is total
allocation rather than retained memory: two very different quantities, and
this is the first.

**But the in-process client does not serialise.**  It hands the handler's
table back as a table, and takes a request body as a table.  So `cjson.encode`
and `cjson.decode` -- the whole payload-size question -- never run on that
path.  A first version of this file reported the same 3,717 bytes for a
1-row, 50-row and 500-row response, which is not a flat cost curve; it is a
measurement blind to the axis it was pointed at.

So the cases below are grouped by what they include, and each group says so:

  dispatch         what the framework costs, payload-independent
  + encode         adding what the server does to the response
  decode +         adding what the server does to the request body

## Reading it

A number going up after a patch is a regression, full stop -- there is no
noise floor to hide behind.  A number going down is an improvement in
allocation, which is *not* automatically an improvement in latency, and the
owner's earlier project has the receipts on that.  Certify time with
`bench/certify/ab.sh`; certify allocation here.

  lua5.4 bench/certify/alloc.lua [akkar_dir]
]]

local akkar_dir = arg[1]
if akkar_dir then
  package.path = akkar_dir .. "/?.lua;" .. akkar_dir .. "/?/init.lua;" .. package.path
end
package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar     = require "akkar"
local memory_db = require "akkar.db.memory"

local ITERATIONS = tonumber(os.getenv "ITERATIONS") or 2000

-- ============================================================== measurement
-- With the collector stopped, `collectgarbage("count")` only grows, so the
-- delta is everything allocated rather than everything retained.
local function bytes_per_call(times, fn)
  fn()                              -- warm: first call pays for one-off setup
  collectgarbage "collect"
  collectgarbage "collect"
  collectgarbage "stop"
  local before = collectgarbage "count"
  for _ = 1, times do fn() end
  local after = collectgarbage "count"
  collectgarbage "restart"
  collectgarbage "collect"
  return (after - before) * 1024 / times
end

-- ==================================================================== fixtures
local function rows(n)
  local out = {}
  for i = 1, n do
    out[i] = { id = i, name = "user" .. i, email = "u" .. i .. "@example.com" }
  end
  return out
end

local function body_with(n)
  return { rows = rows(n) }
end

local function build_app()
  local app = akkar.new()

  app:get("/ping", function() return { pong = true } end)

  app:get("/users/:id", {
    params   = { id = akkar.v.integer { min = 1 } },
    response = { id = "integer", name = "string", email = "string?" },
  }, function(req)
    return req.db:one("select id, name, email from users where id = $1",
                      req.params.id)
  end)

  app:get("/rows/:n", {
    params = { n = akkar.v.integer { min = 1, max = 5000 } },
  }, function(req)
    return { users = req.db:many("select id, name, email from users limit $1",
                                 req.params.n) }
  end)

  app:post("/echo", function(req)
    local n = 0
    if type(req.body) == "table" and type(req.body.rows) == "table" then
      n = #req.body.rows
    end
    return { received = n }
  end)

  app:post("/validated", {
    body = { name = "string", email = "string?" },
  }, function(req) return { name = req.body.name } end)

  return app
end

-- The fake database returns a fixed table, so response size is controlled by
-- the fixture rather than by a query.
local function client_for(row_count)
  local app = build_app()
  local data = rows(row_count)
  return app:test {
    db = memory_db.factory(function(fake)
      fake:on("where id", data[1] or { id = 1, name = "a" })
      fake:on("limit", data)
    end),
  }
end

-- ======================================================================= cases
local cjson = require "cjson"

local small_client  = client_for(1)
local medium_client = client_for(50)
local large_client  = client_for(500)

local small_body  = body_with(1)
local medium_body = body_with(50)
local large_body  = body_with(500)

-- Pre-encoded request bodies, so the decode case measures decode and not the
-- encode that produced its input.
local small_raw  = cjson.encode(small_body)
local medium_raw = cjson.encode(medium_body)
local large_raw  = cjson.encode(large_body)

local groups = {
  { "dispatch only  (what app:test covers)", {
    { "GET /ping",              function() small_client:get "/ping" end },
    { "GET /users/1",           function() small_client:get "/users/1" end },
    { "GET /rows/1",            function() small_client:get "/rows/1" end },
    { "GET /rows/50",           function() medium_client:get "/rows/50" end },
    { "GET /rows/500",          function() large_client:get "/rows/500" end },
    { "POST /validated",        function() small_client:post("/validated", { body = { name = "ada" } }) end },
    { "GET /nowhere (404)",     function() small_client:get "/nowhere" end },
  }},

  { "dispatch + response encode  (what the socket path adds)", {
    { "GET /rows/1",   function() cjson.encode(small_client:get("/rows/1").body) end },
    { "GET /rows/50",  function() cjson.encode(medium_client:get("/rows/50").body) end },
    { "GET /rows/500", function() cjson.encode(large_client:get("/rows/500").body) end },
  }},

  { "request decode alone  (what the socket path adds inbound)", {
    { "1 row",   function() cjson.decode(small_raw) end },
    { "50 rows", function() cjson.decode(medium_raw) end },
    { "500 rows", function() cjson.decode(large_raw) end },
  }},

  { "decode + dispatch  (the full inbound path)", {
    { "POST /echo, 1 row",    function() small_client:post("/echo", { body = cjson.decode(small_raw) }) end },
    { "POST /echo, 50 rows",  function() small_client:post("/echo", { body = cjson.decode(medium_raw) }) end },
    { "POST /echo, 500 rows", function() small_client:post("/echo", { body = cjson.decode(large_raw) }) end },
  }},
}

-- ====================================================================== report
print(("="):rep(72))
print("bytes allocated per request  --  " .. _VERSION ..
      (akkar_dir and ("  [" .. akkar_dir .. "]") or ""))
print(("="):rep(72))
print(string.format("  iterations per case: %d", ITERATIONS))
print()
for _, group in ipairs(groups) do
  print(string.format("  %s", group[1]))
  local first
  for _, case in ipairs(group[2]) do
    local bytes = bytes_per_call(ITERATIONS, case[2])
    first = first or bytes
    print(string.format("    %-24s %14.0f %13.1fx", case[1], bytes,
                        first > 0 and bytes / first or 0))
  end
  print()
end

print()
print("  Allocation is deterministic: two runs of the same tree give the same")
print("  numbers.  A rise after a patch is a regression with no noise floor to")
print("  hide behind -- but a fall is not automatically faster.  Certify time")
print("  separately, with bench/certify/ab.sh.")
