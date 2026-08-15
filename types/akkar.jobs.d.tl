--[[
Teal declarations for akkar.jobs and its stores.

The split is visible in the types: `new` takes any table answering the store
contract, so a backend akkar does not ship is a first-class citizen rather
than a fork.
]]

local akkar = require("akkar")

local record jobs
   new: function(akkar.JobStore, ?string): akkar.Queue
end

return jobs
