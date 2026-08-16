# 5. order_by, limit and offset

By the end of this page you will be able to sort a result by a column the
caller chose, and hand back one page of it at a time.

## `order_by` takes an identifier, so it takes an allow-list

A column name cannot be bound. Postgres cannot plan `order by $1`, because the
plan depends on which column it is. So the name is written into the statement,
and that means it has to be checked:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:order_by("title", { "id", "title", "created_at" })

print(q:to_string())
```

```
select id, title from sqlguide_tasks order by title asc
```

The second argument is the complete list of columns a caller may sort by. It is
written by you. Anything not on it is refused:

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

That refusal is a `500` if it reaches a caller, so do the same check in the
route's schema with `one_of` and the caller gets a clean `422` instead. Both
checks, for two reasons: the schema is there to give the caller a good answer,
and the allow-list is there because a schema you forget to write should not be
the only thing between a stranger and your columns.
[Page 6 of the guide](../guide/06-storing-and-reading.md) shows both together.

### Direction

The third argument is `"asc"` or `"desc"`. Leaving it out means `"asc"`. The
case does not matter:

```lua
local sql = require "akkar.sql"

print(sql.select("id"):from("sqlguide_tasks"):order_by("id", nil, "desc"):to_string())
print(sql.select("id"):from("sqlguide_tasks"):order_by("id", nil, "DESC"):to_string())

local ok, why = pcall(function()
  return sql.select("id"):from("sqlguide_tasks"):order_by("id", nil, "sideways")
end)
print(ok, why)
```

```
select id from sqlguide_tasks order by id desc
select id from sqlguide_tasks order by id desc
false	akkar.sql: order direction must be asc or desc, got sideways
```

Only those two words are accepted, so a direction taken straight from a query
string cannot become anything else.

### One column only

Calling `order_by` twice does not add a second column. It replaces the first:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:order_by("title", { "id", "title" })
q:order_by("id", { "id", "title" }, "desc")

print(q:to_string())
```

```
select id, title from sqlguide_tasks order by id desc
```

The `title` ordering is gone. And you cannot smuggle two columns into one call,
because two columns with a comma between them are not an identifier:

```lua
local sql = require "akkar.sql"

local q = sql.select("id"):from "sqlguide_tasks"
local ok, why = pcall(function() return q:order_by("title, id", { "title, id" }) end)
print(ok, why)
```

```
false	akkar.sql: order column is not a valid identifier: title, id
```

This is a real limit of the builder, and it is the price of the check. If you
need `order by done, created_at desc`, that query is fixed rather than
caller-chosen, so write it as text and hand it to `db:many` yourself.

## `limit` and `offset` are values

Unlike the column name, the numbers are bound:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:order_by("id", { "id" })
q:limit(10)
q:offset(20)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select id, title from sqlguide_tasks order by id asc limit $1 offset $2
1	10
2	20
```

`limit` comes before `offset` in the finished text no matter which order you
called them in, and the numbering follows the text.

Both refuse anything that is not a whole number that is zero or more:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function() return sql.select("*"):from("t"):limit(10.0) end)
print(ok, why)

local ok2, why2 = pcall(function() return sql.select("*"):from("t"):limit(-1) end)
print(ok2, why2)

local ok3, why3 = pcall(function() return sql.select("*"):from("t"):offset("20") end)
print(ok3, why3)
```

```
false	akkar.sql: limit must be a non-negative integer, got 10.0
false	akkar.sql: limit must be a non-negative integer, got -1
false	akkar.sql: offset must be a non-negative integer, got 20
```

The first one surprises people. `10.0` is a float in Lua, not an integer, and
that is exactly what `tonumber(req.query.limit)` gives you when the caller sent
`10.0`. The last one surprises people for the opposite reason: the message
prints `20` because the quotes are not shown, but the value was the **text**
`"20"`, which is what a query string always contains until something converts
it.

Validate in the route schema, where `integer` does the conversion and the
refusal for you:

```lua no-run
app:get("/tasks", {
  query = {
    limit  = v.integer { optional = true, default = 20, min = 1, max = 100 },
    offset = v.integer { optional = true, default = 0, min = 0 },
  },
}, function(req)
  local q = sql.select("id, title"):from "sqlguide_tasks"
  q:order_by("id", { "id", "title" })
  q:limit(req.query.limit):offset(req.query.offset)
  return { tasks = akkar.array(req.db:many(q)) }
end)
```

## A page at a time, against a real table

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
conn:exec [[insert into sqlguide_tasks (title) values
  ('one'), ('two'), ('three'), ('four'), ('five')]]

local function page(number, size)
  local q = sql.select("id, title"):from "sqlguide_tasks"
  q:order_by("id", { "id", "title" })
  q:limit(size)
  q:offset((number - 1) * size)
  return conn:many(q)
end

for number = 1, 3 do
  local titles = {}
  for _, row in ipairs(page(number, 2)) do titles[#titles + 1] = row.title end
  print("page " .. number, table.concat(titles, ", "))
end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
page 1	one, two
page 2	three, four
page 3	five
```

Two rules that page function follows, and both matter.

**Always order when you paginate.** Without `order by`, Postgres may return
rows in any order it likes, and it is free to choose a different one for page 2
than it did for page 1. You would get rows twice and miss others, and it would
work fine in testing on a small table.

**Order by something unique.** `order by title` on a table with two rows called
"one" leaves those two in an undefined order between them, and the same
duplicate-and-miss problem comes back in a smaller form. Sorting by a
caller-chosen column is fine, as long as the query is deterministic overall.
With this builder that means sorting by `id` when you can.

### `offset` gets slower as the page number goes up

`offset 10000` means Postgres finds ten thousand rows and throws them away
before it starts giving you any. That is fine for the first few pages and bad
for page five hundred.

The other approach is to remember the last id you saw and ask for the rows
after it:

```lua
local sql = require "akkar.sql"

local last_id = 4

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where("id > ?", last_id)
q:order_by("id", { "id" })
q:limit(2)

print(q:to_string())
```

```
select id, title from sqlguide_tasks where id > $1 order by id asc limit $2
```

No `offset` at all, so the database jumps straight to the right place using the
index. [The pagination recipe](../recipes/paginate-a-list.md) works this through
properly.

## Checkpoint

You have this if:

- you can sort by a caller-chosen column and know what the second argument is
  for
- you know that `order_by` twice replaces rather than adds
- you know why `limit(10.0)` is refused and `limit(10)` is not
- you always add `order by` when you use `limit` and `offset`

Next: [6. join](06-join.md).
