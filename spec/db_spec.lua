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

  it("binds UUID strings through an explicit typed query value", function()
    conn:exec "drop table if exists akkar_uuid_typing_spec"
    conn:exec "create table akkar_uuid_typing_spec (id uuid primary key, label text not null)"
    local id = "5b06ddf5-4158-45e8-9726-60e064478cac"
    conn:exec(sql.insert_into("akkar_uuid_typing_spec", {
      id = sql.uuid(id), label = "crystal",
    }, { "id", "label" }))
    local row = conn:one(sql.select("label"):from("akkar_uuid_typing_spec")
      :where("id = ?", sql.uuid(id)))
    assert.equal("crystal", row.label)
    conn:exec "drop table akkar_uuid_typing_spec"
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

describe("akkar.db buffered reads", function()
  -- akkar serves pgmoon's two-calls-per-row socket reads out of one large
  -- read.  It is the only place akkar reaches into a dependency's internals,
  -- so what it produces has to be proven identical rather than assumed.
  local function rows_from(config, n)
    local conn = db.connect(config)()
    conn:exec "drop table if exists akkar_buffer_spec"
    conn:exec [[create table akkar_buffer_spec (
      id int, name text, note text, ratio float8, flag boolean)]]
    -- `mod()` rather than `%`, which string.format would have eaten.
    conn:exec("insert into akkar_buffer_spec select g, 'user ' || g, " ..
              "repeat('x', mod(g, 97)), g / 7.0, mod(g, 2) = 0 " ..
              "from generate_series(1, " .. n .. ") g")
    local rows = conn:many "select * from akkar_buffer_spec order by id"
    conn:close()
    return rows
  end

  local function config_with(buffered)
    local c = {}
    for k, val in pairs(CONFIG) do c[k] = val end
    c.buffered_reads = buffered
    return c
  end

  it("returns exactly what the unbuffered driver returns", function()
    -- Row counts chosen to straddle the 64 KB read: a small result fits in one
    -- read, a large one does not, and the message that spans the boundary is
    -- where a buffered reader goes wrong.
    for _, n in ipairs { 1, 100, 2000 } do
      local off = rows_from(config_with(false), n)
      local on  = rows_from(config_with(true), n)
      assert.equal(n, #on, "row count changed at n = " .. n)
      assert.same(off, on, "buffered reads changed the result at n = " .. n)
    end
  end)

  it("handles a single value larger than the read chunk", function()
    -- One field bigger than 64 KB forces the reader to keep asking, which is
    -- the loop that would hang or truncate if the refill were wrong.
    local conn = db.connect(config_with(true))()
    local big = conn:one "select repeat('y', 200000) as blob"
    assert.equal(200000, #big.blob)
    conn:close()
  end)

  it("can be turned off without a fork", function()
    local conn = db.connect(config_with(false))()
    assert.equal(1, conn:one("select 1 as n").n)
    conn:close()
  end)
end)

describe("akkar.db statement_timeout", function()
  -- akkar's deadline stops akkar waiting. It does not stop Postgres working:
  -- the server notices a departed client only when it next tries to write,
  -- and a query producing no output until it completes may not try for
  -- minutes. Under load that leaves the database busier after a timeout than
  -- before one, which is the opposite of the point.
  --- `pooled` matters: CONFIG uses pool_size 0, which returns the bare open
  --- function rather than a pool, and the reuse test needs a real one.
  local function config_with(seconds, pooled)
    local c = {}
    for k, v in pairs(CONFIG) do c[k] = v end
    c.statement_timeout = seconds
    if pooled then c.pool_size = 1 end
    return c
  end

  it("is unset unless asked for", function()
    -- Turning this on by default would kill somebody's migration mid-flight.
    local conn = db.connect(CONFIG)()
    assert.equal("0", conn:one("show statement_timeout").statement_timeout)
    conn:close()
  end)

  it("tells the server, in the server's own units", function()
    local conn = db.connect(config_with(2))()
    assert.equal("2s", conn:one("show statement_timeout").statement_timeout)
    conn:close()
  end)

  it("accepts fractions of a second", function()
    local conn = db.connect(config_with(0.25))()
    assert.equal("250ms", conn:one("show statement_timeout").statement_timeout)
    conn:close()
  end)

  it("actually cancels a query that overruns", function()
    local conn = db.connect(config_with(1))()
    local started = os.clock()
    local ok, err = pcall(function() return conn:one "select pg_sleep(5)" end)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "statement timeout")
    conn:close()
  end)

  it("leaves the connection usable, because a query error is not a protocol error", function()
    -- If a cancelled query cost a reconnect, every slow query would pay for
    -- one and the pool would stop being a pool.
    local factory = db.connect(config_with(1, true))
    local conn = factory()

    pcall(function() return conn:one "select pg_sleep(5)" end)

    assert.is_nil(conn.broken)
    assert.is_false(conn.in_flight)
    assert.equal("STILL-GOOD", conn:one("select 'STILL-GOOD' as who").who)

    conn:release()
    assert.equal(1, #factory.pool.idle, "the connection was discarded needlessly")
  end)
end)

describe("the boot-time warning about unbounded statements", function()
  -- Forgetting statement_timeout is silent and costly: the deadline appears
  -- to work, requests get their 503, and the database keeps running every
  -- query that was abandoned. Asked once at boot on a connection the contract
  -- check has already opened, so it costs nothing per request.
  local akkar = require "akkar"
  local cqueues = require "cqueues"

  local function boot(statement_timeout)
    local lines = {}
    local cfg = {}
    for k, v in pairs(CONFIG) do cfg[k] = v end
    cfg.pool_size = 1
    cfg.statement_timeout = statement_timeout

    local cq = cqueues.new()
    cq:wrap(function()
      akkar.check_capabilities {
        db = db.connect(cfg),
        timeout = 5,
        log = akkar.log.new { level = "warn", format = "text",
                              sink = function(l) lines[#lines + 1] = l end },
      }
    end)
    assert(cq:loop(20))
    return table.concat(lines)
  end

  it("says so when the deadline cannot reach the database", function()
    local out = boot(nil)
    assert.is_truthy(out:find("no statement_timeout", 1, true))
    assert.is_truthy(out:find("statement_timeout = <seconds>", 1, true),
      "the warning must say what to do about it")
  end)

  it("says nothing once it is configured", function()
    assert.is_nil(boot(5):find("no statement_timeout", 1, true))
  end)

  it("speaks through the logger the application configured", function()
    -- A boot warning that ignores the configured sink never reaches whatever
    -- collects logs in production.
    assert.is_truthy(boot(nil):find("WARN", 1, true))
  end)
end)

describe("akkar.sql claiming rows under contention", function()
  -- `skip locked` is the one clause whose behaviour a fake cannot show: it is
  -- defined entirely by what ANOTHER open transaction is holding at that
  -- instant. Two real connections, one real lock.
  local first, second

  local function ids(rows)
    local out = {}
    for index, row in ipairs(rows) do out[index] = row.id end
    return out
  end

  local function claim(conn, size, skip)
    local query = sql.select("id"):from("akkar_claim_spec")
      :where("available_at <= now()")
      :order_by("id", { "id" }, "asc"):limit(size):for_update()
    if skip then query = query:skip_locked() end
    return ids(conn:many(query))
  end

  before_each(function()
    first, second = db.connect(CONFIG)(), db.connect(CONFIG)()
    first:exec "drop table if exists akkar_claim_spec"
    first:exec [[create table akkar_claim_spec (
      id int primary key, available_at timestamptz not null default now())]]
    first:exec [[insert into akkar_claim_spec (id)
      select i from generate_series(1, 4) i]]
  end)

  after_each(function()
    if first then first:exec "drop table if exists akkar_claim_spec" first:close() end
    if second then second:close() end
  end)

  it("gives a second claimer the rows the first is not holding", function()
    local taken
    first:transaction(function(tx)
      assert.same({ 1, 2 }, claim(tx, 2, true))
      -- Still inside the first transaction: rows 1 and 2 are locked right now.
      taken = claim(second, 2, true)
    end)
    -- Without the clause this line would block until the transaction above
    -- committed, and then come back EMPTY or short -- Postgres re-checks the
    -- predicate on the rows it was waiting for, so a queue whose claim moves
    -- `available_at` filters them out and the second worker earns nothing for
    -- the wait.
    assert.same({ 3, 4 }, taken)
  end)

  it("still refuses to hand the same row to two claimers", function()
    local overlap
    first:transaction(function(tx)
      claim(tx, 4, true)
      overlap = claim(second, 4, true)
    end)
    assert.same({}, overlap)
  end)
end)
