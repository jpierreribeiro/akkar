--[[
Teal declarations for the in-memory cache.

A real implementation rather than a stand-in -- a cache is a table with
expiry. Per-process, which matters because akkar's answer to more CPU is more
processes, and two processes have two caches.
]]

local akkar = require("akkar")

local record memory
   record Cache
      get: function(Cache, string): string
      set: function(Cache, string, string, ?integer): string
      del: function(Cache, ...: string): integer
      incr: function(Cache, string): integer
      expire: function(Cache, string, integer): integer
      -- Redis semantics: -2 when the key is gone, -1 when it has no expiry.
      ttl: function(Cache, string): integer
      command: function(Cache, string, ...: any): any

      -- The fault surface. `fail` is an error reply and leaves the
      -- connection healthy; `hang` is a command never answered; `drop` is the
      -- transport gone, and everything after it fails.
      on: function(Cache, string, function(Cache)): Cache
      fail: function(Cache, string, ?string): Cache
      hang: function(Cache, string, ?number): Cache
      drop: function(Cache, string): Cache

      -- What a pool's reuse predicate reads, with the meanings
      -- `akkar.redis` gives them.
      broken: boolean
      in_flight: boolean

      sweep: function(Cache): integer
      size: function(Cache): integer
      reset: function(Cache): Cache
      release: function(Cache)
      close: function(Cache)
   end

   record Options
      -- Injectable so a test can move time without sleeping.
      now: function(): integer

      -- The capacity model, honoured by advancing `akkar.time` rather than
      -- by waiting: commands served per second, and service time each.
      max_qps: number
      latency_ms: number
   end

   new: function(?Options): Cache
   factory: function(?Options): any
end

return memory
