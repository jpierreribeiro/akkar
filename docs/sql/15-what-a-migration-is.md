# 15. What a migration is

By the end of this page you will have run a migration from a script you wrote,
looked at the four things the runner can tell you, and you will know what is
allowed inside a migration file and what is not.

[Page 5 of the guide](../guide/05-a-database.md) got you a `tasks` table with a
migration. This page is what was going on underneath.

## The idea, in three sentences

Your database has a shape: tables, columns, indexes. That shape has to change
over time, and it has to change the same way on your laptop, on your
colleague's, on the test database and on the server.

**A migration is one change to that shape, written as SQL, in a file with a
number in front of it, applied once and recorded.**

The recording is the part that makes it work. Running the whole set again does
nothing, because everything in it is already recorded, which is what makes it
safe to run on every single start.

## The runner

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = {
    { name = "001_create_tasks.sql", sql = [[
      create table sqlguide_tasks (
        id serial primary key,
        title text not null,
        done boolean not null default false
      )
    ]] },
  },
})

for _, name in ipairs(runner:apply()) do print("applied " .. name) end
print("second run applied " .. #runner:apply() .. " files")

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
applied 001_create_tasks.sql
second run applied 0 files
```

Two arguments to `migrate.new`, and both deserve a sentence.

**The connection.** Not the factory. `db.connect` gives you a function that
opens connections, and the runner needs an actual open one, for a reason
[page 18](18-the-lock.md) explains. Passing the wrong one gives you this:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
}

local ok, why = pcall(function() return migrate.new(open, {}) end)
print(ok, why)
```

```
false	akkar.migrate: this is not a database handle; missing :one. A connection factory is not a connection -- call it first, and hand the runner the connection it returns
```

The check happens at `migrate.new`, not at the first query, so the stack still
points at the line that built the runner.

**The options.** `files` is the list of migrations as data, which
[page 19](19-migrations-as-data.md) is about. In a normal project you use
`dir = "migrations"` and a folder of `.sql` files instead. `table` is the name
of the ledger, and it defaults to `akkar_migrations`.

> Every example in this track passes `table = "sqlguide_migrations"` so it
> cannot touch the ledger the guide's own database uses. Your project should
> leave it out and take the default.

## The four things you can ask it

### `runner:files()`

Every migration it can see, in the order it will run them, whether or not they
have been applied:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = {
    { name = "002_add_note.sql",    sql = "alter table sqlguide_tasks add column note text" },
    { name = "001_create_tasks.sql", sql = "create table sqlguide_tasks (id serial primary key)" },
  },
})

for _, file in ipairs(runner:files()) do
  print(file.id, file.name, file.checksum:sub(1, 12))
end

conn:close()
```

```
1	001_create_tasks.sql	7b1055f5cfaa
2	002_add_note.sql	c4ebffb96b2a
```

Sorted by the number in front, not by the order you listed them in. Each entry
carries its `name`, its `id`, its `sql`, and a `checksum` of the exact bytes,
which is [page 17](17-the-ledger-and-the-checksum.md)'s subject.

### `runner:applied()`

What the ledger says has already run. On a database that has never been
migrated it is an empty list rather than an error, because "nothing has been
applied" is the true answer there:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "drop table if exists sqlguide_migrations"

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql",
              sql = "create table sqlguide_tasks (id serial primary key)" } },
})

print("before:", #runner:applied())
runner:apply()
print("after: ", #runner:applied())

for _, row in ipairs(runner:applied()) do
  print(row.name, row.checksum:sub(1, 12))
end

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
before:	0
after: 	1
001_create_tasks.sql	7b1055f5cfaa
```

Each row has `name`, `checksum` and `applied_at`. This is the query a `status`
command wants.

### `runner:pending()`

What has not run yet, in the order it will run. It is `files()` minus
`applied()`, and it is also where the checksum check happens.

### `runner:apply()`

Runs everything pending and returns the names it applied, in order. An empty
list means there was nothing to do, which is the ordinary case on every boot
after the first.

## What may go inside a migration

Several statements are fine. Separate them with semicolons:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "drop table if exists sqlguide_migrations"

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql", sql = [[
    create table sqlguide_tasks (
      id serial primary key,
      title text not null,
      done boolean not null default false
    );
    create index sqlguide_tasks_done on sqlguide_tasks (done);
    insert into sqlguide_tasks (title) values ('the first task');
  ]] } },
})

runner:apply()

print("rows: ", conn:one("select count(*) as n from sqlguide_tasks").n)
print("index:", conn:one(
  "select count(*) as n from pg_indexes where indexname = 'sqlguide_tasks_done'").n)

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
rows: 	1
index:	1
```

Data changes are allowed too, and that is the third line above. A migration
that fills in a new column for the rows that already exist is an ordinary
migration.

## What may not go inside one

There is already a transaction open around your file. akkar opens it, runs your
SQL, writes the ledger row, and commits, all together. Two consequences follow,
and they are much easier to read now than to discover later.

### No `begin`, `commit` or `rollback` in the file

The transaction is not yours. Writing `commit` in the middle of a migration
ends akkar's transaction early, and the ledger row that was supposed to be
atomic with your change is then written separately. The run still reports
success, so nothing tells you the guarantee is gone.

Leave transaction control out. akkar has it.

### Nothing that Postgres refuses to run in a transaction

The one people meet first is `create index concurrently`, which builds an index
without locking the table for writes. It cannot run inside a transaction, and
so it cannot go in a migration:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "drop table if exists sqlguide_migrations"
conn:exec "drop table if exists sqlguide_tasks"

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = {
    { name = "001_tasks.sql",
      sql = "create table sqlguide_tasks (id serial primary key, title text)" },
    { name = "002_index.sql",
      sql = "create index concurrently sqlguide_tasks_title on sqlguide_tasks (title)" },
  },
})

local ok, why = pcall(function() return runner:apply() end)
print(ok, why)
print("applied so far:", conn:one("select count(*) as n from sqlguide_migrations").n)

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
false	db: ERROR: CREATE INDEX CONCURRENTLY cannot run inside a transaction block
applied so far:	1
```

akkar chose the atomicity and says so. There is no way to have both.

Look at the last line, though, because it is the more important lesson. The
first migration applied and was recorded. The second failed, was rolled back,
and was **not** recorded. Nothing after it was attempted.

That is deliberate: a schema stopped at a known point is much better than a
schema half way through a change nobody described. Fix the file, run again, and
it carries on from where it stopped.

If you genuinely need `concurrently`, run that statement by hand outside the
migration system, or write a plain `create index` and accept the lock.

## Checkpoint

You have this if:

- you can apply a migration from a script and see the second run do nothing
- you know why `migrate.new` needs a connection and not the factory
- you can list what `files`, `applied`, `pending` and `apply` each give you
- you know why `begin` and `create index concurrently` are out

Next: [16. Names, numbers and order](16-names-and-order.md).
