--[[
String work whose cost must not grow with attacker-controlled input.

WHY THIS EXISTS. `^%s*(.-)%s*$` is the obvious Lua trim and it appeared in
seven places in this project. The lazy `(.-)` with an anchored `%s*$` makes
Lua's matcher advance one character at a time and re-try the tail from every
position, so the cost tracks the STRING'S LENGTH rather than the amount of
whitespace there is to remove:

    input                    ^%s*(.-)%s*$      this module
    20 bytes, padded            1,906 ns          1,600 ns
    100 bytes, padded           5,561             1,695
    1 KB, padded               54,349             1,763
    10 KB, padded             519,883             2,144      242x
    10 KB, nothing to trim    514,868               395    1300x

**Every caller trims something a client sent**: hops in `X-Forwarded-For`,
entity tags in `If-None-Match`, the `Range` header, field names in
`Accept-Encoding`, and the body of an S3 error response. A client that sends
ten kilobytes in one header therefore turned an 83 µs request into a 600 µs
one -- six times the cost of the whole request, from one header, with no
error and no log line.

That is not a dramatic vulnerability and it is not nothing: it is free
amplification, gated only on a proxy that does not cap header size. The fix
costs less than the thing it replaces at EVERY size, so there is no trade to
weigh.

FOUND BY LOOKING FOR THE SHAPE rather than by reading the code. The header
parse in `akkar/vendor/http/h1_connection.lua` had the same defect and was
found by accident, so every string operation on a request path was measured
against SIZE and anything whose cost per byte did not stay flat was suspect.
JSON encoding and decoding came back clean; this did not.

EQUIVALENCE IS THE CLAIM, and `spec/text_spec.lua` is where it is kept: the
pattern this replaces is held there as the reference and the two are compared
on hand-written shapes and 200,000 random strings drawn from an alphabet
weighted towards whitespace. `%s` in Lua is [ \t\n\v\f\r] -- six characters,
not two -- and a trim that handles fewer is not faster, it is wrong.
]]

local M = {}

--- The six bytes Lua's `%s` matches, as a lookup rather than a comparison
--- chain. Built once at load.
local WHITESPACE = {}
for _, byte in ipairs { 32, 9, 10, 11, 12, 13 } do WHITESPACE[byte] = true end

--- `s` without leading or trailing whitespace.
---
--- Exactly `s:match "^%s*(.-)%s*$"`, at a cost bounded by the whitespace
--- rather than by the length. Returns `s` itself when there is nothing to
--- remove, so the common case allocates nothing at all.
function M.trim(s)
  local n = #s
  if n == 0 then return s end

  local first = 1
  while first <= n and WHITESPACE[s:byte(first)] do first = first + 1 end
  -- All whitespace. The pattern this replaces answers "" here, via an empty
  -- lazy capture.
  if first > n then return "" end

  local last = n
  while WHITESPACE[s:byte(last)] do last = last - 1 end

  if first == 1 and last == n then return s end
  return s:sub(first, last)
end

return M
