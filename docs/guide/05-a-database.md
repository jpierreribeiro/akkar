# 5. A database, from zero

By the end of this page you will have a real database running on your machine,
a `tasks` table inside it, and a migration that created that table.

The task list itself does not change on this page. Page 6 is where it starts
using the database. This page is about getting the database there.

Everything happens in the `akkar` folder, same as
[page 2](02-your-first-route.md).

## Why the tasks keep disappearing

Your tasks live in a Lua table:

```lua no-run
local tasks = {
  { id = 1, title = "buy milk", done = false },
}
```

That table lives in the memory of the running program. When the program stops,
its memory goes back to the operating system, and everything in it is gone.
That is not a bug. It is what memory is.

A database is a separate program whose whole job is to keep data after
everything else stops. It writes to disk, it survives a restart, and several
programs can read the same data at once.

This guide uses **Postgres**, because it is free, it is what most backends
use, and akkar ships an adapter for it.

## Start Postgres with Docker

Docker runs a program in a box with everything it needs already inside. You do
not install Postgres, you download a box that has it.

If you do not have Docker, install [Docker
Desktop](https://www.docker.com/products/docker-desktop/) first. If you
already have Postgres installed some other way, you can use that instead. The
only thing that matters is that the connection details below match.

Run this once:

```sh
docker run -d --name akkar-pg \
  -e POSTGRES_PASSWORD=akkar \
  -e POSTGRES_DB=akkar \
  -p 55432:5432 \
  postgres:16-alpine
```

Docker prints one long line of letters and numbers. That is the id of the
container it just made, it is different every time, and you never need it. The
first run also downloads the Postgres image, which takes a minute.

What each part means:

| Part | Means |
|---|---|
| `-d` | run in the background, do not hold this terminal |
| `--name akkar-pg` | call it `akkar-pg`, so you can stop and start it by name |
| `-e POSTGRES_PASSWORD=akkar` | the password for the database user |
| `-e POSTGRES_DB=akkar` | make a database called `akkar` inside it |
| `-p 55432:5432` | port 55432 on your machine reaches port 5432 in the box |
| `postgres:16-alpine` | which box: Postgres 16, small version |

**Why 55432 and not 5432?** 5432 is the port Postgres normally uses. If you
ever installed Postgres directly, that port is already taken, and the two would
fight. 55432 is free on almost every machine, so nothing clashes.

Check that it is running:

```sh
docker ps --filter name=akkar-pg
```

```
CONTAINER ID   IMAGE                COMMAND                  CREATED        STATUS       PORTS                                           NAMES
342dc2d7dc23   postgres:16-alpine   "docker-entrypoint.s…"   36 hours ago   Up 6 hours   0.0.0.0:55432->5432/tcp, [::]:55432->5432/tcp   akkar-pg
```

`Up` is the word you are looking for. That line was captured on a machine where
the container had been running for a while, so yours will say a few seconds
instead of hours.

Two commands for later, when you reboot or want the memory back:

```sh
docker stop akkar-pg
docker start akkar-pg
```

`stop` and `start` keep your data. Only `docker rm akkar-pg` throws it away.

## What is inside a database

Three words, and then we use them.

A **table** is a grid, like one sheet in a spreadsheet. Your task list will
have a table called `tasks`.

A **column** is one named slot in that grid, and it has a type: `text`,
`integer`, `boolean`. Every row has the same columns.

A **row** is one entry. One task is one row.

```
tasks
 id | title            | done
----+------------------+-------
  1 | buy milk         | false
  2 | walk the dog     | false
```

The table has to exist before you can put anything in it. Making it is what
the rest of this page is about.

## Talk to the database from Lua

Create `check-db.lua` in the `akkar` folder. This is the whole file.

```lua
local db = require "akkar.db"

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  pool_size = 0,
}

local conn = open()
print(conn:one("select version() as version").version)
conn:close()
```

```sh
lua5.4 check-db.lua
```

```
PostgreSQL 16.13 on x86_64-pc-linux-musl, compiled by gcc (Alpine 15.2.0) 15.2.0, 64-bit
```

The database answered. That is the whole point of the file.

Three things in it are worth naming.

**`db.connect { ... }` does not connect.** It returns a function. Calling that
function, `open()`, is what opens a connection. That looks like extra work now,
and page 6 shows why it is right: a server hands that function to akkar and
akkar calls it once per request.

**`pool_size = 0` means "no pool".** A server keeps a small set of connections
open and shares them, because opening one costs real time. A one-off script
wants exactly one connection, and `0` says so. Page 6 uses the normal setting.

**`conn:one(...)` runs one query and gives back the first row.** The row is an
ordinary Lua table, so `row.version` is that column. `select version()` asks
Postgres what version it is, which is the smallest useful question there is.

### If Postgres is not running

Stop the container and run the file again:

```sh
docker stop akkar-pg
lua5.4 check-db.lua
```

```
lua5.4: /home/jp/.luarocks/share/lua/5.4/pgmoon/cqueues.lua:18: socket:connect: Connection refused
stack traceback:
	[C]: in function 'error'
	/home/jp/.luarocks/share/lua/5.4/cqueues/socket.lua:90: in function </home/jp/.luarocks/share/lua/5.4/cqueues/socket.lua:75>
	(...tail calls...)
	/home/jp/.luarocks/share/lua/5.4/cqueues/socket.lua:271: in method 'connect'
	/home/jp/.luarocks/share/lua/5.4/pgmoon/cqueues.lua:18: in method 'connect'
	/home/jp/.luarocks/share/lua/5.4/pgmoon/init.lua:300: in method 'connect'
	./akkar/db.lua:301: in local 'open'
	check-db.lua:12: in main chunk
	[C]: in ?
```

Those paths are from the machine this guide was written on. Yours will say
something else, and the last two lines are the ones that matter: `akkar/db.lua`
tried to connect, and `check-db.lua:12` is your `open()` call.

This one message is uglier than akkar's usual. Nothing in it names your
settings or tells you what to check, because the failure happens inside the
Postgres driver before akkar sees it.

`Connection refused` means nothing was listening at that address. Almost always
one of three things: the container is stopped, the port in your file does not
match the port in the `docker run` command, or you never ran `docker run` at
all.

Start it again before moving on:

```sh
docker start akkar-pg
```

## What a migration is

You need a `tasks` table. The SQL that makes one is a single statement:

```sql
create table tasks (
  id    serial primary key,
  title text    not null,
  done  boolean not null default false
)
```

You could type that into a terminal once and be done. Then the questions start.
Did you run it on your laptop, or only on your colleague's? Did the server get
it? What about the copy of the database you made last week? In three months,
what exactly is in this table, and who changed it?

**A migration is that SQL kept in a file, with a number in front of it, and a
record of whether it has already run.** Three parts, and each one answers one
of those questions.

akkar's runner is `akkar.migrate`. It does this:

1. Look at the list of migrations, in number order.
2. Look in the database at a table called `akkar_migrations`, which is the
   record of what has already run. Call it the ledger.
3. Run the ones that are not in the ledger, oldest first.
4. Write each one into the ledger as it runs.

So running it twice does nothing the second time. That is the property that
makes it safe to run on every start.

### Three rules, and the reasons

**Every migration needs a number at the front of its name.** `001_create_tasks.sql`,
not `create_tasks.sql`. The number is what puts them in order, and order
matters: a migration that adds a column to `tasks` has to run after the one
that creates `tasks`. akkar refuses a name with no number rather than guessing.

**The ledger row is written in the same transaction as the change.** A
transaction is a group of statements that either all happen or none do. So
either the table is created and the ledger says so, or neither. If the machine
dies half way through, you never get the state where the change happened and
nothing recorded it, which is the state that makes the next start run it again.

**There is no way to undo a migration, and that is deliberate.** Other tools
have "down" migrations that reverse a change. akkar does not, and its reason is
worth reading once, because it changes how you write them. Undoing
`add column` means `drop column`, which is fine on an empty table and destroys
a column of real data on a full one. The migration that added the column knew
what to put there. The one that removes it does not know what to put back. So
the only direction is forward: if a migration was wrong, the fix is another
migration that says what should have been said.

## Write the migration and run it

Create `migrate.lua` in the `akkar` folder. This is the whole file.

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

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
  files = {
    { name = "001_create_tasks.sql", sql = [[
      create table tasks (
        id    serial primary key,
        title text    not null,
        done  boolean not null default false
      )
    ]] },
  },
})

local applied = runner:apply()

if #applied == 0 then
  print "nothing to do; the database is already up to date"
end
for _, name in ipairs(applied) do
  print("applied " .. name)
end

conn:close()
```

```sh
lua5.4 migrate.lua
```

```
applied 001_create_tasks.sql
```

Run it again:

```sh
lua5.4 migrate.lua
```

```
nothing to do; the database is already up to date
```

That second run is the whole idea. The migration is in the ledger now, so
akkar left it alone.

Two pieces of Lua in that file, in case they are new to you.

**`[[ ... ]]` is a long string.** Text between double square brackets can span
many lines and can contain quotes without escaping them. SQL is full of both,
so this is the sensible way to write it.

**`runner:apply()` returns a list of the names it applied**, which is empty
when there was nothing to do. `#applied` is how many are in that list.

### The columns you just made

- `id serial primary key` is a whole number that Postgres fills in for you,
  counting up from 1. `primary key` means it identifies the row and cannot
  repeat.
- `title text not null` is text, and `not null` means a row without one is
  refused by the database itself.
- `done boolean not null default false` is true or false, and a row that does
  not say gets `false`.

## Look at what happened

You do not need Postgres installed to look inside. `docker exec` runs a command
inside the running box, and `psql` is the terminal that comes with Postgres.

```sh
docker exec akkar-pg psql -U postgres -d akkar -c '\d tasks'
```

```
                            Table "public.tasks"
 Column |  Type   | Collation | Nullable |              Default              
--------+---------+-----------+----------+-----------------------------------
 id     | integer |           | not null | nextval('tasks_id_seq'::regclass)
 title  | text    |           | not null | 
 done   | boolean |           | not null | false
Indexes:
    "tasks_pkey" PRIMARY KEY, btree (id)
```

There is your table. `\d tasks` means "describe the table called tasks".

And the ledger, which akkar made for itself the first time you ran the
migration:

```sh
docker exec akkar-pg psql -U postgres -d akkar -c 'select name, applied_at from akkar_migrations'
```

```
         name         |          applied_at           
----------------------+-------------------------------
 001_create_tasks.sql | 2026-08-16 08:31:58.198203+00
(1 row)
```

One row, one migration. That row is the reason the second run did nothing.

## Two mistakes akkar refuses

Both are worth seeing on purpose, because both are easy to make.

### A name with no number

Change `name = "001_create_tasks.sql"` to `name = "create_tasks.sql"` and run
it:

```sh
lua5.4 migrate.lua
```

```
lua5.4: akkar.migrate: these files have no leading id, so there is no order to run them in: create_tasks.sql
  name them like `20260816120000_add_users.sql` -- a timestamp rather than a counter, because two people branching from the same commit both pick 007 and two timestamps cannot collide
stack traceback:
	[C]: in function 'error'
	...akkar/migrate.lua:568: in method 'apply'
	migrate.lua:27: in main chunk
	[C]: in ?
```

The path to `migrate.lua` inside akkar will look different on your machine.
`migrate.lua:27` is your file, the line that calls `apply`.

The message suggests a date and time instead of a counter. That is advice for
later, when more than one person writes migrations: two people both pick `007`
and collide, while two timestamps cannot. On your own, `001`, `002`, `003` is
fine, and this guide uses it.

Put the name back before continuing.

### Editing a migration that already ran

Add a column to the SQL of `001_create_tasks.sql`, for example a line saying
`note  text`, and run it again:

```sh
lua5.4 migrate.lua
```

```
lua5.4: ...akkar/migrate.lua:544: akkar.migrate: '001_create_tasks.sql' has changed since it was applied (ledger dbc2018b8b23f9ddbc5e6b5cd5d5e4bf3008b664d8295f2ec3b5e89a2aad606e, file 5aae8df89a98b12bdc4c2bbe72c79a96a175c5af6155e58a76bb246fcafc39b2) -- the database no longer matches the files. Restore the file, or write a new migration for whatever the edit was trying to say
stack traceback:
	[C]: in function 'error'
	...akkar/migrate.lua:568: in method 'apply'
	migrate.lua:28: in main chunk
	[C]: in ?
```

akkar stored a fingerprint of the text when it ran, and the text is different
now. It stops instead of guessing.

This looks strict and it is protecting you. Your migration already ran, so
editing it does not change the database. It only makes your files disagree with
reality, silently, and then nobody can trust either one. **Editing an applied
migration is never the answer. Writing a new one always is.**

Undo your edit before continuing.

## Where migrations normally live

This guide keeps the SQL inside `migrate.lua`, because that keeps every example
on this page a single file you can run.

A real project keeps each migration as its own `.sql` file in a folder, and
points akkar at the folder:

```lua no-run
migrate.new(conn, { dir = "migrations" })
```

Then `migrations/001_create_tasks.sql` is a file with SQL in it and nothing
else, `002_...` sits next to it, and akkar reads the whole folder in number
order. Nothing about the rules changes. The names, the ledger and the refusals
are the same.

One consequence of the guide's way, said out loud so it does not surprise you:
each of the next pages adds **only the migration it introduces**. Page 7 adds
`002`, page 8 adds `003`, and neither repeats `001`, because `001` is already
in your ledger. That means no single file in this guide can build the database
from empty. A folder of `.sql` files does not have that problem, which is
exactly why real projects use one.

## Checkpoint

You have this if:

- `docker ps --filter name=akkar-pg` shows a line saying `Up`
- `lua5.4 check-db.lua` prints a PostgreSQL version
- `lua5.4 migrate.lua` prints `nothing to do; the database is already up to
  date`
- `docker exec akkar-pg psql -U postgres -d akkar -c '\d tasks'` shows three
  columns

And you can say what a migration is in one sentence: a numbered file of SQL
that runs once, in order, and is recorded so it never runs twice.

The table is empty and nothing writes to it yet. That is next:
[6. Storing and reading rows](06-storing-and-reading.md).
