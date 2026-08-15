--[[
akkar.jobs.memory — in-process persistence for a job queue.

Same argument as the other `_memory` adapters: a shared, tested implementation
of the store contract beats a fake per test file.

`dequeue` does not block. Nothing here should sleep waiting for work that can
only arrive from the same process -- if the queue is empty it will stay empty
until this coroutine yields, so blocking would be a deadlock rather than a
wait.
]]

local jobs = require "akkar.jobs"

local Store = {}
Store.__index = Store

local M = {}

function Store:enqueue(key, encoded)
  local list = self.lists[key]
  if not list then list = {} self.lists[key] = list end
  table.insert(list, 1, encoded)
  return #list
end

function Store:dequeue(key)
  local list = self.lists[key]
  if not list or #list == 0 then return nil end
  return table.remove(list)      -- from the tail: FIFO
end

function Store:depth(key)
  local list = self.lists[key]
  return list and #list or 0
end

function M.store()
  return setmetatable({ lists = {} }, Store)
end

function M.new(name)
  return jobs.new(M.store(), name)
end

M.Store = Store
return M
