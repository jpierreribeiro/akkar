--[[
Bitwise operations and integer division, spelled so that every Lua akkar
targets can parse the file that uses them.

WHY THIS EXISTS. LuaJIT 2.1 is Lua 5.1: `&`, `|`, `~`, `<<`, `>>` and `//` are
**syntax errors** there, not missing functions. Nine of akkar's fifty-nine
files did not compile under it for that reason alone, and a syntax error is
the harder kind of incompatibility -- the file never loads far enough to
install a shim.

`docs/substrate/LUAJIT.md` has the inventory and the go/no-go: cqueues builds
and runs under LuaJIT, and the vendored HTTP parses clean, so the blockers are
entirely akkar's own.

WHAT IT COSTS THE TARGET WE ACTUALLY SHIP TO, because that is the real
objection. Every call here is a function call where Lua 5.4 could have used an
operator. Measured, 5,000,000 iterations:

    a & b, native operator            34.0 ns
    tbl.band(a, b), table lookup      56.0 ns
    band(a, b), local alias           53.5 ns
    operator compiled from a string   52.6 ns

There is no clever shape: the call dominates, and compiling the operator from
a string -- which keeps the token out of the source -- buys nothing over a
plain function. So the tax is about 19 ns per operation, unavoidable.

AND IT IS AFFORDABLE, which is the point of measuring it. Only two of akkar's
fourteen bitwise sites run on a normal request: the request-id mask and, when
tracing, the sampled flag. That is roughly 38 ns against a request that takes
85,000 ns of CPU -- **0.04%**, two orders of magnitude below this project's
1.16% noise floor. The rest run per boot, per token or per configured route.

THE IMPLEMENTATION IS COMPILED, NOT WRITTEN. On 5.3 and later the operators
are `load`ed from a string, so this file contains no forbidden token and
parses everywhere, while the resulting function is a real operator rather than
an emulation. On LuaJIT the `load` fails and the `bit` library takes over.

`~` IS TWO DIFFERENT OPERATORS in Lua 5.3+: binary XOR and unary NOT. Only
XOR is provided, because that is all akkar uses, and a `bnot` nobody calls is
a `bnot` nobody has tested.
]]

local M = {}

--- The operators, compiled at load on 5.3+, or nil where the syntax is not
--- understood.
---
--- `load` returns nil plus a message rather than raising, so the failure on
--- LuaJIT is an ordinary branch and not a pcall.
local native = load([[
  return {
    band   = function(a, b) return a & b end,
    bor    = function(a, b) return a | b end,
    bxor   = function(a, b) return a ~ b end,
    lshift = function(a, b) return a << b end,
    rshift = function(a, b) return a >> b end,
    idiv   = function(a, b) return a // b end,
  }
]])

if native then
  local ops = native()
  M.band, M.bor, M.bxor = ops.band, ops.bor, ops.bxor
  M.lshift, M.rshift, M.idiv = ops.lshift, ops.rshift, ops.idiv
  M.NATIVE = true
else
  -- LuaJIT. `bit` is built in there and its functions are JIT-compiled
  -- intrinsics, so this branch is not the slow one -- it is the only one.
  local bit = require "bit"
  M.band, M.bor, M.bxor = bit.band, bit.bor, bit.bxor
  M.lshift, M.rshift = bit.lshift, bit.rshift
  M.NATIVE = false

  -- `bit` returns SIGNED 32-bit results, and akkar's callers want unsigned:
  -- a mask of `0xffffff` against a counter, an OpenSSL version field, a
  -- base64 accumulator. Normalising here rather than at each call site,
  -- because a caller that forgets is a caller with a negative request id.
  local band, bor, bxor, lshift, rshift =
    bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift
  local function unsigned(n) return n < 0 and n + 4294967296 or n end
  M.band   = function(a, b) return unsigned(band(a, b)) end
  M.bor    = function(a, b) return unsigned(bor(a, b)) end
  M.bxor   = function(a, b) return unsigned(bxor(a, b)) end
  M.lshift = function(a, b) return unsigned(lshift(a, b)) end
  M.rshift = function(a, b) return unsigned(rshift(a, b)) end

  -- No `//`. `math.floor(a / b)` agrees with it for the values akkar divides
  -- -- all non-negative, all far below 2^53 -- and differs only in returning
  -- a float where 5.3+ returns an integer, which matters to `math.type` and
  -- LuaJIT has no `math.type`.
  M.idiv = function(a, b) return math.floor(a / b) end
end

return M
