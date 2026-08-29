--[[
Tenant scope — the property under test is that the unscoped statement is never
assembled, not that a reviewer would have caught it.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local sql    = require "akkar.sql"
local memory = require "akkar.db.memory"

local function db_with_log()
  local db = memory.new()
  db:on(".", function() return {} end)
  return db
end

describe("a scoped handle", function()
  it("adds the scope to every read", function()
    local db = db_with_log()
    db:scope("project_id", 7):many(sql.select("*"):from "documents")

    local issued = db.log[1]
    assert.equal("select * from documents where (project_id = $1)", issued.sql)
    assert.equal(7, issued.args[1])
  end)

  it("adds the scope to an update, alongside the handler's own condition", function()
    local db = db_with_log()
    db:scope("project_id", 7):exec(
      sql.update("documents"):set("title", "new"):where("id = ?", 3))

    assert.equal("update documents set title = $1 where (id = $2) and (project_id = $3)",
                 db.log[1].sql)
    assert.same({ "new", 3, 7 }, { table.unpack(db.log[1].args, 1, 3) })
  end)

  it("adds the scope to a delete", function()
    local db = db_with_log()
    db:scope("project_id", 7):exec(sql.delete_from("documents"):where("id = ?", 3))
    assert.equal("delete from documents where (id = $1) and (project_id = $2)", db.log[1].sql)
  end)

  it("sets the scope column on an insert", function()
    local db = db_with_log()
    db:scope("project_id", 7):exec(
      sql.insert_into("documents", { title = "a" }):returning "*")
    assert.equal("insert into documents (project_id, title) values ($1, $2) returning *",
                 db.log[1].sql)
    assert.same({ 7, "a" }, { table.unpack(db.log[1].args, 1, 2) })
  end)

  it("overrides a tenant id the client tried to supply", function()
    -- A body claiming another tenant's id must not be able to write into it.
    local db = db_with_log()
    db:scope("project_id", 7):exec(
      sql.insert_into("documents", { title = "a", project_id = 999 }))
    assert.same({ 7, "a" }, { table.unpack(db.log[1].args, 1, 2) })
  end)

  it("refuses raw SQL, because a string cannot be scoped", function()
    local db = db_with_log()
    local ok, err = pcall(function()
      db:scope("project_id", 7):many "select * from documents"
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "scoped to project_id")
    assert.equal(0, #db.log, "an unscoped statement reached the database")
  end)

  it("refuses a nil tenant id rather than matching every row", function()
    local db = db_with_log()
    local ok, err = pcall(function() db:scope("project_id", nil) end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "is nil")
  end)

  it("narrows when scoped twice rather than replacing", function()
    local db = db_with_log()
    db:scope("org_id", 1):scope("project_id", 7):many(sql.select("*"):from "documents")
    -- Innermost scope lands first; both conditions are ANDed, so the order is
    -- cosmetic -- what matters is that neither was dropped.
    assert.equal("select * from documents where (project_id = $1) and (org_id = $2)",
                 db.log[1].sql)
    assert.same({ 7, 1 }, { table.unpack(db.log[1].args, 1, 2) })
  end)

  it("keeps the scope inside a transaction", function()
    local db = db_with_log()
    db:scope("project_id", 7):transaction(function(tx)
      tx:many(sql.select("*"):from "documents")
    end)
    assert.equal("select * from documents where (project_id = $1)", db.log[2].sql)
  end)

  it("makes crossing tenants greppable rather than silent", function()
    local db = db_with_log()
    db:scope("project_id", 7):unscoped():many "select count(*) from documents"
    assert.equal("select count(*) from documents", db.log[1].sql)
  end)
end)

describe("writes that would touch every row", function()
  it("refuses an update with no where clause", function()
    local ok, err = pcall(function()
      sql.update("documents"):set("title", "x"):build()
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "every row")
  end)

  it("refuses a delete with no where clause", function()
    assert.is_false((pcall(function() sql.delete_from("documents"):build() end)))
  end)

  it("allows it when it is said out loud", function()
    local text = sql.delete_from("sessions"):all_rows():to_string()
    assert.equal("delete from sessions", text)
  end)

  it("counts the tenant scope as a where clause", function()
    -- The scope is what makes an otherwise table-wide delete safe.
    local db = db_with_log()
    db:scope("project_id", 7):exec(sql.delete_from "documents")
    assert.equal("delete from documents where (project_id = $1)", db.log[1].sql)
  end)
end)
