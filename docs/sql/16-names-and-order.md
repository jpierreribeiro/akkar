# 16. Names, numbers and order

By the end of this page you will know exactly how akkar decides which migration
runs first, why the number in front is not optional, and why a timestamp is a
better number than a counter.

## The name is data

akkar reads two things out of a migration's name: the number at the front,
which decides the order, and the rest, which is for you.

The number is the digits at the very start, followed by an underscore or a
hyphen:

| name | id | works? |
|---|---|---|
| `001_create_tasks.sql` | 1 | yes |
| `2_add_note.sql` | 2 | yes |
| `20260816120000_add_users.sql` | 20260816120000 | yes |
| `3-three.sql` | 3 | yes, a hyphen is fine too |
| `create_tasks.sql` | none | refused |
| `003create.sql` | none | refused, there is no separator |

## The number is read as a number

This matters more than it sounds, and it is the reason akkar parses the digits
instead of sorting the names as text.

Sort `2_users.sql`, `9_add_index.sql` and `10_add_column.sql` as text and you
get **10, 2, 9**, because the character `"1"` comes before `"2"`. The tenth
migration would run first.

akkar reads the digits and compares the numbers:

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
    { name = "10_add_column.sql", sql = "select 1" },
    { name = "9_add_index.sql",   sql = "select 1" },
    { name = "2_users.sql",       sql = "select 1" },
  },
})

for _, file in ipairs(runner:files()) do print(file.id, file.name) end

conn:close()
```

```
2	2_users.sql
9	9_add_index.sql
10	10_add_column.sql
```

Two, nine, ten, which is what anybody would expect and what plain text sorting
does not give you.

This was a real defect in akkar, found by comparing it against another runner.
It is worth knowing about even though it is fixed, because of the shape of it:
everything works until the tenth migration, which is weeks after anybody would
think to check, and by then the symptom looks like a broken migration rather
than a broken sort.

## A name with no number is refused

akkar will not guess where an unnumbered file goes:

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
  files = { { name = "create_tasks.sql", sql = "select 1" } },
})

local ok, why = pcall(function() return runner:files() end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: these files have no leading id, so there is no order to run them in: create_tasks.sql
  name them like `20260816120000_add_users.sql` -- a timestamp rather than a counter, because two people branching from the same commit both pick 007 and two timestamps cannot collide
```

Falling back to text order for the odd file would mean the ordering rule
changes depending on what is in the directory, which is worse than either rule
on its own.

## Two files with the same number are refused

This is the one that bites teams, and it is the reason for the advice in that
error message:

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
    { name = "007_add_email.sql", sql = "select 1" },
    { name = "007_add_phone.sql", sql = "select 1" },
  },
})

local ok, why = pcall(function() return runner:files() end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: two migrations share an id, so which runs first is up to the filesystem: 7 (007_add_email.sql and 007_add_phone.sql)
  this is what happens when two branches both pick the next counter; renaming one to a timestamp fixes it for good
```

Here is how it happens, and notice that nobody does anything wrong.

You and a colleague both start work on Monday. The last migration in `main` is
`006`. You write `007_add_email.sql`. They write `007_add_phone.sql`. Both
branches pass their tests, because each has only one `007` in it. Both get
merged. Now the directory has two, and which one runs first is decided by
whatever order the filesystem hands them over.

akkar refuses instead of choosing. A refusal at boot with both names in it is a
five minute rename. Two migrations applied in an order nobody tested is an
afternoon.

## So use a timestamp, not a counter

**Two people cannot pick the same timestamp.** That is the whole argument, and
it is why every error message here suggests one.

Get one from the shell when you make the file:

```sh
date +%Y%m%d%H%M%S
```

```
20260816115920
```

So a migration is `20260816115920_add_email.sql`. It sorts correctly as a
number, it is unique without any coordination, and it tells you when it was
written, which is useful when you are reading a directory of forty of them.

Counters are fine on your own. This guide's own pages use `001`, `002`, `003`,
because there is one of you. The moment there are two of you, switch, and you
do not have to rename the old ones: `001` is a smaller number than
`20260816115920`, so the old ones simply keep sorting first.

## A migration that arrives out of order still runs

This is the last case, and it is worth seeing because akkar does not refuse it.

You apply `20260816120000`. Then a colleague's branch merges, carrying
`20260815090000`, which is **older**. It has not been applied here, so it is
pending, so it runs now, after the newer one:

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

local newer = { name = "20260816120000_create_tasks.sql",
                sql = "create table sqlguide_tasks (id serial primary key)" }
local older = { name = "20260815090000_add_note.sql",
                sql = "alter table sqlguide_tasks add column note text" }

local first = migrate.new(conn, { table = "sqlguide_migrations", files = { newer } })
print("run one:", table.concat(first:apply(), ", "))

local both = migrate.new(conn, { table = "sqlguide_migrations",
                                 files = { newer, older } })
print("run two:", table.concat(both:apply(), ", "))

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
run one:	20260816120000_create_tasks.sql
run two:	20260815090000_add_note.sql
```

The older file ran second. That is what every migration runner does, and it is
the least surprising of the bad options, but be clear about what it means: the
order these two ran in on this database is not the order they will run in on a
fresh one. On a new laptop, `20260815090000` runs first, and if it depends on
something `20260816120000` created, it fails there and worked here.

The habit that avoids it: **before you merge, rebase and rename your migration
so it is the newest one.** That is a rename of a file nobody has applied yet,
which is free.

## Checkpoint

You have this if:

- you can say what akkar reads out of a migration's name
- you know why `10_` sorting before `9_` was a real bug and is not one now
- you know the two refusals, and that both are about ordering
- you would use `date +%Y%m%d%H%M%S` for a name on a team

Next: [17. The ledger and the checksum](17-the-ledger-and-the-checksum.md).
