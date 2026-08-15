--[[
akkar.strict — turns Lua's global-by-default into an error.

The single most common criticism of Lua for larger codebases is that a typo
creates a global instead of failing:

    local total = 0
    for _, item in ipairs(items) do
      totl = totl + item.price      -- a new global, and a nil arithmetic error
    end                             -- somewhere else entirely

On a server it is worse than a typo. A global written inside a handler
survives the request and is visible to the next one, in the same process, for
another user. That is state leaking across requests through a mechanism
nothing in the language flags.

`PLAN.md` has said "nothing global" as an invariant since the beginning.
Until now nothing enforced it, which made it a claim rather than a property.
akkar itself measures clean -- zero global writes across every module, checked
in the bytecode -- but that was discipline, and discipline does not extend to
handlers someone else writes.

## What it does

Reading an undeclared global raises. Writing one raises. Declaring one on
purpose is possible and explicit.

    local strict = require "akkar.strict"
    strict.on()

    counter = 0                 -- error: assignment to undeclared global 'counter'
    strict.declare "counter"    -- explicit, and now allowed
    counter = 0                 -- fine

## What it costs

A metatable lookup on every global access that misses -- which, in code that
does not touch globals, is nothing. Existing globals are untouched: `print`,
`table` and everything else already in `_G` are declared by definition.

It is on by default in development and in the test suite, and off in
production unless asked for, because a false positive that takes down a live
server is worse than the bug it was looking for.
]]

local M = {}

local declared = {}
local active = false

-- Everything already present when strict mode is installed counts as
-- declared: the standard library, and anything the program set up before
-- deciding to be strict.
local function snapshot()
  for name in pairs(_G) do declared[name] = true end
end

local function where(level)
  local info = debug.getinfo(level + 1, "Sl")
  if not info then return "?" end
  return info.short_src .. ":" .. info.currentline
end

--- Declares a global on purpose, so the check is explicit rather than
--- something to work around.
function M.declare(...)
  for i = 1, select("#", ...) do
    declared[(select(i, ...))] = true
  end
end

function M.declared(name)
  return declared[name] == true
end

--- Installs the check.  Idempotent.
function M.on()
  if active then return M end
  snapshot()
  active = true

  setmetatable(_G, {
    __newindex = function(table, name, value)
      if not declared[name] then
        error(string.format(
          "assignment to undeclared global '%s' at %s\n" ..
          "  a global written in a handler outlives the request and is " ..
          "visible to the next one\n" ..
          "  did you mean `local %s`?  to declare it on purpose: " ..
          "require('akkar.strict').declare('%s')",
          name, where(2), name, name), 2)
      end
      rawset(table, name, value)
    end,

    __index = function(_, name)
      if not declared[name] then
        error(string.format(
          "read of undeclared global '%s' at %s\n" ..
          "  most often a typo in a local name, or a module someone " ..
          "forgot to require",
          name, where(2)), 2)
      end
      return nil
    end,
  })
  return M
end

function M.off()
  if not active then return M end
  setmetatable(_G, nil)
  active = false
  return M
end

function M.active()
  return active
end

return M
