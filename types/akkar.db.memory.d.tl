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
      -- `fail` returns immediately; `hang` yields, which is what stages a
      -- coroutine abandoned mid-query. `drop` kills the connection for good.
      hang: function(Fake, string, ?number): Fake
      drop: function(Fake, string): Fake

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

   record Options
      -- The capacity model, honoured by advancing `akkar.time` rather than
      -- by waiting: statements served per second, and service time each.
      max_qps: number
      latency_ms: number
   end

   new: function(?Options): Fake
   -- A function programs the fake; a table is `new`'s options; both together
   -- is `factory(options, program)`.
   factory: function(?any, ?function(Fake)): any
end

return memory
