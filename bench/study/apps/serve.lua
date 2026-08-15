-- The akkar side of the study.  One file, three routes, and it proves which
-- tree it loaded before binding a port.
--
--   /ping        the framework alone
--   /users/:id   one indexed query
--   /rows/:n     a payload sweep, straight from the database
--
-- `AKKAR_ROOT` selects the tree, `AKKAR_LEAN` turns off the two features the
-- peers do not have, so akkar can be reported as-shipped AND like for like.
local root = assert(os.getenv "AKKAR_ROOT", "set AKKAR_ROOT")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local akkar = require "akkar"
local db    = require "akkar.db"

io.stderr:write(("tree=%s\n"):format(package.searchpath("akkar", package.path)))

local lean = os.getenv "AKKAR_LEAN" == "1"

local app = akkar.new()
app:get("/ping", function() return { pong = true } end)

app:get("/users/:id", { params = { id = akkar.v.integer { min = 1 } } },
  function(req)
    return req.db:one("select id, name, email from users where id = $1",
                      req.params.id) or akkar.not_found "user not found"
  end)

app:get("/rows/:n", { params = { n = akkar.v.integer { min = 1, max = 2000 } } },
  function(req)
    return { rows = req.db:many(
      "select id, name, email, note from bench_rows order by id limit $1",
      req.params.n) }
  end)

app:run {
  port = tonumber(arg[1]) or 8500,
  reuseport = true,
  check_capabilities = false,
  -- The deadline is akkar's, not Gin's and not uvicorn's.  Reporting akkar
  -- with it on is honest; reporting ONLY that hides what the feature costs.
  timeout = lean and 0 or nil,
  db = db.connect { port = 55432, database = "akkar", user = "postgres",
                    password = "akkar", pool_size = tonumber(arg[2]) or 10 },
  log = akkar.log.new { level = "error" },
}
