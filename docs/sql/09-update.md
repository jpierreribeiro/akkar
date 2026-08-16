# 9. update and set

By the end of this page you will be able to change a row safely, and you will
have met the refusal that stands between you and the statement that changes
every row in the table.

## `set` once per column

```lua
local sql = require "akkar.sql"

local q = sql.update "sqlguide_tasks"
q:set("done", true, { "done", "title" })
q:set("title", "buy oat milk", { "done", "title" })
q:where("id = ?", 3)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
update sqlguide_tasks set done = $1, title = $2 where id = $3
1	true
2	buy oat milk
3	3
```

`set` takes three things: the column, the value, and the allow-list. The column
is an identifier so it is written into the text and checked. The value is a
value so it is bound. **They can never trade places**, and there is no call
that lets them.

The third argument is the same defence as on `insert_into`: it is the list of
columns a caller may change. Without it, a body containing `is_admin` and a
handler that loops over the body would set it.

### The values come out in text order

Look at the numbering above. The two `set` values are `$1` and `$2`, and the
condition's value is `$3`, because `set` comes before `where` in the finished
statement. If you had written `$1`, `$2`, `$3` yourself and then added another
`set` line, every number after it would have been wrong.

This is the case where `:values()` does not match the order you called things
in, which [page 1](01-the-query-object.md) warned about:

```lua
local sql = require "akkar.sql"

local q = sql.update "sqlguide_tasks"
q:where("id = ?", 3)              -- called first
q:set("title", "new", { "title" }) -- called second

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
update sqlguide_tasks set title = $1 where id = $2
1	new
2	3
```

You called `where` first and its value still came out second, because `build`
numbers the finished text, not your call order.

## The refusal that matters

An `update` with no `where` changes every row in the table. That statement is
legitimate in a migration and almost never legitimate in a handler, so akkar
will not assemble one by accident:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.update("sqlguide_tasks"):set("done", true, { "done" }):build()
end)
print(ok, why)
```

```
false	akkar.sql: update with no where clause would affect every row; add a condition or call :all_rows() to say you meant it
```

The mistake this catches is not "I forgot what `where` is". It is a handler
where the condition is added inside an `if`, and the `if` was false:

```lua no-run
local q = sql.update "tasks"
q:set("done", true, { "done" })
if req.params.id then q:where("id = ?", req.params.id) end   -- and if it is nil?
req.db:exec(q)
```

Without the refusal, a missing id marks every task in the database as done. With
it, that request raises and answers `500`, which is a bad day rather than a
catastrophe.

### `all_rows` when you do mean it

Some updates really are meant to touch everything. Say so by name:

```lua
local sql = require "akkar.sql"

print(sql.update("sqlguide_tasks"):set("done", false, { "done" })
      :all_rows():to_string())
```

```
update sqlguide_tasks set done = $1
```

The value of `all_rows` is that it is a word somebody can search for.
`grep -rn ':all_rows()'` lists every statement in your codebase that can change
a whole table, and that list should be short and should be boring.

### An update with nothing set

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.update("sqlguide_tasks"):where("id = ?", 1):build()
end)
print(ok, why)
```

```
false	akkar.sql: update with no columns; call :set()
```

This one usually means the handler built its `set` calls in a loop over fields
the caller sent, and the caller sent none. An empty PATCH body is a `400`, and
checking for it before you reach the database gives the caller a better answer
than this error would.

### A column that is not on the list

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.update("sqlguide_tasks"):set("is_admin", true, { "done", "title" })
end)
print(ok, why)
```

```
false	akkar.sql: column name 'is_admin' is not in the allowed list (done, title)
```

## Running it, and knowing whether it did anything

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key, title text not null, done boolean not null default false)]]
conn:exec "insert into sqlguide_tasks (title) values ('buy milk'), ('walk the dog')"

local q = sql.update "sqlguide_tasks"
q:set("done", true, { "done", "title" })
q:where("id = ?", 1)

local result = conn:exec(q)
print("changed:", result.affected_rows)

local missing = sql.update "sqlguide_tasks"
missing:set("done", true, { "done" })
missing:where("id = ?", 999)
print("changed:", conn:exec(missing).affected_rows)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
changed:	1
changed:	0
```

`affected_rows` is how you tell "I updated it" from "there was nothing with
that id". Zero is the case that deserves a `404`, and it is easy to forget,
because an update that changed nothing does not fail.

### Or ask for the row back

`returning` turns the update into a query that answers with what it changed,
which saves you the second lookup and the `affected_rows` check at once:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key, title text not null, done boolean not null default false)]]
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local q = sql.update "sqlguide_tasks"
q:set("done", true, { "done" })
q:where("id = ?", 1)
q:returning "id, title, done"

local row = conn:one(q)
print(row.id, row.title, tostring(row.done))

local none = sql.update "sqlguide_tasks"
none:set("done", true, { "done" })
none:where("id = ?", 999)
none:returning "id"
print(tostring(conn:one(none)))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
1	buy milk	true
nil
```

`nil` from `db:one` means no row matched, which is exactly the shape
`or akkar.not_found "..."` wants.

## A trap: `limit` on an update

The builder lets you call `:limit` on an update. Postgres does not support it,
and you only find out when the statement runs:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key, title text not null, done boolean not null default false)]]

local q = sql.update "sqlguide_tasks"
q:set("done", true, { "done" })
q:where("id = ?", 1)
q:limit(1)

print(q:to_string())

local ok, why = pcall(function() return conn:exec(q) end)
print(ok, why)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
update sqlguide_tasks set done = $1 where id = $2 limit $3
false	db: ERROR: syntax error at or near "limit" (51)
```

The builder assembled it happily. `limit` and `offset` belong to `select`, and
the builder does not check which kind of statement you are on. If you want to
update only some of the matching rows, name them in the condition instead, with
`where_in` or a subquery written as text.

## Checkpoint

You have this if:

- you can update one row and read `affected_rows` to see whether it existed
- you know why an update with no condition is refused, and how to say you meant
  it
- you know the set values come before the condition values in the numbering
- you would not reach for `limit` on an update again

Next: [10. delete_from](10-delete.md).
