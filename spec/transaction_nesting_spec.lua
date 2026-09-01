--[[
Nested transactions.

`db:transaction` had no nesting detection and no SAVEPOINT, so a helper that
owns a transaction called from a handler that owns a bigger one produced a
statement stream Postgres reads as one flat transaction that ends early:

    begin | begin | ... | commit | ... | rollback

The second `begin` is a warning and no transaction. The inner `commit` ends the
OUTER one, every statement after it autocommits, and the outer `rollback` is a
no-op warning. Reproduced against a real server: an outer transaction that
raised left all three rows committed, with `in_transaction` false, `broken`
false, and the pool judging the connection fit for reuse.

That shape is the most ordinary refactor there is -- `charge()` inside
`place_order()` -- and on this branch it is money.

The in-memory fake counted a `depth` it never used and reported a clean
rollback, so it disagreed with the real adapter about exactly this and no
memory-backed test could catch it. Both halves are pinned here, and the last
test asserts they agree.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local db     = require "akkar.db"
local memory = require "akkar.db.memory"

local CONFIG = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 2,
}

local function reachable()
  local ok, conn = pcall(db.connect { host = CONFIG.host, port = CONFIG.port,
    database = CONFIG.database, user = CONFIG.user, password = CONFIG.password,
    pool_size = 0 })
  if ok then conn:close() end
  return ok
end

-- Every statement the adapter sends, so the fix can be asserted on the wire
-- rather than only on its effects.
local function recording(conn)
  local issued = {}
  local real = conn.query
  conn.query = function(self, sql, ...)
    if type(sql) == "string" then issued[#issued + 1] = sql end
    return real(self, sql, ...)
  end
  return issued
end

if not reachable() then
  describe("nested transactions (integration)", function()
    pending("Postgres is not reachable on 127.0.0.1:55432; skipping")
  end)
else

describe("nested transactions against a real Postgres", function()
  local factory, conn

  before_each(function()
    factory = db.connect(CONFIG)
    conn = factory()
    conn:exec "drop table if exists akkar_nesting_spec"
    conn:exec "create table akkar_nesting_spec (tag text)"
  end)

  after_each(function()
    if conn then
      conn:exec "drop table if exists akkar_nesting_spec"
      conn:close()
    end
  end)

  local function tags()
    local out = {}
    for _, row in ipairs(conn:many "select tag from akkar_nesting_spec order by tag") do
      out[#out + 1] = row.tag
    end
    return out
  end

  it("rolls back a nested transaction's writes when the outer one raises", function()
    local issued = recording(conn)

    local ok = pcall(function()
      conn:transaction(function(outer)                    -- place_order()
        outer:exec("insert into akkar_nesting_spec values ($1)", "outer-before")
        outer:transaction(function(inner)                 -- charge()
          inner:exec("insert into akkar_nesting_spec values ($1)", "inner")
        end)
        outer:exec("insert into akkar_nesting_spec values ($1)", "outer-after")
        error "payment declined"
      end)
    end)

    assert.is_false(ok)
    -- Before the fix: { "inner", "outer-after", "outer-before" }.
    assert.same({}, tags())
    local begins, commits = 0, 0
    for _, sql in ipairs(issued) do
      if sql == "begin" then begins = begins + 1 end
      if sql == "commit" then commits = commits + 1 end
    end
    assert.equal(1, begins, "a second BEGIN was sent inside an open transaction")
    assert.equal(0, commits, "the nested block committed the outer transaction")
    assert.is_truthy(table.concat(issued, " | "):find("savepoint akkar_sp_2", 1, true),
                     "the nested block did not open a savepoint")
  end)

  it("lets the outer transaction survive a helper that failed", function()
    -- The point of a savepoint rather than a refusal: `charge()` can fail,
    -- `place_order()` can catch it, and the order still commits without the
    -- charge. A failed statement aborts the whole transaction on Postgres
    -- unless something rolls back to a savepoint.
    conn:transaction(function(outer)
      outer:exec("insert into akkar_nesting_spec values ($1)", "order")
      local charged = pcall(function()
        outer:transaction(function(inner)
          inner:exec("insert into akkar_nesting_spec values ($1)", "charge")
          error "card declined"
        end)
      end)
      assert.is_false(charged)
      outer:exec("insert into akkar_nesting_spec values ($1)", "receipt")
    end)

    assert.same({ "order", "receipt" }, tags())
  end)

  it("recovers the outer transaction from a nested statement error", function()
    -- A unique violation inside the helper aborts the transaction; without the
    -- savepoint every later statement fails with "current transaction is
    -- aborted" and the whole order is lost.
    conn:exec "create unique index akkar_nesting_uniq on akkar_nesting_spec (tag)"
    conn:transaction(function(outer)
      outer:exec("insert into akkar_nesting_spec values ($1)", "order")
      local ok = pcall(function()
        outer:transaction(function(inner)
          inner:exec("insert into akkar_nesting_spec values ($1)", "order")
        end)
      end)
      assert.is_false(ok)
      outer:exec("insert into akkar_nesting_spec values ($1)", "receipt")
    end)

    assert.same({ "order", "receipt" }, tags())
  end)

  it("leaves the connection fit for reuse after a nested rollback", function()
    pcall(function()
      conn:transaction(function(outer)
        outer:transaction(function(inner)
          inner:exec("insert into akkar_nesting_spec values ($1)", "x")
        end)
        error "no"
      end)
    end)

    assert.is_false(conn.in_transaction)
    assert.is_falsy(conn.broken)
    assert.equal(0, conn.tx_depth)
    assert.equal("STILL-GOOD", conn:one("select 'STILL-GOOD' as who").who)
  end)

  it("nests three deep", function()
    pcall(function()
      conn:transaction(function(a)
        a:exec("insert into akkar_nesting_spec values ($1)", "a")
        a:transaction(function(b)
          b:exec("insert into akkar_nesting_spec values ($1)", "b")
          b:transaction(function(c)
            c:exec("insert into akkar_nesting_spec values ($1)", "c")
          end)
        end)
        error "no"
      end)
    end)
    assert.same({}, tags())
  end)
end)

end

describe("the in-memory adapter's transactions", function()
  it("issues savepoints for a nested block, like the real adapter", function()
    local fake = memory.new():on("insert into", { id = 1 })

    pcall(function()
      fake:transaction(function(outer)
        outer:exec "insert into orders values (1)"
        outer:transaction(function(inner)
          inner:exec "insert into ledger values (1)"
        end)
        error "declined"
      end)
    end)

    local statements = {}
    for _, call in ipairs(fake.log) do statements[#statements + 1] = call.sql end
    local wire = table.concat(statements, " | ")

    -- Before the fix the fake sent `begin | ... | begin | ... | commit | ...
    -- | rollback` and reported a clean rollback, which is the thing the real
    -- adapter does NOT do.
    assert.equal(1, fake:count "^begin$")
    assert.is_truthy(wire:find("savepoint akkar_sp_2", 1, true))
    assert.equal(0, fake:count "^commit$", "the nested block committed")
    assert.equal(1, fake:count "^rollback$")
    assert.is_true(fake.rolled_back)
    assert.is_nil(fake.committed)
    assert.equal(0, fake.depth)
  end)

  it("rolls the nested block back to its savepoint and carries on", function()
    local fake = memory.new():on("insert into", { id = 1 })

    fake:transaction(function(outer)
      outer:exec "insert into orders values (1)"
      assert.is_false(pcall(function()
        outer:transaction(function(inner)
          inner:exec "insert into ledger values (1)"
          error "declined"
        end)
      end))
      outer:exec "insert into receipts values (1)"
    end)

    assert.is_true(fake:received "rollback to savepoint akkar_sp_2")
    assert.is_true(fake.committed)
    assert.is_nil(fake.rolled_back)
  end)
end)
