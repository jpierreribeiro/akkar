-- A handler in Teal that should type-check cleanly.
local akkar = require("akkar")

local app = akkar.new()

app:get("/users/:id", {
   params = { id = akkar.v.integer({ min = 1 }) },
   response = { id = "integer", name = "string" },
}, function(req: akkar.Request): akkar.Response
   local user = req.db:one("select id, name from users where id = $1", req.params.id)
   if user == nil then
      return akkar.not_found("user not found")
   end
   req.log:info("served user", { id = req.params.id })
   return akkar.ok(user)
end)

app:use(function(req: akkar.Request, next: function(akkar.Request): akkar.Response): akkar.Response
   local res = next(req)
   req.log:info("request", { path = req.path, status = res.status })
   return res
end)

app:run({ port = 8080, strict = true, reuseport = true })
