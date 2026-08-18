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
debugged from a seed.

## The algorithm, and why this one

**xoshiro128++ 1.0**, by David Blackman and Sebastiano Vigna, from the
reference implementation at <https://prng.di.unimi.it/xoshiro128plusplus.c>
(public domain). Their own description: a 32-bit all-purpose generator with a
128-bit state that "passes all tests that are known".

Three constraints picked it, and each ruled something out.

**It must produce the same sequence on Lua 5.4, Lua 5.5 and LuaJIT.**
`math.randomseed(n)` cannot: it seeds an implementation the standard does not
pin -- 5.4 uses xoshiro256**, LuaJIT its own, 5.5 free to change again. A
replay that only works on the interpreter that recorded it is not a replay,
and this project supports two interpreters and measures a third.

**It must not multiply in the hot path.** On LuaJIT a Lua number is a double
and the `bit` library has no multiply, so a 32x32 product loses precision past
2^53. xoshiro128++ is built from rotate, xor, shift and add ALONE -- which is
why it was chosen over xoshiro128** and over any PCG, both of which multiply.
Multiplication appears exactly once here, in seeding, where a 16-bit split
keeps it exact and it runs once per generator.

**It must not be a rock.** Two exist and both were looked at. `lrandom` is C
and Mersenne Twister -- a C dependency, for jitter. `randomlua` is pure Lua
and MIT and would have been the obvious answer, except that it simulates the
bitwise operators by ITERATING THIRTY-TWO TIMES with modulo and division,
because it targets Lua 5.1. akkar has `akkar.bitwise`, which is native
operators on 5.3+ and the `bit` library on LuaJIT; paying thirty-two
iterations to avoid a dependency the tree already carries is the worst of
both.

And the generator this file shipped with for one commit was a hand-written
xorshift32, which is worse than any of them: every xorshift fails BigCrush,
and its LOW BITS are the weak ones -- while `integer` reads exactly those
through `%`. It was replaced rather than patched.

## What a seeded generator does, and what it does NOT do

It makes the framework's own choices repeat: the same seed gives the same
jitter and the same id prefix.

It does **not** make a run deterministic on its own. Scheduling order, socket
readiness and the wall clock are all still real, and each is its own piece of
the same project -- `akkar.time` was the clock's.
]]

-- Through `akkar.bitwise` and not with `~`, `<<`, `>>` written out, because
-- those are SYNTAX errors under LuaJIT -- the file would not load far enough
-- to report a missing function. That is the whole reason `akkar/bitwise.lua`
-- exists, and writing them here would reintroduce the defect it fixed.
local bitwise = require "akkar.bitwise"

local band, bor, bxor = bitwise.band, bitwise.bor, bitwise.bxor
local lshift, rshift = bitwise.lshift, bitwise.rshift

local MASK = 0xffffffff

local M = {}

--- The real one: Lua's own generator, which 5.4 seeds from the OS at startup.
---
--- Wrapped rather than aliased so a caller cannot hold a reference that
--- outlives a `set`.
local real = {
  float = function() return math.random() end,
  integer = function(m, n) return math.random(m, n) end,
}

M.real = real

local current = real

function M.float() return current.float() end
function M.integer(m, n) return current.integer(m, n) end

--- Installs a generator, and returns the function that puts the previous one
--- back.
---
--- Process-wide, exactly like `akkar.time.set`, and with a limitation this
--- project has already been bitten by: `spec/properties_spec.lua` records that
--- seeding the global generator "made three later files deterministic and
--- broke their key isolation". A spec wanting a sequence should hold a
--- `seeded` object rather than install one.
function M.set(source)
  local previous = current
  current = source or real
  return function() current = previous end
end

--- 32-bit multiply, exact on every interpreter this runs on.
---
--- Split into 16-bit halves because a full 32x32 product reaches 2^64, and on
--- LuaJIT a Lua number is a double: past 2^53 the low bits are simply gone.
--- Each partial product here is at most 65535^2, which a double holds exactly.
---
--- Used ONLY for seeding. The generator itself never multiplies, which is the
--- property that let it be chosen.
local function mul32(a, b)
  local ah, al = math.floor(a / 65536) % 65536, a % 65536
  local bh, bl = math.floor(b / 65536) % 65536, b % 65536
  return ((((ah * bl + al * bh) % 65536) * 65536) + al * bl) % 4294967296
end

--- Rotate left, 32-bit.
local function rotl(x, k)
  return band(bor(lshift(x, k), rshift(x, 32 - k)), MASK)
end

--- Expands one scalar seed into four non-zero state words.
---
--- SplitMix-style: a counter through an avalanche, so seeds 1 and 2 give
--- unrelated states rather than adjacent ones. Seeding a xoshiro badly is a
--- documented way to get correlated streams from nearby seeds, which for a
--- replay harness would mean two "different" runs exploring the same thing.
local function expand(seed)
  local z = seed % 4294967296
  local words = {}
  for i = 1, 4 do
    z = (z + 0x9e3779b9) % 4294967296          -- the golden-ratio increment
    local x = z
    x = mul32(bxor(x, rshift(x, 16)), 0x21f0aaad)
    x = mul32(bxor(x, rshift(x, 15)), 0x735a2d97)
    x = bxor(x, rshift(x, 15))
    words[i] = band(x, MASK)
  end
  -- xoshiro is stuck for ever on an all-zero state, and `expand` can produce
  -- one only if every word came out zero -- but "only if" is not "cannot".
  if words[1] == 0 and words[2] == 0 and words[3] == 0 and words[4] == 0 then
    words[1] = 0x9e3779b9
  end
  return words
end

--- A generator that produces the same sequence for the same seed.
function M.seeded(seed)
  local s = expand(seed)
  local s0, s1, s2, s3 = s[1], s[2], s[3], s[4]

  --- xoshiro128++ `next()`, verbatim from the reference:
  ---
  ---     result = rotl(s[0] + s[3], 7) + s[0]
  ---     t = s[1] << 9
  ---     s[2] ^= s[0]; s[3] ^= s[1]; s[1] ^= s[2]; s[0] ^= s[3]
  ---     s[2] ^= t
  ---     s[3] = rotl(s[3], 11)
  local function next_word()
    local result = band(rotl(band(s0 + s3, MASK), 7) + s0, MASK)

    local t = band(lshift(s1, 9), MASK)

    s2 = bxor(s2, s0)
    s3 = bxor(s3, s1)
    s1 = bxor(s1, s2)
    s0 = bxor(s0, s3)

    s2 = bxor(s2, t)

    s3 = rotl(s3, 11)

    return result
  end

  local source = { seed = seed }

  --- A float in [0, 1).
  function source.float()
    return next_word() / 4294967296
  end

  --- An integer in [m, n], or in [1, m] when called with one argument.
  ---
  --- Plain modulo, and the bias is stated rather than hidden: it is at most
  --- one part in 2^32 over any range this is asked for. Rejection sampling
  --- would remove it and would make the sequence depend on how many draws
  --- were discarded -- so changing an unrelated range would change every
  --- later draw, and a recorded seed would stop replaying. For jitter and an
  --- id prefix that trade is the wrong way round.
  ---
  --- Reading the low bits is safe HERE and would not have been before: the
  --- `++` scrambler is what makes xoshiro128's low bits as good as its high
  --- ones, which is exactly what a plain xorshift does not have.
  function source.integer(m, n)
    if n == nil then m, n = 1, m end
    return m + (next_word() % (n - m + 1))
  end

  return source
end

return M
