# akkar.crypto

The four cryptographic primitives a backend needs, over the OpenSSL that akkar
already links for TLS: a CSPRNG, SHA-256, HMAC-SHA2 and PBKDF2. Nothing here is
new cryptography.

**When you need it.** Storing a password, comparing a secret with something a
caller sent, generating an API key or a session id, or signing a value you will
check again later.

```lua no-run
local crypto = require "akkar.crypto"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`crypto.DEFAULT_ITERATIONS`](#cryptodefault_iterations) | number |
| [`crypto.equal`](#cryptoequala-b) | function |
| [`crypto.from_hex`](#cryptofrom_hextext) | function |
| [`crypto.hash_password`](#cryptohash_passwordpassword-options) | function |
| [`crypto.hmac`](#cryptohmackey-data-algorithm) | function |
| [`crypto.hmac_verify`](#cryptohmac_verifykey-data-signature-algorithm) | function |
| [`crypto.random`](#cryptorandomn) | function |
| [`crypto.sha256`](#cryptosha256data) | function |
| [`crypto.to_hex`](#cryptoto_hexbytes) | function |
| [`crypto.token`](#cryptotokenbytes) | function |
| [`crypto.verify_password`](#cryptoverify_passwordpassword-stored-options) | function |

## crypto.DEFAULT_ITERATIONS

The PBKDF2 iteration count `hash_password` uses when the caller names none, and
the count `verify_password` compares a stored hash against to decide
`needs_rehash`. It is `600000`, which is OWASP's 2023 guidance for
PBKDF2-HMAC-SHA256.

**Returns** a number.

```lua
local crypto = require "akkar.crypto"
print(crypto.DEFAULT_ITERATIONS)
```

## crypto.equal(a, b)

Compares two strings without leaking where they differ. The length is compared
first and separately, then every remaining byte is XORed into an accumulator, so
the loop always runs to the end of the input.

Two inputs of different lengths return `false` immediately, and so do two inputs
that are not both strings. Lengths are not treated as secret.

**Returns** `true` or `false`.

```lua
local crypto = require "akkar.crypto"

print(crypto.equal("token", "token"))     --> true
print(crypto.equal("token", "tokeo"))     --> false
print(crypto.equal("token", "tok"))       --> false
print(crypto.equal(nil, "token"))         --> false
```

## crypto.from_hex(text)

Turns a hex string back into bytes. The inverse of `to_hex`.

Only the length is validated. `from_hex` checks that the input has an even
number of characters and then substitutes every pair of hex digits it finds;
characters outside `0-9a-fA-F` are left in the output unchanged rather than
rejected. Validate the alphabet yourself if the input came from a caller.

**Returns** the decoded string, or `nil` and `"odd-length hex"`.

```lua
local crypto = require "akkar.crypto"

print(crypto.from_hex "616b6b6172")        --> akkar
print(crypto.from_hex "abc")               --> nil    odd-length hex
print(crypto.from_hex "zzzz")              --> zzzz   (not rejected)
```

## crypto.hash_password(password, options)

Hashes a password with PBKDF2-HMAC-SHA256 and a per-password salt. **It is slow
on purpose**, and akkar runs one coroutine at a time, so a call at the default
iteration count stops the process answering anybody for the duration. Run it
through `akkar.work`, not inline in a handler.

| field | type | default | meaning |
|---|---|---|---|
| `options.iterations` | number | `crypto.DEFAULT_ITERATIONS` (600000) | PBKDF2 iteration count, stored inside the result |
| `options.salt` | string | 16 bytes from `crypto.random` | the salt, when you need a fixed one for a test |

**Returns** a string in the self-describing format
`pbkdf2-sha256$iterations$salt_hex$key_hex`. The key is 32 bytes. Because the
count is inside the string, raising it later does not invalidate old hashes.

**Raises** when OpenSSL rejects the derivation, which is what
`options.iterations = 0` does: `integer value out of range`. The lowest legal
count is 1.

```lua
local crypto = require "akkar.crypto"

-- iterations = 1 keeps this example fast. Production uses the default, and
-- the default is the whole defence.
local stored = crypto.hash_password("correct horse battery staple",
                                    { iterations = 1 })
print(stored)

print(crypto.verify_password("correct horse battery staple", stored))
print(crypto.verify_password("hunter2", stored))
```

## crypto.hmac(key, data, algorithm)

HMAC of `data` under `key`, returned as raw bytes. `to_hex` it before putting it
in a header, a cookie or a log.

| argument | type | default | meaning |
|---|---|---|---|
| `key` | string | required | the secret |
| `data` | string | required | the message |
| `algorithm` | string | `"sha256"` | any digest name OpenSSL knows: `sha256`, `sha384`, `sha512` |

**Returns** the raw MAC: 32 bytes for sha256, 48 for sha384, 64 for sha512.

**Raises** `bad argument #2 to 'new' (<name>: invalid digest type)` when the
algorithm is not one OpenSSL has.

```lua
local crypto = require "akkar.crypto"

local mac = crypto.hmac("a secret key", "the message")
print(#mac)                        --> 32
print(crypto.to_hex(mac):sub(1, 16))
```

## crypto.hmac_verify(key, data, signature, algorithm)

Recomputes the HMAC of `data` and compares it with `signature` through
`crypto.equal`. It exists so no caller writes `hmac(...) == signature`, which is
the timing leak `equal` is for.

`signature` is the raw MAC, not hex. Hex-encode both sides yourself if that is
what you are holding.

**Returns** `true` or `false`.

```lua
local crypto = require "akkar.crypto"

local key = "a secret key"
local mac = crypto.hmac(key, "transfer 100")

print(crypto.hmac_verify(key, "transfer 100", mac))   --> true
print(crypto.hmac_verify(key, "transfer 900", mac))   --> false
```

## crypto.random(n)

`n` bytes from the operating system's CSPRNG, through `openssl.rand`. Nothing in
this module reaches `math.random`.

| argument | type | default | meaning |
|---|---|---|---|
| `n` | number | `32` | how many bytes |

**Returns** a string of exactly `n` bytes.

**Raises** `akkar.crypto: the CSPRNG returned too few bytes` on a short read.
Refusing is the only safe answer: a short read would produce a token with less
entropy than its length suggests, and nothing downstream could tell.

```lua
local crypto = require "akkar.crypto"

local bytes = crypto.random(16)
print(#bytes)                      --> 16
print(#crypto.random())            --> 32
```

## crypto.sha256(data)

SHA-256 of `data`, returned as 32 raw bytes.

This is the right hash for something already high in entropy, such as an API
key. It is the wrong hash for a password: see `hash_password`.

**Returns** a 32-byte string.

**Raises** `bad argument #1 to 'final' (string expected, got nil)` when `data`
is not a string.

```lua
local crypto = require "akkar.crypto"
print(crypto.to_hex(crypto.sha256 "akkar"))
```

## crypto.to_hex(bytes)

Renders a byte string as lowercase hex, two characters per byte.

**Returns** a string of `2 * #bytes` characters.

```lua
local crypto = require "akkar.crypto"
print(crypto.to_hex "akkar")       --> 616b6b6172
```

## crypto.token(bytes)

A URL-safe random token: `bytes` of CSPRNG output rendered as hex. Hex rather
than base64 because a token travels in URLs, cookies and logs, and base64's
`+`, `/` and `=` each need escaping in at least one of those.

| argument | type | default | meaning |
|---|---|---|---|
| `bytes` | number | `32` | bytes of entropy, so the string is twice as long |

**Returns** a hex string of `2 * bytes` characters.

**Raises** whatever `crypto.random` raises.

```lua
local crypto = require "akkar.crypto"

local id = crypto.token(32)
print(#id)                         --> 64
print(#crypto.token(16))           --> 32
```

## crypto.verify_password(password, stored, options)

Checks a password against a hash `hash_password` produced. The iteration count
and the salt are read out of `stored`, so a hash made under an older cost still
verifies. The final comparison goes through `crypto.equal`.

| field | type | default | meaning |
|---|---|---|---|
| `options.iterations` | number | `crypto.DEFAULT_ITERATIONS` | the count the SECOND return value is compared against. It does not change how the password is verified |

**Returns** two values: `ok`, and `needs_rehash`. `needs_rehash` is true only
when the password matched and the stored hash used fewer iterations than
`options.iterations`. That is how a deployment raises its cost over time: verify
with the old count, then re-hash with the new one while the plaintext is still
in hand.

Anything it cannot parse is `false, false`, not an error: a `stored` that is not
a string, an algorithm other than `pbkdf2-sha256`, a string that does not match
`^([%w%-]+)%$(%d+)%$(%x+)%$(%x+)$`.

`if crypto.verify_password(...)` reads the first value and ignores the second,
which is usually what you want.

```lua
local crypto = require "akkar.crypto"

local old = crypto.hash_password("correct horse", { iterations = 1 })

-- Verified under the count inside the hash, whatever today's default is.
local ok, needs_rehash = crypto.verify_password("correct horse", old,
                                                { iterations = 2 })
print(ok, needs_rehash)            --> true    true

-- Nothing it can parse is still not an error.
print(crypto.verify_password("correct horse", "sha1$deadbeef"))
```

## Not here

**No JWT, and no way to mint a session token.** From the module's own docstring:
"A signed token that carries its own claims cannot be revoked before it expires,
which is the property a session most needs." Use [akkar.session](session.md) for
logins, and [akkar.jwt](jwt.md) to verify an assertion somebody else issued.

**No `encrypt`, no `decrypt`, no AEAD.** This module is the four calls a backend
needs (a CSPRNG, a digest, an HMAC, a KDF) over the OpenSSL akkar already links.
Encrypting application data is not one of them, and choosing a mode and a nonce
policy is not something a framework should decide for you.

## See also

- [akkar.session](session.md), which is where `equal`, `hmac` and `token` are
  used to build a login
- [akkar.auth](auth.md), for API keys, which are hashed with `sha256` here
  rather than with `hash_password`
- the module source, `akkar/crypto.lua`, for the four mistakes it exists to
  prevent
