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
    local key = strict.on()

    counter = 0                 -- error: assignment to undeclared global 'counter'
    strict.declare "counter"    -- explicit, and now allowed
    counter = 0                 -- fine

    strict.off(key)             -- and only with the key `on` gave back

`on` hands back a key because strict mode is **process-wide**: `off` used to
be callable by anything that could `require` this module, which is every
handler in the process, so one of them could switch the check off for the
whole server and every other request in it.

`_G`'s metatable is shared ground and this module does not try to own it. `on`
refuses to install over one somebody else put there rather than replacing it,
and `off` puts back what it found and only when the metatable is still the one
it installed. Setting `__metatable` to make it untouchable was tried and
reverted: busted swaps `_G`'s metatable to implement `insulate` and `expose`,
so protecting it stops the test suite dead -- which is the same lesson from
the other side.

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
local installed                 -- the metatable we put on _G, to recognise it
local previous                  -- whatever was there before, to give back
local key                       -- what `off` has to present

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
---
--- Returns the KEY that `off` requires. `off` used to be callable by anyone
--- who could `require` this module -- which is every handler in the process --
--- so any one of them could turn strict mode off for the whole server and for
--- every other request in it. Turning it off now belongs to whoever turned it
--- on.
---
--- Refuses to install over somebody else's `_G` metatable rather than
--- replacing it. Two libraries arguing over the global table is a
--- configuration error, and silently winning it would break whatever the
--- other one was doing -- an ORM's lazy loader, a REPL's autocomplete --
--- somewhere far from here.
function M.on()
  if active then return key end

  local existing = getmetatable(_G)
  if existing ~= nil then
    error("akkar.strict: the global table already has a metatable, and " ..
          "replacing it would silently break whatever installed it. Turn " ..
          "that off, or leave strict mode off.", 2)
  end

  snapshot()
  active = true
  previous = existing
  key = {}

  installed = {
    -- Protected, so the check cannot be removed by a `setmetatable(_G, nil)`
    -- from anywhere in the process. `off` restores through `debug` because
    -- that is the only door left, and it is the one this module holds.
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
  }

  debug.setmetatable(_G, installed)
  return key
end

--- Takes the check back off, given the key `on` returned.
function M.off(given)
  if not active then return M end
  if given ~= key then
    error("akkar.strict: off() needs the key on() returned. Strict mode is " ..
          "process-wide, so switching it off from anywhere in the process " ..
          "switches it off for every request in it.", 2)
  end
  -- Only ours comes off. If something replaced it despite the protection,
  -- removing that would be the clobber this module refuses to do.
  if rawequal(debug.getmetatable(_G), installed) then
    debug.setmetatable(_G, previous)
  end
  installed, key, active = nil, nil, false
  return M
end

function M.active()
  return active
end

return M
