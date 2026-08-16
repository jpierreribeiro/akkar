# 18. The lock

By the end of this page you will know why a migration runner is a module rather
than a shell script, what happens when two servers boot at the same moment, and
which connection you must hand it.

## The race

Everything a migration runner does looks simple. Read a list of files, run the
ones that have not run, write down which ones you ran. That is thirty lines of
`psql` in a loop.

Then you deploy.

A rolling deploy starts several copies of your service at the same time, on
purpose, so the old ones can be shut down without any downtime. All of them run
your migrations at boot. So:

1. Instance A reads the ledger and sees `007` is pending.
2. Instance B reads the ledger and sees `007` is pending.
3. Both run it.

The lucky outcome is that one of them hits a duplicate key error on the ledger
and crash-loops until somebody looks. The unlucky one is a migration whose
statements are not themselves unique, an `insert`, an
`update ... set n = n + 1`, applied twice with no error anywhere.

## The whole run happens under one lock

akkar takes a Postgres **advisory lock** before it does anything, on a fixed
key:

```lua
local migrate = require "akkar.migrate"

print(migrate.LOCK_KEY)
print(string.format("%x", migrate.LOCK_KEY))
```

```
418414027122
616b6b6172
```

An advisory lock is a lock on a number rather than on a table. Postgres does
not know or care what the number means. Two connections asking for the same
number is all it takes: the second one waits.

The number is the ASCII of the word `akkar` read as an integer, which is why
the hexadecimal above spells it out. It means nothing to Postgres, and it means
something to whoever is reading `pg_locks` at three in the morning.

The key is fixed and not derived from the directory or the ledger name, so at
most one migration run can happen per database at a time. A run that waits
behind an unrelated one has lost a few seconds at boot and nothing else.

### The order of operations is the point

```
take the lock
  create the ledger if it is missing
  work out what is pending
  apply them, one transaction each
release the lock
```

Working out what is pending happens **after** the lock is held. Doing it first
and then locking looks correct and gives back exactly the race the lock was
taken to close: instance B computed its list while A still had not finished,
and B's list is stale by the time B gets in.

Because the list is computed inside, instance B re-reads the ledger when it
gets the lock, finds nothing pending, and does nothing. That is the desired
outcome of a rolling deploy: one instance migrates, the rest confirm there is
nothing to do.

## Waiting is normal, waiting for ever is not

akkar waits, with a bound. The default is 30 seconds and `lock_timeout` changes
it.

Here is what happens when somebody else is holding the lock. This example takes
it by hand on one connection and then tries to migrate on another:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local config = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}

local holder = db.connect(config)()
local waiter = db.connect(config)()

holder:one("select pg_advisory_lock($1)", migrate.LOCK_KEY)

local runner = migrate.new(waiter, {
  table = "sqlguide_migrations",
  lock_timeout = 1,
  files = { { name = "001_create_tasks.sql",
              sql = "create table sqlguide_tasks (id serial primary key)" } },
})

local started = os.time()
local ok, why = pcall(function() return runner:apply() end)
print(ok)
print(why)
print("waited about " .. (os.time() - started) .. " second(s)")

holder:one("select pg_advisory_unlock($1)", migrate.LOCK_KEY)
holder:close()
waiter:close()
```

```
false
akkar.migrate: another runner has held the migration lock for more than 1 seconds.
  That is normal for a slow migration and not normal for a fast one -- check whether a previous deploy died holding it. `select * from pg_locks where locktype = 'advisory'` names the session.
waited about 1 second(s)
```

`lock_timeout = 1` is only to keep the example short. Leave it alone in a real
project unless your migrations are genuinely slow, in which case raise it.

Two designs were rejected here, and knowing why helps you read the message.

**Waiting for ever** was the first version, and it is wrong in the way that
only shows at three in the morning. A lock left behind by a crashed runner, or
a migration genuinely taking twenty minutes, turns every later deploy into a
process that hangs with no output at all. Nothing times out, nothing logs, and
the orchestrator eventually kills a container that looked healthy the whole
time.

**Refusing immediately** if the lock is busy is the other obvious answer, and it
is wrong because a rolling deploy starts several instances on purpose. All but
one of them finding the lock busy is the **normal** case, not an incident.
Failing them means a healthy deploy needs a retry loop somewhere else.

So: wait, but not for ever, and say so when the wait runs out.

### Finding out who holds it

The message tells you the query. Here it is with a lock actually held:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local config = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}

local holder = db.connect(config)()
holder:one("select pg_advisory_lock($1)", migrate.LOCK_KEY)

for _, row in ipairs(holder:many [[
  select locktype, classid, objid, mode, granted
  from pg_locks where locktype = 'advisory']]) do
  print(row.locktype, row.classid, row.objid, row.mode, row.granted)
end

holder:one("select pg_advisory_unlock($1)", migrate.LOCK_KEY)
holder:close()
```

```
advisory	97	1802199410	ExclusiveLock	true
```

The key is split across two columns, `classid` holding the top half and `objid`
the bottom half, which is why neither of them looks like the number you
printed earlier. Add `pid` to that select on a real incident and you have the
process to look at.

If the lock is genuinely stranded, the honest fix is to end the session holding
it. `select pg_terminate_backend(pid)` does that, and it is a thing to do
deliberately after you have checked whether the migration is still running,
never as a reflex.

## Hand it a connection it can keep

The lock is **session-level**, taken with `pg_advisory_lock` rather than the
transaction-scoped `pg_advisory_xact_lock`. That is not a detail you can ignore,
because it decides which connection the runner needs.

Why session-level: each migration commits on its own, so a transaction-scoped
lock would be dropped at the very first `commit`, leaving every migration after
the first one unprotected.

What follows from it: the lock lives on the **session**, which means the
connection. A handle that goes back to a pool half way through takes the lock
with it and the protection is gone. So the runner needs a connection it owns
for the whole run.

In practice that means `pool_size = 0` and one `open()`, which is what every
example on these pages does:

```lua no-run
local open = db.connect {
  host = ..., port = ..., database = ..., user = ..., password = ...,
  pool_size = 0,
}
local conn = open()

migrate.new(conn, { dir = "migrations" }):apply()

conn:close()
```

And it is why `migrate.new` refuses the factory itself with a message saying
so.

## Do not put `statement_timeout` on that connection

This one is worth its own section, because the failure is confusing.

`db.connect { statement_timeout = 30 }` sets a limit on every statement, on the
connection, for good reasons your handlers want. But Postgres counts the wait
for an advisory lock against `statement_timeout` too. So a connection built
that way cancels the lock wait early, **and** would cancel a long migration.

The result is a message that says the wrong number:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local holder = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}()
holder:one("select pg_advisory_lock($1)", migrate.LOCK_KEY)

local timed = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
  statement_timeout = 1,
}()

local runner = migrate.new(timed, {
  table = "sqlguide_migrations",
  lock_timeout = 30,
  files = { { name = "001_create_tasks.sql", sql = "select 1" } },
})

local started = os.time()
local ok, why = pcall(function() return runner:apply() end)
print(ok)
print(why)
print("but it only waited about " .. (os.time() - started) .. " second(s)")

holder:one("select pg_advisory_unlock($1)", migrate.LOCK_KEY)
holder:close()
timed:close()
```

```
false
akkar.migrate: another runner has held the migration lock for more than 30 seconds.
  That is normal for a slow migration and not normal for a fast one -- check whether a previous deploy died holding it. `select * from pg_locks where locktype = 'advisory'` names the session.
but it only waited about 1 second(s)
```

The message says thirty seconds. It waited one. Nothing is broken in akkar: the
`statement_timeout` on the connection cancelled the wait first, and akkar can
only report the bound it asked for.

**So open a separate connection for migrations, without `statement_timeout`.**
Your application's pool keeps its timeout, and the migration connection does
not. [Page 20](20-on-deploy.md) shows the shape.

akkar does take care of the other half of this for you. It sets Postgres's own
`lock_timeout` to bound the wait, then sets it back to `0` before running any
migration, so a migration that legitimately waits on a lock of its own, an
`alter table` behind a long read, does not inherit the deploy's patience.

## The lock is always released

On success and on failure, and before the error is re-raised. A failed
migration that kept the lock would leave every other instance blocked at boot
behind a run that is already over, turning one bad migration into an outage of
the whole fleet, from the code that was supposed to make startup safer.

And if the release itself fails, the lock is on the session, so closing the
connection clears it. akkar says that in the message too.

## Checkpoint

You have this if:

- you can describe the race between two booting instances in three lines
- you know the pending list is computed after the lock, and why that order
  matters
- you know why the lock is session-level and what that means for the connection
  you pass
- you would not give the migration connection a `statement_timeout`

Next: [19. Migrations as data](19-migrations-as-data.md).
