--[[
akkar.migrate, against a real Postgres.

There is no in-memory half of this suite and there should not be. Every
property the module claims is a property of the DATABASE -- an advisory lock
that survives a commit, a transaction that takes the ledger row down with the
change it rolled back, a `create table` that really did not happen. A fake
would answer yes to all of them by construction, which is how a test proves
the wrong thing.

Skipped, not failed, when Postgres is unreachable, in the shape `db_spec` uses:

  docker run -d --name akkar-pg -e POSTGRES_PASSWORD=akkar \
    -e POSTGRES_DB=akkar -p 55432:5432 postgres:16-alpine
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local CONFIG = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}

-- Connect AND ask a question. `spec/jobs_spec.lua` records what a guard that
-- only builds the handle is worth: cqueues sockets are lazy, so every Redis
-- skip in this suite was decorative for as long as somebody's machine happened
-- to have Redis running. The pgmoon path does authenticate inside `connect`,
-- so a bare pcall would probably be enough here -- "probably enough" is not a
-- thing to leave in a guard whose failure mode is a silently empty suite.
local function reachable()
  local ok, conn = pcall(function() return db.connect(CONFIG)() end)
  if not ok or not conn then return false end
  local alive = pcall(function() return conn:one "select 1 as n" end)
  pcall(function() conn:close() end)
  return alive
end

if not reachable() then
  describe("akkar.migrate (integration)", function()
    pending "Postgres is not reachable on 127.0.0.1:55432; skipping"
  end)
  return
end

local LEDGER = "akkar_migrate_spec_ledger"
local TABLES = {
  LEDGER,
  "akkar_migrate_spec_notes",
  "akkar_migrate_spec_probe",
  "akkar_migrate_spec_boom",
  "akkar_migrate_spec_ghost",
}

local function reset(conn)
  for _, name in ipairs(TABLES) do
    conn:exec("drop table if exists " .. name)
  end
end

-- A directory per test. `os.tmpname` hands back a name it has already created
-- as a FILE, so it is removed before the directory takes its place -- otherwise
-- `mkdir` fails and every test writes its migrations into the same place as
-- every other one.
local function temp_dir()
  local path = os.tmpname()
  os.remove(path)
  assert(os.execute("mkdir -p " .. path), "could not create " .. path)
  return path
end

local function write(dir, name, sql)
  local file = assert(io.open(dir .. "/" .. name, "wb"))
  file:write(sql)
  file:close()
end

--- How many advisory locks this backend is holding.
---
--- The migration files run on the same connection as the lock, so a `select`
--- from inside one of them sees exactly what the runner is holding at that
--- moment. That is the only way to observe the lock from a single-process
--- test, and it is a real observation rather than a proxy for one.
local function advisory_locks(conn)
  return conn:one([[select count(*)::int as n from pg_locks
                    where locktype = 'advisory' and pid = pg_backend_pid()]]).n
end

local function exists(conn, name)
  return conn:one("select to_regclass($1) is not null as present", name).present
end

local function names_of(rows)
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = row.name end
  return out
end

describe("akkar.migrate", function()
  local conn, dir, runner

  before_each(function()
    conn = db.connect(CONFIG)()
    reset(conn)
    dir = temp_dir()
    runner = migrate.new(conn, { dir = dir, table = LEDGER })
  end)

  after_each(function()
    if conn then
      pcall(function() reset(conn) end)
      pcall(function() conn:close() end)
    end
    if dir then os.execute("rm -rf " .. dir) end
  end)

  describe("the contract it asks of its handle", function()
    it("refuses something that is not a connection", function()
      -- The mistake this catches is a specific one: `db.connect` returns a
      -- FACTORY, and handing that factory straight to `migrate.new` is the
      -- obvious thing to do. Without the check the failure arrives several
      -- lines later as an attempt to index a function.
      local ok, err = pcall(function()
        return migrate.new(db.connect(CONFIG), { dir = dir })
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):match "expected a database handle, got function")

      -- And the same mistake wearing a disguise, which is why the type check
      -- is not enough on its own: `db.connect` with a POOL returns a callable
      -- TABLE rather than a function, so it passes for a handle until someone
      -- asks it a question. Found by this test -- the first version checked
      -- only for `:one` and never fired against the unpooled factory, and a
      -- version checking only the type would never fire against this one.
      local pooled = db.connect { host = CONFIG.host, port = CONFIG.port,
        database = CONFIG.database, user = CONFIG.user,
        password = CONFIG.password, pool_size = 2 }
      local pooled_ok, pooled_err = pcall(function()
        return migrate.new(pooled, { dir = dir })
      end)
      assert.is_false(pooled_ok)
      assert.is_truthy(tostring(pooled_err):match "missing :one")
    end)

    it("refuses a ledger name that is not an identifier", function()
      -- The ledger name is the one value that reaches SQL as text rather than
      -- as a bound parameter, because an identifier cannot be bound.
      local ok, err = pcall(function()
        return migrate.new(conn, { dir = dir, table = "x; drop table users; --" })
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):match "not a usable table name")
    end)
  end)

  describe("reading the directory", function()
    it("says so when the directory is not there", function()
      -- Reading a missing directory as "nothing to migrate" would let a
      -- mistyped path deploy an empty schema without a word of complaint, and
      -- it would look identical to a project that has not written its first
      -- migration yet.
      local absent = migrate.new(conn, { dir = dir .. "/not-here", table = LEDGER })
      local ok, err = pcall(function() return absent:pending() end)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):match "cannot read the migration directory")
    end)

    it("reports nothing applied against a database that never has been", function()
      write(dir, "001_notes.sql", "create table akkar_migrate_spec_notes (id int)")
      assert.same({}, runner:applied())
      assert.equal(1, #runner:pending())
      -- And reading did not create the ledger: `applied` and `pending` are
      -- reads, and the only thing that creates the table is `apply`, which
      -- holds the lock by then.
      assert.is_false(exists(conn, LEDGER))
    end)
  end)

  describe("applying", function()
    local function three_migrations()
      -- Written 003, 001, 002 on purpose. `find` returns directory order, and
      -- directory order is not name order -- so a runner that forgot to sort
      -- would try to insert into a table that does not exist yet.
      write(dir, "003_third.sql",
        "insert into akkar_migrate_spec_notes (label) values ('three')")
      write(dir, "001_notes.sql",
        "create table akkar_migrate_spec_notes (id serial primary key, label text)")
      write(dir, "002_second.sql",
        "insert into akkar_migrate_spec_notes (label) values ('two')")
    end

    local function labels()
      local out = {}
      for _, row in ipairs(conn:many
        "select label from akkar_migrate_spec_notes order by id") do
        out[#out + 1] = row.label
      end
      return out
    end

    it("applies them in filename order", function()
      three_migrations()
      assert.same({ "001_notes.sql", "002_second.sql", "003_third.sql" },
                  runner:apply())
      assert.same({ "two", "three" }, labels())
    end)

    it("applies nothing the second time", function()
      three_migrations()
      runner:apply()

      assert.same({}, runner:apply(), "a second run applied something")
      assert.same({ "two", "three" }, labels(),
        "the inserts ran twice -- which is the failure a 'create table' " ..
        "migration would have caught and an 'insert' one never does")
      assert.equal(3, #runner:applied())
      assert.same({}, runner:pending())
    end)

    it("records the name and the checksum of what it applied", function()
      write(dir, "001_notes.sql", "create table akkar_migrate_spec_notes (id int)")
      runner:apply()

      local row = runner:applied()[1]
      assert.equal("001_notes.sql", row.name)
      assert.equal(migrate.checksum_of "create table akkar_migrate_spec_notes (id int)",
                   row.checksum)
      assert.is_truthy(row.applied_at)
    end)
  end)

  describe("the checksum check", function()
    it("refuses a file that changed after it was applied", function()
      write(dir, "001_notes.sql",
        "create table akkar_migrate_spec_notes (id serial primary key)")
      runner:apply()

      -- Somebody edits history: same name, different bytes. The database and
      -- the files now disagree and nothing else would ever say so.
      write(dir, "001_notes.sql",
        "create table akkar_migrate_spec_notes (id serial primary key, oops text)")

      local ok, err = pcall(function() return runner:pending() end)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):match "001_notes%.sql")
      assert.is_truthy(tostring(err):match "has changed since it was applied")

      -- And `apply` refuses too, rather than only the read path.
      local applied_ok = pcall(function() return runner:apply() end)
      assert.is_false(applied_ok)

      -- The refusal must not have left the lock behind.
      assert.equal(0, advisory_locks(conn))
    end)

    it("does not mind a file that was applied and has since been deleted", function()
      -- Squashing old migrations away once they are everywhere is ordinary.
      -- Refusing it would make this module the reason the directory can never
      -- be cleaned, so it is deliberately not an error.
      write(dir, "001_notes.sql", "create table akkar_migrate_spec_notes (id int)")
      runner:apply()
      assert(os.remove(dir .. "/001_notes.sql"))

      assert.same({}, runner:pending())
      assert.equal(1, #runner:applied())
    end)
  end)

  describe("a migration that fails", function()
    it("rolls it back, does not record it, and stops", function()
      write(dir, "001_notes.sql",
        "create table akkar_migrate_spec_notes (id serial primary key, label text)")
      -- Two statements: the first would succeed on its own, so the table's
      -- absence afterwards is the rollback and nothing else.
      write(dir, "002_boom.sql",
        "create table akkar_migrate_spec_boom (id int);\nselect 1 / 0;\n")
      write(dir, "003_third.sql",
        "insert into akkar_migrate_spec_notes (label) values ('three')")

      local ok, err = pcall(function() return runner:apply() end)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):match "division by zero")

      assert.is_false(exists(conn, "akkar_migrate_spec_boom"),
        "the failed migration's first statement survived its own rollback")
      assert.same({ "001_notes.sql" }, names_of(runner:applied()),
        "a migration that failed was recorded as applied")
      assert.equal(0, conn:one
        "select count(*)::int as n from akkar_migrate_spec_notes".n,
        "the run continued past a migration that failed")
    end)

    it("gives the advisory lock back anyway", function()
      -- A failed migration that kept the lock turns one bad file into a fleet
      -- that cannot boot: every other instance blocks at a run that is over.
      write(dir, "001_boom.sql", "select 1 / 0")

      assert.is_false(pcall(function() return runner:apply() end))
      assert.equal(0, advisory_locks(conn),
        "the lock survived the failure, and every other instance is now stuck")
    end)
  end)

  describe("the ledger row and the change are one transaction", function()
    it("loses the change when the ledger row is refused", function()
      -- The rollback tests above prove the pair goes down together when the
      -- MIGRATION fails. This is the other direction, and it is the one that
      -- actually distinguishes "one transaction" from "two that usually both
      -- work": the migration succeeds and the LEDGER INSERT is what fails.
      --
      -- Staged with a check constraint on the ledger, because a ledger write
      -- cannot be made to fail from outside the module any other way. The
      -- runner's `create table if not exists` finds this table already here
      -- and leaves it alone.
      conn:exec("create table " .. LEDGER .. [[ (
        name text primary key,
        checksum text not null,
        applied_at timestamptz not null default now(),
        constraint refuse_one check (name <> 'zz_forbidden.sql')
      )]])

      write(dir, "001_notes.sql", "create table akkar_migrate_spec_notes (id int)")
      write(dir, "zz_forbidden.sql", "create table akkar_migrate_spec_ghost (id int)")

      assert.is_false(pcall(function() return runner:apply() end))

      assert.is_true(exists(conn, "akkar_migrate_spec_notes"),
        "the migration before the refused one should have committed")
      assert.is_false(exists(conn, "akkar_migrate_spec_ghost"),
        "the change committed while its ledger row did not -- which is exactly " ..
        "the state that makes the next deploy apply this migration twice")
      assert.same({ "001_notes.sql" }, names_of(runner:applied()))
    end)
  end)

  describe("the advisory lock", function()
    it("is held for the whole run and released at the end", function()
      -- The migrations run on the runner's own connection, so a migration can
      -- look at `pg_locks` and report what the runner was holding while it
      -- ran. Two of them, because the interesting claim is that the lock
      -- SURVIVES the first migration's COMMIT -- which is why this is
      -- `pg_advisory_lock` and not `pg_advisory_xact_lock`. With the
      -- transaction-scoped variant the second row here reads 0 and every
      -- migration after the first runs unprotected.
      write(dir, "001_probe.sql", [[
        create table akkar_migrate_spec_probe (step int, held int);
        insert into akkar_migrate_spec_probe (step, held)
          select 1, count(*)::int from pg_locks
           where locktype = 'advisory' and pid = pg_backend_pid();
      ]])
      write(dir, "002_probe.sql", [[
        insert into akkar_migrate_spec_probe (step, held)
          select 2, count(*)::int from pg_locks
           where locktype = 'advisory' and pid = pg_backend_pid();
      ]])

      assert.equal(0, advisory_locks(conn), "something already held the lock")
      runner:apply()

      local seen = {}
      for _, row in ipairs(conn:many
        "select step, held from akkar_migrate_spec_probe order by step") do
        seen[row.step] = row.held
      end
      assert.equal(1, seen[1], "the first migration ran without the lock held")
      assert.equal(1, seen[2],
        "the lock did not survive the first migration's commit, so every " ..
        "migration after the first ran unprotected")

      assert.equal(0, advisory_locks(conn), "the lock was never released")
    end)

    it("has the ledger's primary key behind it as a backstop", function()
      -- What happens if the lock is ever wrong. Two runners that both got in
      -- would each compute the same pending list, and the second one's ledger
      -- write then collides with the first's -- so the second migration fails
      -- and rolls back rather than applying its change a second time in
      -- silence. That is the difference between a bug that stops a deploy and
      -- a bug that doubles a row.
      --
      -- A second runner cannot be staged in one process, so the collision is
      -- staged where the effect is identical: a migration writes the ledger
      -- row for the file that comes after it, as if another instance had just
      -- applied it.
      local third = "insert into akkar_migrate_spec_notes (label) values ('three')"
      write(dir, "001_notes.sql",
        "create table akkar_migrate_spec_notes (id serial primary key, label text)")
      write(dir, "002_claim.sql",
        "insert into " .. LEDGER .. " (name, checksum) values ('003_third.sql', '" ..
        migrate.checksum_of(third) .. "')")
      write(dir, "003_third.sql", third)

      local ok, err = pcall(function() return runner:apply() end)
      assert.is_false(ok, "the already-recorded migration was applied again")
      assert.is_truthy(tostring(err):match "duplicate key")
      assert.equal(0, conn:one
        "select count(*)::int as n from akkar_migrate_spec_notes".n,
        "the change went in even though its ledger row was refused")
      assert.equal(0, advisory_locks(conn))
    end)
  end)
end)

describe("migrations as data, for an image with no shell", function()
  -- The deploy that found this ran the same binary from a scratch container:
  -- two files, no libc, no `/bin/sh`. `io.popen` needs a shell, so listing a
  -- directory is not merely awkward there, it is impossible -- and the error
  -- said "No such file or directory" about the SHELL while naming the
  -- directory, which is as misleading as an error gets.
  --
  -- Adding a C dependency to list files would trade the small binary for a
  -- convenience. Handing the migrations over as data costs nothing and is the
  -- honest shape for a single artefact anyway: a schema that travels inside
  -- the binary cannot fall out of step with the code that expects it.
  local db_module = require "akkar.db"

  local CONFIG = {
    host = "127.0.0.1", port = 55432, database = "akkar",
    user = "postgres", password = "akkar", pool_size = 0,
  }

  local function reachable()
    local ok, conn = pcall(function() return db_module.connect(CONFIG)() end)
    if ok and conn then conn:close() end
    return ok
  end

  if not reachable() then
    pending "Postgres is not reachable on 127.0.0.1:55432; skipping"
    return
  end

  local db, runner

  before_each(function()
    db = db_module.connect(CONFIG)()
    db:exec "drop table if exists akkar_data_spec"
    db:exec "drop table if exists akkar_data_ledger"
    runner = require("akkar.migrate").new(db, {
      table = "akkar_data_ledger",
      files = {
        { name = "002_second.sql", sql = "alter table akkar_data_spec add column note text" },
        { name = "001_first.sql",  sql = "create table akkar_data_spec (id serial primary key)" },
      },
    })
  end)

  after_each(function()
    if db then
      db:exec "drop table if exists akkar_data_spec"
      db:exec "drop table if exists akkar_data_ledger"
      db:close()
    end
  end)

  it("applies them in name order, not the order they were listed", function()
    -- Deliberately given second-then-first: without the sort, 002 alters a
    -- table 001 has not created yet.
    local applied = runner:apply()
    assert.same({ "001_first.sql", "002_second.sql" }, applied)
    local row = db:one "select to_regclass('akkar_data_spec') is not null as present"
    assert.is_true(row.present)
  end)

  it("is idempotent, exactly as the directory path is", function()
    runner:apply()
    assert.same({}, runner:apply())
  end)

  it("refuses an edited migration, exactly as the directory path does", function()
    runner:apply()

    local tampered = require("akkar.migrate").new(db, {
      table = "akkar_data_ledger",
      files = {
        { name = "001_first.sql", sql = "create table akkar_data_spec (id serial primary key) -- edited" },
        { name = "002_second.sql", sql = "alter table akkar_data_spec add column note text" },
      },
    })
    local ok, why = pcall(function() return tampered:pending() end)
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("001_first.sql", 1, true))
  end)

  it("refuses both sources at once", function()
    -- Two sources of migrations is two answers to what has been applied.
    local ok, why = pcall(function()
      return require("akkar.migrate").new(db, { dir = "x", files = {} })
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("not both", 1, true))
  end)

  it("refuses a malformed entry rather than skipping it", function()
    for _, bad in ipairs {
      { { name = "a.sql" } },                 -- no sql
      { { sql = "select 1" } },               -- no name
      { "not a table" },
    } do
      local ok = pcall(function()
        return require("akkar.migrate").new(db, { files = bad })
      end)
      assert.is_false(ok, "a malformed migration entry was accepted")
    end
  end)
end)
