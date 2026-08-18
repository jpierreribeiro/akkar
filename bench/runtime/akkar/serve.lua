--[[
The akkar side of the runtime comparison.

THIS FILE DID NOT EXIST WHEN THE FIRST RESULTS WERE PUBLISHED, and that is why
it exists now. `run.sh` starts `rt-akkar-serve.lua`; that file was written by
hand on the study box and lived only there. When the box went away, the one
candidate whose numbers the whole comparison is about became the one candidate
that could not be reproduced -- while Luvit, OpenResty and Lapis all had their
services versioned in this directory.

`bench/runtime/METHOD.md` rule 1 says the candidates must answer the same
thing before any clock starts. A service that exists only on a machine cannot
be held to that rule, because nobody can read what it did.

Routes match the other three candidates exactly:

  /ping        the runtime alone, no database
  /users/:id   one indexed query, validated before the database is touched

`run.sh` loads only `/ping`. `/users/:id` is here anyway, because D5
(saturation) and D7 (dependency down) are the second pass and both need it,
and because Lapis's service carries it -- a candidate with fewer routes is not
a candidate that is faster, it is a candidate answering a different question.
]]

local akkar = require "akkar"
local db    = require "akkar.db"

-- Which tree was loaded, printed before the port is bound. `run.sh` sets
-- LUA_PATH to point at a checkout rather than the rock tree, and the whole
-- akkar/Lapis delta depends on that having worked. A run that silently
-- measured the installed rock instead would look completely normal.
io.stderr:write(("tree=%s\n"):format(tostring(package.searchpath("akkar", package.path))))

local app = akkar.new()

app:get("/ping", function() return { pong = true } end)

app:get("/users/:id", { params = { id = akkar.v.integer { min = 1 } } },
  function(req)
    return req.db:one("select id, name, email from users where id = $1",
                      req.params.id) or akkar.not_found "user not found"
  end)

app:run {
  port = tonumber(arg[1]) or 8403,
  reuseport = true,
  check_capabilities = false,

  -- AS SHIPPED. The deadline stays on, the capabilities stay on, the pool is
  -- the size `run.sh` passes. Reporting akkar with its invariants switched off
  -- would measure something nobody deploys, and the comparison exists to price
  -- those invariants rather than to hide them.
  --
  -- `socket_buffer` is deliberately NOT set: the default is what an
  -- application gets, and D3 -- the cost per idle keep-alive connection -- is
  -- exactly the dimension that default was chosen to move.
  db = db.connect { port = 55432, database = "akkar", user = "postgres",
                    password = "akkar", pool_size = tonumber(arg[2]) or 10 },
  log = akkar.log.new { level = "error" },
}
