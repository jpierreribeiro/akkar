--[[
The in-memory adapter matched SQL as a Lua pattern.

Every needle a test author writes here is a piece of the SQL itself, and SQL is
full of Lua pattern magic. Matched as a pattern, `(order_id, amount)` is a
capture of the literal text between the parentheses, so it matches SQL that has
no parentheses in it at all:

    db:count "insert into ledger (order_id, amount)"   ->   0

for a query that WAS issued. An `assert.equal(0, ...)` meaning "we did not
double-charge" then passes unconditionally -- a test proving the opposite of
what it says, which is the one thing a fake must never do.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local memory = require "akkar.db.memory"

describe("matching a query against a needle", function()
  local function charged(times)
    local fake = memory.new():on("insert into ledger", { id = 1 })
    for _ = 1, times do
      fake:exec("insert into ledger (order_id, amount) values ($1, $2)", 1, 500)
    end
    return fake
  end

  it("counts a query whose text contains pattern magic", function()
    assert.equal(1, charged(1):count "insert into ledger (order_id, amount)")
    assert.equal(2, charged(2):count "insert into ledger (order_id, amount)")
  end)

  it("reports it as received", function()
    assert.is_true(charged(1):received "insert into ledger (order_id, amount)")
  end)

  it("does not count a query that was never issued", function()
    -- The assertion above is only worth anything if this one still holds.
    assert.equal(0, charged(1):count "insert into refunds (order_id, amount)")
    assert.is_false(charged(1):received "insert into refunds (order_id, amount)")
  end)

  it("does not raise on a needle that is not a valid pattern", function()
    -- `"values ($1"` used to come back as "unfinished capture", thrown at the
    -- test from inside the fake.
    assert.equal(1, charged(1):count "values ($1, $2)")
  end)

  it("still honours a deliberate Lua pattern", function()
    local fake = memory.new()
      :on("^insert into users", { id = 42 })
      :on("select .* from users", { id = 1, name = "ada" })

    assert.equal(42, fake:one("insert into users (name) values ($1)", "ada").id)
    assert.equal("ada", fake:one("select id, name from users where id = $1", 1).name)
    assert.equal(1, fake:count "^insert into users")
  end)

  it("programs a response for a query with parentheses in it", function()
    local fake = memory.new():on("insert into ledger (order_id, amount)", { id = 7 })
    assert.equal(7, fake:one("insert into ledger (order_id, amount) values ($1, $2)", 1, 5).id)
  end)
end)
