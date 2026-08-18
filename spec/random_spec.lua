--[[
`akkar.random` — the seam that lets a run be replayed.

The interesting assertions here are not about the generator. A xorshift that
repeats for a seed is easy and would be worth little on its own; what this file
has to prove is that **the framework reads the seam**, which is the thing
`akkar.time` existed for years without doing -- `req.clock` was a capability an
application could fill while akkar itself called `cqueues.monotime()` directly,
and nothing noticed.

So the tests that matter are the last two: the retry backoff's jitter and the
execution id prefix, which were the only two places the framework drew a random
number, and which are now substitutable.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local random = require "akkar.random"

describe("akkar.random", function()
  it("produces the sequence the reference implementation does", function()
    -- xoshiro128++ 1.0, Blackman and Vigna, from
    -- <https://prng.di.unimi.it/xoshiro128plusplus.c>. These sixteen words
    -- were produced by an INDEPENDENT implementation of the same algorithm
    -- and the same seeding, written in another language for this purpose --
    -- so a transcription error in the Lua, a wrong constant or a state
    -- update in the wrong order, shows up here rather than as "random
    -- numbers that look random".
    --
    -- The identical sixteen were then confirmed under Lua 5.4, Lua 5.5 AND
    -- LuaJIT. That is the property `math.randomseed` cannot give at all --
    -- it seeds an implementation the standard does not pin -- and it is the
    -- reason this file exists rather than a call to it.
    local expected = {
      80372098, 2594957127, 2747729271, 1056900822,
      541662558, 1111294658, 2386477819, 3443815176,
      3593745235, 728031209, 2193223646, 2228668742,
      793195240, 94894221, 118093377, 412197174,
    }
    local source = random.seeded(42)
    for i = 1, #expected do
      assert.equal(expected[i], math.floor(source.float() * 4294967296),
        ("word %d of the reference sequence"):format(i))
    end
  end)

  it("gives the same sequence for the same seed", function()
    local a, b = random.seeded(42), random.seeded(42)
    for _ = 1, 100 do
      assert.equal(a.integer(1, 1000000), b.integer(1, 1000000))
    end
  end)

  it("gives a different sequence for a different seed", function()
    local a, b = random.seeded(42), random.seeded(43)
    local same = 0
    for _ = 1, 100 do
      if a.integer(1, 1000000) == b.integer(1, 1000000) then same = same + 1 end
    end
    -- Not "never equal": two draws from a million can collide, and asserting
    -- they cannot would make this test fail by chance about once in ten
    -- thousand runs. Ten collisions in a hundred draws is not chance.
    assert.is_true(same < 10, ("%d of 100 draws collided"):format(same))
  end)

  it("survives a zero seed", function()
    -- xorshift is stuck at zero for ever, so a seed of 0 must be replaced
    -- rather than accepted. Somebody will pass 0.
    local a = random.seeded(0)
    local seen = {}
    for _ = 1, 20 do seen[#seen + 1] = a.integer(1, 1000000) end
    local distinct = {}
    for _, v in ipairs(seen) do distinct[v] = true end
    local n = 0
    for _ in pairs(distinct) do n = n + 1 end
    assert.is_true(n > 15, "a zero seed produced a stuck sequence")
  end)

  it("stays inside the range it was given", function()
    local a = random.seeded(7)
    for _ = 1, 500 do
      local v = a.integer(3, 9)
      assert.is_true(v >= 3 and v <= 9, "out of range: " .. tostring(v))
    end
    for _ = 1, 500 do
      local f = a.float()
      assert.is_true(f >= 0 and f < 1, "out of range: " .. tostring(f))
    end
  end)

  it("puts the previous generator back", function()
    local before = random.integer(1, 1000000)
    local restore = random.set(random.seeded(99))
    assert.equal(random.seeded(99).integer(1, 1000000), random.integer(1, 1000000))
    restore()
    -- The real generator answers again; that it differs from the seeded one is
    -- not assertable, but that it RUNS is.
    assert.is_number(random.integer(1, 1000000))
    assert.is_number(before)
  end)

  -- ----------------------------------------------------------------- seams

  it("is what the retry backoff draws its jitter from", function()
    -- `delay_for` is exported as a plain function, so this exercises the
    -- computation itself rather than a queue built around it.
    local jobs = require "akkar.jobs"
    local backoff = { first = 10, factor = 2, max = 300 }

    local function delays_under(seed)
      local restore = random.set(random.seeded(seed))
      local out = {}
      for attempt = 1, 5 do out[attempt] = jobs.delay_for(attempt, backoff) end
      restore()
      return out
    end

    local first, again = delays_under(1234), delays_under(1234)
    assert.same(first, again)

    -- And it is really the jitter moving, not a constant: a different seed
    -- has to produce different delays, or the seam is there and unused.
    local other = delays_under(5678)
    local identical = true
    for i = 1, #first do if first[i] ~= other[i] then identical = false end end
    assert.is_false(identical, "the seed did not change the jitter")
  end)

  it("is what the execution id prefix is drawn from", function()
    -- The prefix is per-process and computed at load, so this asserts the
    -- CALL rather than the value: reloading `akkar.execution` under a seeded
    -- generator twice must produce the same prefix.
    local function prefix_under(seed)
      local restore = random.set(random.seeded(seed))
      package.loaded["akkar.execution"] = nil
      local execution = require "akkar.execution"
      local id = execution.id()
      restore()
      return id:sub(1, 8)
    end

    local a = prefix_under(2024)
    local b = prefix_under(2024)
    local c = prefix_under(1999)

    assert.equal(a, b)
    assert.are_not.equal(a, c, "the seed did not reach the id prefix")

    -- Left as the real module found it, so no later spec inherits a seeded
    -- prefix from this one.
    package.loaded["akkar.execution"] = nil
    require "akkar.execution"
  end)
end)
