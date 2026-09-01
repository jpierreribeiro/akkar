--[[
The tenant scope, attacked rather than confirmed.

scope_spec asserts that the scope is PRESENT in the statement.  Present is not
the same as binding: SQL gives `and` higher precedence than `or`, so a scope
appended to a handler's own disjunction ends up guarding one branch and leaving
the other free.  The statement still contains `tenant_id = $n`, a reviewer
still sees it, and every text-level assertion still passes -- while the query
returns another tenant's rows.

These tests run against a real PostgreSQL, because the property under test is
what the SERVER does with the text.  A fake that returns whatever it is told
would agree with the bug.

  docker run -d --name akkar-pg -e POSTGRES_PASSWORD=akkar \
    -e POSTGRES_DB=akkar -p 55432:5432 postgres:16-alpine
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local db  = require "akkar.db"
local sql = require "akkar.sql"

local CONFIG = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}

local function reachable()
  local ok, conn = pcall(db.connect(CONFIG))
  if ok then conn:close() end
  return ok
end

if not reachable() then
  describe("the tenant scope under attack", function()
    pending("Postgres is not reachable on 127.0.0.1:55432; skipping")
  end)
  return
end

describe("the tenant scope under attack", function()
  local conn

  before_each(function()
    conn = db.connect(CONFIG)()
    conn:exec "drop table if exists akkar_scope_attack"
    conn:exec [[create table akkar_scope_attack (
      id serial primary key, tenant_id int, title text, body text)]]
    conn:exec [[insert into akkar_scope_attack (tenant_id, title, body) values
      (7, 'mine', 'ours'),
      (9, 'theirs', 'SECRET-OF-TENANT-9')]]
  end)

  after_each(function()
    if conn then conn:exec "drop table if exists akkar_scope_attack" conn:close() end
  end)

  -- The ordinary shape this protects: searching two columns at once.  Nothing
  -- about it is unusual, hostile, or a misuse of the API.
  it("holds when the handler's own condition contains an or", function()
    local rows = conn:scope("tenant_id", 7):many(
      sql.select("id, tenant_id, title, body"):from("akkar_scope_attack")
        :where("title like ? or body like ?", "%s%", "%s%"))

    for _, row in ipairs(rows) do
      assert.equal(7, tonumber(row.tenant_id),
        "a row belonging to tenant " .. tostring(row.tenant_id) ..
        " came back from a query scoped to tenant 7")
    end
  end)

  it("does not delete another tenant's rows through an or", function()
    conn:scope("tenant_id", 7):exec(
      sql.delete_from("akkar_scope_attack"):where("title = ? or title = ?", "theirs", "mine"))

    local survivor = conn:one(
      "select count(*)::int as n from akkar_scope_attack where tenant_id = 9")
    assert.equal(1, survivor.n, "a delete scoped to tenant 7 destroyed tenant 9's row")
  end)

  -- Parenthesising each condition is not enough on its own: a caller who
  -- closes the parenthesis themselves rebalances the clause and the scope is
  -- bypassed again.  These are the payloads that did it.
  it("refuses a condition that closes a parenthesis it did not open", function()
    for _, attack in ipairs {
      "1=1) or (1=1",
      "1=1) or (1=1) --",
      "1=1) or (body like '%SECRET%'",
    } do
      local ok, err = pcall(function()
        sql.select("*"):from("akkar_scope_attack"):where(attack)
      end)
      assert.is_false(ok, "accepted a clause-restructuring condition: " .. attack)
      assert.matches("akkar%.sql", tostring(err))
    end
  end)

  it("refuses comment introducers and statement separators", function()
    for _, attack in ipairs { "1=1 --", "1=1 /* x", "1=1; drop table akkar_scope_attack" } do
      assert.is_false(pcall(function()
        sql.select("*"):from("akkar_scope_attack"):where(attack)
      end), "accepted: " .. attack)
    end
  end)

  it("still accepts the honest fragments this codebase actually writes", function()
    -- Balanced parentheses and no placeholders are ordinary and must keep
    -- working; the application depends on exactly this shape for now() windows.
    assert.has_no.errors(function()
      sql.select("*"):from("akkar_scope_attack")
        :where("(title is null or title <= now())")
        :where("body is not null")
        :where("lower(title) like ?", "%x%")
        :where("id in (?, ?)", 1, 2)
    end)
  end)

  it("does not update another tenant's rows through an or", function()
    conn:scope("tenant_id", 7):exec(
      sql.update("akkar_scope_attack"):set("title", "rewritten")
        :where("title = ? or title = ?", "theirs", "mine"))

    local other = conn:one(
      "select title from akkar_scope_attack where tenant_id = 9")
    assert.equal("theirs", other.title, "an update scoped to tenant 7 rewrote tenant 9's row")
  end)
end)
