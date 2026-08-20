-- What hex encoding costs, old against new, in one process and interleaved.
--
-- WHY THIS FILE EXISTS. `akkar.crypto.to_hex` renders every session cookie,
-- every CSRF token and every signature akkar produces. It was written one byte
-- at a time, and one byte at a time in Lua is not what it looks like:
--
--     s:byte(i), sixty-four times        7.46 us
--     s:byte(1, -1), same sixty-four     0.34 us
--
-- Twenty-two to one, and the hex arithmetic beside it was noise. For scale, an
-- OpenSSL HMAC over the same token costs about 6 us: hex encoding in Lua was
-- costing more than the cryptography it exists to render.
--
-- MEASURED THIS WAY BECAUSE THE OTHER WAY LIED. Timing the old version, then
-- the new one, gave answers that moved 30% to 50% between runs on a developer
-- laptop, and a first attempt at a related measurement reported an 18.8%
-- difference in a constant-time function that interleaving showed to be 2.4%
-- against a 30% floor. Arms in one process, interleaved inside every round,
-- minimum kept, spread reported as the floor a difference has to clear.
package.path = "./?.lua;./?/init.lua;" .. package.path

local crypto = require "akkar.crypto"

local N = tonumber(os.getenv "N") or 100000
local ROUNDS = tonumber(os.getenv "ROUNDS") or 9

local HEX = "0123456789abcdef"
local bitwise = require "akkar.bitwise"

--- Exactly what shipped before 2026-08-20, kept so the comparison is against
--- the code and not against a memory of it.
local function to_hex_before(bytes)
  local out = {}
  for i = 1, #bytes do
    local b = bytes:byte(i)
    local hi, lo = bitwise.rshift(b, 4), bitwise.band(b, 15)
    out[i] = HEX:sub(hi + 1, hi + 1) .. HEX:sub(lo + 1, lo + 1)
  end
  return table.concat(out)
end

local SIZES = { 16, 32, 64, 1024 }

print(("%d iterations, %d interleaved rounds\n"):format(N, ROUNDS))
print("  bytes        before        after     ratio    floor")

for _, size in ipairs(SIZES) do
  local input = crypto.random(size)
  assert(to_hex_before(input) == crypto.to_hex(input), "the two disagree")

  local arms = { before = to_hex_before, after = crypto.to_hex }
  local samples = { before = {}, after = {} }
  local iterations = size > 256 and (N // 10) or N

  for _ = 1, ROUNDS do
    for name, fn in pairs(arms) do
      fn(input)
      local t0 = os.clock()
      for _ = 1, iterations do fn(input) end
      samples[name][#samples[name] + 1] = (os.clock() - t0) / iterations * 1e6
    end
  end

  local best, floor = {}, 0
  for name, list in pairs(samples) do
    table.sort(list)
    best[name] = list[1]
    floor = math.max(floor, list[#list] - list[1])
  end

  print(("  %5d   %8.3f us   %8.3f us   %6.2fx   %5.2f us")
    :format(size, best.before, best.after, best.before / best.after, floor))
end

print()
print("A ratio is only a result where the gap clears the floor beside it.")
