--[[
Integration tests for akkar.db, against a real Postgres.

These are separate from `akkar_spec.lua` because that suite deliberately runs
with no database at all.  Parameter binding, though, cannot be tested without
a server: the whole point is that the SERVER does the binding, so a fake would
be testing the fake.

Skipped, not failed, when Postgres is unreachable — a contributor without
Docker should still get a green suite.

  docker run -d --name akkar-pg -e POSTGRES_PASSWORD=akkar \
    -e POSTGRES_DB=akkar -p 55432:5432 postgres:16-alpine
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local db = require "akkar.db"

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
  describe("akkar.db (integration)", function()
    pending("Postgres is not reachable on 127.0.0.1:55432; skipping")
  end)
  return
end

describe("akkar.db parameter binding", function()
  local conn

  before_each(function()
    conn = db.connect(CONFIG)()
    conn:exec "drop table if exists akkar_binding_spec"
    conn:exec [[create table akkar_binding_spec (
      id serial primary key, txt text, num int, flag boolean)]]
  end)

  after_each(function()
    if conn then conn:exec "drop table if exists akkar_binding_spec" conn:close() end
  end)

  it("round-trips a value that is itself SQL", function()
    local nasty = "'; drop table akkar_binding_spec; --"
    local row = conn:one(
      "insert into akkar_binding_spec (txt) values ($1) returning txt", nasty)
    assert.equal(nasty, row.txt)

    -- The table is still here, which is the actual assertion.
    local alive = conn:one "select count(*)::int as n from akkar_binding_spec"
    assert.equal(1, alive.n)
  end)

  it("turns nil into SQL NULL, not the string 'NULL'", function()
    conn:exec("insert into akkar_binding_spec (txt) values ($1)", nil)
    local nulls = conn:one
      "select count(*)::int as n from akkar_binding_spec where txt is null"
    assert.equal(1, nulls.n)
  end)

  it("does not substitute a literal $1 appearing inside a value", function()
    -- The deleted hand-rolled binder substituted $n from highest to lowest,
    -- so a value bound to $2 containing "$1" was rewritten on the next pass.
    local row = conn:one(
      "insert into akkar_binding_spec (txt, num) values ($2, $1) returning txt",
      7, "cost is $1 today")
    assert.equal("cost is $1 today", row.txt)
  end)

  it("binds more than nine parameters positionally", function()
    local args = {}
    for i = 1, 12 do args[i] = "v" .. i end
    local row = conn:one("select $12::text as twelfth", table.unpack(args))
    assert.equal("v12", row.twelfth)      -- not $1 followed by "2"
  end)

  it("keeps non-string types", function()
    local row = conn:one(
      "insert into akkar_binding_spec (num, flag) values ($1, $2) returning num, flag",
      42, true)
    assert.equal(42, row.num)
    assert.is_true(row.flag)
  end)
end)

describe("akkar.db parameter typing", function()
  local conn

  before_each(function()
    conn = db.connect(CONFIG)()
    conn:exec "drop table if exists akkar_typing_spec"
    conn:exec [[create table akkar_typing_spec (
      id integer primary key, weight double precision, label text)]]
    conn:exec [[insert into akkar_typing_spec (id, weight, label)
      select i, i * 1.5, 'row' || i from generate_series(1, 5000) i]]
    conn:exec "analyze akkar_typing_spec"
  end)

  after_each(function()
    if conn then conn:exec "drop table if exists akkar_typing_spec" conn:close() end
  end)

  local function plan_for(sql, ...)
    local rows = conn:many("explain (costs off) " .. sql, ...)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r["QUERY PLAN"] end
    return table.concat(out, "\n")
  end

  -- The regression this exists for: pgmoon types every Lua number as
  -- `numeric`, which is a cross-type comparison against an integer column and
  -- therefore a sequential scan.  Measured at 43x on 10,000 rows.
  it("uses the index for an integer parameter", function()
    local plan = plan_for("select id from akkar_typing_spec where id = $1", 42)
    assert.is_truthy(plan:match "Index",
      "expected an index scan, got:\n" .. plan)
    assert.is_nil(plan:match "Seq Scan",
      "a sequential scan means the parameter type killed the index:\n" .. plan)
  end)

  it("declares a Lua integer as bigint, not numeric", function()
    local plan = plan_for("select id from akkar_typing_spec where id = $1", 42)
    assert.is_truthy(plan:match "bigint", "parameter was not sent as bigint:\n" .. plan)
    assert.is_nil(plan:match "numeric", "parameter is still numeric:\n" .. plan)
  end)

  it("still returns the right rows", function()
    assert.equal("row42", conn:one("select label from akkar_typing_spec where id = $1", 42).label)
    assert.equal(4999, #conn:many(
      "select id from akkar_typing_spec where id > $1 order by id", 1))
  end)

  it("keeps floats as floats", function()
    -- 1.5 must not become an integer, or the value changes.
    local row = conn:one(
      "select id from akkar_typing_spec where weight = $1", 63.0)
    assert.equal(42, row.id)
  end)

  it("distinguishes an integer from a float of the same value", function()
    -- Lua 5.4 has a real integer subtype; the driver must respect it.
    assert.equal("integer", math.type(42))
    assert.equal("float", math.type(42.0))
    assert.equal(42, conn:one("select $1::bigint as v", 42).v)
    assert.equal(42, conn:one("select $1::float8 as v", 42.0).v)
  end)

  it("leaves a SQL NULL out of the row rather than needing a sentinel", function()
    -- The removed clean() pass existed to swap a sentinel that pgmoon never
    -- produces, because convert_null is off by default.
    conn:exec "insert into akkar_typing_spec (id, label) values (99999, null)"
    local row = conn:one("select id, label from akkar_typing_spec where id = $1", 99999)
    assert.equal(99999, row.id)
    assert.is_nil(row.label)
  end)
end)
