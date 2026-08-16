# 7. group_by

By the end of this page you will be able to count and total rows per group, and
you will know the two things the builder cannot do here and what to write
instead.

## Counting without grouping first

An aggregate is a function that turns many rows into one number: `count`,
`sum`, `avg`, `min`, `max`. They go in the column list, which is your text, so
nothing new is needed to use them:

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
  owner text not null,
  done boolean not null default false,
  minutes integer not null default 0)]]
conn:exec [[insert into sqlguide_tasks (owner, done, minutes) values
  ('ana', false, 10), ('ana', true, 5), ('ana', false, 30), ('bo', true, 15)]]

local q = sql.select("count(*) as n, avg(minutes) as mean"):from "sqlguide_tasks"
print(q:to_string())

local row = conn:one(q)
print(row.n, row.mean)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
select count(*) as n, avg(minutes) as mean from sqlguide_tasks
4	15.0
```

One row came back, because that is what an aggregate over a whole table is: one
answer. Use `db:one` for it, not `db:many`.

Give every aggregate a name with `as`. Without one, Postgres calls the column
`count`, and `row.count` reads worse than `row.n` and collides the moment you
have two of them.

## `group_by` splits the rows first

Add a `group by` and you get one row per distinct value of that column instead
of one row for the whole table:

```lua
local sql = require "akkar.sql"

local q = sql.select("owner, count(*) as n, sum(minutes) as total")
             :from "sqlguide_tasks"
q:group_by("owner", { "owner", "done" })
q:order_by("n", { "n", "owner" }, "desc")

print(q:to_string())
```

```
select owner, count(*) as n, sum(minutes) as total from sqlguide_tasks group by owner order by n desc
```

The second argument is an allow-list, for the same reason it is on
`order_by`: a column name is an identifier, it is written into the statement,
and it cannot be bound. If the grouping column comes from a caller, that list
is what stops them naming a column you never meant to expose.

Running it:

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
  owner text not null,
  done boolean not null default false,
  minutes integer not null default 0)]]
conn:exec [[insert into sqlguide_tasks (owner, done, minutes) values
  ('ana', false, 10), ('ana', true, 5), ('ana', false, 30), ('bo', true, 15)]]

local q = sql.select("owner, count(*) as n, sum(minutes) as total")
             :from "sqlguide_tasks"
q:group_by("owner", { "owner", "done" })
q:order_by("n", { "n", "owner" }, "desc")

for _, row in ipairs(conn:many(q)) do
  print(row.owner, row.n, row.total)
end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
ana	3	45
bo	1	15
```

Two rows for two owners. `order_by("n", ...)` sorted by the name you gave the
count, which Postgres allows, and which is why naming your aggregates pays off
twice.

### Every plain column in the select list has to be in the group by

This is a SQL rule, not an akkar rule, and it is the first error people meet
here. If you select `owner, title, count(*)` and group by `owner` alone,
Postgres refuses, because there are three different titles in the group and it
does not know which one you wanted.

The fix is either to add the column to the group, or to wrap it in an aggregate
such as `min(title)`. Since `group_by` takes one column only, the practical
answer is: select the grouping column, and aggregates of everything else.

## `where` filters before grouping

The condition applies to rows, and it runs first:

```lua
local sql = require "akkar.sql"

local q = sql.select("owner, count(*) as n"):from "sqlguide_tasks"
q:where("done = ?", false)
q:group_by("owner", { "owner" })
q:order_by("owner", { "owner" })

print(q:to_string())
```

```
select owner, count(*) as n from sqlguide_tasks where done = $1 group by owner order by owner asc
```

Read that as: throw away the finished tasks, then count what is left, per
owner. It is not the same question as "owners who have finished no tasks", and
mixing the two up is the classic grouping mistake.

## The two things the builder will not do

### One grouping column

Calling `group_by` twice replaces rather than adds, exactly like `order_by`:

```lua
local sql = require "akkar.sql"

local q = sql.select("count(*) as n"):from "sqlguide_tasks"
q:group_by("owner", { "owner", "done" })
q:group_by("done", { "owner", "done" })

print(q:to_string())
```

```
select count(*) as n from sqlguide_tasks group by done
```

`group by owner` is gone. There is no way to group by two columns through the
builder.

### There is no `having`

`having` is the condition that applies **after** grouping, the one that says
"only owners with more than two tasks". The builder has no method for it, and
`:where` is not it, because `where` runs first.

Both of those are the same signal: the query has stopped depending on the
request and become a fixed report. Write it as text and pass its values
normally:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key,
  owner text not null,
  done boolean not null default false,
  minutes integer not null default 0)]]
conn:exec [[insert into sqlguide_tasks (owner, done, minutes) values
  ('ana', false, 10), ('ana', true, 5), ('ana', false, 30), ('bo', true, 15)]]

for _, row in ipairs(conn:many([[
  select owner, done, count(*) as n
  from sqlguide_tasks
  group by owner, done
  having count(*) > $1
  order by owner, done]], 1)) do
  print(row.owner, tostring(row.done), row.n)
end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
ana	false	2
```

That statement has two grouping columns and a `having`, and it is completely
safe: the only thing that varies is `$1`, which is bound. **The builder is for
statements whose shape changes with the request. A fixed statement does not
need it**, and reaching for text here is not a step backwards.

## Checkpoint

You have this if:

- you can produce one row per owner with a count on it
- you know `where` filters rows before the grouping happens
- you know the builder does one grouping column and no `having`, and that a
  fixed statement written as text with `$1` is the right answer when you need
  more

Next: [8. insert_into](08-insert.md).
