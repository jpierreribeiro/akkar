# 6. join

By the end of this page you will be able to read rows from two tables at once,
and you will know the two things about akkar's `join` that will otherwise cost
you an afternoon: it has no aliases, and the clause is text you are trusted
with.

## What a join is, in one paragraph

Your tasks each belong to a person. The `sqlguide_tasks` table does not store
the person's name, it stores their id, because storing the name in both places
means changing it in both places. A join is how you ask for both tables in one
question: "every task, with the name of the person it belongs to".

## The clause is written in full

`:join` takes the whole clause, starting with the word `join`:

```lua
local sql = require "akkar.sql"

local q = sql.select("sqlguide_tasks.title, sqlguide_people.name")
             :from "sqlguide_tasks"
q:join "join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"

print(q:to_string())
```

```
select sqlguide_tasks.title, sqlguide_people.name from sqlguide_tasks join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id
```

You write the word `join`, so you also choose which kind. `left join` keeps the
rows that have no match on the other side:

```lua
local sql = require "akkar.sql"

local q = sql.select("sqlguide_tasks.title, sqlguide_people.name")
             :from "sqlguide_tasks"
q:join "left join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"

print(q:to_string())
```

```
select sqlguide_tasks.title, sqlguide_people.name from sqlguide_tasks left join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id
```

Call `:join` more than once for more than one table. Each clause is appended in
the order you added it.

## There are no aliases, so write the full name every time

Most SQL you will read uses short aliases: `from tasks t join people p on
p.id = t.person_id`. You cannot do that here, because `:from` refuses
`tasks t`. It is two words, and a table name has to be one identifier:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function() return sql.select("*"):from "sqlguide_tasks t" end)
print(ok, why)
```

```
false	akkar.sql: table name is not a valid identifier: sqlguide_tasks t
```

So the rule for joined queries is: **write the full table name in front of
every column, everywhere.** In the select list, in the join condition, and in
the where clause. It is longer to type and it always works.

The one thing you cannot do at all is join a table to itself, because that is
the case that genuinely needs two names for one table. If you need it, write
the whole statement as text and pass it to `db:many` with its own values.

## Values in a join clause

A `?` inside a join clause binds a value, the same as in a condition:

```lua
local sql = require "akkar.sql"

local q = sql.select("sqlguide_tasks.title"):from "sqlguide_tasks"
q:join("join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id "
    .. "and sqlguide_people.name = ?", "ana")
q:where("sqlguide_tasks.title like ?", "buy%")

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select sqlguide_tasks.title from sqlguide_tasks join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id and sqlguide_people.name = $1 where sqlguide_tasks.title like $2
1	ana
2	buy%
```

Notice the numbering. The join sits before the `where` in the finished text, so
its value is `$1` and the condition's is `$2`, even though you added the
condition later. You did not have to know that, which is the point of letting
`build` do the counting.

## The clause is not checked, so nothing from a request goes in it

This is the one place in `akkar.sql` where you can still write an injection,
and it is worth being blunt about.

The text you pass to `:join` is copied into the statement exactly as given.
akkar does not read it. That is the same rule as the column list in
[`select`](02-select-and-from.md): safe because it is your text, in your file,
fixed before any request arrives.

So this is a bug, and akkar cannot stop you writing it:

```lua no-run
-- NEVER. The caller now controls part of the statement.
q:join("join " .. req.query.table .. " on ...")
```

If a table name really has to vary, put it through `sql.identifier` with a list
first, exactly as [page 2](02-select-and-from.md) showed for columns.
There is no version of this where unchecked request text belongs in a join.

## Watch out for two columns with the same name

A row comes back as one flat Lua table, one field per column of the result. If
two columns in your select list have the same name, they collide, and **the
last one wins**:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local row = conn:one "select 1 as id, 2 as id"
print(row.id)

conn:close()
```

```
2
```

Nothing warns you. On a join between two tables that both have an `id`, that is
the difference between the task's id and the person's id, silently.

So give them names:

```lua
local sql = require "akkar.sql"

local q = sql.select("sqlguide_tasks.id as task_id, "
               .. "sqlguide_people.id as person_id, sqlguide_people.name")
             :from "sqlguide_tasks"
q:join "join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"

print(q:to_string())
```

```
select sqlguide_tasks.id as task_id, sqlguide_people.id as person_id, sqlguide_people.name from sqlguide_tasks join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id
```

`as task_id` renames the column in the result, so the row has `row.task_id` and
`row.person_id` and nothing is lost.

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
conn:exec "drop table if exists sqlguide_people"
conn:exec "create table sqlguide_people (id serial primary key, name text not null)"
conn:exec [[create table sqlguide_tasks (
  id serial primary key,
  person_id integer references sqlguide_people(id),
  title text not null)]]
conn:exec "insert into sqlguide_people (name) values ('ana'), ('bo')"
conn:exec [[insert into sqlguide_tasks (person_id, title) values
  (1, 'buy milk'), (2, 'walk the dog'), (null, 'nobody owns me')]]

local inner = sql.select("sqlguide_tasks.title, sqlguide_people.name")
                 :from "sqlguide_tasks"
inner:join "join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"
inner:order_by("title", { "title" })

print "join:"
for _, row in ipairs(conn:many(inner)) do print("", row.title, row.name) end

local outer = sql.select("sqlguide_tasks.title, sqlguide_people.name")
                 :from "sqlguide_tasks"
outer:join "left join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"
outer:order_by("title", { "title" })

print "left join:"
for _, row in ipairs(conn:many(outer)) do print("", row.title, tostring(row.name)) end

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_people"
conn:close()
```

```
join:
	buy milk	ana
	walk the dog	bo
left join:
	buy milk	ana
	nobody owns me	nil
	walk the dog	bo
```

The plain `join` dropped the task with no person. The `left join` kept it and
gave it `nil` for the name, because akkar leaves a SQL `null` out of the row
table entirely, and a missing field in Lua reads as `nil`.

That last detail matters when you send the row on as JSON: a field that is
`nil` is simply not in the object. If the caller needs to see it, set a default
in your handler.

## Checkpoint

You have this if:

- you can join two tables and get one flat row back
- you know why there are no aliases and what you write instead
- you know that `?` works inside a join clause and that the rest of the clause
  is not checked
- you would alias two columns that share a name rather than let one win

Next: [7. group_by](07-group-by.md).
