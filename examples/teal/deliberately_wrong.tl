local akkar = require("akkar")
local app = akkar.new()

app:get("/users/:id", function(req: akkar.Request): akkar.Response
   local id = req.parms.id                    -- ERRO 1: campo inexistente
   return akkar.ok({ id = id })
end)

app:get("/x", function(req: akkar.Request): akkar.Response
   local n: integer = req.path                -- ERRO 2: string em integer
   return akkar.ok({ n = n })
end)

app:run({ timout = 5 })                       -- ERRO 3: opcao inexistente
