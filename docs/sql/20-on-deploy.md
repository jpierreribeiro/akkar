# 20. Running them on deploy

By the end of this page you will have a migration script you can run on every
deploy, you will know where it goes in the sequence, and you will know how to
write a migration that does not break the version of your app that is still
running.

This is the last page of the track.

## The script

One file, and it does one thing:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

-- A connection of its own, and NO statement_timeout on it.
-- Postgres counts the wait for the advisory lock against statement_timeout,
-- and a long migration is not a runaway query.
local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  pool_size = 0,
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

local applied = runner:apply()

print("applied " .. #applied .. " migration(s)")
for _, name in ipairs(applied) do print("  " .. name) end

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
applied 1 migration(s)
  001_create_tasks.sql
```

In your project it is the same file with `dir = "migrations"` instead of
`files`, no `table` line, and no `drop table` at the end. The two drops are
here so this page cleans up after itself.

Run it with `lua5.4 migrate.lua`, or from a binary built by `akkar build` with
`./myapp run migrate.lua`.

## Where it goes in the deploy

**Before the new code starts serving, and after the new code exists.**

The order that works:

1. Build the new version.
2. Run the migrations, using the new version's migration files.
3. Start the new version.
4. Stop the old version.

Step 2 has to happen with the new files, because they are the ones that
describe the schema the new code expects. And it has to finish before step 3,
because the new code will fail on the first request otherwise.

`docs/DEPLOY.md` has the container-level detail, including the important
practical point that a `scratch` image has no shell, so it cannot read a
migrations directory. That is [page 19](19-migrations-as-data.md)'s subject and
the reason `files` exists.

### Running it on every instance is fine

You do not have to arrange for exactly one instance to run migrations. Let them
all run it. [The lock](18-the-lock.md) makes that safe: one gets in, the others
wait, and then find nothing to do.

That is worth choosing deliberately, because the alternative, a special
migration step that runs once somewhere, is a piece of deployment machinery
that can be forgotten, skipped, or run against the wrong database.

## A failure stops the deploy, because it exits non-zero

An error out of `apply` is not caught by anything, so the script raises and
Lua exits with status `1`. Every deployment tool in the world knows what that
means.

Here is a real failure, with a typo in the second migration
(`add colum` instead of `add column`):

```lua no-run
local runner = migrate.new(conn, {
  files = {
    { name = "001_create_tasks.sql",
      sql = "create table sqlguide_tasks (id serial primary key)" },
    { name = "002_typo.sql",
      sql = "alter table sqlguide_tasks add colum note text" },
  },
})

local applied = runner:apply()
print("applied " .. #applied .. " migration(s)")
```

```
lua5.4: db: ERROR: syntax error at or near "text" (43)
stack traceback:
	[C]: in function 'error'
	./akkar/migrate.lua:568: in method 'apply'
	migrate.lua:26: in main chunk
	[C]: in ?
exit=1
```

The `print` never ran. And the ledger afterwards had exactly one row in it,
`001_create_tasks.sql`, so the database stopped at a point that is written
down. Fix the typo, deploy again, and `002` runs.

**Do not wrap `apply` in `pcall` to keep the deploy going.** A service that
starts against a schema it does not have will fail on real requests instead,
which is the same outage with the cause removed from view.

## Checking without applying

Sometimes you want to know before you press the button. `pending()` tells you,
and touches nothing:

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
  files = {
    { name = "001_create_tasks.sql",
      sql = "create table sqlguide_tasks (id serial primary key)" },
    { name = "002_add_note.sql",
      sql = "alter table sqlguide_tasks add column note text" },
  },
})

print("applied: " .. #runner:applied())
for _, file in ipairs(runner:pending()) do print("pending: " .. file.name) end

runner:apply()

print("after, applied: " .. #runner:applied())
print("after, pending: " .. #runner:pending())

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
applied: 0
pending: 001_create_tasks.sql
pending: 002_add_note.sql
after, applied: 2
after, pending: 0
```

That is a `status` command. It is also the check to run in CI on a pull
request: if `pending()` raises there, somebody edited an applied migration, and
you would much rather find out then.

## Write migrations that do not break the running version

This is the part that catches people who have done everything else right.

During a rolling deploy, the old version and the new version are running **at
the same time**, against the database you just migrated. So a migration must
not break the old code, even for the thirty seconds before it is gone.

The rule: **a migration may add, and may not take away, until nothing uses the
thing being taken away.**

A rename is the clearest example. Do not rename a column in one migration.
Instead:

1. **Add** the new column. Deploy code that writes both and reads the old one.
2. Backfill the new column from the old one, in a migration.
3. Deploy code that reads the new one.
4. **Then** drop the old column, in a later migration, once nothing reads it.

Four deploys instead of one, and none of them has a moment where the running
code and the database disagree.

The same shape applies to the others:

| change | safe now | needs a later step |
|---|---|---|
| add a nullable column | yes | no |
| add a column with a default | yes | no |
| add an index | yes, though it locks writes while it builds | no |
| add a `not null` constraint | only if every row already has a value | backfill first |
| rename a column | no | add, backfill, switch, drop |
| drop a column | no | stop using it, deploy, then drop |
| change a column's type | no | new column, backfill, switch, drop |

If you can afford downtime, take it and ignore all of this. It is much simpler.
Just do it on purpose rather than by accident.

## Forward only

There is no down migration in akkar and there will not be, which
[page 15](15-what-a-migration-is.md) and the module's own source argue out. The
consequence for your deploy is worth stating plainly here:

**Your rollback plan cannot be "run the down migration".** It has to be either
"the new schema still works with the old code", which the expand-and-contract
rule above buys you, or "restore from a backup", which you should have tested.

A migration that was wrong is fixed by another migration that says what should
have been said.

## Checkpoint

You have this if:

- you have a migration script that exits non-zero when something fails
- you know it runs before the new version serves, and that every instance
  running it is fine
- you can say why you do not `pcall` around `apply`
- you can describe the four steps of renaming a column without downtime

## The end of the track

You now know every method in `akkar.sql` and every option in `akkar.migrate`.

Where to go next:

- [The reference for `akkar.sql`](../reference/sql.md) and
  [for `akkar.migrate`](../reference/migrate.md), for looking things up
- [`docs/DEPLOY.md`](../DEPLOY.md), for the container-level detail
- [The recipes](../recipes/README.md), for whole tasks built out of these parts
- The source, `akkar/sql.lua` and `akkar/migrate.lua`, which is short and
  explains its own decisions at length
