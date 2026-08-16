# 11. Identifiers and allow-lists

By the end of this page you will know why half of `akkar.sql` takes an extra
list argument, what that list is protecting, and what happens on the day you
leave it out.

This is the most important page in this track. Everything else is a method.
This is the idea.

## Two kinds of thing go into a statement

A **value** is data: a title, an id, a boolean, a date. Values travel beside
the statement, bound as `$1`, `$2`. They can be anything, including an attack
string, because there is no way for them to become part of the statement.

An **identifier** is a name in the database: a table, a column. Identifiers
travel **inside** the statement text, because there is nowhere else for them to
go.

That difference is not akkar's choice. It is Postgres.

## Why an identifier cannot be a parameter

The honest answer is that Postgres plans the statement before it sees the
values, and the plan depends on which column you meant. Which index to use,
what type the column is, whether the sort can be skipped: none of that can be
decided while the column name is still unknown.

So `select * from $1` is not a statement Postgres can even parse:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function()
  return conn:many("select * from $1", "sqlguide_tasks")
end)
print(ok, why)

conn:close()
```

```
false	db: ERROR: syntax error at or near "$1" (15)
```

That one is loud, and a loud failure is the good case. Here is the quiet one,
which is worse. `order by $1` **is** valid SQL, so it runs. It just does not do
what you think:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"
conn:exec "insert into sqlguide_tasks (title) values ('zebra'), ('apple'), ('mango')"

for _, row in ipairs(conn:many("select id, title from sqlguide_tasks order by $1",
                               "title")) do
  print(row.id, row.title)
end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
1	zebra
2	apple
3	mango
```

Not sorted. `zebra`, `apple`, `mango` is the order they were inserted in.
Postgres bound `$1` as the **string** `'title'`, sorted every row by that same
constant, which is no sorting at all, and returned them untouched. No error, no
warning, and a test with three rows in it would probably pass.

This is why `order_by` takes a column name rather than a value. There was never
an option to bind it.

## So an identifier is checked, twice

Since the name has to be written into the text, akkar checks it. Two separate
checks, and they catch two different problems.

### The pattern, which always runs

Letters, digits and underscores, starting with a letter or an underscore.
Optionally one dot, for `schema.table`. Nothing else:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.select("*"):from "sqlguide_tasks; drop table sqlguide_tasks"
end)
print(ok, why)

local ok2, why2 = pcall(function()
  return sql.select("*"):from("sqlguide_tasks"):order_by("title; drop table x")
end)
print(ok2, why2)
```

```
false	akkar.sql: table name is not a valid identifier: sqlguide_tasks; drop table sqlguide_tasks
false	akkar.sql: order column is not a valid identifier: title; drop table x
```

This is the check that makes injection through an identifier impossible. It
runs whether or not you passed a list.

It is deliberately narrower than what Postgres accepts. A quoted name with a
space in it is a legal Postgres identifier and akkar still refuses it:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.select("*"):from("sqlguide_tasks"):order_by('"weird name"')
end)
print(ok, why)
```

```
false	akkar.sql: order column is not a valid identifier: "weird name"
```

The trade is written down in the source: the cost of refusing an unusual but
valid name is a clear error, and the cost of accepting a crafted one is the
database.

### The allow-list, which runs when you pass it

The pattern stops `title; drop table x`. It does not stop `password_hash`,
because `password_hash` is a perfectly good identifier. It is a real column,
spelled correctly, that this route was never meant to expose.

Only you know which columns a route is about, so you say so:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"

local ok, why = pcall(function()
  return q:order_by("password_hash", { "id", "title", "created_at" })
end)
print(ok, why)
```

```
false	akkar.sql: order column 'password_hash' is not in the allowed list (id, title, created_at)
```

Sorting by a column you did not choose is not harmless. `order by password_hash`
does not print the hashes, but it puts the rows in an order that depends on
them, and a caller who can page through the result learns the order. That is a
slow leak of a secret, out of a sort parameter nobody thought about.

## Where the list goes, in every method that takes one

| method | the identifier is | the list argument is |
|---|---|---|
| `sql.select(columns)` | none, it is your text | there is none |
| `:from(table, allowed)` | the table | 2nd |
| `sql.update(table, allowed)` | the table | 2nd |
| `sql.delete_from(table, allowed)` | the table | 2nd |
| `sql.insert_into(table, row, allowed_columns, allowed_table)` | every key of `row`, and the table | 3rd for columns, 4th for the table |
| `:set(column, value, allowed)` | the column | 3rd |
| `:order_by(column, allowed, direction)` | the column | 2nd |
| `:group_by(column, allowed)` | the column | 3rd |
| `:where_in(column, values, allowed)` | the column | 3rd |
| `:scope(column, value, allowed)` | the column | 3rd |
| `sql.identifier(name, allowed, what)` | the name | 2nd |

Two members of that table are worth staring at.

`:where(condition, ...)` is not on it. The condition is **your text**, like the
column list in `select`. akkar does not read it and cannot check it. Nothing
from a request belongs in it, ever. Only the values after it come from outside.

`:join(clause, ...)` is not on it either, for the same reason.

## `sql.identifier`, when you are writing the text yourself

The same check, on its own, for the times you are not using the builder:

```lua
local sql = require "akkar.sql"

local wanted = "title"                     -- pretend this arrived as ?sort=title
local column = sql.identifier(wanted, { "id", "title", "done" }, "column name")

print("select id, title from sqlguide_tasks order by " .. column)
```

```
select id, title from sqlguide_tasks order by title
```

The third argument is only the word used in the error message. Pass
`"column name"` or `"table name"` so the message reads properly:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(sql.identifier, "oops", { "id" }, "sort column")
print(ok, why)
```

```
false	akkar.sql: sort column 'oops' is not in the allowed list (id)
```

That is the one door where checked request text reaches SQL, and it is narrow
on purpose: gluing is fine here precisely because `column` can only be one of
three strings you wrote yourself.

## What happens when you leave the list out

Nothing, at first. That is the problem.

With no list, the pattern still runs, so you are still safe from injection.
What you lose is the answer to "which columns is this route about", and two
different bugs walk through the gap:

**A caller sorting or grouping by a column you did not intend**, as above.

**A caller writing a column you did not intend.** This is the one from
[page 8](08-insert.md), and it is worth repeating in full because no error
message appears anywhere:

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk", is_admin = true }

print(sql.insert_into("sqlguide_tasks", body):to_string())
```

```
insert into sqlguide_tasks (is_admin, title) values ($1, $2)
```

A valid, well formed statement that gives the caller a column you never meant
them to touch.

## Two layers, and why you want both

The allow-list raises an error. An error out of a handler is a `500`, which
tells the caller nothing useful and puts a stack trace in your logs.

So do the check twice, in two places, for two different reasons:

```lua no-run
app:get("/tasks", {
  query = {
    sort = v.string { optional = true, one_of = { "id", "title" }, default = "id" },
  },
}, function(req)
  local q = sql.select("id, title"):from "tasks"
  q:order_by(req.query.sort, { "id", "title" })
  return { tasks = akkar.array(req.db:many(q)) }
end)
```

The **schema** is there to give the caller a good answer. `?sort=password_hash`
gets a `422` naming the field and the allowed values, before your handler runs
at all.

The **allow-list** is there because the schema is a separate thing that
somebody will edit, and a forgotten schema should not be the only thing between
a stranger and your columns.

The second one is not paranoia about your colleagues. It is that these two
lines live in different parts of the file, and the day one of them changes
without the other is a day nobody notices.

## Checkpoint

You have this if:

- you can say why `order by $1` is worse than a syntax error
- you know the pattern check runs always and the list check runs when you pass
  it
- you can name what the list stops that the pattern does not
- you pass the list on `insert_into` and `order_by` without being told

Next: [12. one, many and exec](12-running-a-query.md).
