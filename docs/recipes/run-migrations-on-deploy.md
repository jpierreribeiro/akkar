# Run migrations on deploy

A program that brings the database up to date and exits, safe to run from
every instance of a deploy at the same time.

## The whole file

Save it as `migrate.lua`, next to your `app.lua`.

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"
local logging = require "akkar.log"

local log = logging.new()

-- The migrations travel inside the program, not beside it. A deploy artefact
-- with no shell and no files still has these.
local MIGRATIONS = {
  { name = "20260816090000_create_notes.sql", sql = [[
    create table notes (
      id      serial primary key,
      body    text not null,
      created timestamptz not null default now()
    ) ]] },
}

-- pool_size = 0 opens one connection and no pool. This program makes one
-- connection, uses it, and ends.
local connection = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  pool_size = 0,
}()

local ok, why = pcall(function()
  local runner = migrate.new(connection, { files = MIGRATIONS })
  local applied = runner:apply()
  log:info("migrations applied", { count = #applied })
  for _, name in ipairs(applied) do log:info("migrated", { file = name }) end
end)

connection:close()

if not ok then
  log:error("migrations failed", { detail = tostring(why) })
  os.exit(1)
end
```

Run it before the server, and let the exit code stop the deploy:

```sh
lua5.4 migrate.lua && lua5.4 app.lua
```

## Try it

```sh
lua5.4 migrate.lua
```

```
INFO  migrations applied count=1
INFO  migrated file=20260816090000_create_notes.sql
```

Again:

```
INFO  migrations applied count=0
```

Nothing happened the second time, and nothing will happen on the hundredth.
akkar keeps a table called `akkar_migrations` listing what has run, matched by
name and by a checksum of the SQL, so an edit to a migration that has already
been applied is refused rather than silently ignored.

## Why it is a separate program and not part of `app:run`

Migrating inside the server means every process of a deploy migrates, and the
schema changes while the previous version is still serving requests against
it. As a separate program the deploy can order the two: migrate once, then
start. Running it from several machines at once is still safe, because
`runner:apply()` takes a Postgres advisory lock first and the second runner
waits rather than racing. Migrations are up only, on purpose: a down migration
is code that has to be right on the worst day of the release and is almost
never tested, so the way back is a new migration forward. During development
you can keep them as files with `migrate.new(connection, { dir =
"migrations" })` instead of embedding them, which
[page 5](../guide/05-a-database.md) of the guide shows.
