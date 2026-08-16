# 8. insert_into

By the end of this page you will be able to write a row from a request body,
get the finished row back in the same round trip, and you will have seen what
happens to an insert that trusts the body.

## The shape

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("sqlguide_tasks",
                          { title = "buy milk", done = false },
                          { "title", "done" })

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
insert into sqlguide_tasks (done, title) values ($1, $2)
1	false
2	buy milk
```

Four arguments, and the third one is the important one:

| argument | is | example |
|---|---|---|
| `table_name` | the table, an identifier | `"sqlguide_tasks"` |
| `row` | a Lua table of column to value | `{ title = "buy milk" }` |
| `allowed_columns` | the list of columns a caller may write | `{ "title", "done" }` |
| `allowed_table` | an optional list of table names | usually left out |

The column names are the **keys of `row`**. On a real route, `row` came from a
request body, so those keys came from a stranger. That is why they are checked,
and it is why the third argument exists.

### The columns come out sorted

`done` came before `title` above, even though you wrote `title` first. Lua
tables have no order, so akkar sorts the names to have one. The result is that
the same row always produces the same statement text, which is a small thing
that matters: two spellings of the same insert are two statements for Postgres
to plan, and one is enough.

### A field that is not there is not a column

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk" }        -- no `done` was sent

local q = sql.insert_into("sqlguide_tasks",
                          { title = body.title, done = body.done },
                          { "title", "done" })
print(q:to_string())
```

```
insert into sqlguide_tasks (title) values ($1)
```

`body.done` was `nil`, so the key was never in the table, so the column is not
in the statement. The database then applies whatever default the column has.
That is usually what you want. It is worth knowing it is happening, because it
means an insert cannot set a column to `null` on purpose by passing `nil`. If
you need an explicit null, write that statement as text.

## `returning` gives you the finished row

Postgres can answer an insert with the row it just wrote:

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("sqlguide_tasks", { title = "buy milk" }, { "title" })
q:returning "id, title, done"

print(q:to_string())
```

```
insert into sqlguide_tasks (title) values ($1) returning id, title, done
```

Without it you would have to run a second query to find out what `id` the
database chose. With it, one round trip, and no guessing. Called with no
argument it returns everything:

```lua
local sql = require "akkar.sql"

print(sql.insert_into("sqlguide_tasks", { title = "buy milk" }, { "title" })
      :returning():to_string())
```

```
insert into sqlguide_tasks (title) values ($1) returning *
```

`returning` works on `update` and `delete` too, and it is text you wrote, so it
is not checked.

## The whole thing, against a real database

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
  id serial primary key,
  title text not null,
  done boolean not null default false)]]

local body = { title = "buy milk" }        -- pretend this is req.body

local made = conn:one(
  sql.insert_into("sqlguide_tasks", body, { "title", "done" })
     :returning "id, title, done")

print(made.id, made.title, tostring(made.done))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
1	buy milk	false
```

`db:one` is right for an insert with `returning`, because one row comes back.
Without `returning`, use `db:exec`.

## The allow-list, and what happens without it

Here is the part that is worth the whole page.

`allowed_columns` is a list of the columns a **caller** may write. Leave it out
and akkar checks that each key is a valid identifier, which stops an injection,
and then writes every column the body contained.

Watch what that means when the body contains one you did not expect:

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk", is_admin = true }   -- the caller added a field

local careless = sql.insert_into("sqlguide_tasks", body)
print(careless:to_string())
for index, value in ipairs(careless:values()) do print(index, tostring(value)) end
```

```
insert into sqlguide_tasks (is_admin, title) values ($1, $2)
1	true
2	buy milk
```

`is_admin = true`, written by the caller, into your table. No injection, no
crash, nothing in a log. The statement is perfectly formed and does exactly
what the body asked for.

This has a name: **mass assignment**. It is the second-most common way a body
does something you did not intend, after injection, and unlike injection it
looks fine in review because the code is short and there is no string
concatenation anywhere.

The list is the fix:

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk", is_admin = true }

local ok, why = pcall(function()
  return sql.insert_into("sqlguide_tasks", body, { "title", "done" })
end)
print(ok, why)
```

```
false	akkar.sql: column name 'is_admin' is not in the allowed list (title, done)
```

The message names the column that was refused and prints the whole list it was
checked against, so you can see at a glance whether the caller sent something
odd or you forgot to allow a column you meant to.

The check happens at `insert_into`, before any statement exists, so the refused
column never reaches a statement at all.

Two habits follow, and they are cheap:

**Pass the list every time.** Even when the body is validated by a schema,
because the schema is a separate file that somebody will edit.

**Build the row yourself instead of passing the body.** The strongest version
takes the fields it wants by name, so an unexpected key cannot reach the
builder at all:

```lua no-run
local row = { title = req.body.title, done = req.body.done }
sql.insert_into("tasks", row, { "title", "done" })
```

Then a body with `is_admin` in it produces a row without one, and the
allow-list is your second line rather than your only one.

## The other refusals

### A key that is not an identifier

```lua
local sql = require "akkar.sql"

local body = { ["title, is_admin"] = "buy milk" }

local ok, why = pcall(function()
  return sql.insert_into("sqlguide_tasks", body, nil)
end)
print(ok, why)
```

```
false	akkar.sql: column name is not a valid identifier: title, is_admin
```

This is the check that runs even with no allow-list, and it is what makes the
key of a JSON object safe to use as a column name at all.

### An empty row

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.insert_into("sqlguide_tasks", {}, { "title" }):build()
end)
print(ok, why)
```

```
false	akkar.sql: insert with no columns
```

Notice this one waits for `build`. Until then, you might still be about to call
`:scope`, which adds a column of its own.

### The table, if it varies

The fourth argument is the allow-list for the table name:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.insert_into("accounts", { title = "x" }, { "title" }, { "sqlguide_tasks" })
end)
print(ok, why)
```

```
false	akkar.sql: table name 'accounts' is not in the allowed list (sqlguide_tasks)
```

## One row at a time

The builder inserts one row. For several, run several inserts inside one
[transaction](13-transactions.md), which is what the guide's bulk endpoint
does, or write a multi-row `insert ... values (...), (...)` as text.

And `:where` on an insert is silently dropped, which
[page 3](03-where.md) shows. If you meant "only if it is not already there",
that is `on conflict`, and it goes in text you write yourself.

## Checkpoint

You have this if:

- you can insert a row from a body and get the id back in one call
- you can explain mass assignment to somebody in two sentences
- you pass `allowed_columns` without thinking about it
- you know `insert with no columns` arrives at `build`, not at `insert_into`

Next: [9. update and set](09-update.md).
