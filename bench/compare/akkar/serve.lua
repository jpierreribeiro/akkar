--[[
akkar, matching the other two exactly.

The schema does the validation Gin does by hand and FastAPI does with
Pydantic, and `response` emits the same three fields.  Logging is at warn so
nothing is written per request.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local db    = require "akkar.db"

local port = tonumber(arg[1]) or 8403
local pool = tonumber(arg[2]) or 10

local app = akkar.new()

app:get("/ping", function() return { pong = true } end)

app:get("/users/:id", {
  params   = { id = akkar.v.integer { min = 1 } },
  response = { id = "integer", name = "string", email = "string?" },
}, function(req)
  local user = req.db:one(
    "select id, name, email from users where id = $1", req.params.id)
  return user or akkar.not_found "user not found"
end)

-- Variable payload, to find where serialisation starts to dominate.
app:get("/rows/:n", {
  params = { n = akkar.v.integer { min = 1, max = 5000 } },
}, function(req)
  return { users = req.db:many(
    "select id, name, email from users order by id limit $1", req.params.n) }
end)

app:run {
  port = port,
  reuseport = true,
  db = db.connect { port = 55432, database = "akkar",
                    user = "postgres", password = "akkar", pool_size = pool },
  log = akkar.log.new { level = "warn" },
}
