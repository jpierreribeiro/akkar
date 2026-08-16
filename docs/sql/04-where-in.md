# 4. where_in, for a list

By the end of this page you will be able to ask "is this column one of these
values" with a list that arrived from a caller, and you will know what happens
when that list is empty.

## The problem

You have a list of ids and you want the rows for all of them. In SQL that is:

```sql
select id, title from sqlguide_tasks where id in (1, 2, 3)
```

The number of values is not fixed. It is however many the caller sent. So you
cannot write the condition ahead of time, and `:where("id in (?)", ids)` does
not work either, because one `?` binds one value and a Lua list is one value
that Postgres does not understand.

## `where_in` writes one placeholder per element

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where_in("id", { 1, 2, 3 }, { "id" })

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select id, title from sqlguide_tasks where id in ($1, $2, $3)
1	1
2	2
3	3
```

Three elements, three placeholders, three values. Five elements would give you
five. Every one is bound, so a list of strings arriving from a request stays a
list of strings:

```lua
local sql = require "akkar.sql"

local titles = { "buy milk", "'); drop table sqlguide_tasks; --" }

local q = sql.select("id"):from "sqlguide_tasks"
q:where_in("title", titles, { "id", "title" })

print(q:to_string())
print(q:values()[2])
```

```
select id from sqlguide_tasks where title in ($1, $2)
'); drop table sqlguide_tasks; --
```

The attack string is in the values list, where it is text and nothing else. The
statement has two placeholders in it and no user text at all.

## The third argument is the allow-list

`where_in` takes a **column name**, and a column name is an identifier, so it
cannot be bound. It is checked the same way `from` is:

```lua
local sql = require "akkar.sql"

local q = sql.select("id"):from "sqlguide_tasks"
local ok, why = pcall(function()
  return q:where_in("password_hash", { 1, 2 }, { "id", "title" })
end)
print(ok, why)
```

```
false	akkar.sql: column name 'password_hash' is not in the allowed list (id, title)
```

You can leave the list out when the column is a constant you wrote. Pass it
whenever the column name could have come from a request.

## An empty list matches nothing, on purpose

This is the part that catches people, and akkar decided it for you:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where_in("id", {}, { "id" })

print(q:to_string())
print("#values", #q:values())
```

```
select id, title from sqlguide_tasks where false
#values	0
```

The condition became the word `false`, which no row can satisfy. So an empty
list gives you an empty result.

Two other things could have happened, and both are worse.

**Writing `id in ()`** is a syntax error in Postgres. The query would fail with
a message about a parenthesis, from a request that was not wrong, only empty.

**Dropping the condition** would leave `select id, title from sqlguide_tasks`
with no `where` at all, which returns **every row in the table**. That is the
dangerous one. "Show me the tasks with these ids" and a list of none would
answer with everybody's tasks. The same query on a page with a tenant filter
would still be scoped, but on a page without one it is a data leak caused by an
empty array in a JSON body.

Here it is against a real database, so you can see that "no rows" is what
actually comes back:

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
conn:exec "insert into sqlguide_tasks (title) values ('buy milk'), ('walk the dog'), ('read the guide')"

local some = sql.select("id, title"):from "sqlguide_tasks"
some:where_in("id", { 1, 3 }, { "id" })
print("some:", #conn:many(some))

local none = sql.select("id, title"):from "sqlguide_tasks"
none:where_in("id", {}, { "id" })
print("none:", #conn:many(none))

print("everything:", #conn:many(sql.select("id"):from "sqlguide_tasks"))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
some:	2
none:	0
everything:	3
```

Two, then none, then three. The middle line is the one this section is about.

## Two limits worth knowing

**A hole in the list breaks it.** A Lua list with a `nil` in the middle has a
length Lua cannot agree on, and you get the misleading message from
[page 3](03-where.md):

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where_in("id", { 1, nil, 3 }, { "id" })

local ok, why = pcall(function() return q:to_string() end)
print(ok, why)
```

```
false	akkar.sql: 3 placeholder(s) but 2 value(s) -- this is a bug in akkar.sql
```

It is not a bug in akkar. It is a `nil` in your list. Build the list with
`list[#list + 1] = value` so it cannot get holes.

**A very long list will not fit.** Postgres allows at most 65535 bound
parameters in one statement. A list longer than that fails with a message that
does not explain itself:

```lua no-run
local ids = {}
for i = 1, 70000 do ids[i] = i end
q:where_in("id", ids, { "id" })
```

```
db: ERROR: invalid message format
```

If you have tens of thousands of ids, `where_in` is the wrong tool. Put them in
a table and join to it, or send them in batches.

## Checkpoint

You have this if:

- `where_in("id", { 1, 2, 3 }, { "id" })` gives you `id in ($1, $2, $3)`
- you can say what an empty list produces, and why the alternative was refused
- you know the column is checked and the values are not

Next: [5. order_by, limit and offset](05-order-limit-offset.md).
