# 14. scope, so a query cannot cross tenants

By the end of this page you will be able to hand a handler a database handle
that cannot read or write another customer's rows, even if the query is wrong.

[Page 8 of the guide](../guide/08-only-your-own.md) introduces this with the
task list. This page is the mechanism underneath, and the parts the guide did
not need.

## The bug this removes

An application with more than one customer keeps their rows in the same tables,
with a column saying whose they are: `project_id`, `account_id`, `tenant_id`.
Every query has to say which one:

```sql
select * from documents where project_id = $1 and id = $2
```

Nobody writes the version without `and project_id = $1` on purpose. It happens
on one route out of two hundred, on a Thursday, in a hurry. And review does not
catch it reliably, because the wrong query looks exactly like the two hundred
right ones minus five words.

So the possibility is removed instead of the habit.

## `Query:scope` adds the condition

On a `select`, `update` or `delete`, scope adds one condition:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_notes"
q:where("id = ?", 7)
q:scope("project_id", 42)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select id, title from sqlguide_notes where id = $1 and project_id = $2
1	7
2	42
```

The value is bound like any other value. The column is an identifier, so it
takes the usual optional allow-list as a third argument.

`:is_scoped()` tells you whether it has been called:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_notes"
print(q:is_scoped())
q:scope("project_id", 42)
print(q:is_scoped())
```

```
false
true
```

It is there for your own assertions, in a test. Nothing inside akkar reads it.

### On an insert it overwrites the row

This is the half people forget, and it is the dangerous half. An unscoped read
shows somebody another tenant's data. An unscoped **write** puts data into
another tenant.

```lua
local sql = require "akkar.sql"

local body = { title = "notes", project_id = 2 }    -- the caller named project 2

local q = sql.insert_into("sqlguide_notes", body, { "title", "project_id" })
q:scope("project_id", 42)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
insert into sqlguide_notes (project_id, title) values ($1, $2)
1	42
2	notes
```

The caller asked for project 2 and got project 42, which is the one they are
actually in. **The client does not get a say.** If the row had no `project_id`
at all, scope adds the column instead:

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("sqlguide_notes", { title = "notes" }, { "title" })
q:scope("project_id", 42)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
insert into sqlguide_notes (project_id, title) values ($1, $2)
1	42
2	notes
```

Same statement either way, which is deliberate: one shape instead of two,
whether or not the client happened to send the column.

## `db:scope` is the handle you actually use

Calling `:scope` on every query yourself is a habit, and habits are what this
is replacing. So scope the handle once, at the top of the handler, and use it
for everything:

```lua no-run
local db = req.db:scope("project_id", req.user.project_id)
return db:many(sql.select("*"):from "documents")
```

Every query that goes through `db` gets the condition applied for it. The
unscoped statement is never assembled, so there is no window in which it could
be sent.

## The handle refuses raw SQL

This is the part that surprises people, and it is not an oversight:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec [[create table sqlguide_notes (
  id serial primary key, project_id integer not null, title text not null)]]
conn:exec [[insert into sqlguide_notes (project_id, title) values
  (42, 'ours one'), (42, 'ours two'), (7, 'theirs')]]

local mine = conn:scope("project_id", 42)

for _, row in ipairs(mine:many(sql.select("id, title"):from "sqlguide_notes")) do
  print(row.id, row.title)
end

local ok, why = pcall(function()
  return mine:many "select title from sqlguide_notes"
end)
print(ok, why)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
1	ours one
2	ours two
false	db: this handle is scoped to project_id, so it takes an akkar.sql query rather than raw SQL -- a string cannot be scoped without parsing it. Use db:unscoped() if the query genuinely covers every tenant.
```

Two rows out of three, and a refusal.

The reason is in the message. To add `and project_id = 42` to a string, akkar
would have to understand the string: find the `where`, know whether there is a
`union` in it, notice a subquery, get the brackets right. That is a SQL parser
living inside the framework, and a SQL parser that disagrees with Postgres about
one edge case is worse than no protection at all, because it would look like
protection.

A query object does not need parsing. akkar built it, so it knows where the
conditions are.

## `unscoped`, and why it has a name

Some queries really do cross tenants: an admin report, a nightly count, a
migration. So the escape exists, and it is spelled out at the call site:

```lua no-run
req.db:unscoped():many "select count(*) from documents"
```

`unscoped()` does nothing at all. On a plain connection it returns the
connection. On a scoped handle it returns the connection underneath.

Its whole value is that `grep -rn ':unscoped()'` gives you the complete list of
queries in your codebase that can see every tenant. A short list somebody can
actually read through is worth more than a rule nobody can verify.

## The three things it does not let you get wrong

### A nil tenant id is refused, loudly

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function() return conn:scope("project_id", nil) end)
print(ok, why)

conn:close()
```

```
false	db: scope value for 'project_id' is nil; a missing tenant id has to fail here rather than quietly match every row
```

Think about what the alternative would have been. `where project_id = null` is
never true, so a nil would have matched no rows and every list would have come
back empty, which looks like "this customer has no data" rather than "the
session is broken". Failing here is the kind thing to do.

### Scoping twice narrows

An organisation and a project are both true at once, so the second scope adds
to the first rather than replacing it:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_notes"
q:scope("org_id", 3)
q:scope("project_id", 42)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select * from sqlguide_notes where org_id = $1 and project_id = $2
1	3
2	42
```

The same is true of handles: `req.db:scope("org_id", 3):scope("project_id", 42)`
gives a handle with both conditions.

### A transaction stays scoped

The closure gets the **scoped** handle, not the connection, so nothing inside a
transaction can reach past the scope:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:scope("project_id", 42):transaction(function(tx)
  local ok, why = pcall(function() return tx:many "select 1" end)
  print(ok, why)
end)

conn:close()
```

```
false	db: this handle is scoped to project_id, so it takes an akkar.sql query rather than raw SQL -- a string cannot be scoped without parsing it. Use db:unscoped() if the query genuinely covers every tenant.
```

Same refusal inside the transaction as outside it.

## What it looks like when it saves you

An update aimed at somebody else's row. The condition is right, the id exists,
and nothing happens:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec [[create table sqlguide_notes (
  id serial primary key, project_id integer not null, title text not null)]]
conn:exec "insert into sqlguide_notes (project_id, title) values (7, 'theirs')"

local mine = conn:scope("project_id", 42)

local q = sql.update "sqlguide_notes"
q:set("title", "renamed", { "title" })
q:where("id = ?", 1)

print("changed:", mine:exec(q).affected_rows)
print("still:  ", conn:one("select title from sqlguide_notes where id = 1").title)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
changed:	0
still:  	theirs
```

The handler asked to rename note 1. Note 1 belongs to project 7. The handle is
scoped to 42, so the statement that went out was
`... where id = $1 and project_id = $2`, and it matched nothing.

`affected_rows` of `0` is then a `404`, which is also the right answer to give
a caller who asked about a row that is not theirs. Telling them it exists but
belongs to somebody else is itself a leak.

## Checkpoint

You have this if:

- you can scope a handle and see the extra condition in the SQL
- you know what scope does to an insert, and why it overrides the body
- you can explain why a scoped handle refuses a string
- you know what `unscoped()` is for and why it is not just an omission

Next: [15. What a migration is](15-what-a-migration-is.md).
