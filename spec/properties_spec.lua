--[[
Properties — statements that must hold for EVERY schedule, not for the ones
somebody thought to write down.

The pool and the tenant scope are where this project's two worst failure modes
live, and both were violated inside the last two days:

  * two callers of `get()` received the same object, because `put` was not
    idempotent;
  * a request abandoned inside `open` took a slot out of the pool for the life
    of the process.

Neither was found by an example test, because an example encodes a schedule
somebody imagined. These generate schedules instead, check the invariants after
every single step, and print the seed when they fail -- so a counterexample is
a command to re-run rather than a story about a Tuesday.

Deliberately NOT a quickcheck dependency. A seeded generator and a list of
invariants is sixty lines and has no second use in a library this size.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local Pool    = require "akkar.pool"
local sql     = require "akkar.sql"
local scope   = require "akkar.scope"
local memory  = require "akkar.db.memory"
local cqueues = require "cqueues"

--- A generator this file owns, so seeding it cannot reach any other spec.
--- `spec/fuzz_spec.lua` learned that the hard way: seeding the global one made
--- three later files deterministic and broke their key isolation.
---
--- NOW `akkar.random.seeded`, WHICH IS AN OBJECT AND NOT A GLOBAL, so that
--- property survives -- `random.set` is the thing that would reach other
--- specs, and nothing here calls it. What changes is that the project has one
--- generator instead of two, and that a seed printed by a failure here means
--- the same sequence on every interpreter.
---
--- AND THE ONE IT REPLACES WAS NOT CHOOSING. `(state * 1103515245 + 12345)
--- % 2^31` is a textbook LCG, and bit k of one has period 2^(k+1) -- so its
--- lowest bit alternates. `% n` reads the low bits. Measured, seed 7919:
---
---     old, n = 2:   1 2 1 2 1 2 1 2 1 2 1 2
---     new, n = 2:   2 1 2 2 2 2 1 1 2 2 2 1
---
--- Every binary decision these schedules made was ALTERNATING, not random.
--- The file's own opening argues that an example test "encodes a schedule
--- somebody imagined" -- and a schedule that alternates is one of those. The
--- defects it found were real; the space it searched was a fraction of what
--- it looked like.
local akkar_random = require "akkar.random"

local function generator(seed)
  local source = akkar_random.seeded(seed)
  return function(n) return source.integer(1, n) end
end

-- ============================================================== the pool
local function invariants(pool, where)
  local stats = pool:stats()

  local seen = {}
  for _, resource in ipairs(pool.idle) do
    assert(not seen[resource],
      where .. ": the same resource is in the idle set twice")
    seen[resource] = true
  end

  assert(stats.live + stats.reserved <= stats.size,
    ("%s: live=%d reserved=%d exceeds size=%d")
      :format(where, stats.live, stats.reserved, stats.size))
  assert(stats.idle <= stats.live,
    ("%s: idle=%d exceeds live=%d"):format(where, stats.idle, stats.live))
  assert(stats.live >= 0 and stats.idle >= 0,
    where .. ": a count went negative")
end

describe("the pool, under schedules nobody wrote", function()
  local function run_schedule(seed, steps)
    local random = generator(seed)
    local opened = 0

    local pool = Pool.new(function()
      opened = opened + 1
      return { id = opened, close = function() end }
    end, 3, function(resource) return not resource.broken end)

    local held = {}

    for step = 1, steps do
      local where = ("seed %d, step %d"):format(seed, step)
      local action = random(10)

      if action <= 4 then                       -- take one
        if #held < 6 then
          local cq = cqueues.new()
          cq:wrap(function()
            local ok, resource = pcall(function() return pool:get() end)
            if ok then held[#held + 1] = resource end
          end)
          cq:loop(0.05)                          -- may park; that is a schedule too
        end

      elseif action <= 7 then                   -- give one back
        if #held > 0 then
          local index = random(#held)
          local resource = table.remove(held, index)
          pool:put(resource)
        end

      elseif action == 8 then                   -- give the SAME one back twice
        if #held > 0 then
          local resource = held[random(#held)]
          pool:put(resource)
          pool:put(resource)
        end

      elseif action == 9 then                   -- one goes bad while checked out
        if #held > 0 then
          local resource = table.remove(held, random(#held))
          resource.broken = true
          pool:put(resource)
        end

      else                                      -- abandon one entirely
        if #held > 0 then table.remove(held, random(#held)) end
      end

      invariants(pool, where)
    end

    return pool
  end

  it("holds its invariants over a thousand random steps, on ten seeds", function()
    for seed = 1, 10 do
      local ok, why = pcall(run_schedule, seed * 7919, 100)
      assert.is_true(ok, tostring(why))
    end
  end)

  it("never hands the same resource to two holders", function()
    -- The one that actually happened. `put` twice used to put it in `idle`
    -- twice, and two `get()` calls returned the same table -- two requests on
    -- one connection, the worst thing this file can produce.
    for seed = 1, 5 do
      local random = generator(seed * 104729)
      local pool = Pool.new(function() return { close = function() end } end, 3)

      local out = {}
      for _ = 1, 60 do
        if random(2) == 1 and #out < 3 then
          local cq = cqueues.new()
          cq:wrap(function()
            local ok, r = pcall(function() return pool:get() end)
            if ok then
              for _, already in ipairs(out) do
                assert(already ~= r, "seed " .. seed .. ": get() returned a resource " ..
                                     "that another holder already had")
              end
              out[#out + 1] = r
            end
          end)
          cq:loop(0.05)
        elseif #out > 0 then
          local r = table.remove(out, random(#out))
          pool:put(r)
          pool:put(r)                            -- twice, on purpose
        end
      end
    end
  end)
end)

-- ============================================================== the scope
describe("the tenant scope, over generated queries", function()
  --- Builds a random-but-valid query. The point is not the SQL; it is that
  --- whatever is built, the tenant predicate survives it.
  local function random_query(random)
    local columns = { "*", "id", "id, name", "count(*)" }
    local tables  = { "documents", "invoices", "notes" }
    local q = sql.select(columns[random(#columns)]):from(tables[random(#tables)])

    for _ = 1, random(4) - 1 do
      local which = random(3)
      if which == 1 then q:where("name like ?", "a%")
      elseif which == 2 then q:where("created_at > ?", 1755000000)
      else q:limit(random(50)) end
    end
    return q
  end

  it("puts the tenant on every query, however it was built", function()
    -- akkar's most distinctive claim: it is impossible to issue a query
    -- without tenant scope. That was checked by examples; this checks it over
    -- two hundred generated shapes.
    for seed = 1, 8 do
      local random = generator(seed * 15485863)
      local db = memory.new()
      db:on(".*", {})
      local scoped = scope.wrap(db, "project_id", 42)

      for step = 1, 25 do
        local ok, why = pcall(function()
          return scoped:many(random_query(random))
        end)
        assert.is_true(ok, ("seed %d step %d: %s"):format(seed, step, tostring(why)))
      end

      for _, entry in ipairs(db.log) do
        assert.is_truthy(entry.sql:find("project_id", 1, true),
          ("seed %d: a query went out with no tenant predicate: %s")
            :format(seed, entry.sql))
      end
      assert.is_true(#db.log > 0, "no query was recorded at all")
    end
  end)

  it("refuses raw SQL no matter how it is dressed up", function()
    -- A string cannot be scoped without parsing it, and a SQL parser inside
    -- the framework would be a second, worse database. The refusal is the
    -- feature, and it must not have an accidental door.
    local db = memory.new()
    db:on(".*", {})
    local scoped = scope.wrap(db, "project_id", 42)

    local attempts = {
      "select * from documents",
      "SELECT * FROM documents",
      "  select 1  ",
      "select * from documents where project_id = 42",   -- even a correct one
      "",
    }

    for _, raw in ipairs(attempts) do
      local ok = pcall(function() return scoped:many(raw) end)
      assert.is_false(ok, ("raw SQL was accepted: %q"):format(raw))
    end

    assert.equal(0, #db.log,
      "a refused query still reached the database")
  end)
end)
