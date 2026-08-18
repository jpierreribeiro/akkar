-- Can a coroutine be REUSED, and what would that be worth?
--
-- The two per-request coroutines are 55% of a request. Removing either is
-- risky -- lua-http's carries pipelining and upgrades, akkar's IS the
-- abandonment mechanism. But there is a third possibility neither the plan
-- nor the ablation considered: keep the coroutines and stop creating them.
--
-- A DEAD coroutine cannot be restarted, so there is no pooling of finished
-- ones. A SUSPENDED one can be resumed for ever, which is the standard worker
-- pattern: N long-lived coroutines, each looping on a queue.
--
-- If that works, the per-request cost stops being "a coroutine" and becomes
-- "a handoff", and the stack is allocated once at its high-water mark instead
-- of per request.
local cqueues   = require "cqueues"
local condition = require "cqueues.condition"

local N = 20000

local function descender(depth)
  local src = { "local function f0() return 1 end" }
  for i = 1, depth do
    src[#src + 1] = ("local function f%d() local x = f%d() return x + 0 end")
      :format(i, i - 1)
  end
  src[#src + 1] = ("return function() return f%d() end"):format(depth)
  return assert(load(table.concat(src, "\n")))()
end

local WORK = descender(8)

-- ------------------------------------------------------- a dead coroutine
print("resuming a finished coroutine:")
do
  local co = coroutine.create(function() return 1 end)
  print("  first resume :", coroutine.resume(co))
  print("  second resume:", coroutine.resume(co))
  print("  status       :", coroutine.status(co))
end

-- --------------------------------------------- one coroutine per unit of work
local function per_request()
  local cq = cqueues.new()
  for _ = 1, 200 do cq:wrap(WORK) cq:step(0) end
  collectgarbage(); collectgarbage()
  collectgarbage "stop"
  local before = collectgarbage "count"
  for _ = 1, N do
    cq:wrap(WORK)
    cq:step(0)
  end
  local after = collectgarbage "count"
  collectgarbage "restart"
  return (after - before) * 1024 / N
end

-- ------------------------------------------------------ one long-lived worker
--
-- The worker parks on a condition, runs whatever it is handed, and parks
-- again. Its stack is allocated once, at the deepest thing it ever ran.
local function worked()
  local cq = cqueues.new()
  local ready = condition.new()
  local done  = condition.new()
  local job

  cq:wrap(function()
    while true do
      if not job then ready:wait() end
      local fn = job
      job = nil
      if fn == false then return end
      fn()
      done:signal()
    end
  end)
  cq:step(0)

  local function run(fn)
    job = fn
    ready:signal()
    cq:step(0)
  end

  for _ = 1, 200 do run(WORK) end
  collectgarbage(); collectgarbage()
  collectgarbage "stop"
  local before = collectgarbage "count"
  for _ = 1, N do run(WORK) end
  local after = collectgarbage "count"
  collectgarbage "restart"
  run(false)
  return (after - before) * 1024 / N
end

print()
local a = per_request()
local b = worked()
print(("a coroutine per unit of work   %8.0f bytes"):format(a))
print(("one long-lived worker          %8.0f bytes"):format(b))
print(("difference                     %8.0f bytes  (%.0f%%)"):format(a - b, (a - b) / a * 100))
