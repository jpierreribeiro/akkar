# 17. The ledger and the checksum

By the end of this page you will know what akkar writes down about a migration,
why that row is written at the same instant as the change itself, and why
editing a migration that has already run is refused rather than warned about.

## The ledger is one small table

akkar creates it the first time you apply anything:

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
runner:apply()

for _, row in ipairs(conn:many([[
  select column_name, data_type
  from information_schema.columns
  where table_name = 'sqlguide_migrations'
  order by ordinal_position]])) do
  print(row.column_name, row.data_type)
end

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
name	text
checksum	text
applied_at	timestamp with time zone
```

Three columns:

- **`name`** is the file name, and it is the primary key. That is what "applied
  once" means in the end: a second row with the same name cannot exist.
- **`checksum`** is a fingerprint of the file's exact bytes.
- **`applied_at`** is when it ran.

The table is called `akkar_migrations` unless you say otherwise. The name goes
into SQL as an identifier, so it cannot be a bound parameter, so it is checked
when you build the runner:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function()
  return migrate.new(conn, { table = "my migrations; drop table users" })
end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: 'my migrations; drop table users' is not a usable table name; it goes into SQL as an identifier, which cannot be a bound parameter, so it must be letters, digits and underscores
```

The name comes from your own configuration rather than from a request, so this
is not a door anybody can walk through today. It is checked anyway, because
"not reachable from outside" is a property of the calling code, and calling
code changes.

## The row is written inside the same transaction

This is the sentence that makes the module worth having:

```
begin
  <your migration>
  insert into akkar_migrations (name, checksum) values (...)
commit
```

Both, or neither.

Imagine the other order: apply the change, commit, then record it. Now imagine
the process is killed in the gap. It happens: an out of memory kill, a lost
connection, a deploy timeout. The change is applied and unrecorded, so the next
boot finds it pending and applies it **again**.

For `create table` the second run fails loudly, which is the good case. For an
`insert`, or an `update ... set count = count + 1`, it succeeds quietly and
your data is wrong.

You can see the atomicity from the failing side. A migration that raises is
rolled back **and** not recorded, and nothing after it is attempted:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "drop table if exists sqlguide_migrations"
conn:exec "drop table if exists sqlguide_first"
conn:exec "drop table if exists sqlguide_never"

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = {
    { name = "001_first.sql", sql = "create table sqlguide_first (id int)" },
    { name = "002_boom.sql",  sql =
      "create table sqlguide_boom (id int); select this_function_does_not_exist()" },
    { name = "003_never.sql", sql = "create table sqlguide_never (id int)" },
  },
})

local ok, why = pcall(function() return runner:apply() end)
print(ok, why)

print("first exists:", conn:one("select to_regclass('sqlguide_first') is not null as p").p)
print("boom exists: ", conn:one("select to_regclass('sqlguide_boom') is not null as p").p)
print("never exists:", conn:one("select to_regclass('sqlguide_never') is not null as p").p)
print("recorded:    ", conn:one("select count(*) as n from sqlguide_migrations").n)

conn:exec "drop table sqlguide_first"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
false	db: ERROR: function this_function_does_not_exist() does not exist (45)
first exists:	true
boom exists: 	false
never exists:	false
recorded:    	1
```

Read those four lines carefully, because they are the whole design.

`001` ran and is recorded. `002` failed: the `create table` inside it was rolled
back even though that statement itself was fine, because the whole file is one
transaction. `003` was never attempted. And the ledger has exactly one row, so
it is an honest account of where the database actually is.

Fix the file, run again, and it carries on from `002`.

## The checksum, and why an edit is an error

The checksum is a SHA-256 of the file's exact bytes:

```lua
local migrate = require "akkar.migrate"

print(migrate.checksum_of "create table sqlguide_tasks (id serial primary key)")
print(migrate.checksum_of "create table sqlguide_tasks (id serial primary key) ")
```

```
7b1055f5cfaae63c414f4f512a1fc2f2f1094836330353de5b6e26b3481da5d0
b0566e097c3e5aaab431691e981fef57cbe42c0fa6ef959fdf0b55afe0291003
```

One trailing space, a completely different fingerprint. That is what a hash is
for.

If a file that was already applied has different bytes today than when it ran,
akkar stops:

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

local original = "create table sqlguide_tasks (id serial primary key)"
local edited   = original .. ", title text)"

migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql", sql = original } },
}):apply()

local changed = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql", sql = edited } },
})

local ok, why = pcall(function() return changed:apply() end)
print(ok)
print(why)

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
false
./akkar/migrate.lua:544: akkar.migrate: '001_create_tasks.sql' has changed since it was applied (ledger 7b1055f5cfaae63c414f4f512a1fc2f2f1094836330353de5b6e26b3481da5d0, file a50bdd97901b307bb678bb2adcc74938fba3086a8f76bc928a1d4688ed92b027) -- the database no longer matches the files. Restore the file, or write a new migration for whatever the edit was trying to say
```

The `./akkar/migrate.lua:544:` at the front is Lua saying which line raised.
The message you care about starts at `akkar.migrate:`, and it gives you both
fingerprints so you can tell at a glance that they differ.

### Why this is an error and not a warning

Because a warning scrolls past during a deploy.

Think about what your edit actually did. The migration already ran. Editing the
file does not change the database. It changes the **story** about the database,
so that from now on "the schema is what the migrations say" is false, and every
statement anybody makes based on that sentence is wrong. A colleague setting up
a fresh laptop gets your edited version and a different schema from yours, and
neither of you can tell.

**Editing an applied migration is never the answer. Writing a new one always
is.** If the change was wrong, `002_fix_it.sql` says what should have been said,
and the two files together are the true history.

The fix for the error is therefore to put the file back exactly as it was, and
to put the change you wanted into a new file.

### Two sharp edges

**Line endings count.** The bytes are compared exactly, so a checkout that
rewrites line endings changes every checksum and every file reads as edited.
akkar does not normalise them, because it cannot tell a line ending inside a
string literal from one between statements. Keep your working tree's line
endings stable, which for most people means letting git leave them alone.

**A file that was applied and then deleted is not an error.** Squashing old
migrations away once they are on every server is an ordinary thing to do, and
refusing it would make akkar the reason your directory can never be cleaned:

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

migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql",
              sql = "create table sqlguide_tasks (id serial primary key)" } },
}):apply()

local squashed = migrate.new(conn, { table = "sqlguide_migrations", files = {} })
print("pending:", #squashed:pending())
print("applied:", #squashed:applied())

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
pending:	0
applied:	1
```

The ledger still remembers it. There is simply no file to compare against, and
that is fine.

## Checkpoint

You have this if:

- you can name the three columns of the ledger and say which one is the key
- you can explain why the ledger row is written in the same transaction, using
  the crash-in-the-gap story
- you know what to do when you get a checksum error, and it is not "edit the
  ledger"
- you know that a deleted migration is fine and an edited one is not

Next: [18. The lock](18-the-lock.md).
