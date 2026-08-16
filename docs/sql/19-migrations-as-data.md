# 19. Migrations as data

By the end of this page you will know the two ways to give akkar your
migrations, why the second one exists, and how to move from one to the other
without every migration looking edited.

## The normal way is a directory

A folder of `.sql` files, one per migration, and nothing else:

```
migrations/
  20260816090000_create_tasks.sql
  20260816093000_add_note.sql
```

```lua no-run
migrate.new(conn, { dir = "migrations" }):apply()
```

Here it is end to end, with the example making its own folder so you can run it:

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

local dir = "/tmp/sqlguide-migrations"
os.execute("rm -rf " .. dir)
os.execute("mkdir -p " .. dir)

local function write(name, body)
  local file = assert(io.open(dir .. "/" .. name, "w"))
  file:write(body)
  file:close()
end

write("20260816090000_create_tasks.sql", [[
create table sqlguide_tasks (
  id serial primary key,
  title text not null,
  done boolean not null default false
);
]])
write("20260816093000_add_note.sql", [[
alter table sqlguide_tasks add column note text;
]])

local runner = migrate.new(conn, { dir = dir, table = "sqlguide_migrations" })

for _, file in ipairs(runner:files()) do print("found:  ", file.name) end
for _, name in ipairs(runner:apply()) do print("applied:", name) end

for _, row in ipairs(conn:many([[
  select column_name from information_schema.columns
  where table_name = 'sqlguide_tasks' order by ordinal_position]])) do
  print("column: ", row.column_name)
end

os.execute("rm -rf " .. dir)
conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
found:  	20260816090000_create_tasks.sql
found:  	20260816093000_add_note.sql
applied:	20260816090000_create_tasks.sql
applied:	20260816093000_add_note.sql
column: 	id
column: 	title
column: 	done
column: 	note
```

Only files ending in `.sql` are read, and only in that folder itself.
Subdirectories are skipped on purpose: a folder somebody made to "archive" old
migrations should not be applied, and applying an archive is a worse failure
than not finding it.

A directory that is not there is an error rather than "nothing to migrate",
because a mistyped path would otherwise look exactly like a project that has
not written its first migration yet:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  dir = "/tmp/sqlguide-does-not-exist", table = "sqlguide_migrations" })

local ok, why = pcall(function() return runner:files() end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: cannot read the migration directory '/tmp/sqlguide-does-not-exist' -- it does not exist, or is not readable from the working directory
```

Note the last words. The path is relative to the **working directory of the
process**, not to your source file. Running your app from a different folder is
the usual cause of that message when the directory really does exist.

## The other way is a list

```lua no-run
migrate.new(conn, {
  files = {
    { name = "001_create_tasks.sql", sql = "create table tasks (...)" },
    { name = "002_add_note.sql",     sql = "alter table tasks add column note text" },
  },
})
```

Same input, handed over directly instead of read from disk. Every rule from the
last four pages is unchanged: the names still need numbers, the ledger is the
same, the checksums are computed the same way.

Pass one or the other, never both:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function()
  return migrate.new(conn, { dir = "migrations", files = {} })
end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: pass `dir` or `files`, not both -- two sources of migrations is two answers to what has been applied
```

And the shape of each entry is checked when you build the runner, not when you
apply, because the alternative is a failure half way through a deploy while
holding the lock:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function()
  return migrate.new(conn, { files = { { name = "001_create_tasks.sql" } } })
end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: files[1] must be { name = string, sql = string }
```

## Why the list exists: a container with no shell

This is not a convenience. It is a deployment that was found the hard way.

Lua has no way to list a directory. There is no `readdir` in the standard
library, and adding a C library for it would trade away the thing that makes
`akkar build` worth having. So akkar shells out to `find`, through `io.popen`.

`io.popen` needs `/bin/sh`.

The single-file binary `akkar build` produces runs happily in a `scratch`
container: two files, no libc, no shell. That is the whole point of the
runtime. And in that image, listing a directory is impossible. The failure
looked like this, and it is a good lesson in reading errors:

```
could not list /migrations: ... No such file or directory
```

The missing file is the **shell**, not the directory. That was proven rather
than guessed: the same binary, the same mount, the same database, applied both
migrations from an Alpine image and neither from scratch.

akkar cannot fix that by finding another way to read a directory, because there
is not one. So the fix is that a deployment which cannot list files should not
have to. When it detects that there is no shell, it adds this to the error:

```
there is no shell in this image, which is normal for a binary built by `akkar
build` and running in a scratch container.
pass the migrations as data instead: migrate.new(db, { files = { { name = ...,
sql = ... } } })
```

There is a second reason to like it, beyond the container. A deploy whose
schema travels **inside** the binary cannot fall out of step with the code. One
artefact, one schema, and no chance of copying the binary without its
migrations folder.

## Moving from a directory to a list

The checksums are computed the same way on both paths, deliberately, so the
same migration produces the same ledger row whichever way it reached akkar.
Otherwise moving would look like every migration had been edited at once, and
[page 17](17-the-ledger-and-the-checksum.md) says what akkar does about that.

You can check it yourself:

```lua
local migrate = require "akkar.migrate"

local body = "create table sqlguide_tasks (id serial primary key)\n"

local path = "/tmp/sqlguide-one-migration.sql"
local out = assert(io.open(path, "w"))
out:write(body)
out:close()

local back = assert(io.open(path, "rb"))
local from_disk = back:read "a"
back:close()
os.remove(path)

print(migrate.checksum_of(from_disk))
print(migrate.checksum_of(body))
print("same:", migrate.checksum_of(from_disk) == migrate.checksum_of(body))
```

```
e55985cb2ea74a1617203a28e2710c7c1662ebe58c12de16ef20c06afc9ec8b9
e55985cb2ea74a1617203a28e2710c7c1662ebe58c12de16ef20c06afc9ec8b9
same:	true
```

The bytes are the bytes. So the way to move is to embed the files **exactly**,
including the final newline, which is where this usually goes wrong.

Generate the Lua rather than typing it. A build step that reads the directory
and writes a module is a few lines, and it keeps the two in step:

```lua no-run
-- tools/embed-migrations.lua, run before `akkar build`
local out = assert(io.open("migrations_embedded.lua", "w"))
out:write "return {\n"

local pipe = assert(io.popen "find migrations -maxdepth 1 -name '*.sql' | sort")
for path in pipe:lines() do
  local file = assert(io.open(path, "rb"))
  local sql = file:read "a"
  file:close()
  out:write(("  { name = %q, sql = %q },\n"):format(path:match "([^/]+)$", sql))
end
pipe:close()

out:write "}\n"
out:close()
```

`%q` is the important part: it is Lua's own quoting, so a migration full of
quotes, newlines and backslashes comes back byte for byte. Then your
application does:

```lua no-run
migrate.new(conn, { files = require "migrations_embedded" }):apply()
```

The generator runs on your machine, where there is a shell. The binary runs
where there is not, and it does not need one.

## Which to use

**Development: a directory.** You are creating a new migration every few days,
and a folder of files is what an editor, a diff and a code review all
understand.

**A scratch container, or any single-artefact deploy: the list.** Because it is
the only thing that works, and because it makes the binary complete.

Both together in one project is fine, as long as one runner uses one of them.

## Checkpoint

You have this if:

- you can point a runner at a directory and at a list, and know they behave the
  same
- you know why the directory version needs a shell and where that fails
- you know the checksums match across both, and why that matters
- you would generate the embedded list rather than paste it

Next: [20. Running them on deploy](20-on-deploy.md).
