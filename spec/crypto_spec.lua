--[[
akkar.crypto — the four mistakes, checked.

Not "does SHA-256 produce the right digest" — OpenSSL's own suite answers that
and repeating it here would be theatre. What is checked is the part akkar
wrote: that the comparison is constant time, that the password format
round-trips and carries its own cost, that nothing reaches for `math.random`,
and that raising the cost later does not lock anybody out.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local crypto = require "akkar.crypto"

describe("akkar.crypto", function()
  describe("randomness", function()
    it("does not repeat itself", function()
      local seen = {}
      for _ = 1, 200 do
        local token = crypto.token(16)
        assert.is_nil(seen[token], "the CSPRNG produced a duplicate")
        seen[token] = true
      end
    end)

    it("produces the requested number of bytes", function()
      assert.equal(32, #crypto.random(32))
      assert.equal(64, #crypto.token(32))       -- hex doubles it
    end)

    it("is not affected by seeding Lua's PRNG", function()
      -- The failure this catches: someone swapping `openssl.rand` for
      -- `math.random` because it was simpler. A seeded `math.random` produces
      -- the same sequence twice, and a session id from it is guessable.
      math.randomseed(42)
      local first = crypto.token(16)
      math.randomseed(42)
      local second = crypto.token(16)
      assert.are_not.equal(first, second,
        "tokens repeat when Lua's PRNG is reseeded, so they come from it")
    end)
  end)

  describe("constant-time comparison", function()
    it("agrees with equality on the answer", function()
      assert.is_true(crypto.equal("abc", "abc"))
      assert.is_false(crypto.equal("abc", "abd"))
      assert.is_false(crypto.equal("abc", "abcd"))
      assert.is_false(crypto.equal("", "a"))
      assert.is_true(crypto.equal("", ""))
    end)

    it("refuses anything that is not a string, rather than raising", function()
      -- A comparison that raises on nil is a comparison somebody wraps in
      -- pcall and gets wrong. `nil` is simply not equal to a secret.
      assert.is_false(crypto.equal(nil, "a"))
      assert.is_false(crypto.equal("a", nil))
      assert.is_false(crypto.equal(42, "42"))
    end)

    it("does not return early on the first differing byte", function()
      -- Timing cannot be asserted reliably on a shared machine, so what is
      -- checked is the property that makes early return impossible: the
      -- result depends on every byte. Flipping the LAST byte of a long string
      -- must be detected, which a loop that stopped at the first difference
      -- would also do -- so the real guard is the implementation reading all
      -- of it, and this pins the observable half.
      local a = string.rep("x", 4096)
      local b = string.rep("x", 4095) .. "y"
      assert.is_false(crypto.equal(a, b))
      assert.is_true(crypto.equal(a, string.rep("x", 4096)))
    end)
  end)

  describe("hmac", function()
    it("verifies its own signature and rejects a forged one", function()
      local key, data = "secret-key", "the message"
      local sig = crypto.hmac(key, data)

      assert.is_true(crypto.hmac_verify(key, data, sig))
      assert.is_false(crypto.hmac_verify("other-key", data, sig))
      assert.is_false(crypto.hmac_verify(key, "the messag", sig))
      assert.is_false(crypto.hmac_verify(key, data, sig:sub(1, -2) .. "\0"))
    end)

    it("is deterministic for the same key and data", function()
      assert.equal(crypto.hmac("k", "d"), crypto.hmac("k", "d"))
    end)
  end)

  describe("passwords", function()
    -- Deliberately few iterations in these tests. The real default is 600,000
    -- and takes tens of milliseconds; a suite that paid that on every example
    -- would be a suite people skip.
    local FAST = { iterations = 1000 }

    it("round-trips", function()
      local stored = crypto.hash_password("correct horse", FAST)
      assert.is_true((crypto.verify_password("correct horse", stored, FAST)))
      assert.is_false((crypto.verify_password("wrong horse", stored, FAST)))
    end)

    it("salts, so the same password hashes differently every time", function()
      -- Without this a stolen table shows which accounts share a password,
      -- and one cracked hash unlocks all of them.
      local a = crypto.hash_password("same", FAST)
      local b = crypto.hash_password("same", FAST)
      assert.are_not.equal(a, b)
      assert.is_true((crypto.verify_password("same", a, FAST)))
      assert.is_true((crypto.verify_password("same", b, FAST)))
    end)

    it("carries its own cost, so it can be raised later", function()
      local stored = crypto.hash_password("pw", { iterations = 1000 })
      assert.is_truthy(stored:match "^pbkdf2%-sha256%$1000%$")

      -- Verifying against a HIGHER current default still succeeds -- nobody is
      -- locked out -- and reports that the hash should be replaced.
      local ok, needs_rehash = crypto.verify_password("pw", stored,
                                                      { iterations = 5000 })
      assert.is_true(ok)
      assert.is_true(needs_rehash, "a stale iteration count was not reported")

      -- And a hash already at the current cost does not ask to be redone.
      local current = crypto.hash_password("pw", { iterations = 5000 })
      local ok2, again = crypto.verify_password("pw", current, { iterations = 5000 })
      assert.is_true(ok2)
      assert.is_false(again)
    end)

    it("refuses a hash it does not recognise instead of accepting it", function()
      -- The dangerous failure: an unparseable hash treated as a match. Every
      -- one of these must be false.
      for _, bad in ipairs {
        "", "not-a-hash", "md5$1$aa$bb", "pbkdf2-sha256$notanumber$aa$bb",
        "pbkdf2-sha256$1000$$", "pbkdf2-sha256$1000$zz$bb",
      } do
        assert.is_false((crypto.verify_password("pw", bad, FAST)),
          "accepted a malformed hash: " .. bad)
      end
      assert.is_false((crypto.verify_password("pw", nil, FAST)))
      assert.is_false((crypto.verify_password("pw", 42, FAST)))
    end)

    it("does not accept the stored hash as the password", function()
      -- A real defect class: an implementation that compares the input to the
      -- stored string somewhere along the way lets the contents of a leaked
      -- database log everybody in.
      local stored = crypto.hash_password("pw", FAST)
      assert.is_false((crypto.verify_password(stored, stored, FAST)))
    end)
  end)

  describe("hex", function()
    it("round-trips arbitrary bytes, including zero", function()
      local raw = "\0\1\2\255\254 abc\n"
      assert.equal(raw, crypto.from_hex(crypto.to_hex(raw)))
    end)

    it("refuses odd-length input rather than dropping a nibble", function()
      local ok, why = crypto.from_hex "abc"
      assert.is_nil(ok)
      assert.is_truthy(why)
    end)
  end)
end)
