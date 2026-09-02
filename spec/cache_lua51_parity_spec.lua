--[[
The memory cache answers `INCR` and runs scripts the way Redis does.

Two divergences, one file, because they are the same defect wearing two hats:
the fake was permissive where the server is strict, so a suite could be green
about code the server refuses.

## `INCR`

Measured before the fix: `set("hits", "abc")` then `incr` returned **1**,
silently zeroing a live value, and `set("f", "1.5")` then `incr` returned
**2.5**. Redis answers `ERR value is not an integer or out of range` to both.
A rate limiter or a counter tested against that fake passed here and 500s
there.

`tonumber` is not Redis's parser. `string2ll` is stricter in six ways, and
every case in the table below was read off redis 7.4.7 rather than recalled.

## The script sandbox

Redis embeds Lua 5.1; this process is Lua 5.4. So `//`, `&`, `table.unpack`
and `math.tointeger` all worked in the suite and are refused by the server --
`EVAL "return 7//2" 0` answers `ERR Error compiling script`.

The quietest case is the one that matters most: `tostring(10/2)` is "5.0" in
5.4 and "5" in 5.1, so a script building a key out of a number wrote a
DIFFERENT STRING on the two backends with nothing failing on either.

## How it is asserted

One table of cases, driven over both adapters, the shape
`spec/cache_fault_parity_spec.lua` and `spec/capacity_spec.lua` already use.
The memory half never skips -- if the fix is reverted this file must go red on
a machine with nothing installed -- and the server half is added when there is
a server to add it from.

The two adapters do not format an error identically and are not asked to:
`akkar/redis.lua:command` prefixes every message it passes up with `redis: `,
and the server appends the script's sha to a failure inside `EVAL`. `reply_of`
strips both, so what is compared is the REPLY, which is the thing both stores
are answerable for.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local memory  = require "akkar.cache.memory"
local redis   = require "akkar.redis"
local cqueues = require "cqueues"

--- The server's reply, with the transport's decoration taken off.
local function reply_of(err)
  local text = tostring(err)
  text = text:gsub("^redis: ", "")
  text = text:gsub(" script: %x+, on @user_script.*$", "")
  return text
end

local function reachable()
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if not ok then return false end
  local alive = pcall(function() return conn:ping() end)
  conn:close()
  return alive
end

--- `run(fn)` hands `fn` something that answers `command(...)` and a namespace
--- to build keys in. The two adapters differ in how they are opened and in
--- nothing else the cases can see.
local function with_memory(fn)
  return fn(memory.new(), "spec:")
end

local function with_redis(fn)
  local failure, result
  local cq = cqueues.new()
  cq:wrap(function()
    local conn   = redis.connect { pool_size = 0 }()
    local prefix = ("spec:lua51:%d:"):format(math.random(1, 1e9))
    local ok, res = pcall(fn, conn, prefix)
    pcall(function()
      conn:command("EVAL",
        "local n = redis.call('KEYS', ARGV[1]) " ..
        "for i = 1, #n do redis.call('DEL', n[i]) end return #n", 0, prefix .. "*")
    end)
    conn:close()
    if ok then result = res else failure = res end
  end)
  assert(cq:loop(30))
  if failure then error(failure, 0) end
  return result
end

local stores = { { name = "akkar.cache.memory", run = with_memory } }
if reachable() then
  stores[#stores + 1] = { name = "akkar.redis", run = with_redis }
else
  describe("akkar.redis (Lua 5.1 parity)", function()
    pending "Redis is not reachable on 127.0.0.1:6379; skipping the server half"
  end)
end

-- ==================================================================== INCR

local NOT_AN_INTEGER = "ERR value is not an integer or out of range"

-- Every one of these is a value `tonumber` accepts and `string2ll` does not.
local REFUSED = {
  { "abc",                  "not a number at all" },
  { "1.5",                  "a decimal point" },
  { "1.0",                  "a decimal point, even a harmless one" },
  { "1e3",                  "an exponent" },
  { "0x10",                 "hexadecimal" },
  { " 1",                   "leading space" },
  { "1 ",                   "trailing space" },
  { "+1",                   "an explicit plus" },
  { "01",                   "a leading zero" },
  { "-0",                   "negative zero" },
  { "",                     "the empty string" },
  { "9223372036854775808",  "one past the top of a signed 64-bit integer" },
}

local ACCEPTED = {
  { "41", 42 }, { "0", 1 }, { "-2", -1 }, { "-1", 0 },
  { "9223372036854775806", 9223372036854775807 },
}

for _, store in ipairs(stores) do
  describe(store.name .. " counts only what Redis calls an integer", function()
    for _, case in ipairs(REFUSED) do
      local value, why = case[1], case[2]
      it("refuses to INCR " .. why, function()
        store.run(function(cache, prefix)
          local key = prefix .. "incr:" .. why:gsub("%W", "-")
          cache:command("SET", key, value)

          local ok, err = pcall(function() return cache:command("INCR", key) end)
          assert.is_false(ok,
            ("INCR answered %s for a value of %q"):format(tostring(err), value))
          assert.equal(NOT_AN_INTEGER, reply_of(err))

          -- AND IT LEFT THE VALUE ALONE. The old behaviour did not merely
          -- answer wrongly, it OVERWROTE: "abc" became "1". A counter that
          -- destroys the thing it cannot read is worse than one that refuses.
          assert.equal(value, cache:command("GET", key))
        end)
      end)
    end

    for _, case in ipairs(ACCEPTED) do
      local value, expected = case[1], case[2]
      it(("counts %s up to %s"):format(value, expected), function()
        store.run(function(cache, prefix)
          local key = prefix .. "incr:ok:" .. value:gsub("%W", "-")
          cache:command("SET", key, value)
          assert.equal(expected, tonumber(cache:command("INCR", key)))
        end)
      end)
    end

    it("starts an absent key at one", function()
      store.run(function(cache, prefix)
        assert.equal(1, tonumber(cache:command("INCR", prefix .. "incr:fresh")))
      end)
    end)

    it("refuses the increment that would overflow", function()
      store.run(function(cache, prefix)
        local key = prefix .. "incr:ceiling"
        cache:command("SET", key, "9223372036854775807")
        local ok, err = pcall(function() return cache:command("INCR", key) end)
        assert.is_false(ok, "INCR went past the top of a signed 64-bit integer")
        assert.equal("ERR increment or decrement would overflow", reply_of(err))
      end)
    end)

    it("applies the same rule to HINCRBY", function()
      -- The identical defect one command along, and the reply is not the
      -- identical text: Redis says `hash value` for the stored side.
      store.run(function(cache, prefix)
        local key = prefix .. "hincrby"
        cache:command("HSET", key, "f", "abc")
        local ok, err = pcall(function() return cache:command("HINCRBY", key, "f", 1) end)
        assert.is_false(ok)
        assert.equal("ERR hash value is not an integer", reply_of(err))
      end)
    end)
  end)
end

-- ============================================================ the sandbox

-- Source Redis's Lua 5.1 cannot parse. Every one of these compiles under 5.4
-- and answers `ERR Error compiling script` on the server.
local WILL_NOT_COMPILE = {
  { "return 7 // 2",        "integer division" },
  { "return 6 & 3",         "a bitwise and" },
  { "return 6 | 3",         "a bitwise or" },
  { "return 6 ~ 3",         "a bitwise exclusive or" },
  { "return 1 << 2",        "a left shift" },
  { "return 8 >> 2",        "a right shift" },
  { "do goto out end ::out:: return 1", "a goto label" },
}

-- Names 5.4 has and Redis's 5.1 does not, plus the two ways a script can
-- reach for a global that is not there.
local WILL_NOT_RUN = {
  { "return table.unpack({1, 2})",     "table.unpack" },
  { "return math.tointeger(2.0)",      "math.tointeger" },
  { "return math.type(2)",             "math.type" },
  { "return math.maxinteger + 1",      "math.maxinteger" },
  { "return string.pack('i4', 1)",     "string.pack" },
  { "return table.move({1}, 1, 1, 2)", "table.move" },
  { "return nosuchglobal",             "a global that does not exist" },
  { "leaked = 1 return 1",             "a global assignment" },
}

-- What both must answer the same. The first three are the quiet case: a
-- number crossing into a key or a value.
local AGREE = {
  { "return tostring(10/2)",                                   "5" },
  { "return tostring(1/3)",                                    "0.33333333333333" },
  { "redis.call('SET', KEYS[1], 10/2) return redis.call('GET', KEYS[1])",  "5" },
  { "redis.call('SET', KEYS[1], 1/7) return redis.call('GET', KEYS[1])",   "0.14285714285714285" },
  { "redis.call('SET', KEYS[1], 3.7) return redis.call('GET', KEYS[1])",   "3.7" },
  { "redis.call('SET', KEYS[1], 0.1 + 0.2) return redis.call('GET', KEYS[1])",
    "0.30000000000000004" },
  { "return _VERSION",                                         "Lua 5.1" },
  { "return unpack({7})",                                      7 },
  { "return -3.7",                                             -3 },
  { "return 3.999",                                            3 },
  { "return tostring(math.floor(7/2))",                        "3" },
}

for _, store in ipairs(stores) do
  describe(store.name .. " runs a script the way Redis 5.1 would", function()
    for _, case in ipairs(WILL_NOT_COMPILE) do
      local script, what = case[1], case[2]
      it("refuses " .. what, function()
        store.run(function(cache, prefix)
          local ok, err = pcall(function()
            return cache:command("EVAL", script, 1, prefix .. "k")
          end)
          assert.is_false(ok, what .. " ran; Redis would not have compiled it")
          assert.is_truthy(reply_of(err):match "Error compiling script",
            ("the refusal was %q, not a compile failure"):format(reply_of(err)))
        end)
      end)
    end

    for _, case in ipairs(WILL_NOT_RUN) do
      local script, what = case[1], case[2]
      it("refuses " .. what, function()
        store.run(function(cache, prefix)
          local ok = pcall(function()
            return cache:command("EVAL", script, 1, prefix .. "k")
          end)
          assert.is_false(ok, what .. " worked; it does not exist on the server")
        end)
      end)
    end

    for i, case in ipairs(AGREE) do
      local script, expected = case[1], case[2]
      it(("agrees on case %d: %s"):format(i, script), function()
        store.run(function(cache, prefix)
          local reply = cache:command("EVAL", script, 1, prefix .. "agree" .. i)
          if type(expected) == "number" then reply = tonumber(reply) end
          assert.equal(expected, reply)
        end)
      end)
    end

    it("still lets redis.pcall hand back the error redis.call raises", function()
      -- The sandbox got stricter; this must not have got stricter with it.
      -- It is the property `spec/memory_adapters_spec.lua` pins, restated
      -- here because the environment it runs in was replaced wholesale.
      store.run(function(cache, prefix)
        local reply = cache:command("EVAL", [[
          local bad = redis.pcall('INCR', KEYS[1])
          if type(bad) == 'table' and bad.err then return bad.err end
          return 'no error was reported'
        ]], 1, prefix .. "pcall")
        cache:command("SET", prefix .. "pcall", "abc")
        reply = cache:command("EVAL", [[
          local bad = redis.pcall('INCR', KEYS[1])
          if type(bad) == 'table' and bad.err then return bad.err end
          return 'no error was reported'
        ]], 1, prefix .. "pcall")
        assert.equal(NOT_AN_INTEGER, reply)
      end)
    end)
  end)
end
