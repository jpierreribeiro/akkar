# 2. select and from

By the end of this page you will know what each of the two arguments to a
`select` is allowed to be, which one is checked and which one is not, and why
that difference exists.

## `select` takes text, and it is your text

```lua
local sql = require "akkar.sql"

print(sql.select("id, title, done"):from("sqlguide_tasks"):to_string())
```

```
select id, title, done from sqlguide_tasks
```

Whatever you pass to `sql.select` is copied into the statement exactly as you
wrote it. It is not checked, and it is not escaped.

That sounds alarming after the injection page. It is not, and the reason is
worth saying plainly: **the column list is written by you, in your source file,
and it does not change when a request arrives.** The dangerous input is the
input that comes from a stranger, and a string constant in your own file is
never that.

So expressions are fine, because they are yours:

```lua
local sql = require "akkar.sql"

print(sql.select("id, upper(title) as shout, done"):from("sqlguide_tasks"):to_string())
print(sql.select("count(*) as n"):from("sqlguide_tasks"):to_string())
```

```
select id, upper(title) as shout, done from sqlguide_tasks
select count(*) as n from sqlguide_tasks
```

And leaving the argument out gives you everything:

```lua
local sql = require "akkar.sql"

print(sql.select():from("sqlguide_tasks"):to_string())
print(sql.select("*"):from("sqlguide_tasks"):to_string())
```

```
select * from sqlguide_tasks
select * from sqlguide_tasks
```

Prefer naming the columns. `select *` hands the caller every column the table
has, including the ones you add next month, including `password_hash`.

### If a column name really does come from the caller

Then it is no longer your text, and it has to be checked. `sql.identifier` is
the check, on its own:

```lua
local sql = require "akkar.sql"

local wanted = "title"                       -- pretend this came from ?fields=
local column = sql.identifier(wanted, { "id", "title", "done" }, "column name")
print(sql.select("id, " .. column):from("sqlguide_tasks"):to_string())

local ok, why = pcall(sql.identifier, "password_hash", { "id", "title", "done" },
                      "column name")
print(ok, why)
```

```
select id, title from sqlguide_tasks
false	akkar.sql: column name 'password_hash' is not in the allowed list (id, title, done)
```

That is the only shape in which caller-chosen text ever reaches a statement:
compared against a list you wrote, and refused if it is not on the list.
[Page 11](11-identifiers-and-allow-lists.md) is entirely about this.

## `from` takes an identifier, and it is checked

The table name is different from the column list, because it goes through the
same door a request could one day come through. So it is checked every time,
against a pattern:

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("sqlguide_tasks"):to_string())
print(sql.select("*"):from("public.sqlguide_tasks"):to_string())
```

```
select * from sqlguide_tasks
select * from public.sqlguide_tasks
```

Letters, digits and underscores, starting with a letter or an underscore.
Optionally one dot, for `schema.table`. Anything else is refused:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.select("*"):from "sqlguide_tasks t"
end)
print(ok, why)
```

```
false	akkar.sql: table name is not a valid identifier: sqlguide_tasks t
```

**A table alias is not an identifier, so you cannot have one.** `tasks t` is
two words. This is a real limit and it changes how you write joins, so
[page 6](06-join.md) covers what to do instead: write the full table name
everywhere.

### The second argument is an allow-list

`from` takes an optional list of table names. When you pass it, the table has
to be one of them:

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("sqlguide_tasks", { "sqlguide_tasks", "sqlguide_people" })
      :to_string())

local ok, why = pcall(function()
  return sql.select("*"):from("accounts", { "sqlguide_tasks", "sqlguide_people" })
end)
print(ok, why)
```

```
select * from sqlguide_tasks
false	akkar.sql: table name 'accounts' is not in the allowed list (sqlguide_tasks, sqlguide_people)
```

You will rarely need this on `from`, because the table is usually a constant in
your handler. It exists for the case where it is not, and the same argument
appears on `insert_into`, `update` and `delete_from`, where it matters more.

## Forgetting `from`

The table is the one thing a query cannot be assembled without:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.select("*"):where("id = ?", 1):build()
end)
print(ok, why)
```

```
false	akkar.sql: no table; call :from()
```

Notice when that error arrives: at `build`, not at `select`. Nothing is checked
for completeness until you ask for the finished statement, because until then
you might still be about to add the missing piece.

## What goes where, in one table

| you pass | to | checked? | why |
|---|---|---|---|
| `"id, title"` | `sql.select` | no | it is your text, in your file |
| `"sqlguide_tasks"` | `:from` | yes, pattern and optional list | it is an identifier, so it cannot be bound |
| `false`, `10`, `"buy%"` | `:where`, `:limit` | not checked, and does not need to be | it is bound as a value and can never become SQL |

## Checkpoint

You have this if:

- `sql.select("id"):from("sqlguide_tasks"):to_string()` prints
  `select id from sqlguide_tasks`
- you can say why the column list is not checked and the table name is
- `from "tasks t"` raising is something you expect, not something that
  surprises you

Next: [3. where, and the question mark](03-where.md).
