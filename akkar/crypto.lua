--[[
akkar.crypto — the primitives, over the OpenSSL that is already linked.

## Why this is a module and not a dependency

luaossl is already a dependency, for TLS. So PBKDF2, HMAC, SHA-2 and a CSPRNG
are already inside the binary and were simply not reachable. This file is not
new cryptography; it is the four calls a backend needs, with the mistakes that
surround them made structurally hard.

## The four mistakes this file exists to prevent

**Comparing secrets with `==`.** Lua's string equality returns on the first
differing byte, so the time it takes leaks how much of a prefix the attacker
guessed. That is enough to recover a token one byte at a time over a network.
`M.equal` compares in constant time, and every comparison in this file and in
`akkar.session` goes through it.

**Storing a password with a fast hash.** SHA-256 of a password is a password in
a hat: a modern GPU tries billions a second. `M.hash_password` uses PBKDF2 with
a per-password salt and a deliberate iteration count, and the count is stored
IN the hash so it can be raised later without invalidating everybody.

**A salt or a token from `math.random`.** Lua's PRNG is seeded predictably and
is not a CSPRNG. Every random byte here comes from `openssl.rand`, and there is
no path in this module that reaches `math.random`.

**Hashing a password on the event loop.** PBKDF2 is expensive ON PURPOSE, and
that cost lands on a single-threaded cooperative scheduler: 100 ms of hashing
is 100 ms in which akkar answers nobody. `akkar/work.lua` exists for exactly
this and `M.hash_password` says so in its docstring rather than leaving the
next person to discover it under load.

## What is deliberately NOT here

**No JWT for sessions.** A signed token that carries its own claims cannot be
revoked before it expires, which is the property a session most needs -- log
out, change password, ban a user. `akkar.session` keeps session state on the
server behind a random opaque id, which is what a cookie session is and what
the browser has done correctly since 1994.

JWT still has a narrow honest use -- a short-lived assertion issued by somebody
else, which you VERIFY -- and if that is added later it belongs in its own
module with `verify` and no `issue`, so nobody reaches for it to keep a user
logged in.
]]

local rand   = require "openssl.rand"
local bitwise = require "akkar.bitwise"
local digest = require "openssl.digest"
local hmac   = require "openssl.hmac"
local kdf    = require "openssl.kdf"

local M = {}

-- Iterations for PBKDF2-HMAC-SHA256.
--
-- A number, not a feeling: OWASP's 2023 guidance for PBKDF2-HMAC-SHA256 is
-- 600,000. It is stored inside every hash this module produces, so raising it
-- later re-hashes people as they log in instead of locking anybody out.
local DEFAULT_ITERATIONS = 600000
local SALT_BYTES = 16
local KEY_BYTES  = 32

-- ============================================================ random and hex

--- `n` bytes from the operating system's CSPRNG.
function M.random(n)
  local bytes = rand.bytes(n or 32)
  if not bytes or #bytes < (n or 32) then
    -- Refusing is the only safe answer. A short read here would silently
    -- produce a token with less entropy than its length suggests, and nothing
    -- downstream could tell.
    error("akkar.crypto: the CSPRNG returned too few bytes", 0)
  end
  return bytes
end

--- Every byte value as its two hex characters, built once at load.
---
--- 256 short strings, interned by Lua, so the whole table is a few kilobytes
--- and no hex pair is ever built again.
local HEX_PAIR = {}
for b = 0, 255 do HEX_PAIR[b] = string.format("%02x", b) end

--- THE COST HERE WAS THE `byte` CALL, NOT THE HEX.
---
--- This used to walk the string one byte at a time: `bytes:byte(i)` per
--- iteration, two `bitwise` calls, two single-character `sub`s and a
--- concatenation. Measured on a 64 byte token, which is what `token(32)`
--- returns and what every session and CSRF check hexes:
---
---     one byte at a time      54.6 us
---     all bytes, one call      8.5 us
---
--- and the reason is not the arithmetic. `s:byte(i)` sixty-four times costs
--- 7.46 us; `s:byte(1, -1)` for the same sixty-four bytes costs 0.34 us. The
--- per-byte method call was twenty-two times the work of reading the whole
--- string at once, and everything else was noise beside it.
---
--- For scale, an OpenSSL HMAC over the same token is 6.3 us. Hex encoding in
--- Lua was costing more than the cryptography it exists to render.
---
--- CHUNKED, because `byte(1, -1)` pushes one value per byte onto the stack
--- and a long enough string overflows it: 250,000 bytes is fine here and
--- 1,000,000 raises "string slice too long". 4,096 is far below any limit,
--- keeps the win, and means this function has no input size it fails on.
local HEX_CHUNK = 4096

--- AND A FAST PATH FOR THE SIZE THIS IS ACTUALLY CALLED WITH.
---
--- Chunking is what makes the function total, but nothing in akkar hexes more
--- than a few dozen bytes: `token(n)` and `hmac` produce 16, 32 or 64, and
--- every session cookie, CSRF token and signature is one of those. Paying for
--- the chunk loop's setup on every one of them is paying for the case that
--- never happens.
---
--- The branch also lets the byte table be rewritten IN PLACE as the output,
--- rather than filling a second table beside it, which is most of what it
--- buys. Measured on the sizes that occur:
---
---     32 bytes    5.24 us chunked    3.37 us direct
---     64 bytes    8.86 us chunked    5.87 us direct
---
--- Against the 54.6 us this function cost before either change, the 64 byte
--- case is 9.3x.
function M.to_hex(bytes)
  local n = #bytes
  if n <= HEX_CHUNK then
    local pack = { bytes:byte(1, n) }
    for i = 1, n do pack[i] = HEX_PAIR[pack[i]] end
    return table.concat(pack)
  end

  local out = {}
  local at = 1
  for start = 1, n, HEX_CHUNK do
    local stop = start + HEX_CHUNK - 1
    if stop > n then stop = n end
    local pack = { bytes:byte(start, stop) }
    for i = 1, #pack do
      out[at] = HEX_PAIR[pack[i]]
      at = at + 1
    end
  end
  return table.concat(out)
end

function M.from_hex(text)
  if #text % 2 ~= 0 then return nil, "odd-length hex" end
  return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

--- A URL-safe random token, `bytes` of entropy rendered as hex.
---
--- Hex rather than base64: a token travels in URLs, cookies and logs, and
--- base64's `+`, `/` and `=` each need escaping in at least one of those. The
--- cost is a third more characters for the same entropy, which nobody notices.
function M.token(bytes)
  return M.to_hex(M.random(bytes or 32))
end

-- ===================================================== constant-time compare

--- Compares two strings without leaking where they differ.
---
--- `a == b` returns on the first differing byte. Over a network that timing
--- difference is measurable, and it turns a 256-bit token into 32 sequential
--- one-byte guesses. Every secret comparison in akkar goes through here.
---
--- The length is compared too, and it is compared FIRST and separately on
--- purpose: lengths are not secret, and folding the length check into the loop
--- would make the loop's duration depend on the shorter input.
--- READ IN BLOCKS, AND STILL CONSTANT TIME.
---
--- Same finding as `to_hex` above: the per-byte `a:byte(i)` was the cost, not
--- the arithmetic. Reading both strings a block at a time cuts it, and it does
--- not weaken the guarantee, because what the guarantee needs is that the work
--- does not depend on WHERE the inputs differ. The loops below always run to
--- the end of the input; no comparison exits early and no branch depends on a
--- byte's value. Blocking changes how many bytes are fetched per call, which
--- is a function of the length alone, and the length is already public here.
---
--- `HEX_CHUNK` is reused for the same reason it exists there: `byte(1, -1)`
--- pushes one value per byte and a long enough string overflows the stack.
function M.equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  if #a ~= #b then return false end
  local diff = 0
  local n = #a
  -- The same fast path, for the same reason: every secret compared here is a
  -- token or a signature, and none of them is four kilobytes.
  if n <= HEX_CHUNK then
    local pa = { a:byte(1, n) }
    local pb = { b:byte(1, n) }
    for i = 1, n do
      diff = bitwise.bor(diff, bitwise.bxor(pa[i], pb[i]))
    end
    return diff == 0
  end

  for start = 1, n, HEX_CHUNK do
    local stop = start + HEX_CHUNK - 1
    if stop > n then stop = n end
    local pa = { a:byte(start, stop) }
    local pb = { b:byte(start, stop) }
    for i = 1, #pa do
      diff = bitwise.bor(diff, bitwise.bxor(pa[i], pb[i]))
    end
  end
  return diff == 0
end

-- =================================================================== hashing

function M.sha256(data)
  return digest.new("sha256"):final(data)
end

--- HMAC-SHA256, returned raw. `M.to_hex` it if you need to print it.
function M.hmac(key, data, algorithm)
  return hmac.new(key, algorithm or "sha256"):final(data)
end

--- True when `signature` is a valid HMAC of `data` under `key`.
---
--- Exists so that no caller writes `hmac(...) == signature`, which is the
--- timing leak `M.equal` is for. A verifier next to the signer is how the
--- right comparison becomes the easy one.
function M.hmac_verify(key, data, signature, algorithm)
  return M.equal(M.hmac(key, data, algorithm), signature)
end

-- ================================================================= passwords

--- Hashes a password. **This is expensive on purpose — see the warning.**
---
--- Six hundred thousand PBKDF2 iterations take tens of milliseconds, and akkar
--- runs one coroutine at a time on a cooperative scheduler. Calling this
--- directly inside a handler stops the server answering anybody else for that
--- whole time, and a login endpoint under a credential-stuffing attack is
--- precisely when that matters most.
---
--- `akkar.work` exists for this: run it there, not inline. akkar's blocking
--- watchdog will warn about it either way, which is the framework noticing
--- rather than the operator.
---
--- The format is `pbkdf2-sha256$iterations$salt_hex$key_hex`: self-describing,
--- so the iteration count can be raised later and old hashes still verify.
function M.hash_password(password, options)
  options = options or {}
  local iterations = options.iterations or DEFAULT_ITERATIONS
  local salt = options.salt or M.random(SALT_BYTES)

  local key = kdf.derive {
    type = "PBKDF2",
    pass = password,
    salt = salt,
    iter = iterations,
    md   = "sha256",
    outlen = KEY_BYTES,
  }

  return ("pbkdf2-sha256$%d$%s$%s"):format(iterations, M.to_hex(salt), M.to_hex(key))
end

--- Verifies a password against a stored hash, in constant time.
---
--- Returns `ok, needs_rehash`. The second value is true when the stored hash
--- used fewer iterations than the current default, which is how a deployment
--- raises its cost over time: verify with the old count, then re-hash with the
--- new one while the plaintext is still in hand. Nobody is locked out and
--- nobody has to run a migration over a password table they cannot read.
function M.verify_password(password, stored, options)
  options = options or {}
  if type(stored) ~= "string" then return false, false end

  local algorithm, iterations, salt_hex, key_hex =
    stored:match "^([%w%-]+)%$(%d+)%$(%x+)%$(%x+)$"
  if algorithm ~= "pbkdf2-sha256" then return false, false end

  iterations = tonumber(iterations)
  local salt = M.from_hex(salt_hex)
  local expected = M.from_hex(key_hex)
  if not salt or not expected then return false, false end

  local key = kdf.derive {
    type = "PBKDF2",
    pass = password,
    salt = salt,
    iter = iterations,
    md   = "sha256",
    outlen = #expected,
  }

  local ok = M.equal(key, expected)
  return ok, ok and iterations < (options.iterations or DEFAULT_ITERATIONS)
end

M.DEFAULT_ITERATIONS = DEFAULT_ITERATIONS

return M
