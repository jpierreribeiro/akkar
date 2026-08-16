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

local HEX = "0123456789abcdef"

function M.to_hex(bytes)
  local out = {}
  for i = 1, #bytes do
    local b = bytes:byte(i)
    out[i] = HEX:sub((b >> 4) + 1, (b >> 4) + 1) .. HEX:sub((b & 15) + 1, (b & 15) + 1)
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
function M.equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  if #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do
    diff = diff | (a:byte(i) ~ b:byte(i))
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
