# 1. The query object

By the end of this page you will know what `akkar.sql` hands you, the three
ways to look at it, and exactly where the `$1` in the finished statement comes
from.

Nothing here touches the database. A query is an ordinary Lua value until you
give it to `req.db`, and this page is only about the value.

## A query is a table that remembers pieces

`sql.select` does not build any SQL. It makes a table and puts one piece of
information in it. Every method you call after that adds another piece and
hands the same table back.

```lua
local sql = require "akkar.sql"

local q = sql.select "id, title"
print(type(q))

local same = q:from "sqlguide_tasks"
print(same == q)
```

```
table
true
```

`same == q` is `true` because `:from` returned the very query it was called on.
That is why calls can be written in a chain, and why they can also be written
apart on separate lines. These two are the same query, built two ways:

```lua
local sql = require "akkar.sql"

local chained = sql.select("id, title"):from("sqlguide_tasks"):where("done = ?", false)

local apart = sql.select "id, title"
apart:from "sqlguide_tasks"
apart:where("done = ?", false)

print(chained:to_string())
print(apart:to_string())
```

```
select id, title from sqlguide_tasks where done = $1
select id, title from sqlguide_tasks where done = $1
```

The second form is the one you want inside a handler, because you can put an
`if` in the middle of it:

```lua no-run
local q = sql.select("id, title"):from "sqlguide_tasks"
if req.query.done ~= nil then
  q:where("done = ?", req.query.done)
end
```

A chain cannot have an `if` in the middle. That is the whole reason this module
exists: the query changes depending on what the caller asked for, and the old
way of doing that was gluing strings together.

## The three ways to look at it

You will use all three, for three different jobs.

### `:to_string()` gives you the text

Use it when you want to see what you built. It is for reading, for a log line,
and for a test.

```lua
local sql = require "akkar.sql"

local q = sql.select("id"):from("sqlguide_tasks"):where("id = ?", 1)
print(q:to_string())
```

```
select id from sqlguide_tasks where id = $1
```

Look at what is missing from that line: the number `1` is not in it. That is
deliberate. A log line with the real values written into the SQL is the exact
text somebody copies later into a statement that is not safe, so `to_string`
never produces one.

### `:values()` gives you the values

A plain Lua list, in the order the placeholders appear.

```lua
local sql = require "akkar.sql"

local q = sql.select "*"
q:from "sqlguide_tasks"
q:where("done = ?", false)
q:where("title like ?", "buy%")
q:limit(5)

for index, value in ipairs(q:values()) do
  print(index, type(value), tostring(value))
end
```

```
1	boolean	false
2	string	buy%
3	number	5
```

Three things worth noticing.

The values keep their Lua types. `false` is still a boolean, not the text
`"false"`. This is what "the value never becomes text" means in practice.

`limit(5)` put a value in the list too. The limit is a number, so it is bound
like any other number rather than written into the statement.

The order is the order of the placeholders in the finished text, not the order
you called the methods in. On this query they happen to match. On an `update`
they do not, and [page 9](09-update.md) shows why.

### `:build()` gives you both, ready to send

`build` returns the text first and then every value, as separate return values.

```lua
local sql = require "akkar.sql"

local q = sql.select("id"):from("sqlguide_tasks"):where("done = ?", false):limit(5)

local text, first, second = q:build()
print(text)
print(type(first), tostring(first))
print(type(second), tostring(second))
```

```
select id from sqlguide_tasks where done = $1 limit $2
boolean	false
number	5
```

That shape is not an accident. It is exactly the argument list `db:many` takes:

```lua no-run
req.db:many(q:build())
```

And because that is so common, you do not have to write it. `db:one`,
`db:many` and `db:exec` call `build` for you when you hand them a query:

```lua no-run
req.db:many(q)
```

Both lines do the same thing. Use the short one.

## Where `$1` comes from

You write `?`. Postgres wants `$1`, `$2`, `$3`. The swap happens once, at
`build`, counting from left to right through the finished text.

This matters more than it looks. Consider three separate conditions added at
three different moments:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("done = ?", false)
q:where("title like ?", "buy%")
q:where("id > ?", 10)
q:limit(3)

print(q:to_string())
```

```
select * from sqlguide_tasks where done = $1 and title like $2 and id > $3 limit $4
```

Nobody counted. If you had written `$1`, `$2`, `$3` yourself, every optional
filter would change the numbering of every filter after it, and one wrong
number is a query that reads the wrong value or fails outright. Counting
placeholders by hand is the other half of why people give up and concatenate
strings.

Notice `and` between the conditions. Conditions are always joined with `and`,
and [page 3](03-where.md) says what to do when you want `or`.

## Nothing is sent yet

None of the examples above opened a connection. The query is data. It becomes
a statement when you hand it to a database handle, and not before, which is why
you can build one in a test and check it with `to_string` without any Postgres
running at all.

## Checkpoint

You have this if you can answer these without looking:

- What does `sql.select("id"):from "t"` return? A query, which is a Lua table.
- Which of the three methods do you use in a test? `to_string` and `values`.
- Which one does `db:many` call for you? `build`.
- Who turns `?` into `$1`? `build` does, once, left to right.

Next: [2. select and from](02-select-and-from.md).
