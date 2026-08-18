--[[
`akkar.bitwise`, which exists so nine files can parse under LuaJIT.

These check the CONTRACT rather than the implementation, because the two
implementations are genuinely different -- Lua 5.3+ operators compiled from a
string, or LuaJIT's `bit` library with its signed 32-bit results normalised.
A test that only ran the branch this interpreter takes would say nothing about
the other one, so every case states a value that both must produce.

The values are taken from what akkar actually does with these: masking a
request-id counter, decoding OpenSSL's packed version, base64url, a content
hash, a CIDR comparison and a constant-time compare.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local bitwise = require "akkar.bitwise"

describe("akkar.bitwise", function()
  it("says which implementation it is", function()
    -- Not decoration: a run that silently took the wrong branch would pass
    -- every case below and prove nothing about the other interpreter.
    assert.is_boolean(bitwise.NATIVE)
  end)

  it("masks, which is what the request id does every request", function()
    -- `execution.lua` keeps a counter and masks it to 24 bits.
    assert.equal(0xffffff, bitwise.band(0xffffffff, 0xffffff))
    assert.equal(0x000001, bitwise.band(0x1000001, 0xffffff))
    assert.equal(0, bitwise.band(0xff000000, 0xffffff))
  end)

  it("shifts right, which is how doctor reads OpenSSL's version", function()
    -- `(raw >> 28) & 0xFF` and friends, against a real packed version.
    local raw = 0x30000090          -- OpenSSL 3.0.0, patch 9
    assert.equal(3, bitwise.band(bitwise.rshift(raw, 28), 0xFF))
    assert.equal(0, bitwise.band(bitwise.rshift(raw, 20), 0xFF))
  end)

  it("shifts left and ors, which is base64url in jwt.lua", function()
    -- `(bits << 6) | value`, the accumulator loop.
    local bits = 0
    for _, value in ipairs { 0x1a, 0x2b, 0x3c, 0x0d } do
      bits = bitwise.bor(bitwise.lshift(bits, 6), value)
    end
    assert.equal(0x6ABF0D, bits)
    -- and the byte extraction that follows it
    assert.equal(0xBF, bitwise.band(bitwise.rshift(bits, 8), 0xff))
  end)

  it("xors, which is the etag hash and the constant-time compare", function()
    assert.equal(0, bitwise.bxor(0xdeadbeef, 0xdeadbeef))
    assert.equal(0xff, bitwise.bxor(0x0f, 0xf0))
    -- `crypto.lua` ors the xor of every byte pair and checks for zero.
    local diff = 0
    for i = 1, 4 do
      diff = bitwise.bor(diff, bitwise.bxor(("abcd"):byte(i), ("abcd"):byte(i)))
    end
    assert.equal(0, diff)
    diff = bitwise.bor(diff, bitwise.bxor(("a"):byte(1), ("b"):byte(1)))
    assert.is_true(diff ~= 0)
  end)

  it("never answers negative, whatever the top bit is", function()
    -- THE ONE THAT WOULD BREAK LUAJIT SILENTLY. `bit` returns SIGNED 32-bit
    -- results, so `bit.band(0xffffffff, 0xffffffff)` is -1 there and 4294967295
    -- on 5.4. A negative request id, a negative version field or a negative
    -- CIDR mask would all be wrong in ways that look like data rather than
    -- like a bug.
    assert.equal(0xffffffff, bitwise.band(0xffffffff, 0xffffffff))
    assert.equal(0xffffffff, bitwise.bor(0xf0f0f0f0, 0x0f0f0f0f))
    assert.equal(0xffffffff, bitwise.bxor(0x00000000, 0xffffffff))
    assert.equal(0x80000000, bitwise.lshift(1, 31))
    assert.is_true(bitwise.band(0xffffffff, 0xffffffff) > 0)
  end)

  it("builds a CIDR mask, which is init.lua's trusted-proxy check", function()
    -- `(0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF`
    local function mask(bits)
      return bitwise.band(bitwise.lshift(0xFFFFFFFF, 32 - bits), 0xFFFFFFFF)
    end
    assert.equal(0xFFFFFF00, mask(24))
    assert.equal(0xFFFF0000, mask(16))
    assert.equal(0xFFFFFFFF, mask(32))
  end)

  it("divides towards zero for the values akkar divides", function()
    -- All non-negative and far below 2^53, which is the whole domain: a
    -- typo-distance and a civil-from-days date.
    assert.equal(3, bitwise.idiv(10, 3))
    assert.equal(0, bitwise.idiv(2, 3))
    assert.equal(5, bitwise.idiv(15, 3))
    assert.equal(2020, bitwise.idiv(808000, 400))
  end)
end)
