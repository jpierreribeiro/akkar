# akkar.sql

Builds SQL statements from data. A value is always bound as a parameter, never
written into the statement text, and there is no method that takes raw SQL.

**When you need it.** When the statement depends on what the caller asked for:
an optional filter, a sort column from a query string, a list of ids. A fixed
statement does not need this module, `db:many("select ...", value)` is enough.

```lua no-run
local sql = require "akkar.sql"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`query:all_rows`](#queryall_rows) | method |
| [`query:build`](#querybuild) | method |
| [`query:from`](#queryfromtable_name-allowed) | method |
| [`query:group_by`](#querygroup_bycolumn-allowed) | method |
| [`query:is_scoped`](#queryis_scoped) | method |
| [`query:join`](#queryjoinclause-) | method |
| [`query:limit`](#querylimitn) | method |
| [`query:offset`](#queryoffsetn) | method |
| [`query:order_by`](#queryorder_bycolumn-allowed-direction) | method |
| [`query:returning`](#queryreturningcolumns) | method |
| [`query:scope`](#queryscopecolumn-value-allowed) | method |
| [`query:set`](#querysetcolumn-value-allowed) | method |
| [`query:to_string`](#queryto_string) | method |
| [`query:values`](#queryvalues) | method |
| [`query:where`](#querywherecondition-) | method |
| [`query:where_in`](#querywhere_incolumn-values-allowed) | method |
| [`sql.delete_from`](#sqldelete_fromtable_name-allowed) | function |
| [`sql.identifier`](#sqlidentifiername-allowed-what) | function |
| [`sql.insert_into`](#sqlinsert_intotable_name-row-allowed_columns-allowed_table) | function |
| [`sql.Query`](#sqlquery) | table |
| [`sql.select`](#sqlselectcolumns) | function |
| [`sql.update`](#sqlupdatetable_name-allowed) | function |

Also on this page: [Identifiers and values](#identifiers-and-values), and
[Not here](#not-here).

## sql.delete_from(table_name, allowed)

Starts a `delete` statement. `allowed` is an optional list of table names; when
given, `table_name` must be one of them.

**Returns** a [Query](#query).

**Raises** when `table_name` is not a plain identifier, or is not in `allowed`.

A `delete` with no `where` raises at `build` time unless
[`:all_rows()`](#queryall_rows) was called.

```lua
local sql = require "akkar.sql"

local q = sql.delete_from("ref_sql_tasks", { "ref_sql_tasks" })
q:where("id = ?", 7)

print(q:to_string())
print(q:values()[1])
```

## sql.identifier(name, allowed, what)

Checks one identifier and returns it. `what` is the word used in the error
message (`"column name"`, `"table name"`). `allowed` is an optional list; when
given, `name` must be in it.

This is the same check every other function in this module uses. Call it
directly when you are writing SQL text by hand and still need a name from a
request checked.

**Returns** `name`, unchanged.

**Raises** `akkar.sql: <what> is not a valid identifier: <name>` when the name
is not letters, digits and underscores (optionally one dot for a qualified
name), and `akkar.sql: <what> '<name>' is not in the allowed list (...)` when
it is not in `allowed`.

```lua
local sql = require "akkar.sql"

print(sql.identifier("title", { "id", "title" }, "column name"))
print(sql.identifier("public.tasks", nil, "table name"))

local ok, why = pcall(sql.identifier, "password_hash", { "id", "title" },
                      "column name")
print(ok, why)
```

## sql.insert_into(table_name, row, allowed_columns, allowed_table)

Starts an `insert`. The column names come from the keys of `row`, so on a real
route they came from a request body; every one is checked, and
`allowed_columns` is how a route says which columns a client may write.

Columns are sorted by name, so the same row always produces the same statement
text.

**Returns** a [Query](#query).

**Raises** when a key of `row` is not a plain identifier or is not in
`allowed_columns`, when `table_name` fails the same check against
`allowed_table`, and at `build` time with `akkar.sql: insert with no columns`
when `row` was empty.

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("ref_sql_tasks",
                          { title = "buy milk", done = false },
                          { "title", "done" })
q:returning "id, title, done"

print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

## sql.Query

The [Query](#query) metatable, exported so a test can check
`getmetatable(q) == sql.Query`. Nothing else needs it.

```lua no-run
local sql = require "akkar.sql"
local is_query = getmetatable(sql.select "*") == sql.Query
```

## sql.select(columns)

Starts a `select`. `columns` is SQL text, defaulting to `"*"`. It is not
checked, because it is written by you and not by a caller: put a column name
that came from a request through [`sql.identifier`](#sqlidentifiername-allowed-what)
first.

The table is set separately, with [`:from`](#queryfromtable_name-allowed).

**Returns** a [Query](#query).

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title, done"):from "ref_sql_tasks"
q:where("done = ?", false)
q:order_by("title", { "id", "title" })
q:limit(10)

print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

## sql.update(table_name, allowed)

Starts an `update`. `allowed` is an optional list of table names. Columns are
set with [`:set`](#querysetcolumn-value-allowed).

**Returns** a [Query](#query).

**Raises** when `table_name` fails the identifier check, at `build` time with
`akkar.sql: update with no columns; call :set()` when nothing was set, and at
`build` time when there is no `where` and no
[`:all_rows()`](#queryall_rows).

```lua
local sql = require "akkar.sql"

local q = sql.update("ref_sql_tasks", { "ref_sql_tasks" })
q:set("done", true, { "done", "title" })
q:where("id = ?", 3)
q:returning "id, done"

print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

## Query

What the five functions above return. Every method returns the query, so calls
chain. Nothing is assembled until [`:build`](#querybuild), which is also what
`db:one`, `db:many` and `db:exec` call when they are handed a query instead of
a string.

A `?` in any condition marks a value. Numbering into `$1`, `$2` happens once,
at `build`, so fragments compose without anyone counting placeholders.

### query:all_rows()

Says that an `update` or a `delete` with no `where` was meant. Without it,
`build` raises rather than write a statement that touches every row.

**Returns** the query.

```lua
local sql = require "akkar.sql"

local q = sql.delete_from("ref_sql_sessions")
local ok, why = pcall(function() return q:to_string() end)
print(ok, why)

print(q:all_rows():to_string())
```

### query:build()

Assembles the statement. Returns the SQL text followed by the bound values, in
placeholder order, which is exactly the argument list `db:many` takes.

**Returns** `sql, value1, value2, ...`.

**Raises** `akkar.sql: no table; call :from()` when no table was set, and the
per-kind errors listed under the five starting functions.

```lua
local sql = require "akkar.sql"
local db  = require "akkar.db.memory"

local fake = db.new():on("select id, title", { id = 1, title = "buy milk" })

local q = sql.select("id, title"):from("ref_sql_tasks"):where("id = ?", 1)
print(q:build())

-- db:one calls :build itself, so the query goes straight in.
print(fake:one(q).title)
```

### query:from(table_name, allowed)

Sets the table. `allowed` is an optional list of table names.

`table_name` must be a plain identifier or `schema.name`. An alias
(`"tasks t"`) is refused, because it is not an identifier.

**Returns** the query.

**Raises** `akkar.sql: table name is not a valid identifier: <name>`.

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("public.ref_sql_tasks"):to_string())

local ok, why = pcall(function()
  return sql.select("*"):from "ref_sql_tasks t"
end)
print(ok, why)
```

### query:group_by(column, allowed)

Adds a `group by` on one column. The column is an identifier, so it is checked
against `allowed` when one is given.

**Returns** the query.

**Raises** on a column that fails the identifier check.

```lua
local sql = require "akkar.sql"

local q = sql.select("done, count(*) as n"):from "ref_sql_tasks"
q:group_by("done", { "done" })
print(q:to_string())
```

### query:is_scoped()

Whether [`:scope`](#queryscopecolumn-value-allowed) has been called. This is
what a scoped handle from `akkar.scope` checks before it runs anything.

**Returns** `true` or `false`.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "ref_sql_documents"
print(q:is_scoped())
q:scope("project_id", 9)
print(q:is_scoped())
```

### query:join(clause, ...)

Appends join text to a `select`, with its own values. The clause is written in
full, including the word `join`, and `?` in it binds a value like anywhere
else.

The clause itself is SQL text and is not checked, so nothing from a request
belongs in it.

**Returns** the query.

```lua
local sql = require "akkar.sql"

local q = sql.select("ref_sql_tasks.id, ref_sql_users.name")
             :from "ref_sql_tasks"
q:join("join ref_sql_users on ref_sql_users.id = ref_sql_tasks.user_id " ..
       "and ref_sql_users.active = ?", true)
q:where("ref_sql_tasks.done = ?", false)

print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

### query:limit(n)

Adds `limit`. The number is bound as a value, not written into the text.

**Returns** the query.

**Raises** `akkar.sql: limit must be a non-negative integer, got <n>`. A float
is refused, so `limit(10.0)` fails and `limit(10)` does not.

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("ref_sql_tasks"):limit(10):to_string())

local ok, why = pcall(function()
  return sql.select("*"):from("ref_sql_tasks"):limit(10.0)
end)
print(ok, why)
```

### query:offset(n)

Adds `offset`, bound as a value. Same rule as `limit`.

**Returns** the query.

**Raises** `akkar.sql: offset must be a non-negative integer, got <n>`.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "ref_sql_tasks"
q:limit(10):offset(20)
print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

### query:order_by(column, allowed, direction)

Sets `order by`. `direction` is `"asc"` (the default) or `"desc"`, in any case.

A column name cannot be a bound value, because Postgres cannot plan
`order by $1`. So a column that arrived from a caller has to be checked
against `allowed`, a list you wrote.

Calling it twice replaces the previous ordering rather than adding to it.

**Returns** the query.

**Raises** `akkar.sql: order column '<name>' is not in the allowed list (...)`
and `akkar.sql: order direction must be asc or desc, got <direction>`.

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "ref_sql_tasks"
q:order_by("title", { "id", "title" }, "desc")
print(q:to_string())

local ok, why = pcall(function()
  q:order_by("password_hash", { "id", "title" })
end)
print(ok, why)
```

### query:returning(columns)

Adds `returning`, so an `insert`, `update` or `delete` answers with the rows it
touched. `columns` is SQL text, defaulting to `"*"`.

**Returns** the query.

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("ref_sql_tasks", { title = "buy milk" }, { "title" })
print(q:returning("id, title"):to_string())
```

### query:scope(column, value, allowed)

Binds the query to one tenant.

On a `select`, `update` or `delete` it adds `column = value` as a condition. On
an `insert` it sets that column on the row, replacing whatever the row already
had, so a body claiming another tenant's id cannot write into it.

**Returns** the query, marked scoped.

**Raises** on a column that fails the identifier check, and
`akkar.sql: scope value for '<column>' is nil` when `value` is nil.

```lua
local sql = require "akkar.sql"

local read = sql.select("*"):from "ref_sql_documents"
print(read:scope("project_id", 42):to_string())

local write = sql.insert_into("ref_sql_documents",
                              { title = "notes", project_id = 1 },
                              { "title", "project_id" })
write:scope("project_id", 42)
print(write:to_string())
for index, value in ipairs(write:values()) do
  print(index, tostring(value))
end
```

### query:set(column, value, allowed)

Sets one column on an `update`. The column is an identifier and the value is a
value, and they cannot trade places. Call it once per column.

**Returns** the query.

**Raises** on a column that fails the identifier check.

```lua
local sql = require "akkar.sql"

local q = sql.update("ref_sql_tasks")
q:set("done", true, { "done", "title" })
q:set("title", "buy oat milk", { "done", "title" })
q:where("id = ?", 3)
print(q:to_string())
```

### query:to_string()

The statement text alone, with the values left out. For tests and for logging.

The values are deliberately not written into it: a log line showing real values
spliced into SQL is how a safe query gets copied into an unsafe one.

**Returns** the SQL text.

**Raises** whatever [`:build`](#querybuild) raises, since it calls it.

```lua
local sql = require "akkar.sql"

print(sql.select("id"):from("ref_sql_tasks"):where("id = ?", 1):to_string())
```

### query:values()

The bound values as a list, in placeholder order. For assertions.

**Returns** a table.

**Raises** whatever [`:build`](#querybuild) raises.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "ref_sql_tasks"
q:where("done = ?", false):where("title like ?", "buy%"):limit(5)

for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

### query:where(condition, ...)

Adds a condition. Conditions are joined with `and`. Each `?` in `condition`
takes one value from the arguments.

**Returns** the query.

**Raises** `akkar.sql: condition has N placeholder(s) but M value(s) were
given: <condition>` when the counts differ. The count is of `?` characters
anywhere in the text, so a `?` inside a string literal counts too.

On an `insert`, a condition and its values are dropped at `build` time without
an error. `where` on an insert is not meaningful, and nothing tells you so.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "ref_sql_tasks"
q:where("done = ?", false)
q:where("title like ?", "buy%")
print(q:to_string())

local ok, why = pcall(function() q:where("id = ?") end)
print(ok, why)
```

### query:where_in(column, values, allowed)

Adds `column in (...)` with one placeholder per element, so a list arriving as
data stays data.

An empty list becomes the condition `false`, which matches no rows. `in ()` is
a syntax error in Postgres, and dropping the condition instead would return
every row rather than none.

**Returns** the query.

**Raises** on a column that fails the identifier check.

```lua
local sql = require "akkar.sql"

local some = sql.select("*"):from "ref_sql_tasks"
some:where_in("id", { 1, 2, 3 }, { "id" })
print(some:to_string())

local none = sql.select("*"):from "ref_sql_tasks"
none:where_in("id", {}, { "id" })
print(none:to_string())
```

## Identifiers and values

A value can be a parameter. An identifier cannot: Postgres has no placeholder
for a table or column name, because the plan depends on which one it is.

So the two are handled differently, everywhere in this module:

| what | how it travels | how it is checked |
|---|---|---|
| a value, in `where`, `set`, `where_in`, `limit`, `offset`, `scope` | bound as `$1`, `$2` | not checked, it can be anything |
| an identifier, in `from`, `set`, `order_by`, `group_by`, `where_in`, `scope`, `insert_into` | written into the text | pattern, plus your `allowed` list |
| SQL text, in `select`, `returning`, `join`, `where` | written into the text as given | not checked, so nothing from a request belongs here |

The identifier pattern is `^[%a_][%w_]*$`, or two of those with one dot
between them. It is narrower than what Postgres accepts. A quoted name with a
space in it is refused, and the cost of that is a clear error, while the cost
of accepting a crafted one is the database.

## Not here

`where_raw` does not exist, and neither does any other way to add unchecked SQL
carrying values. An escape hatch is where the injection goes.

`query:order` does not exist. The module's own header shows `q:order("name")`;
the method is [`order_by`](#queryorder_bycolumn-allowed-direction) and it takes
an allow-list.

There is no `or`. Conditions are joined with `and`. Write the alternation
inside one condition: `q:where("(a = ? or b = ?)", x, y)`.

There is no `execute`. A query is handed to `db:one`, `db:many` or `db:exec`,
which call `:build` for you.

## See also
- [akkar.db](db.md) runs what this builds
- [akkar.scope](scope.md) uses `:scope` and `:is_scoped` to refuse an unscoped query
- [akkar.migrate](migrate.md) does not use this: a migration is SQL you wrote
- the module source, `akkar/sql.lua`, for why there is no escape hatch
