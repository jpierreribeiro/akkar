--[[
akkar.jobs.redis — Redis persistence for a job queue.  Semantics live in
`akkar.jobs`; this only stores and retrieves.

A Redis list gives FIFO for free: `LPUSH` to the head, `BRPOP` from the tail.
`BRPOP` blocks server-side rather than polling, and blocking there costs
nothing here because the Redis adapter yields while it waits.
]]

local jobs = require "akkar.jobs"

local Store = {}
Store.__index = Store

local M = {}

function Store:enqueue(key, encoded)
  return self.cache:command("LPUSH", key, encoded)
end

function Store:dequeue(key, timeout)
  local reply = self.cache:command("BRPOP", key, timeout)
  if type(reply) ~= "table" then return nil end
  return reply[2]
end

function Store:depth(key)
  return self.cache:command("LLEN", key)
end

--- Returns a ready-to-use queue, which is what a caller almost always wants.
function M.new(cache, name)
  return jobs.new(setmetatable({ cache = cache }, Store), name)
end

M.Store = Store
return M
