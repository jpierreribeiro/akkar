# 3. where, and the question mark

By the end of this page you will be able to write any condition you need,
including the ones with several values, the ones that are optional, and the
ones that want `or`.

## One `?` per value

`:where` takes a condition and then one value for each `?` in it.

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where("done = ?", false)

print(q:to_string())
print(q:values()[1])
```

```
select id, title from sqlguide_tasks where done = $1
false
```

The `?` is a mark saying "a value goes here". It is not the value. The value
travels beside the statement, in a separate list, and Postgres receives the two
as two different things.

Several `?` in one condition take several values, in order:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("id between ? and ?", 10, 20)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select * from sqlguide_tasks where id between $1 and $2
1	10
2	20
```

## Two conditions mean `and`

Call `:where` as many times as you like. Every condition is joined to the ones
before it with `and`:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("done = ?", false)
q:where("title like ?", "buy%")
q:where("id > ?", 3)

print(q:to_string())
```

```
select * from sqlguide_tasks where done = $1 and title like $2 and id > $3
```

That is what makes an optional filter easy. Each one is an `if` that either
adds a condition or does not:

```lua
local sql = require "akkar.sql"

local function search(filters)
  local q = sql.select("id, title"):from "sqlguide_tasks"
  if filters.done ~= nil then q:where("done = ?", filters.done) end
  if filters.text then q:where("title like ?", "%" .. filters.text .. "%") end
  return q
end

print(search({}):to_string())
print(search({ done = true }):to_string())
print(search({ done = true, text = "milk" }):to_string())
print(search({ done = true, text = "milk" }):values()[2])
```

```
select id, title from sqlguide_tasks
select id, title from sqlguide_tasks where done = $1
select id, title from sqlguide_tasks where done = $1 and title like $2
%milk%
```

Look at the last value. `"%milk%"` was built by gluing strings together, and
that is completely safe, because it is a **value**. It goes into the values
list. The percent signs are part of the text the database compares against, not
part of the statement. Gluing is only dangerous when the result becomes SQL.

## There is no `or` method

Conditions are always joined with `and`. When you want `or`, write it inside
one condition, and put brackets round it:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("(title like ? or note like ?)", "%milk%", "%milk%")
q:where("done = ?", false)

print(q:to_string())
```

```
select * from sqlguide_tasks where (title like $1 or note like $2) and done = $3
```

The brackets are not decoration. Without them the statement reads
`a or b and c`, and `and` binds tighter than `or` in SQL, so you would get
`a or (b and c)`, which is a different question. akkar cannot add the brackets
for you, because it does not read your condition.

## A condition with no values at all

Perfectly normal, and you pass nothing after it:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("note is null")
q:where("done = ?", false)

print(q:to_string())
print("#values", #q:values())
```

```
select * from sqlguide_tasks where note is null and done = $1
#values	1
```

`is null` is the right way to ask about a missing value. `note = ?` with
nothing to bind is not, and the next section is about what happens if you try.

## The mistakes, and the messages

### The count does not match

akkar counts the `?` characters and counts the values you passed. If they
differ, it stops immediately, at the `:where` call, rather than building a
statement that cannot work:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"

local ok, why = pcall(function() return q:where("id = ?") end)
print(ok, why)

local ok2, why2 = pcall(function() return q:where("id = ?", 1, 2) end)
print(ok2, why2)
```

```
false	akkar.sql: condition has 1 placeholder(s) but 0 value(s) were given: id = ?
false	akkar.sql: condition has 1 placeholder(s) but 2 value(s) were given: id = ?
```

The message ends with the condition itself, so you can see which of the
conditions in a long handler it is talking about.

### A question mark inside a string counts too

The count is of `?` characters anywhere in the text. It does not know that one
of yours is inside quotes:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
local ok, why = pcall(function() return q:where("title = 'what?'") end)
print(ok, why)
```

```
false	akkar.sql: condition has 1 placeholder(s) but 0 value(s) were given: title = 'what?'
```

The fix is not to fight it. A literal in a condition is a value, so it should
have been bound in the first place:

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("sqlguide_tasks"):where("title = ?", "what?"):to_string())
```

```
select * from sqlguide_tasks where title = $1
```

Now the question mark inside the value is just a character in a string. This is
the general rule wearing a small hat: if it is a value, bind it.

### A `nil` value, and a message that blames akkar

This one is worth knowing before it happens to you, because the message is
misleading.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("title = ?", nil)

local ok, why = pcall(function() return q:to_string() end)
print(ok, why)
```

```
false	akkar.sql: 1 placeholder(s) but 0 value(s) -- this is a bug in akkar.sql
```

It says "this is a bug in akkar.sql" and it almost certainly is not. It is a
`nil` in your values.

Here is what happened. `:where` counted the arguments correctly, saw one value,
and accepted the condition. But `nil` cannot be stored in a Lua list, so
nothing went into the values list, and at `build` time there was a `?` with no
value behind it. The internal check that fires last is the one that notices,
and it assumes it is akkar's fault.

Where `nil` comes from in real code is a field that was not in the request
body:

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk" }        -- no `note` was sent

local q = sql.select("*"):from "sqlguide_tasks"
q:where("note = ?", body.note)             -- body.note is nil

local ok, why = pcall(function() return q:to_string() end)
print(ok, why)
```

```
false	akkar.sql: 1 placeholder(s) but 0 value(s) -- this is a bug in akkar.sql
```

Two fixes, and which one you want depends on what you meant.

If a missing field means "do not filter on this at all", guard it, which is the
optional-filter pattern from earlier on this page:

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk" }

local q = sql.select("*"):from "sqlguide_tasks"
if body.note ~= nil then q:where("note = ?", body.note) end

print(q:to_string())
```

```
select * from sqlguide_tasks
```

If a missing field means "find the rows where this column is empty", say that
in SQL, because `= null` is never true in SQL even when the column is null:

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("sqlguide_tasks"):where("note is null"):to_string())
```

```
select * from sqlguide_tasks where note is null
```

### `where` on an insert is thrown away

An `insert` has nowhere to put a condition, and akkar drops it without saying
anything:

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("sqlguide_tasks", { title = "buy milk" }, { "title" })
q:where("id = ?", 1)

print(q:to_string())
print("#values", #q:values())
```

```
insert into sqlguide_tasks (title) values ($1)
#values	1
```

The condition is gone and the `1` never appears. If you meant "insert only if
this row is not already there", that is a different statement,
`insert ... on conflict do nothing`, and it goes in the text you pass to
`db:exec` yourself.

## Checkpoint

You have this if:

- you can write a two-value condition and know which `$` each one becomes
- you know that two `:where` calls mean `and`, and how to get `or`
- you would recognise `condition has 1 placeholder(s) but 0 value(s)` as a
  counting mistake and `this is a bug in akkar.sql` as a `nil` you passed in

Next: [4. where_in, for a list](04-where-in.md).
