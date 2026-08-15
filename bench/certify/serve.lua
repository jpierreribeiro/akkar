--[[
The certification target.

Separate from `bench/serve.lua` because certification needs routes that
exercise the paths a performance patch touches, and adding them to the
throughput target would change what that target measures.

Routes, each aimed at one cost:

  /ping           dispatch and nothing else
  /users/:id      dispatch, validation, one query, response schema
  /rows/:n        the same, with a response that grows -- where serialisation
                  starts to dominate
  /echo           a request BODY that grows -- decode, null handling, body
                  validation

  lua5.4 bench/certify/serve.lua [port] [pool] [akkar_dir]

`akkar_dir` is how A/B works: point two runs at two copies of the framework
and the harness compares them without either knowing about the other.
]]

local akkar_dir = arg[3]
if akkar_dir then
  package.path = akkar_dir .. "/?.lua;" .. akkar_dir .. "/?/init.lua;" .. package.path
end
package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local db    = require "akkar.db"

local port = tonumber(arg[1]) or 8500
local pool = tonumber(arg[2]) or 10

local app = akkar.new()

app:get("/ping", function() return { pong = true } end)

app:get("/users/:id", {
  params   = { id = akkar.v.integer { min = 1 } },
  response = { id = "integer", name = "string", email = "string?" },
}, function(req)
  local user = req.db:one("select id, name, email from users where id = $1",
                          req.params.id)
  return user or akkar.not_found "user not found"
end)

app:get("/rows/:n", {
  params = { n = akkar.v.integer { min = 1, max = 5000 } },
}, function(req)
  return { users = req.db:many(
    "select id, name, email from users order by id limit $1", req.params.n) }
end)

-- Body-side cost.  Echoes a count rather than the body, so the response stays
-- constant while the request grows: that isolates decode from encode.
app:post("/echo", function(req)
  local n = 0
  if type(req.body) == "table" and type(req.body.rows) == "table" then
    n = #req.body.rows
  end
  return { received = n }
end)

app:run {
  port = port,
  reuseport = true,
  db = db.connect { port = 55432, database = "akkar",
                    user = "postgres", password = "akkar", pool_size = pool },
  log = akkar.log.new { level = "warn" },
}
