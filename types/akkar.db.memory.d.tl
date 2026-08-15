--[[
Teal declarations for the in-memory database stand-in.

It does not parse SQL: `on` programs a response against a Lua pattern matched
on the query. Pretending to execute SQL would be a second, worse database.
]]

local akkar = require("akkar")

local record memory
   record Fake
      on: function(Fake, string, any): Fake
      fail: function(Fake, string, ?string): Fake

      one: function(Fake, string, ...: any): {string: any}
      many: function(Fake, string, ...: any): {{string: any}}
      exec: function(Fake, string, ...: any): any
      transaction: function(Fake, function(Fake): any): any
      release: function(Fake)
      close: function(Fake)

      -- What a test asks afterwards.
      received: function(Fake, string): boolean
      count: function(Fake, ?string): integer
      reset: function(Fake): Fake

      committed: boolean
      rolled_back: boolean
   end

   new: function(): Fake
   factory: function(?function(Fake)): any
end

return memory
