-- A small API whose contract is the source of `client.ts` beside it.
--
-- `akkar gen app.lua -o client.ts` regenerates the client from these schemas,
-- and CI runs the same command with `--check`, so a change to any schema here
-- that is not regenerated fails the build. That is the whole discipline: the
-- route table is the one place the contract is written, and everything else --
-- the served `/openapi.json`, the runtime validator, the TypeScript client --
-- is derived from it and cannot drift.
local akkar = require "akkar"

local app = akkar.new()

app:get("/users/:id", {
  params = { id = akkar.v.string { min = 1, max = 64 } },
  response = { id = "string", name = "string", email = "string" },
}, function(req)
  return { id = req.params.id, name = "Ada", email = "ada@example.com" }
end)

app:get("/users", {
  query = {
    q     = akkar.v.string { optional = true },
    limit = akkar.v.integer { min = 1, max = 100, optional = true },
  },
  response = {
    users = akkar.v.array {
      items = akkar.v.object { fields = { id = "string", name = "string" } },
    },
  },
}, function()
  return { users = { { id = "u1", name = "Ada" } } }
end)

app:post("/transfers", {
  body = {
    to     = akkar.v.string { min = 1 },
    amount = akkar.v.integer { min = 1 },
    memo   = akkar.v.string { optional = true, max = 140 },
  },
  responses = {
    [201] = { id = "string", status = "string" },
  },
}, function(req)
  return akkar.response(201, { id = "tr_1", status = "posted" })
end)

return app
