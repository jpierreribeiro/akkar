--[[
akkar.jwt — verifying a token somebody ELSE issued. There is no `issue` here.

## The missing half is the design, not an oversight

This module exposes `verify`. It exposes no way to sign, mint, issue or
refresh a token, and that is deliberate to the point of being the reason the
file is shaped this way.

`akkar/session.lua` keeps session state on the server behind an opaque random
id, and its docstring gives the argument at length: **a self-contained token
cannot be revoked before it expires**, and revocation is the property a
session most needs -- log out, change password, ban an account, rotate after
privilege escalation. Every workaround for that (a deny-list, a short expiry
plus a refresh token) reintroduces the server-side lookup the token was
supposed to remove, and now the system has two mechanisms where it had one.

`akkar/crypto.lua` wrote down what would happen if JWT ever arrived:

> JWT still has a narrow honest use -- a short-lived assertion issued by
> somebody else, which you VERIFY -- and if that is added later it belongs in
> its own module with `verify` and no `issue`, so nobody reaches for it to
> keep a user logged in.

This is that module, and the promise is kept by omission. An `issue` function
here would be picked up within a week by somebody who wanted a login that did
not need Redis, and the argument in `session.lua` would be lost to a
convenience. The only way to make that argument hold is to not ship the
function.

**The one honest use**: an identity provider -- Auth0, Okta, Keycloak, Google,
your company's SSO -- issues a short-lived assertion about who the caller is,
and you verify it at your edge. You did not mint it, you cannot revoke it, and
it expires in minutes. Verify it, read `sub`, and open a real session if the
caller is a browser.

## The two attacks this file exists to refuse

Both are older than most of the libraries that still fall for them, and both
come from the same root: **a JWT tells you which algorithm to use to check it,
and that is the attacker's field to fill in.**

**`alg: none`.** The specification has an "unsecured JWT" whose signature is
the empty string. A verifier that reads `alg` from the header and dispatches
on it will happily take `{"alg":"none"}` with no signature at all and report
the claims as verified. Every claim in that token was written by whoever sent
it.

**Algorithm confusion, RS256 to HS256.** A service configured for RS256 holds
the issuer's PUBLIC key -- which is public, by construction. An attacker
rewrites the header to `HS256` and signs the token with that public key as an
HMAC secret. A verifier that dispatches on the header's `alg` computes
HMAC-SHA256 with the key it has, which is the key the attacker used, and the
signature matches. The public key became a shared secret because the token
asked it to.

The fix is the same for both and it is structural rather than a check: **the
caller states the algorithm and the header must agree with it.** `alg` is a
required option, not a default. A token's header is an input, never an
instruction. `spec/jwt_spec.lua` runs both attacks against a correctly
configured verifier and asserts the refusal.

## What is refused rather than warned about

An unverified claim is a refusal. There is no "we could not check the
audience, carrying on" path, because a caller who reads `claims.sub` after a
warning has already trusted the token.

Three consequences worth knowing before the first call:

**`exp` is required.** A bearer assertion with no expiry is a permanent
credential handed to a system that cannot revoke it, which is the exact thing
this module's existence is an argument against. Pass `require_exp = false` if
your issuer genuinely does not set one, and know what you turned off.

**`aud` must be checked when the token carries one.** An `aud` names who the
token was minted for. A verifier that ignores it accepts a token the user
obtained for a DIFFERENT service and replays here -- which is the whole reason
the claim exists. So a token carrying `aud` is refused unless the caller says
what audience they are. `aud = false` opts out explicitly and reads like the
decision it is.

**RSA and ECDSA are not supported, and the refusal says so.** HMAC only.
Pretending to support RS256 by falling through to an HMAC comparison is
exactly the confusion attack above, so `alg = "RS256"` is an error with a
message rather than a signature check with a surprise.

## Base64url is decoded strictly

The three segments are decoded by an alphabet table, not by a permissive
`gsub` into a standard base64 decoder. Standard base64's `+`, `/` and `=` are
not base64url and a JWT never carries padding, so accepting them means two
different strings decode to the same signature -- and a signature with two
spellings is a signature that can be replayed past a deny-list keyed on the
token text. Non-canonical trailing bits are refused for the same reason.
]]

local crypto = require "akkar.crypto"
local json   = require "akkar.json"
local time   = require "akkar.time"
local bitwise = require "akkar.bitwise"

local M = {}

-- The algorithms this module can actually check.
--
-- Three, and no asymmetric ones. The value is the OpenSSL digest name
-- `akkar.crypto.hmac` expects; the table is also the membership test, so
-- adding an algorithm and forgetting to teach the verifier about it is not
-- expressible.
local HMAC_ALGORITHMS = {
  HS256 = "sha256",
  HS384 = "sha384",
  HS512 = "sha512",
}

-- Algorithms a caller might reasonably configure and which this module cannot
-- honour. Named separately from "unknown" so the error can say WHY -- an
-- operator who set `alg = "RS256"` because their IdP signs with RS256 needs to
-- be told akkar has no RSA verification, not that they made a typo.
local ASYMMETRIC = {
  RS256 = true, RS384 = true, RS512 = true,
  PS256 = true, PS384 = true, PS512 = true,
  ES256 = true, ES384 = true, ES512 = true,
  EdDSA = true,
}

-- A ceiling on the token itself, applied before anything is decoded.
--
-- A JWT arrives in a header from the network and every segment is decoded
-- into memory. Eight kilobytes is already larger than any assertion an
-- identity provider emits (a fat Auth0 token with a dozen claims is under
-- two), and the alternative to a limit here is decoding whatever a caller
-- felt like sending.
local MAX_TOKEN_BYTES = 8 * 1024

-- Clock skew allowance, in seconds.
--
-- Thirty rather than the more common three hundred. Leeway exists because two
-- machines disagree about the time, not because expiry is negotiable, and a
-- leeway approaching the lifetime of a short-lived assertion deletes the
-- expiry it is meant to soften. Five minutes is the hard ceiling for the same
-- reason: past that, `exp` stops meaning anything on a token that lives ten
-- minutes.
local DEFAULT_LEEWAY = 30
local MAX_LEEWAY     = 300

-- ============================================================== base64url

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local VALUE = {}
for i = 1, #ALPHABET do VALUE[ALPHABET:sub(i, i)] = i - 1 end

--- Decodes one base64url segment, refusing anything that is not one.
---
--- Strict on four counts, and each one is a real forgery surface rather than
--- pedantry:
---
--- **The alphabet.** `+`, `/` and `=` belong to standard base64 and not to
--- this encoding. The common shortcut -- translate them and hand the result to
--- a lenient decoder -- means the same signature has several spellings, so a
--- token blocked by its text can be resent in a different one.
---
--- **The padding.** RFC 7515 says a JWT's segments carry none. A trailing `=`
--- is not a harmless nicety here; it is the marker that something re-encoded
--- the token with the wrong function.
---
--- **The impossible length.** Four base64 characters carry three bytes, so a
--- segment whose length is 1 modulo 4 encodes a fractional byte and cannot
--- have been produced by an encoder.
---
--- **The trailing bits.** The final character of a short group has bits that
--- no byte uses, and an encoder leaves them zero. Accepting a non-zero
--- remainder is accepting up to four spellings of the same bytes.
---
--- Returns the decoded string, or nil and a reason.
function M.b64url_decode(text)
  if type(text) ~= "string" then return nil, "not a string" end
  if text == "" then return nil, "empty" end
  if #text % 4 == 1 then
    return nil, "length is impossible for base64url"
  end

  local bits, width, out = 0, 0, {}
  for i = 1, #text do
    local char = text:sub(i, i)
    local value = VALUE[char]
    if value == nil then
      return nil, ("contains %q, which is not base64url"):format(char)
    end
    bits  = bitwise.bor(bitwise.lshift(bits, 6), value)
    width = width + 6
    if width >= 8 then
      width = width - 8
      out[#out + 1] = string.char(bitwise.band(bitwise.rshift(bits, width), 0xff))
      bits = bitwise.band(bits, bitwise.lshift(1, width) - 1)
    end
  end

  if bits ~= 0 then
    return nil, "has trailing bits set, so it is not canonical base64url"
  end
  return table.concat(out)
end

--- Decodes a segment and parses it as a JSON object.
---
--- A JSON array is refused as well as a scalar. Both decode to a Lua table in
--- every serializer akkar can be configured with, so `type(value) == "table"`
--- is not the check it looks like, and a header that is a list would reach the
--- `alg` lookup as a silent nil.
local function decode_object(segment, what)
  local raw, why = M.b64url_decode(segment)
  if not raw then return nil, ("the %s segment %s"):format(what, why) end

  local ok, value = pcall(json.decode, raw)
  if not ok or type(value) ~= "table" then
    return nil, ("the %s is not a JSON object"):format(what)
  end
  if value[1] ~= nil then
    return nil, ("the %s is a JSON array, not an object"):format(what)
  end
  return value
end

-- ============================================================ claim checks

--- Does `presented` satisfy `expected`? Either may be a string or a list.
---
--- Shared by `aud`, which is a list in the token and may be a list in the
--- configuration, and used for `iss`, where a caller with two acceptable
--- issuers during a migration should not have to run two verifiers.
local function intersects(presented, expected)
  local wanted = {}
  if type(expected) == "table" then
    for _, value in ipairs(expected) do wanted[value] = true end
  else
    wanted[expected] = true
  end

  if type(presented) == "table" then
    for _, value in ipairs(presented) do
      if wanted[value] then return true end
    end
    return false
  end
  return wanted[presented] == true
end

--- `exp`, `nbf` and `iat` against `akkar.time`, with leeway.
---
--- Read through `akkar.time` rather than `os.time` so a spec can prove expiry
--- without sleeping -- which is the entire argument that module makes, and a
--- module that verifies expiry is the one place where a test that waits for
--- real seconds is most tempting and least useful.
---
--- Every clause refuses. There is no branch here that records a problem and
--- returns the claims anyway.
local function check_times(claims, options, leeway)
  local now = time.now()

  local exp = claims.exp
  if exp == nil then
    if options.require_exp ~= false then
      -- A token with no expiry is a permanent credential, and this module
      -- cannot revoke one. Refusing by default is the whole position of
      -- `akkar.session` applied to somebody else's token.
      return nil, "the token has no exp, and a token that never expires " ..
                  "cannot be withdrawn; set require_exp = false to accept it"
    end
  elseif type(exp) ~= "number" then
    return nil, "exp is not a number"
  elseif now > exp + leeway then
    return nil, ("the token expired at %d and it is now %d"):format(exp, now)
  end

  local nbf = claims.nbf
  if nbf ~= nil then
    if type(nbf) ~= "number" then return nil, "nbf is not a number" end
    if now < nbf - leeway then
      return nil, ("the token is not valid until %d and it is now %d")
                  :format(nbf, now)
    end
  end

  local iat = claims.iat
  if iat ~= nil then
    if type(iat) ~= "number" then return nil, "iat is not a number" end
    -- A token issued in the future is a token whose issuer's clock is wrong or
    -- whose `iat` was chosen by hand. Neither is a token to trust, and the
    -- second is how `max_age` gets defeated.
    if now < iat - leeway then
      return nil, ("the token claims to have been issued at %d, which is in " ..
                   "the future; it is now %d"):format(iat, now)
    end
    if options.max_age and now > iat + options.max_age + leeway then
      return nil, ("the token is older than the %d seconds this caller accepts")
                  :format(options.max_age)
    end
  elseif options.max_age then
    return nil, "max_age was asked for and the token carries no iat"
  end

  return true
end

-- ================================================================== verify

--- Picks the secret for a token, refusing to guess.
---
--- With `keys`, a `kid` is mandatory and there is no fallback to `key`. An
--- issuer that rotates keys publishes a `kid`, and a verifier that silently
--- tries a default when the `kid` is unknown accepts tokens signed with a
--- retired key -- which is the thing rotation was for.
local function secret_for(header, options)
  if options.keys then
    local kid = header.kid
    if type(kid) ~= "string" then
      return nil, "this verifier is configured with keys by id and the " ..
                  "token header carries no kid"
    end
    local secret = options.keys[kid]
    if secret == nil then
      return nil, ("no key is configured for kid %q"):format(kid)
    end
    return secret
  end

  if type(options.key) ~= "string" or options.key == "" then
    error("akkar.jwt: verify needs `key` (a string) or `keys` (a table of " ..
          "kid -> string)", 2)
  end
  return options.key
end

--- Verifies a token. Returns the claims, or nil and a reason.
---
---     local claims, why = jwt.verify(token, {
---       alg    = "HS256",                    -- REQUIRED. see below.
---       key    = os.getenv "IDP_SHARED_SECRET",
---       iss    = "https://idp.example.com/",
---       aud    = "https://api.example.com",
---       leeway = 30,
---     })
---     if not claims then
---       req.log:info("rejected an assertion", { reason = why })
---       return akkar.unauthorized()
---     end
---
--- **`alg` is required and it is the security property.** It is not defaulted,
--- because a default is a value nobody chose, and the value nobody chose is
--- the one the attacker gets to influence through the header. With `alg`
--- stated, `alg: none` and the RS256-to-HS256 confusion are the same refusal:
--- the header does not say what the caller said.
---
--- The reason string is for your log, not for the client. Telling a caller
--- which of eight checks their forged token failed is a free oracle; answer
--- 401 with nothing in it and keep the detail where you can read it.
function M.verify(token, options)
  options = options or {}

  local expected = options.alg
  if type(expected) ~= "string" then
    error("akkar.jwt: verify needs `alg`, the algorithm you expect. It is " ..
          "required and not defaulted on purpose: the token's own header is " ..
          "an attacker-controlled field, and a verifier that trusts it " ..
          "accepts alg:none and the RS256-to-HS256 confusion", 2)
  end
  if ASYMMETRIC[expected] then
    error("akkar.jwt: " .. expected .. " is not supported. akkar verifies " ..
          "HMAC signatures only, and quietly checking an RSA token with an " ..
          "HMAC is precisely the confusion attack this module refuses. Use " ..
          "an HS* shared secret, or verify the assertion at a gateway that " ..
          "has the issuer's public key", 2)
  end
  local digest = HMAC_ALGORITHMS[expected]
  if not digest then
    error("akkar.jwt: unknown algorithm " .. expected ..
          "; this module verifies HS256, HS384 and HS512", 2)
  end

  local leeway = options.leeway or DEFAULT_LEEWAY
  if type(leeway) ~= "number" or leeway < 0 or leeway > MAX_LEEWAY then
    error(("akkar.jwt: leeway must be between 0 and %d seconds. It exists " ..
           "for clock skew between two machines, and a leeway near the " ..
           "lifetime of a short-lived assertion deletes its expiry")
          :format(MAX_LEEWAY), 2)
  end

  if type(token) ~= "string" or token == "" then
    return nil, "no token"
  end
  if #token > MAX_TOKEN_BYTES then
    return nil, ("the token is %d bytes, over the %d byte ceiling")
                :format(#token, MAX_TOKEN_BYTES)
  end

  -- Exactly three segments. A JWE -- an ENCRYPTED token -- has five, and it is
  -- not a thing this module can read; matching loosely would take its first
  -- three parts and check a signature over the wrong bytes.
  local header_b64, payload_b64, signature_b64 =
    token:match "^([^%.]+)%.([^%.]+)%.([^%.]*)$"
  if not header_b64 then
    return nil, "the token is not three base64url segments separated by dots"
  end

  local header, why = decode_object(header_b64, "header")
  if not header then return nil, why end

  -- ATTACK ONE, NAMED SO THE REFUSAL IS FINDABLE IN A LOG.
  --
  -- `alg: none` would fail the comparison below anyway, and it gets its own
  -- clause regardless: it is the single most reported JWT vulnerability in
  -- existence, and a verifier that refuses it as a side effect of a generic
  -- string compare gives an operator reading the logs nothing to recognise.
  -- The case-insensitive match is not decoration -- "None" and "NONE" have
  -- both worked in shipped libraries whose check was `alg == "none"`.
  if type(header.alg) ~= "string" then
    return nil, "the token header has no alg"
  end
  if header.alg:lower() == "none" then
    return nil, "the token asks to be accepted unsigned (alg: none), which " ..
                "means every claim in it was written by whoever sent it"
  end

  -- ATTACK TWO, AND THE ONE LINE THAT CLOSES IT.
  --
  -- The header is compared against what the CALLER said, never dispatched on.
  -- A token arriving as HS256 at a verifier configured for RS256 is the
  -- public-key-as-HMAC-secret confusion, and it dies here before any key is
  -- fetched and any HMAC is computed.
  if header.alg ~= expected then
    return nil, ("the token is signed with %s and this verifier accepts only " ..
                 "%s"):format(header.alg, expected)
  end

  -- `crit` lists header parameters the issuer says MUST be understood. akkar
  -- understands none of them, so the specification's own instruction is to
  -- refuse rather than to ignore the list and verify anyway.
  if header.crit ~= nil then
    return nil, "the token header carries crit, and akkar understands no " ..
                "critical header parameters"
  end

  local secret, key_why = secret_for(header, options)
  if not secret then return nil, key_why end

  local signature
  signature, why = M.b64url_decode(signature_b64)
  if not signature then
    return nil, "the signature segment " .. (why or "is not base64url")
  end

  -- Constant time, through `akkar.crypto`. A signature compared with `==`
  -- leaks how long a prefix the attacker guessed, and a forger may retry
  -- freely -- which is the exact shape `akkar.crypto.equal` documents.
  --
  -- The signature is checked BEFORE the payload is decoded. Nothing in the
  -- claims is looked at, not even to produce a better error, until the bytes
  -- are known to be the issuer's.
  local signed = header_b64 .. "." .. payload_b64
  if not crypto.hmac_verify(secret, signed, signature, digest) then
    return nil, "the signature does not verify"
  end

  local claims
  claims, why = decode_object(payload_b64, "payload")
  if not claims then return nil, why end

  local ok
  ok, why = check_times(claims, options, leeway)
  if not ok then return nil, why end

  if options.iss ~= nil then
    if claims.iss == nil then
      return nil, "an issuer was required and the token carries no iss"
    end
    if not intersects(claims.iss, options.iss) then
      return nil, ("the token was issued by %q, which this verifier does not " ..
                   "accept"):format(tostring(claims.iss))
    end
  end

  -- THE AUDIENCE IS CHECKED OR THE TOKEN IS REFUSED. There is no third state.
  --
  -- `aud` names the service a token was minted for. A user can usually obtain
  -- a legitimate token for some OTHER relying party of the same identity
  -- provider -- that is what an IdP is for -- and replay it here. Ignoring
  -- `aud` accepts it, and the claim carrying the answer was sitting in the
  -- token the whole time.
  --
  -- So: a token that declares an audience is refused unless the caller says
  -- which audience they are. `aud = false` is the way to say "I know, and I
  -- accept tokens minted for anyone", which is a sentence somebody has to
  -- write down rather than a default they never saw.
  if options.aud == nil then
    if claims.aud ~= nil then
      return nil, "the token names an audience and this verifier was not " ..
                  "told which audience it is; pass aud = \"...\", or " ..
                  "aud = false to accept a token minted for anybody"
    end
  elseif options.aud ~= false then
    if claims.aud == nil then
      return nil, "an audience was required and the token carries no aud"
    end
    if not intersects(claims.aud, options.aud) then
      return nil, "the token was minted for a different audience"
    end
  end

  for _, name in ipairs(options.require or {}) do
    if claims[name] == nil then
      return nil, ("the token carries no %s, which this caller requires")
                  :format(name)
    end
  end

  return claims
end

M.HMAC_ALGORITHMS = HMAC_ALGORITHMS
M.DEFAULT_LEEWAY  = DEFAULT_LEEWAY
M.MAX_TOKEN_BYTES = MAX_TOKEN_BYTES

-- There is no M.issue, M.sign, M.encode or M.new. See the top of the file:
-- the omission is the design, and a helpful addition here undoes the argument
-- `akkar/session.lua` makes for keeping sessions on the server.

return M
