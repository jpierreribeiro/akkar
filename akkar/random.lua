--[[
akkar.random — the generator the framework reads, so a run can be replayed.

## THIS IS NOT FOR SECRETS. NOTHING HERE IS UNPREDICTABLE.

`akkar/crypto.lua` opens with the reason and it applies with more force to a
module whose whole purpose is to be reproducible: **a salt or a token from
`math.random` is a defect**, Lua's generator is seeded predictably, and a
seeded one is predictable BY CONSTRUCTION. `akkar.crypto.random_bytes` reads
the OS entropy source and is the only correct answer for a session id, a CSRF
token, a password salt or a trace id -- `akkar/trace.lua:144` says so about
trace ids specifically, and it says it because somebody will otherwise reach
for the nearest generator.

The rule this module needs, stated once: if being able to GUESS the value
matters, this is the wrong module. If it only has to be spread out, it is the
right one.

## Why it exists

For the same reason `akkar.time` exists, and the argument is that file's
argument. The framework used `math.random` directly in two places -- the retry
backoff's jitter and the request id's per-process prefix -- and a direct call
is a call nothing can substitute. A run that cannot be replayed cannot be
debugged from a seed, and the deterministic simulation this is the first piece
of is the only way akkar's four invariants stop being declared and start being
checked by machine under injected failure.

## What a seeded generator does, and what it does NOT do

It makes the framework's own choices repeat: the same seed gives the same
jitter and the same id prefix.

It does **not** make a run deterministic on its own. Scheduling order, socket
readiness and the wall clock are all still real, and each is its own piece of
the same project -- `akkar.time` was the clock's. Saying otherwise here would
promise a replay that does not exist yet.
]]

-- Through `akkar.bitwise` and not with `~`, `<<`, `>>` written out, because
-- those are SYNTAX errors under LuaJIT -- the file would not load far enough
-- to report a missing function. That is the whole reason `akkar/bitwise.lua`
-- exists, and writing them here would have reintroduced the defect it fixed,
-- in the newest file in the tree.
local bitwise = require "akkar.bitwise"

local M = {}

--- The real one: Lua's own generator, which 5.4 seeds from the OS at startup.
---
--- Wrapped rather than aliased so a caller cannot hold a reference that
--- outlives a `set`, which is how the clock's seam was got wrong first.
local real = {
  --- A float in [0, 1).
  float = function() return math.random() end,
  --- An integer in [m, n].
  integer = function(m, n) return math.random(m, n) end,
}

M.real = real

local current = real

function M.float() return current.float() end
function M.integer(m, n) return current.integer(m, n) end

--- Installs a generator, and returns the function that puts the previous one
--- back.
---
--- Process-wide, exactly like `akkar.time.set`, and with the same limitation
--- written down there: two tests running concurrently against different
--- generators would see each other. The restore function is what keeps the
--- suite honest about it.
function M.set(source)
  local previous = current
  current = source or real
  return function() current = previous end
end

--- A generator that produces the same sequence for the same seed.
---
--- xorshift32 rather than `math.randomseed`, and the reason is portability of
--- the SEQUENCE and not of the algorithm. `math.randomseed(n)` seeds an
--- implementation the standard does not pin: Lua 5.4 uses xoshiro256**, LuaJIT
--- uses its own, and 5.5 is free to change again. A replay that only works on
--- the interpreter that recorded it is not a replay, and this project already
--- supports two interpreters and measures a third.
---
--- Thirty-two bits is deliberate and sufficient: this seeds jitter and an id
--- prefix, not a cipher. Anything that needs more than that needs
--- `akkar.crypto` instead, for the reason at the top of this file.
function M.seeded(seed)
  local state = seed % 0x100000000
  if state == 0 then state = 0x9e3779b9 end   -- xorshift is stuck at zero

  local source = {}

  local band, bxor = bitwise.band, bitwise.bxor
  local lshift, rshift = bitwise.lshift, bitwise.rshift

  local function next_word()
    -- The classic xorshift32 triple. Masked at each step because a Lua 5.4
    -- integer is 64 bits and the shifts would otherwise carry past 32.
    state = bxor(state, band(lshift(state, 13), 0xffffffff))
    state = bxor(state, rshift(state, 17))
    state = bxor(state, band(lshift(state, 5), 0xffffffff))
    state = band(state, 0xffffffff)
    return state
  end

  function source.float()
    return next_word() / 0x100000000
  end

  function source.integer(m, n)
    if n == nil then m, n = 1, m end
    -- Modulo rather than rejection sampling: the bias is one part in 2^32
    -- over the ranges this is asked for, and a rejection loop would make the
    -- sequence depend on how many draws were discarded -- which is exactly
    -- the kind of thing that makes a replay stop replaying when an unrelated
    -- range changes.
    return m + (next_word() % (n - m + 1))
  end

  --- The seed it was made with, so a failing run can print what to pass back.
  source.seed = seed

  return source
end

return M
