# akkar.jwt

Verifies a JWT that somebody else issued. HMAC signatures only, and the
algorithm is stated by the caller rather than read from the token.

**When you need it.** An identity provider (Auth0, Okta, Keycloak, Google, your
company's SSO) hands the caller a short-lived assertion and you check it at your
edge. Read `sub`, then open a real [session](session.md) if the caller is a
browser. This is not the module for keeping a user logged in.

```lua no-run
local jwt = require "akkar.jwt"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`jwt.b64url_decode`](#jwtb64url_decodetext) | function |
| [`jwt.DEFAULT_LEEWAY`](#jwtdefault_leeway) | number |
| [`jwt.HMAC_ALGORITHMS`](#jwthmac_algorithms) | table |
| [`jwt.MAX_TOKEN_BYTES`](#jwtmax_token_bytes) | number |
| [`jwt.verify`](#jwtverifytoken-options) | function |

## jwt.b64url_decode(text)

Decodes one base64url segment. Exported because the payload of a token you have
already verified is sometimes wanted raw.

Strict on four counts, each of which is a forgery surface rather than pedantry:
the alphabet is base64url only, so `+`, `/` and `=` are refused; a length of 1
modulo 4 encodes a fractional byte and cannot have come from an encoder; and
non-zero trailing bits in the final group are refused, because accepting them
accepts up to four spellings of the same bytes. A signature with two spellings is
a signature that can be replayed past a deny-list keyed on the token text.

**Returns** the decoded string, or `nil` and one of: `"not a string"`,
`"empty"`, `"length is impossible for base64url"`, `"contains %q, which is not
base64url"`, `"has trailing bits set, so it is not canonical base64url"`.

```lua
local jwt = require "akkar.jwt"

print(jwt.b64url_decode "eyJhbGciOiJIUzI1NiJ9")
print(jwt.b64url_decode "YWJjZA==")                --> nil, contains "=" ...
print(jwt.b64url_decode "YWJ+")                    --> nil, contains "+" ...
print(jwt.b64url_decode "a")                       --> nil, length is impossible
```

## jwt.DEFAULT_LEEWAY

The clock-skew allowance `verify` uses when `options.leeway` is absent, in
seconds. It is `30`, not the more common 300: leeway exists because two machines
disagree about the time, not because expiry is negotiable. The hard ceiling is
300, and `verify` raises above it.

**Returns** a number.

## jwt.HMAC_ALGORITHMS

The algorithms this module can check, as a table mapping the JWT name to the
OpenSSL digest name: `HS256`, `HS384`, `HS512`. It is also the membership test
`verify` uses, so adding an algorithm and forgetting to teach the verifier about
it is not expressible.

**Returns** a table.

```lua
local jwt = require "akkar.jwt"

local names = {}
for name in pairs(jwt.HMAC_ALGORITHMS) do names[#names + 1] = name end
table.sort(names)
print(table.concat(names, " "))          --> HS256 HS384 HS512
print(jwt.DEFAULT_LEEWAY, jwt.MAX_TOKEN_BYTES)
```

## jwt.MAX_TOKEN_BYTES

The ceiling on the token string, applied before anything is decoded: `8192`.
Larger than any assertion an identity provider emits, and the alternative to a
limit is decoding whatever a caller felt like sending.

**Returns** a number.

## jwt.verify(token, options)

Verifies a token and returns its claims. Every check refuses; there is no branch
that records a problem and returns the claims anyway.

| field | type | default | meaning |
|---|---|---|---|
| `alg` | string | **required** | the algorithm you expect. `HS256`, `HS384` or `HS512` |
| `key` | string | required unless `keys` | the shared secret |
| `keys` | table | none | `kid` to secret. When set, the token header must carry a `kid` and there is no fallback to `key` |
| `iss` | string or list | none | acceptable issuers. When set, a token with no `iss` is refused |
| `aud` | string, list or `false` | none | acceptable audiences. See below |
| `leeway` | number | `30` | clock skew, in seconds. Must be between 0 and 300 |
| `require_exp` | boolean | `true` | set `false` to accept a token with no `exp` |
| `max_age` | number | none | refuse a token whose `iat` is older than this. A token with no `iat` is refused when this is set |
| `require` | list | `{}` | claim names that must be present |

**`alg` is required and it is the security property.** It is not defaulted,
because a default is a value nobody chose, and the value nobody chose is the one
the attacker gets to influence through the header. With `alg` stated, `alg: none`
and the RS256-to-HS256 confusion are the same refusal: the header does not say
what the caller said.

**`aud` is checked or the token is refused; there is no third state.** An `aud`
names the service a token was minted for, and a user can usually obtain a
legitimate token for some other relying party of the same identity provider and
replay it here. So a token carrying `aud` is refused unless the caller says which
audience they are. `aud = false` says "I accept a token minted for anybody", and
it reads like the decision it is.

The signature is checked before the payload is decoded. Nothing in the claims is
looked at, not even to build a better error, until the bytes are known to be the
issuer's. The comparison runs through `akkar.crypto.hmac_verify`, which is
constant time.

**Returns** the claims table, or `nil` and a reason string. The reason is for
your log, not for the client: telling a caller which of eight checks their forged
token failed is a free oracle. Answer 401 with nothing in it.

**Raises**, rather than returning a reason, when the caller configured the
verifier wrongly. Every one of these is a mistake in your code, not in the token:

- `akkar.jwt: verify needs `alg`, the algorithm you expect. ...` when `alg` is
  not a string.
- `akkar.jwt: RS256 is not supported. akkar verifies HMAC signatures only ...`
  for `RS*`, `PS*`, `ES*` and `EdDSA`. Quietly checking an RSA token with an HMAC
  is exactly the confusion attack.
- `akkar.jwt: unknown algorithm <name>; this module verifies HS256, HS384 and
  HS512`.
- `akkar.jwt: leeway must be between 0 and 300 seconds. ...`
- `akkar.jwt: verify needs `key` (a string) or `keys` (a table of kid -> string)`
  when neither is usable and `keys` was not given.

```lua
local jwt    = require "akkar.jwt"
local crypto = require "akkar.crypto"
local json   = require "akkar.json"

local SECRET = crypto.token(32)

-- akkar.jwt has no `issue`, so this example plays the identity provider.
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function b64url(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local chunk = { ALPHABET:sub((n >> 18 & 63) + 1, (n >> 18 & 63) + 1),
                    ALPHABET:sub((n >> 12 & 63) + 1, (n >> 12 & 63) + 1) }
    if b then chunk[3] = ALPHABET:sub((n >> 6 & 63) + 1, (n >> 6 & 63) + 1) end
    if c then chunk[4] = ALPHABET:sub((n & 63) + 1, (n & 63) + 1) end
    out[#out + 1] = table.concat(chunk)
  end
  return table.concat(out)
end

local header  = b64url(json.encode { alg = "HS256", typ = "JWT" })
local payload = b64url(json.encode {
  sub = "user-42",
  iss = "https://idp.example.com/",
  aud = "https://api.example.com",
  exp = os.time() + 3600,
})
local signed = header .. "." .. payload
local token  = signed .. "." .. b64url(crypto.hmac(SECRET, signed, "sha256"))

local claims, why = jwt.verify(token, {
  alg = "HS256",
  key = SECRET,
  iss = "https://idp.example.com/",
  aud = "https://api.example.com",
})
print("subject:", claims and claims.sub, why)

-- The same token presented to a service it was not minted for.
print("replayed:", jwt.verify(token, {
  alg = "HS256", key = SECRET, aud = "https://other.example.com",
}))

-- A configuration mistake raises rather than returning a reason.
print(pcall(jwt.verify, token, { key = SECRET }))
print(pcall(jwt.verify, token, { alg = "RS256", key = SECRET }))
```

Read the reason, do not return it:

```lua no-run
local claims, why = jwt.verify(token, { alg = "HS256", key = SECRET,
                                        aud = "https://api.example.com" })
if not claims then
  req.log:info("rejected an assertion", { reason = why })
  return akkar.unauthorized()
end
```

## Every reason verify returns

In the order the checks run. All of them are `nil, "<reason>"`.

| reason | means |
|---|---|
| `no token` | `token` is not a string, or is empty |
| `the token is %d bytes, over the %d byte ceiling` | longer than `MAX_TOKEN_BYTES` |
| `the token is not three base64url segments separated by dots` | not `a.b.c`. A JWE, which is encrypted, has five and is not readable here |
| `the header segment <why>` | the header is not canonical base64url |
| `the header is not a JSON object` / `... is a JSON array, not an object` | it decoded to something else |
| `the token header has no alg` | `alg` is absent or not a string |
| `the token asks to be accepted unsigned (alg: none), ...` | matched case-insensitively, because `None` and `NONE` have both worked in shipped libraries |
| `the token is signed with %s and this verifier accepts only %s` | the algorithm confusion attack, closed |
| `the token header carries crit, and akkar understands no critical header parameters` | `crit` lists parameters the issuer says must be understood |
| `this verifier is configured with keys by id and the token header carries no kid` | `keys` was set and the header has no `kid` |
| `no key is configured for kid %q` | there is no fallback to `key` |
| `the signature segment <why>` | not canonical base64url |
| `the signature does not verify` | |
| `the payload segment <why>` / `the payload is not a JSON object` | |
| `the token has no exp, and a token that never expires cannot be withdrawn; set require_exp = false to accept it` | |
| `exp is not a number` / `the token expired at %d and it is now %d` | |
| `nbf is not a number` / `the token is not valid until %d and it is now %d` | |
| `iat is not a number` / `the token claims to have been issued at %d, which is in the future; it is now %d` | |
| `the token is older than the %d seconds this caller accepts` | `max_age` |
| `max_age was asked for and the token carries no iat` | |
| `an issuer was required and the token carries no iss` | |
| `the token was issued by %q, which this verifier does not accept` | |
| `the token names an audience and this verifier was not told which audience it is; pass aud = "...", or aud = false to accept a token minted for anybody` | |
| `an audience was required and the token carries no aud` | |
| `the token was minted for a different audience` | |
| `the token carries no %s, which this caller requires` | from `options.require` |

Time is read through [akkar.time](time.md), so a spec can prove expiry with
`time.manual` instead of sleeping.

## Not here

**No `issue`, `sign`, `encode` or `new`.** From the module's own docstring: "an
`issue` function here would be picked up within a week by somebody who wanted a
login that did not need Redis, and the argument in `session.lua` would be lost to
a convenience. The only way to make that argument hold is to not ship the
function." `spec/jwt_spec.lua` asserts the absence.

**No RSA or ECDSA verification.** HMAC only, and `alg = "RS256"` is an error with
a message rather than a signature check with a surprise, because falling through
to an HMAC comparison is precisely the confusion attack. Verify an asymmetric
assertion at a gateway that holds the issuer's public key.

**No JWKS fetching and no key rotation client.** `keys` is a table you fill in.
Fetching a `jwks_uri` on a cache miss is a network call inside a verification
path, and akkar will not make one behind your back.

## See also

- [akkar.session](session.md), which is what this project uses to keep somebody
  logged in
- [akkar.crypto](crypto.md), for the constant-time HMAC comparison underneath
- the module source, `akkar/jwt.lua`, and `spec/jwt_spec.lua`, which runs both
  attacks against a correctly configured verifier and asserts the refusal
