# 12. one, many and exec

By the end of this page you will know which of the three methods to call, what
each one gives back, and what a row actually is once it reaches Lua.

Up to now every page built a query and printed it. This page sends it.

## The handle

Inside a handler you never open a connection. akkar puts one on `req.db` for
the request and takes it back afterwards:

```lua no-run
app:get("/tasks", function(req)
  return { tasks = akkar.array(req.db:many(sql.select("*"):from "tasks")) }
end)
```

In a script, you open one yourself, which is what every example on this page
does:

```lua no-run
local open = db.connect { ... , pool_size = 0 }
local conn = open()
```

They are the same object with the same four methods. `db.connect` returns a
**factory**, not a connection, and calling it is what opens one.
[The reference](../reference/db.md) has the full configuration table.

## The three, and when you reach for each

| call | gives back | reach for it when |
|---|---|---|
| `db:one(q)` | the first row, or `nil` | you asked for one thing |
| `db:many(q)` | a list of rows | you asked for a list |
| `db:exec(q)` | a table with `affected_rows` | you changed rows and do not need them back |

All three accept the same two shapes. A query object:

```lua no-run
req.db:many(q)
```

Or text and values:

```lua no-run
req.db:many("select id, title from tasks where done = $1", false)
```

The first calls `:build()` for you. There is no third shape and no `execute`
method.

## What a row is

A plain Lua table, one field per column, with Lua types:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key, title text not null, done boolean not null default false)]]
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local row = conn:one "select id, title, done from sqlguide_tasks where id = 1"

print(type(row))
print(row.id, type(row.id))
print(row.title, type(row.title))
print(row.done, type(row.done))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
table
1	number
buy milk	string
false	boolean
```

There is nothing else to learn about the shape. No wrapper object, no accessor
methods, no lazy loading. It is a table, so it goes straight back as JSON.

**A SQL `null` is not in the table at all.** akkar leaves the field out rather
than inventing a value for it, so `row.note` reads as `nil`, and a JSON
response simply has no `note` key. If the caller needs the key to be there, set
it in your handler.

## `db:one` gives `nil` when nothing matched

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"

print(tostring(conn:one "select id from sqlguide_tasks where id = 999"))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
nil
```

That `nil` is why `or akkar.not_found "..."` shows up everywhere in akkar
handlers:

```lua no-run
local task = req.db:one(sql.select("*"):from("tasks"):where("id = ?", req.params.id))
return task or akkar.not_found "no task with that id"
```

`db:one` is `db:many` plus `rows[1]`. It does not add `limit 1` and it does not
complain if the query matched a hundred rows. If you meant one, put the
condition or the `limit` there yourself.

## `db:many` always gives a list

Even when nothing matched. An empty list, never `nil`:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"

local rows = conn:many "select id from sqlguide_tasks"
print(type(rows), #rows)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
table	0
```

So `ipairs(rows)` is always safe. What is not safe is returning that list
straight to a caller, because an empty Lua table becomes `{}` in JSON rather
than `[]`. Wrap it in `akkar.array`, which
[page 6 of the guide](../guide/06-storing-and-reading.md) explains in full.

## `db:exec` gives you `affected_rows`

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local result = conn:exec("update sqlguide_tasks set title = $1 where id = $2",
                         "buy oat milk", 1)
for key, value in pairs(result) do print(key, value) end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
affected_rows	1
```

One field, and it is the one that tells you whether the row existed. Zero is
the `404` case.

`exec` and `many` are the same call underneath, so nothing breaks if you pick
the other one. `many` on an insert gives you a table with `affected_rows` on it
and a length of zero, which is confusing to read rather than wrong. Use the
name that says what you meant.

## The errors, and where they come from

Two very different things can go wrong, and they read differently.

**The builder refuses**, before anything is sent. Those are the messages from
the last nine pages, all starting with `akkar.sql:`.

**Postgres refuses**, after it is sent. Those start with `db: ERROR:`:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"

local ok, why = pcall(function() return conn:many "select nope from sqlguide_tasks" end)
print(ok, why)

local ok2, why2 = pcall(function() return conn:many("select $1, $2", 1) end)
print(ok2, why2)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
false	db: ERROR: column "nope" does not exist (8)
false	db: ERROR: bind message supplies 1 parameters, but prepared statement "" requires 2
```

Both raise rather than return an error, which is how the rest of akkar behaves:
a failure travels up as an error, the request handler chain turns it into a
`500`, and you do not have to check a return value after every query.

The number in brackets on the first one is the character position in the
statement where Postgres stopped. On a long statement it is the fastest way to
find the typo.

The second message is worth recognising, because it is not obvious. It means
the statement had two `$` placeholders and you passed one value. That is the
mistake the builder exists to make impossible: with `?` and `:where`, the count
is checked in Lua before anything is sent, and the message names the condition
instead.

## One connection, one request

The pool is worth understanding in one paragraph, because it explains a rule
you will otherwise trip over.

`db.connect` with no `pool_size` keeps ten connections and hands one to each
request that asks for `req.db`. When the request ends, the connection goes
back. That is why you never close `req.db` yourself, and why a connection is
not shared between two requests at the same time.

The rule it explains is on the next page: inside a transaction you must use the
handle the closure was given, not `req.db`, because a second borrowed
connection is outside the transaction and will not be undone.

## Checkpoint

You have this if:

- you can say which of `one`, `many` and `exec` to call without thinking
- you expect `nil` from `one` and `{}` from `many` when nothing matched
- you can tell an `akkar.sql:` error from a `db: ERROR:` one and know which
  side of the wire each came from

Next: [13. transaction, and the trap in it](13-transactions.md).
