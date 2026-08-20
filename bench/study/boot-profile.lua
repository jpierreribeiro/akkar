-- Where does `require "akkar"` spend its time, and what does it drag in?
--
-- The runtime comparison measured akkar booting in 63 ms against 15 ms for
-- OpenResty and Luvit. Boot is not a headline number for a long-running
-- service, but it is the whole number for two cases this project cares about:
-- a process per student on the teaching platform, and any cold start.
--
-- Instruments `require` itself, so the cost is attributed to whoever asked
-- first rather than to whoever happens to be at the top of the file.
--
-- WHAT IT FOUND ON ITS FIRST RUN, 2026-08-19: `akkar/init.lua` required
-- `akkar.websocket` eagerly, which pulls the vendored socket, lua-http's
-- request and client halves, and three `lpeg_patterns` grammars. 123.7 ms and
-- 65 modules, on every boot of every application, whether or not a socket is
-- ever opened. Deferring it took boot to first response from 164 ms to 68.
--
-- CAVEAT ON THE SELF-TIME COLUMN, so nobody reads it as gospel: children are
-- attributed by name prefix, which is right for `akkar.vendor.http.*` under
-- `akkar.vendor.http` and wrong for a module that requires something outside
-- its own namespace. The ordering is reliable; the percentages overlap. Use it
-- to find the expensive CHAIN, then measure that chain in isolation, which is
-- what turned 74.8 ms of overlapping attribution into a measured 123.7.
package.path = "./?.lua;./?/init.lua;" .. package.path

local real_require = require
local depth, cost, order = 0, {}, {}
local self_time = {}

_G.require = function(name)
  if package.loaded[name] then return real_require(name) end
  depth = depth + 1
  local started = os.clock()
  local ok, mod = pcall(real_require, name)
  local elapsed = os.clock() - started
  depth = depth - 1
  if cost[name] == nil then
    cost[name] = elapsed
    order[#order + 1] = name
  end
  if not ok then error(mod, 0) end
  return mod
end

local t0 = os.clock()
real_require "akkar"
local total = os.clock() - t0

-- SELF TIME, not inclusive. A module that requires three others is charged
-- for itself only, or the totals sum to several times the truth.
for _, name in ipairs(order) do
  local children = 0
  for _, other in ipairs(order) do
    if other ~= name and other:find(name .. ".", 1, true) == 1 then
      children = children + cost[other]
    end
  end
  self_time[name] = cost[name] - children
end

table.sort(order, function(a, b) return (self_time[a] or 0) > (self_time[b] or 0) end)

print(("require \"akkar\": %.1f ms total, %d modules")
  :format(total * 1000, #order))
print()
print("os quinze mais caros, tempo proprio:")
local shown = 0
for _, name in ipairs(order) do
  local ms = (self_time[name] or 0) * 1000
  if ms >= 0.5 and shown < 15 then
    shown = shown + 1
    print(("  %-34s %6.1f ms   %4.1f%%"):format(name, ms, ms / (total * 1000) * 100))
  end
end

-- WHAT A /ping SERVICE ACTUALLY TOUCHES. Anything loaded eagerly and never
-- used is boot time an application did not ask for.
print()
local akkar_modules = 0
for _, name in ipairs(order) do
  if name:find("^akkar") then akkar_modules = akkar_modules + 1 end
end
print(("dos %d modulos, %d sao do akkar e %d sao dependencias")
  :format(#order, akkar_modules, #order - akkar_modules))
