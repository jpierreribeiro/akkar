--[[
Lapis on cqueues, matching bench/compare/akkar/serve.lua.

THIS IS THE MOST INFORMATIVE CANDIDATE IN THE SET, and the reason is the
substrate. Lapis can run under OpenResty or under lua-http/cqueues. Run on
cqueues it stands on exactly what akkar stands on -- on this box, literally
the same rocks in ~/.luarocks, the same cqueues build akkar's own runs read.

With the base held constant, the difference between these two numbers is not
"a different stack". It is akkar: the router, the chain, the request table,
the deadline, the lazy capabilities, the guaranteed release. It is the closest
thing available to a price tag on the four invariants.

The first provisioning run reported `lapis.cqueues` as ABSENT and it was
wrong -- a bare pcall hid `module 'http.headers' not found`. The backend is
present; it wanted lua-http, which lives in the user tree here. Recorded
because concluding "the backend does not exist" would have removed the one
candidate that makes the comparison mean anything.
]]

local lapis    = require "lapis"
local respond  = require "lapis.application".respond_to
local json     = require "cjson"

local app = lapis.Application()

app:get("/ping", function()
  return { json = { pong = true } }
end)

-- Validation matches akkar's `v.integer { min = 1 }`: rejected before the
-- database, with the same status akkar returns.
app:get("/users/:id", function(self)
  local id = tonumber(self.params.id)
  if not id or id ~= math.floor(id) or id < 1 then
    return { status = 422, json = { error = "invalid id" } }
  end

  local db = require "lapis.db"
  local rows = db.select("id, name, email from users where id = ?", id)
  local row = rows and rows[1]
  if not row then
    return { status = 404, json = { error = "user not found" } }
  end

  return { json = { id = row.id, name = row.name, email = row.email } }
end)

app.handle_404 = function(self)
  return { status = 404,
           json = { error = "no route for " .. self.req.method
                            .. " " .. self.req.parsed_url.path } }
end

return app
