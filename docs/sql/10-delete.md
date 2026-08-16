# 10. delete_from

By the end of this page you will be able to delete a row, tell the difference
between "deleted it" and "it was not there", and you will know the two errors
that stop a delete.

## The shape

```lua
local sql = require "akkar.sql"

local q = sql.delete_from("sqlguide_tasks", { "sqlguide_tasks" })
q:where("id = ?", 7)

print(q:to_string())
print(q:values()[1])
```

```
delete from sqlguide_tasks where id = $1
7
```

Two arguments: the table, and an optional allow-list of table names. There is
no `set` and no column list, because a delete removes whole rows.

## The same refusal as `update`

A `delete` with no condition empties the table:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function() return sql.delete_from("sqlguide_tasks"):build() end)
print(ok, why)
```

```
false	akkar.sql: delete with no where clause would affect every row; add a condition or call :all_rows() to say you meant it
```

And the same escape, for the cases where emptying a table is the job. Clearing
expired sessions on a schedule is the honest example:

```lua
local sql = require "akkar.sql"

print(sql.delete_from("sqlguide_sessions"):all_rows():to_string())
```

```
delete from sqlguide_sessions
```

Reach for `:all_rows()` only in the code where a whole table really is the
target, and never in a handler that took an id from the request. In a handler,
a missing id should be a `400`, not a `delete` that succeeds.

## Did it delete anything

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local function remove(id)
  local q = sql.delete_from "sqlguide_tasks"
  q:where("id = ?", id)
  return conn:exec(q).affected_rows
end

print("first time: ", remove(1))
print("second time:", remove(1))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
first time: 	1
second time:	0
```

That is the whole logic of a `DELETE` route: `1` is a `204`, and `0` is a
`404`. The guide's task list does exactly this on
[page 6](../guide/06-storing-and-reading.md).

`returning` works here too, and it is useful when you want to tell the caller
what you removed, or write it to an audit log:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local q = sql.delete_from "sqlguide_tasks"
q:where("id = ?", 1)
q:returning "id, title"

local row = conn:one(q)
print(row.id, row.title)
print(tostring(conn:one(q)))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
1	buy milk
nil
```

The second call deleted nothing, so `returning` returned no rows, so `db:one`
gave `nil`. One check instead of two.

## The error you will actually hit

Not the builder's. The database's, when another table points at the row you are
deleting:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "drop table if exists sqlguide_people"
conn:exec "create table sqlguide_people (id serial primary key, name text not null)"
conn:exec [[create table sqlguide_tasks (
  id serial primary key,
  person_id integer not null references sqlguide_people(id),
  title text not null)]]
conn:exec "insert into sqlguide_people (name) values ('ana')"
conn:exec "insert into sqlguide_tasks (person_id, title) values (1, 'buy milk')"

local q = sql.delete_from "sqlguide_people"
q:where("id = ?", 1)

local ok, why = pcall(function() return conn:exec(q) end)
print(ok, why)

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_people"
conn:close()
```

```
false	db: ERROR: update or delete on table "sqlguide_people" violates foreign key constraint "sqlguide_tasks_person_id_fkey" on table "sqlguide_tasks"
Key (id)=(1) is still referenced from table "sqlguide_tasks".
```

Postgres is protecting you from a task whose owner does not exist. The second
line names the exact row and the exact table that still points at it.

Three ways out, and the choice is about what your application means:

**Delete the children first**, inside one
[transaction](13-transactions.md), so you never end up having deleted half.

**Let the database do it**, by declaring the reference as
`references sqlguide_people(id) on delete cascade` in the migration that
creates it. Then deleting a person deletes their tasks. This is convenient and
it is quiet, so use it where the child rows genuinely have no meaning without
the parent.

**Do not delete at all.** Add a `deleted_at timestamptz` column, set it instead
of removing the row, and add `where deleted_at is null` to your reads. Nothing
is lost, the references stay valid, and "undelete" becomes possible. The cost
is that every query has to remember the condition, and forgetting it shows
deleted rows to somebody.

## Checkpoint

You have this if:

- you can delete by id and answer `404` when nothing matched
- you know what `:all_rows()` is for and why it has to be typed
- you would recognise a foreign key error and know your three options

Next: [11. Identifiers and allow-lists](11-identifiers-and-allow-lists.md).
