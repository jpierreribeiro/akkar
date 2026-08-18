-- What does one frame of call depth cost a coroutine, IN THE RANGE THIS
-- RUNTIME ACTUALLY OCCUPIES?
--
-- The ablation study measured 40 non-tail frames at 13,416 bytes and 200 at
-- 54,376 -- about 270 bytes a frame. But akkar's stacks are 6 and 8 frames
-- deep, and Lua grows a stack by DOUBLING, so the marginal cost of one frame
-- is not a constant: it is zero until the stack has to double, and then it is
-- the whole new stack. A slope measured at 40 and 200 says nothing about 6.
--
-- If the slope is flat here, "shorten the call chain" is not a lever and the
-- only way to remove those bytes is to not create the coroutine.
local cqueues = require "cqueues"

local N = 20000

--- A function that descends `depth` non-tail frames and returns.
---
--- Built with `load` so each depth is genuinely separate code rather than a
--- recursive call the compiler might treat differently.
local function descender(depth)
  local src = { "local function f0() return 1 end" }
  for i = 1, depth do
    src[#src + 1] = ("local function f%d() local x = f%d() return x + 0 end")
      :format(i, i - 1)
  end
  src[#src + 1] = ("return function() return f%d() end"):format(depth)
  return assert(load(table.concat(src, "\n")))()
end

local function cost(depth)
  local fn = descender(depth)
  local cq = cqueues.new()
  -- Warm: the controller's own structures should not land in the measurement.
  for _ = 1, 200 do cq:wrap(fn) cq:step(0) end

  collectgarbage(); collectgarbage()
  collectgarbage "stop"
  local before = collectgarbage "count"
  for _ = 1, N do
    cq:wrap(fn)
    cq:step(0)
  end
  local after = collectgarbage "count"
  collectgarbage "restart"
  return (after - before) * 1024 / N
end

print(("%-8s %12s %12s"):format("frames", "bytes", "marginal"))
local previous
for _, depth in ipairs { 1, 2, 4, 6, 8, 10, 12, 16, 24, 40 } do
  local bytes = cost(depth)
  print(("%-8d %12.0f %12s"):format(depth, bytes,
    previous and ("%+.0f"):format(bytes - previous) or "-"))
  previous = bytes
end
