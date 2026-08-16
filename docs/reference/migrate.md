# akkar.migrate

Runs plain SQL files once each, in numeric order, inside a transaction, under a
Postgres advisory lock, and records each one in a ledger table.

**When you need it.** At startup, before the server listens, so a fresh
database gets its schema and an existing one gets whatever is new. Also on a
rolling deploy, where several instances start at once and only one of them may
apply anything.

```lua no-run
local migrate = require "akkar.migrate"
```

## Index

Every public symbol on this page, in alphabetical order. `runner` is what
`migrate.new` returns.

| symbol | kind |
|---|---|
| [`migrate.checksum_of`](#migratechecksum_ofbytes) | function |
| [`migrate.LOCK_KEY`](#migratelock_key) | value |
| [`migrate.Migrate`](#migratemigrate) | table |
| [`migrate.new`](#migratenewdb-options) | function |
| [`runner:applied`](#runnerapplied) | method |
| [`runner:apply`](#runnerapply) | method |
| [`runner:files`](#runnerfiles) | method |
| [`runner:pending`](#runnerpending) | method |

Also on this page:
[What a migration file may contain](#what-a-migration-file-may-contain),
[What the connection must be](#what-the-connection-must-be) and
[Not here](#not-here).

## migrate.checksum_of(bytes)

The SHA-256 of a string, lowercase hex. This is what goes in the ledger's
`checksum` column and what a later run compares against.

**Returns** a 64-character string.

```lua
local migrate = require "akkar.migrate"

print(migrate.checksum_of "create table ref_migrate_users (id int)")
```

## migrate.LOCK_KEY

The bigint handed to `pg_advisory_lock`. It is `0x616b6b6172`, the ASCII of
`akkar`, and it is fixed: one key means at most one migration run per database
at a time.

Postgres attaches no meaning to it. It is recognisable so that
`select * from pg_locks where locktype = 'advisory'` at three in the morning
says whose lock it is.

```lua
local migrate = require "akkar.migrate"

print(migrate.LOCK_KEY)
print(string.format("%x", migrate.LOCK_KEY))
```

## migrate.Migrate

The [Runner](#runner) metatable, exported for tests. Nothing else needs it.

```lua no-run
local migrate = require "akkar.migrate"
local is_runner = getmetatable(runner) == migrate.Migrate
```

## migrate.new(db, options)

Wraps a connection with a runner. Nothing runs yet and nothing is read from the
database.

`db` is checked here rather than at the first query, so a handle that cannot
answer the contract fails while the stack still says who built it.

| field | type | default | meaning |
|---|---|---|---|
| `dir` | string | `"migrations"` | directory of `.sql` files, read one level deep |
| `files` | list | none | migrations as data: `{ { name = ..., sql = ... }, ... }`. Not with `dir` |
| `table` | string | `"akkar_migrations"` | the ledger table |
| `lock_timeout` | number | `30` | seconds to wait for the advisory lock |

`files` exists for a deployment that cannot list a directory. The binary
`akkar build` produces runs in a scratch container with no shell, and
`io.popen "find ..."` needs one.

**Returns** a [Runner](#runner).

**Raises**

- `akkar.migrate: expected a database handle, got <type>`
- `akkar.migrate: this is not a database handle; missing :<method>. A connection factory is not a connection -- call it first, and hand the runner the connection it returns`
- `akkar.migrate: '<name>' is not a usable table name; it goes into SQL as an identifier ...` for a ledger name that is not letters, digits and underscores, or is longer than 63 characters
- `akkar.migrate: pass `dir` or `files`, not both -- two sources of migrations is two answers to what has been applied`
- `akkar.migrate: `files` must be a list of { name, sql }, got <type>`
- `akkar.migrate: files[N] must be { name = string, sql = string }`

```lua
local memory  = require "akkar.db.memory"
local migrate = require "akkar.migrate"

local runner = migrate.new(memory.new(), {
  table = "ref_migrate_ledger",
  files = {
    { name = "001_create_users.sql", sql = "create table ref_migrate_users (id int)" },
  },
})
print(getmetatable(runner) == migrate.Migrate)

local ok, why = pcall(migrate.new, memory.new(), { table = "drop table x" })
print(ok, why)
```

## Runner

What `new` returns. Four methods. Only `apply` writes anything.

### runner:apply()

Applies everything pending and returns the names it applied, in order. Empty on
every boot after the first, which is the ordinary case.

The sequence, in this order, and the order is the point:

1. `set lock_timeout = <lock_timeout * 1000>`
2. `select pg_advisory_lock(LOCK_KEY)`, which blocks until it is ours
3. `set lock_timeout = 0`, so a long migration is not bound by the deploy's patience
4. `create table if not exists <ledger>`
5. compute the pending list, **now**, with the lock held
6. per file: `begin`, the file's SQL, the ledger row, `commit`
7. `select pg_advisory_unlock(LOCK_KEY)`, on both the success and the failure path

The pending list is computed after the lock, never before. A list computed
first and applied second is the race the lock was taken to close.

The ledger row is written in the same transaction as the migration, so a crash
leaves the database either changed and recorded or neither.

The lock is session level, not transaction level, because each migration
commits on its own and a transaction-scoped lock would be dropped at the first
`commit`.

**Returns** a list of file names.

**Raises**

- `akkar.migrate: another runner has held the migration lock for more than N seconds. ...` when `lock_timeout` runs out
- whatever the first failing migration raised. That one is rolled back and not recorded, and the ones after it are not attempted
- whatever [`pending`](#runnerpending) raises, including the changed-checksum error
- `akkar.migrate: the migrations applied but the advisory lock could not be released: <why>. The lock is session scoped, so closing this connection clears it`

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  table = "ref_migrate_ledger",
  files = {
    { name = "001_create_users.sql", sql = [[
      create table ref_migrate_users (
        id    serial primary key,
        email text not null unique
      )
    ]] },
    { name = "002_add_name.sql",
      sql = "alter table ref_migrate_users add column name text" },
  },
})

for _, name in ipairs(runner:apply()) do print("applied " .. name) end
print("second run applied " .. #runner:apply())

conn:exec "drop table ref_migrate_users"
conn:exec "drop table ref_migrate_ledger"
conn:close()
```

### runner:applied()

What the ledger says has run, ordered by name.

Each row is `{ name, checksum, applied_at }`. Note the ordering is by name,
which is string order, unlike [`files`](#runnerfiles) and
[`pending`](#runnerpending), which are in numeric id order.

On a database that has never been migrated it answers an empty list rather than
an error about a missing table: "nothing has been applied" is the true answer
there, and it is the one a status command wants.

**Returns** a list of rows.

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  table = "ref_migrate_ledger",
  files = { { name = "001_create_users.sql",
              sql = "create table ref_migrate_users (id int)" } },
})

print("before", #runner:applied())
runner:apply()
for _, row in ipairs(runner:applied()) do
  print(row.name, row.checksum:sub(1, 12), row.applied_at ~= nil)
end

conn:exec "drop table ref_migrate_users"
conn:exec "drop table ref_migrate_ledger"
conn:close()
```

### runner:files()

Every migration, in the order it will be applied. Reads the directory, or the
`files` list, and hashes each one. Touches no database.

Each entry is `{ id, name, path, sql, checksum }`. `path` is `nil` when the
migrations came from `files`.

The id is the digits at the front of the name, up to the first `_` or `-`, read
as a number. Sorting is by that number, so `10_x.sql` runs after `9_x.sql`.

**Returns** a list of entries.

**Raises**

- `akkar.migrate: these files have no leading id, so there is no order to run them in: <names>` with the suggestion to name them like `20260816120000_add_users.sql`
- `akkar.migrate: two migrations share an id, so which runs first is up to the filesystem: 7 (007_a.sql and 007_b.sql)`
- `akkar.migrate: cannot read the migration directory '<dir>' -- it does not exist, or is not readable from the working directory`, with a second paragraph about scratch containers when there is no shell
- `akkar.migrate: could not list <dir>: <why>` when `io.popen` itself fails
- `akkar.migrate: cannot read <path>: <why>`

```lua
local memory  = require "akkar.db.memory"
local migrate = require "akkar.migrate"

local runner = migrate.new(memory.new(), {
  files = {
    { name = "10_add_index.sql", sql = "create index on ref_migrate_users (email)" },
    { name = "9_add_email.sql",  sql = "alter table ref_migrate_users add column email text" },
  },
})

for _, file in ipairs(runner:files()) do
  print(file.id, file.name, file.checksum:sub(1, 8), tostring(file.path))
end

local unnumbered = migrate.new(memory.new(), {
  files = { { name = "create_users.sql", sql = "select 1" } },
})
local ok, why = pcall(function() return unnumbered:files() end)
print(ok, (why:gsub("\n.*", "")))
```

### runner:pending()

What has not run yet, in the order it will run. A read, so it is safe to call
from a status command.

A file already in the ledger whose bytes differ today raises. That is an error
and not a warning, because a warning scrolls past during a deploy and the
sentence "the schema is what the migrations say" has just become false.

Two consequences of comparing exact bytes, stated rather than discovered:

- a checkout that rewrites line endings changes every checksum, and every file
  then reads as edited. Keep the working tree's line endings stable; there is
  no flag here
- a file that was applied and has since been deleted from disk is **not** an
  error. Squashing old migrations away once they are everywhere is ordinary

**Returns** a list of entries, the same shape [`files`](#runnerfiles) returns.

**Raises** `akkar.migrate: '<name>' has changed since it was applied (ledger
<hash>, file <hash>) -- the database no longer matches the files. Restore the
file, or write a new migration for whatever the edit was trying to say`, plus
everything `files` raises.

Unlike every other error in this module, that one is raised with a level rather
than with 0, so a source position is prepended to it. Called from
[`apply`](#runnerapply), the position is a line inside `akkar/migrate.lua`, not
a line in your code.

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local files = { { name = "001_create_users.sql",
                  sql = "create table ref_migrate_users (id int)" } }
local runner = migrate.new(conn, { table = "ref_migrate_ledger", files = files })

print("pending before", #runner:pending())
runner:apply()
print("pending after", #runner:pending())

local edited = migrate.new(conn, {
  table = "ref_migrate_ledger",
  files = { { name = "001_create_users.sql",
              sql = "create table ref_migrate_users (id bigint)" } },
})
local ok, why = pcall(function() return edited:pending() end)
print(ok, why)

conn:exec "drop table ref_migrate_users"
conn:exec "drop table ref_migrate_ledger"
conn:close()
```

## What a migration file may contain

One or more statements, and nothing that fights the transaction wrapped around
it.

- No `begin`, `commit` or `rollback`. There is already a transaction open.
- Nothing Postgres refuses to run inside a transaction. `create index
  concurrently` is the one people meet first, and there is no way to have both
  it and the atomicity above. This module chooses the atomicity.

Naming: digits, then `_` or `-`, then anything. `001_create_users.sql`,
`20260816120000_add_users.sql`. A name with no leading digits is refused, and
two names with the same number are refused.

A timestamp beats a counter as soon as two people write migrations, because two
people branching from the same commit both pick `007` and two timestamps cannot
collide.

```lua no-run
-- migrations/20260816120000_add_users.sql
--
-- create table users (
--   id    serial primary key,
--   email text not null unique
-- );
```

## What the connection must be

A connection this runner keeps for the whole run. The advisory lock lives on
the session, so a handle that goes back to a pool half way through takes the
lock with it. `db.connect { pool_size = 0 }` gives one that is nobody else's.

**No `statement_timeout` on it.** Postgres counts the wait for an advisory lock
against `statement_timeout`, so a connection configured with a request-sized
one cancels the wait, and cancels a long migration too. `lock_timeout` is the
right knob and this module sets it itself.

```lua no-run
local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  pool_size = 0,                 -- a connection of our own
                                 -- and deliberately no statement_timeout
}
local runner = migrate.new(open(), { dir = "migrations" })
```

## Not here

There are no down migrations and there will not be. A down migration is written
against a schema and run against data, and `alter table drop column` reverses
cleanly on an empty table and destroys a column of real data on a full one. If
a migration was wrong, the fix is another migration.

There is no `runner:rollback`, `runner:reset` or `runner:redo`, for the same
reason.

There is no `runner:create` that writes a new file. Naming is the one decision
this module refuses to make for you.

There is no directory recursion. `find -maxdepth 1`, so a backup directory, an
editor's `.sql~` or an `archive/` subfolder is not picked up. Applying an
archive is a worse failure than not finding it.

## See also
- [akkar.db](db.md) opens the connection this runs on
- [akkar.sql](sql.md) is for statements a handler builds, not for migrations
- the module source, `akkar/migrate.lua`, for the argument behind up-only and behind a bounded lock wait
