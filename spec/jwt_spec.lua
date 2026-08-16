--[[
akkar.jwt — the two attacks, and the function that is not here.

The tests that carry this module are the refusals, and two of them carry the
rest. Both are older than most of the libraries that still fall for them and
both come from the same root: a JWT tells the verifier which algorithm to use,
and the token is written by whoever sent it.

**`alg: none`** — the header claims the token is unsigned, and a verifier that
dispatches on the header accepts it with no signature at all.

**RS256 to HS256** — a service configured for RS256 holds the issuer's PUBLIC
key. An attacker rewrites the header to HS256 and signs with that public key as
an HMAC secret; a verifier that dispatches on the header uses the key it has,
which is the key the attacker used, and the signature matches.

Both are tested here with a token that a signature-only verifier WOULD accept:
the header says one thing and the signature is a genuinely valid HMAC under the
verifier's own key. That is the version that matters. A test using a token with
a garbage signature proves nothing, because the signature check alone would
refuse it and the `alg` check would never be exercised.

The last test in the file asserts that `issue` does not exist. It is not
decoration: `akkar/session.lua` argues that a self-contained token cannot be
revoked, and the only thing keeping that argument true is the absence of a
function somebody would otherwise reach for.

The clock is `akkar.time.manual`, so expiry is proven without waiting for it.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local jwt    = require "akkar.jwt"
local crypto = require "akkar.crypto"
local json   = require "akkar.json"
local time   = require "akkar.time"

local SECRET = crypto.token(32)
local NOW    = 1755000000

-- A public key is PUBLIC. That is the whole premise of the confusion attack:
-- the attacker has this string because everybody does.
local PUBLIC_KEY = "-----BEGIN PUBLIC KEY-----\nMIIBIjANBg...\n-----END PUBLIC KEY-----"

-- =============================================================== the forger
--
-- The spec is allowed to mint tokens because the spec is the attacker. The
-- module is not, and the last describe block in this file is what enforces
-- that. Keeping the encoder here rather than exporting it from `akkar.jwt` is
-- the same decision as omitting `issue`.

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

--- Builds a token. `signer` decides what lands in the third segment.
---
--- Split this way so that a test can put a VALID signature under a LYING
--- header, which is the only interesting version of both attacks.
local function forge(header, payload, signer)
  local signing = b64url(json.encode(header)) .. "." ..
                  b64url(json.encode(payload))
  return signing .. "." .. b64url(signer and signer(signing) or "")
end

local function hmac_with(key, digest)
  return function(signing) return crypto.hmac(key, signing, digest or "sha256") end
end

local function claims(overrides)
  local out = { sub = "user-42", exp = NOW + 300, iat = NOW }
  for k, v in pairs(overrides or {}) do
    if v == json.null then out[k] = nil else out[k] = v end
  end
  return out
end

--- A well-formed, correctly signed HS256 token.
local function good(overrides, header_overrides)
  local header = { alg = "HS256", typ = "JWT" }
  for k, v in pairs(header_overrides or {}) do header[k] = v end
  return forge(header, claims(overrides), hmac_with(SECRET))
end

local restore
before_each(function() restore = time.set(time.manual { now = NOW }) end)
after_each(function() if restore then restore() end end)

-- =========================================================================

describe("verifying an honest token", function()
  it("returns the claims", function()
    local out, why = jwt.verify(good(), { alg = "HS256", key = SECRET })
    assert.is_table(out, tostring(why))
    assert.equal("user-42", out.sub)
    assert.equal(NOW + 300, out.exp)
  end)

  it("verifies HS384 and HS512 too", function()
    for alg, digest in pairs { HS384 = "sha384", HS512 = "sha512" } do
      local token = forge({ alg = alg }, claims(), hmac_with(SECRET, digest))
      local out, why = jwt.verify(token, { alg = alg, key = SECRET })
      assert.is_table(out, alg .. ": " .. tostring(why))
    end
  end)

  it("refuses a token signed with a different key", function()
    local token = forge({ alg = "HS256" }, claims(), hmac_with(crypto.token(32)))
    local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
    assert.is_nil(out)
    assert.is_truthy(why:find("signature", 1, true))
  end)

  it("refuses a token whose payload was edited after signing", function()
    -- The whole point of the signature: the header and the payload are signed
    -- TOGETHER, so swapping the payload for a more generous one invalidates it.
    local token = good()
    local header, _, signature = token:match "^([^%.]+)%.([^%.]+)%.([^%.]+)$"
    local tampered = header .. "." ..
                     b64url(json.encode(claims { sub = "admin" })) .. "." ..
                     signature

    local out = jwt.verify(tampered, { alg = "HS256", key = SECRET })
    assert.is_nil(out)
  end)
end)

-- =========================================================================

describe("ATTACK ONE: alg none", function()
  it("refuses an unsigned token", function()
    -- The textbook form: the header says the token needs no signature, and the
    -- third segment is empty. A verifier that dispatches on `alg` reports
    -- every claim in this token as verified. Every one of them was written by
    -- the sender.
    local token = forge({ alg = "none" }, claims { sub = "admin" }, nil)

    local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
    assert.is_nil(out, "an alg:none token was accepted")
    assert.is_truthy(why:find("unsigned", 1, true), why)
  end)

  it("refuses it in every spelling, because libraries have shipped `== 'none'`",
    function()
      for _, spelling in ipairs { "none", "None", "NONE", "nOnE" } do
        local token = forge({ alg = spelling }, claims { sub = "admin" }, nil)
        local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
        assert.is_nil(out, spelling .. " was accepted")
        assert.is_truthy(why:find("unsigned", 1, true), spelling .. ": " .. why)
      end
    end)

  it("refuses it even when the signature IS valid, which is the real test",
    function()
      -- A token whose header says `none` and whose signature is a genuine
      -- HMAC-SHA256 under the verifier's own key. A verifier that checked only
      -- the signature would accept this happily, so this is what proves the
      -- `alg` check does independent work rather than being shadowed by the
      -- signature comparison.
      local token = forge({ alg = "none" }, claims { sub = "admin" },
                          hmac_with(SECRET))

      local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
      assert.is_nil(out, "an alg:none token with a valid HMAC was accepted")
      assert.is_truthy(why:find("unsigned", 1, true), why)
    end)
end)

describe("ATTACK TWO: algorithm confusion, RS256 to HS256", function()
  it("refuses to be an RS256 verifier at all, and says why", function()
    -- The attack needs a verifier holding a PUBLIC key and dispatching on the
    -- header. akkar cannot be that verifier, because it will not accept the
    -- configuration: HMAC is all it can check, and quietly HMAC-ing with an
    -- RSA public key IS the attack.
    --
    -- Refusing at configuration time rather than at verification time matters:
    -- it fails on the first call in development, not on the first forged token
    -- in production.
    local ok, why = pcall(jwt.verify, good(), {
      alg = "RS256", key = PUBLIC_KEY,
    })
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("RS256", 1, true), tostring(why))
    assert.is_truthy(tostring(why):find("confusion", 1, true), tostring(why))
  end)

  it("refuses a token forged by HMAC-ing the public key", function()
    -- What the attacker actually sends: header rewritten to HS256, signature
    -- computed with the public key as the HMAC secret. Against a vulnerable
    -- RS256 verifier this is a valid token for any claims the attacker likes.
    local forged = forge({ alg = "HS256" }, claims { sub = "admin" },
                         hmac_with(PUBLIC_KEY))

    local ok = pcall(jwt.verify, forged, { alg = "RS256", key = PUBLIC_KEY })
    assert.is_false(ok, "the RS256-to-HS256 forgery was processed")
  end)

  it("refuses a header that disagrees with the caller, VALID SIGNATURE AND ALL",
    function()
      -- The confusion attack in the direction akkar can actually be configured
      -- for, and the sharpest version of the test in this file.
      --
      -- The header says RS256. The signature is a genuine, correct
      -- HMAC-SHA256 over the signing input using the verifier's own secret.
      -- A verifier that ignores `alg` and just checks the HMAC -- which is how
      -- several libraries "fixed" alg:none -- accepts this token. akkar
      -- refuses it on the header alone, before a key is fetched and before an
      -- HMAC is computed.
      local token = forge({ alg = "RS256" }, claims { sub = "admin" },
                          hmac_with(SECRET))

      local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
      assert.is_nil(out, "a token whose header lied about its algorithm was accepted")
      assert.is_truthy(why:find("RS256", 1, true), why)
      assert.is_truthy(why:find("HS256", 1, true), why)
    end)

  it("refuses HS512 where HS256 was asked for", function()
    -- Not only the asymmetric case. A caller who pinned HS256 gets HS256, and
    -- a token that downgrades or upgrades within the family is still a token
    -- whose header chose the algorithm.
    local token = forge({ alg = "HS512" }, claims(), hmac_with(SECRET, "sha512"))
    local out = jwt.verify(token, { alg = "HS256", key = SECRET })
    assert.is_nil(out)
  end)

  it("makes `alg` impossible to forget, because a default would be the hole",
    function()
      local ok, why = pcall(jwt.verify, good(), { key = SECRET })
      assert.is_false(ok)
      assert.is_truthy(tostring(why):find("alg", 1, true), tostring(why))
    end)

  it("refuses a header carrying crit, which akkar cannot honour", function()
    local token = forge({ alg = "HS256", crit = { "exp" } }, claims(),
                        hmac_with(SECRET))
    local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
    assert.is_nil(out)
    assert.is_truthy(why:find("crit", 1, true), why)
  end)
end)

-- =========================================================================

describe("decoding base64url strictly", function()
  it("decodes what it should", function()
    assert.equal("Hello", jwt.b64url_decode "SGVsbG8")
    assert.equal("A", jwt.b64url_decode "QQ")
    assert.equal("any carnal pleasure.",
                 jwt.b64url_decode "YW55IGNhcm5hbCBwbGVhc3VyZS4")
    -- An empty segment is not a zero-length decode, it is a missing segment.
    assert.is_nil(jwt.b64url_decode "")
  end)

  it("refuses standard base64's alphabet and its padding", function()
    -- `+`, `/` and `=` are base64, not base64url, and a JWT carries no
    -- padding. The usual shortcut -- translate them and hand the result to a
    -- lenient decoder -- gives one signature several spellings, so a token
    -- blocked by its text can be resent in another one.
    for _, bad in ipairs { "ab+d", "ab/d", "abcd=", "ab=d", "ab cd", "ab\nd" } do
      local out, why = jwt.b64url_decode(bad)
      assert.is_nil(out, ("%q was decoded"):format(bad))
      assert.is_string(why)
    end
  end)

  it("refuses a length no encoder could have produced", function()
    -- Four characters carry three bytes, so a length of 1 modulo 4 encodes a
    -- fractional byte.
    local out, why = jwt.b64url_decode "QQQQQ"
    assert.is_nil(out)
    assert.is_truthy(why:find("impossible", 1, true), why)
  end)

  it("refuses non-canonical trailing bits", function()
    -- "QQ" and "QR" both decode to the byte 0x41 under a lenient decoder,
    -- because the last four bits of the second character are not used. Two
    -- spellings of one signature is one spelling too many.
    assert.equal("A", jwt.b64url_decode "QQ")
    local out, why = jwt.b64url_decode "QR"
    assert.is_nil(out, "a non-canonical encoding was accepted")
    assert.is_truthy(why:find("canonical", 1, true), why)
  end)

  it("refuses garbage instead of producing garbage", function()
    for _, bad in ipairs { "!!!!", "....", "\0\0\0\0" } do
      assert.is_nil(jwt.b64url_decode(bad))
    end
  end)

  it("refuses a whole token whose segments are not base64url", function()
    local token = good()
    local header, payload, signature =
      token:match "^([^%.]+)%.([^%.]+)%.([^%.]+)$"

    -- A padded signature is the same signature, and it must not be accepted
    -- under a second spelling.
    local out = jwt.verify(header .. "." .. payload .. "." .. signature .. "=",
                           { alg = "HS256", key = SECRET })
    assert.is_nil(out)

    out = jwt.verify("!!!." .. payload .. "." .. signature,
                     { alg = "HS256", key = SECRET })
    assert.is_nil(out)
  end)
end)

describe("refusing a token that is not the right shape", function()
  it("wants exactly three segments", function()
    for _, bad in ipairs {
      "", "abc", "a.b", "a.b.c.d",
      -- Five segments is a JWE, an ENCRYPTED token. Matching loosely would
      -- check a signature over the wrong bytes.
      "a.b.c.d.e",
    } do
      local out, why = jwt.verify(bad, { alg = "HS256", key = SECRET })
      assert.is_nil(out, ("%q was accepted"):format(bad))
      assert.is_string(why)
    end
  end)

  it("refuses a payload that is not a JSON object", function()
    local signing = b64url(json.encode { alg = "HS256" }) .. "." ..
                    b64url '"not an object"'
    local token = signing .. "." .. b64url(crypto.hmac(SECRET, signing))
    local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
    assert.is_nil(out)
    assert.is_truthy(why:find("object", 1, true), why)
  end)

  it("refuses a token past the size ceiling before decoding it", function()
    local out, why = jwt.verify(string.rep("a", jwt.MAX_TOKEN_BYTES + 1) ..
                                ".b.c", { alg = "HS256", key = SECRET })
    assert.is_nil(out)
    assert.is_truthy(why:find("ceiling", 1, true), why)
  end)
end)

-- =========================================================================

describe("the clock claims, against akkar.time", function()
  it("refuses an expired token", function()
    local clock = time.manual { now = NOW }
    restore(); restore = time.set(clock)

    local token = good { exp = NOW + 60 }
    assert.is_table(jwt.verify(token, { alg = "HS256", key = SECRET }))

    -- Not one second of real waiting.
    clock:advance(3600)
    local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
    assert.is_nil(out)
    assert.is_truthy(why:find("expired", 1, true), why)
  end)

  it("allows the configured leeway and no more", function()
    local clock = time.manual { now = NOW }
    restore(); restore = time.set(clock)

    local token = good { exp = NOW + 10 }
    clock:advance(30)          -- 20 seconds past expiry

    assert.is_table(jwt.verify(token, { alg = "HS256", key = SECRET,
                                        leeway = 60 }))
    assert.is_nil(jwt.verify(token, { alg = "HS256", key = SECRET,
                                      leeway = 5 }))
    assert.is_nil(jwt.verify(token, { alg = "HS256", key = SECRET,
                                      leeway = 0 }))
  end)

  it("refuses a leeway large enough to delete the expiry", function()
    local ok, why = pcall(jwt.verify, good(),
                          { alg = "HS256", key = SECRET, leeway = 86400 })
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("clock skew", 1, true), tostring(why))
  end)

  it("refuses a token that is not valid yet", function()
    local out, why = jwt.verify(good { nbf = NOW + 600 },
                                { alg = "HS256", key = SECRET })
    assert.is_nil(out)
    assert.is_truthy(why:find("not valid until", 1, true), why)

    -- Inside the leeway, an nbf a few seconds out is clock skew, not an attack.
    assert.is_table(jwt.verify(good { nbf = NOW + 10 },
                               { alg = "HS256", key = SECRET, leeway = 30 }))
  end)

  it("refuses a token issued in the future", function()
    local out, why = jwt.verify(good { iat = NOW + 3600 },
                                { alg = "HS256", key = SECRET })
    assert.is_nil(out)
    assert.is_truthy(why:find("future", 1, true), why)
  end)

  it("refuses a token with no expiry, because it cannot be withdrawn", function()
    -- The position `akkar/session.lua` takes, applied to somebody else's
    -- token: a credential this system cannot revoke must at least expire.
    local token = good { exp = json.null }
    local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
    assert.is_nil(out)
    assert.is_truthy(why:find("never expires", 1, true), why)

    -- Turning it off is possible and it is a sentence somebody had to write.
    assert.is_table(jwt.verify(token, { alg = "HS256", key = SECRET,
                                        require_exp = false }))
  end)

  it("enforces max_age against iat", function()
    local clock = time.manual { now = NOW }
    restore(); restore = time.set(clock)

    local token = good { iat = NOW, exp = NOW + 86400 }
    clock:advance(600)

    assert.is_table(jwt.verify(token, { alg = "HS256", key = SECRET,
                                        max_age = 3600 }))
    assert.is_nil(jwt.verify(token, { alg = "HS256", key = SECRET,
                                      max_age = 60 }))

    -- max_age with no iat to measure from is a check that cannot be made, and
    -- a check that cannot be made is a refusal.
    local no_iat = good { iat = json.null }
    assert.is_nil(jwt.verify(no_iat, { alg = "HS256", key = SECRET,
                                       max_age = 3600 }))
  end)

  it("refuses a claim of the wrong type instead of comparing it", function()
    for _, name in ipairs { "exp", "nbf", "iat" } do
      local token = good { [name] = "soon" }
      local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
      assert.is_nil(out, name .. " as a string was accepted")
      assert.is_truthy(why:find("not a number", 1, true), why)
    end
  end)
end)

-- =========================================================================

describe("the issuer and the audience", function()
  it("checks iss when the caller supplies one", function()
    local token = good { iss = "https://idp.example.com/" }

    assert.is_table(jwt.verify(token, { alg = "HS256", key = SECRET,
                                        iss = "https://idp.example.com/" }))
    assert.is_nil(jwt.verify(token, { alg = "HS256", key = SECRET,
                                      iss = "https://other.example.com/" }))
    -- A list, for a migration between two issuers.
    assert.is_table(jwt.verify(token, { alg = "HS256", key = SECRET,
      iss = { "https://old.example.com/", "https://idp.example.com/" } }))
  end)

  it("refuses when an issuer was required and the token carries none", function()
    -- The unverified claim is a refusal, not a warning: a caller who reads
    -- `claims.sub` after a warning has already trusted the token.
    local out, why = jwt.verify(good(), { alg = "HS256", key = SECRET,
                                          iss = "https://idp.example.com/" })
    assert.is_nil(out)
    assert.is_truthy(why:find("no iss", 1, true), why)
  end)

  it("matches aud whether the token carries one or a list", function()
    local api = "https://api.example.com"
    assert.is_table(jwt.verify(good { aud = api },
                               { alg = "HS256", key = SECRET, aud = api }))
    assert.is_table(jwt.verify(good { aud = { "https://other", api } },
                               { alg = "HS256", key = SECRET, aud = api }))
    assert.is_nil(jwt.verify(good { aud = { "https://other" } },
                             { alg = "HS256", key = SECRET, aud = api }))
  end)

  it("REFUSES a token that names an audience when the caller did not", function()
    -- This is the replay that ignoring `aud` allows: the user obtains a
    -- perfectly legitimate token for another relying party of the same
    -- identity provider -- which is what an IdP is for -- and sends it here.
    -- The claim naming the intended service was in the token all along.
    local token = good { aud = "https://someone-elses-api.example.com" }
    local out, why = jwt.verify(token, { alg = "HS256", key = SECRET })
    assert.is_nil(out, "a token minted for another service was accepted")
    assert.is_truthy(why:find("audience", 1, true), why)

    -- Opting out is possible and it has to be written down.
    assert.is_table(jwt.verify(token, { alg = "HS256", key = SECRET,
                                        aud = false }))
  end)

  it("refuses when an audience was required and the token carries none",
    function()
      local out = jwt.verify(good(), { alg = "HS256", key = SECRET,
                                       aud = "https://api.example.com" })
      assert.is_nil(out)
    end)

  it("requires the claims the caller named", function()
    local out, why = jwt.verify(good(), { alg = "HS256", key = SECRET,
                                          require = { "sub", "email" } })
    assert.is_nil(out)
    assert.is_truthy(why:find("email", 1, true), why)

    assert.is_table(jwt.verify(good { email = "a@b.c" },
                               { alg = "HS256", key = SECRET,
                                 require = { "sub", "email" } }))
  end)
end)

describe("keys by kid, for an issuer that rotates", function()
  local OLD, NEW = crypto.token(32), crypto.token(32)

  it("picks the key the header names", function()
    local token = forge({ alg = "HS256", kid = "2026-08" }, claims(),
                        hmac_with(NEW))
    assert.is_table(jwt.verify(token, { alg = "HS256",
                                        keys = { ["2026-07"] = OLD,
                                                 ["2026-08"] = NEW } }))
  end)

  it("refuses an unknown kid instead of falling back to a default", function()
    -- A verifier that tries a default when the kid is unknown accepts tokens
    -- signed with a retired key, which is the thing rotation was for.
    local token = forge({ alg = "HS256", kid = "2020-01" }, claims(),
                        hmac_with(OLD))
    local out, why = jwt.verify(token, { alg = "HS256",
                                         keys = { ["2026-08"] = NEW } })
    assert.is_nil(out)
    assert.is_truthy(why:find("no key is configured", 1, true), why)
  end)

  it("refuses a token with no kid when configured by kid", function()
    local out, why = jwt.verify(good(), { alg = "HS256",
                                          keys = { ["2026-08"] = NEW } })
    assert.is_nil(out)
    assert.is_truthy(why:find("kid", 1, true), why)
  end)
end)

-- =========================================================================

describe("the function that is not here", function()
  it("exposes no way to issue, sign or mint a token", function()
    -- Not decoration. `akkar/session.lua` keeps sessions on the server because
    -- a self-contained token cannot be revoked before it expires -- log out,
    -- change password, ban an account -- and `akkar/crypto.lua` wrote down in
    -- advance that if JWT ever arrived it would arrive with `verify` and no
    -- `issue`, "so nobody reaches for it to keep a user logged in".
    --
    -- The only thing that keeps that promise is the absence of the function.
    -- An `issue` added here for convenience would be used for a login within a
    -- week, and this assertion is what makes adding it a deliberate act.
    for _, name in ipairs { "issue", "sign", "encode", "new", "create",
                            "mint", "token", "refresh" } do
      assert.is_nil(jwt[name],
                    "akkar.jwt must not expose " .. name .. "; see the " ..
                    "argument in akkar/session.lua")
    end
  end)

  it("says what it is for, in the module the docstring points at", function()
    -- The honest use is a short-lived assertion issued by SOMEBODY ELSE, which
    -- is a thing you verify. Checked as text because a docstring that stops
    -- being true is worse than one that was never written.
    --
    -- Whitespace is collapsed first because the assertion is about the
    -- SENTENCE, not about where a line happened to wrap. Matching the raw text
    -- makes the test fail the next time somebody reflows a paragraph, and a
    -- test that punishes formatting is a test people delete.
    local file = assert(io.open("akkar/jwt.lua"))
    local source = file:read "a":gsub("%s+", " ")
    file:close()

    assert.is_truthy(source:find("cannot be revoked before it expires", 1, true))
    assert.is_truthy(source:find("short-lived assertion", 1, true))
    assert.is_truthy(source:find("identity provider", 1, true))
    assert.is_truthy(source:find("You did not mint it", 1, true))
  end)
end)
