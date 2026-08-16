# 13. transaction, and the trap in it

By the end of this page you will be able to make several statements happen
together or not at all, and you will have seen, with real output, the one
mistake that writes a row while telling the caller their request was rejected.

## What a transaction is for

Two statements that must both happen. Move money out of one account and into
another. Create an order and reduce the stock. Write a row and write the log
entry that says you wrote it.

If the first succeeds and the second fails, you are left with a state that your
application does not have a word for. A transaction removes that state: either
both statements land, or neither does.

## The closure is the transaction

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

conn:transaction(function(tx)
  tx:exec("insert into sqlguide_notes (body) values ($1)", "first")
  tx:exec("insert into sqlguide_notes (body) values ($1)", "second")
end)

print("rows:", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
rows:	2
```

akkar sent `begin` before your function and `commit` after it. You did not
write either, and **there is no way to leave a transaction open by forgetting**,
because there is no line for you to forget.

If the function raises, akkar sends `rollback` instead and re-raises whatever
you raised:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

local ok = pcall(function()
  conn:transaction(function(tx)
    tx:exec("insert into sqlguide_notes (body) values ($1)", "undone")
    error "changed my mind"
  end)
end)

print("ok:  ", ok)
print("rows:", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
ok:  	false
rows:	0
```

The insert is gone. A failure from Postgres does the same thing, so a broken
statement half way through does not leave the first half behind.

`transaction` returns whatever your function returned, so you can build the
answer inside it and hand it straight back.

## Use `tx`, not `req.db`

The argument the closure receives is the connection with the transaction open
on it. In a handler, `req.db` might be a different connection from the pool,
and a statement sent on that one is outside your transaction and will not be
undone.

```lua no-run
req.db:transaction(function(tx)
  tx:exec("insert into ...")     -- inside
  req.db:exec("insert into ...") -- WRONG: may be a different connection
end)
```

The rule is simple: inside the closure, the only handle you touch is `tx`.

## The trap: returning a 4xx commits

This is the expensive one. It is written in akkar's own source with a note
saying it cost somebody an afternoon, and it is worth an afternoon of yours to
read the next twenty lines.

An akkar handler answers by returning. `akkar.bad_request "..."` is a value,
and returning it is how you send a `400`. So this looks completely reasonable:

```lua no-run
req.db:transaction(function(tx)
  tx:exec("insert into tasks ...")
  if something_is_wrong then
    return akkar.bad_request "no"     -- looks like a refusal
  end
end)
```

It is not a refusal. **The closure returned, so it did not fail, so akkar
committed.** The `400` then travels up and answers the caller. The row is
written, and the caller is told their request was rejected, which is the worst
of both.

Here it is happening:

```lua
local akkar = require "akkar"
local db    = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

local answer = conn:transaction(function(tx)
  tx:exec("insert into sqlguide_notes (body) values ($1)", "written anyway")
  return akkar.bad_request "no"
end)

print("status:", answer.status)
print("rows:  ", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
status:	400
rows:  	1
```

A `400` and a row. Nothing crashed, nothing was logged, and the row is in the
table.

### `error(...)` is the form that refuses

Change one word:

```lua
local akkar = require "akkar"
local db    = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

local ok, response = pcall(function()
  return conn:transaction(function(tx)
    tx:exec("insert into sqlguide_notes (body) values ($1)", "rolled back")
    error(akkar.bad_request "no")
  end)
end)

print("raised:", not ok)
print("status:", response.status)
print("rows:  ", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
raised:	true
status:	400
rows:  	0
```

Same `400` to the caller, and no row. That is what you wanted both times.

This works because a response thrown with `error` is not a crash in akkar. The
framework treats a response-as-error as a response: `pcall` inside
`transaction` sees the raise and rolls back, then re-raises it, and the handler
chain answers with the `400` exactly as if it had been returned.
[Page 4 of the guide](../guide/04-errors.md) is where that idea is introduced.

**Inside a transaction, raise to refuse.** Say it out loud once and it will
stick.

### Why akkar does not fix this for you

It could look at what the closure returned, see a `4xx`, and roll back. It
deliberately does not, and the reason is that the change would be a guess about
what you meant.

A closure can legitimately return a `4xx` after work that **should** persist.
Recording the rejected attempt is the ordinary example: you write a row saying
somebody tried, then you answer `429` or `403`. A rule that read the status
code would silently throw that row away, which is the same defect pointing the
other way and much harder to see.

So the rule stays mechanical. Returned means finished, raised means failed.

## Two more things worth knowing

### There are no savepoints

A `transaction` inside a `transaction` is not a nested transaction. There is
one, and a failure anywhere in it undoes everything:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec "create table sqlguide_notes (id serial primary key, body text not null)"

local ok = pcall(function()
  conn:transaction(function(tx)
    tx:exec("insert into sqlguide_notes (body) values ($1)", "outer")
    tx:transaction(function(inner)
      inner:exec("insert into sqlguide_notes (body) values ($1)", "inner")
      error "the inner one failed"
    end)
  end)
end)

print("ok:  ", ok)
print("rows:", conn:one("select count(*) as n from sqlguide_notes").n)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
ok:  	false
rows:	0
```

The outer insert went too. If you wanted "try this part, and carry on if it
fails", a transaction is not the tool.

### Keep them short

A transaction holds locks on the rows it touched until it ends. Anything slow
inside it, an HTTP call to a payment provider, a file upload, a `sleep`, holds
those locks for that long, and every other request that wants those rows waits.

Do the slow thing first, then open the transaction to write the result.

## Checkpoint

You have this if:

- you can write two inserts that both happen or neither does
- you know to use `tx` and never `req.db` inside the closure
- you can say what `return akkar.bad_request "..."` does inside a transaction,
  and what to write instead
- you know there are no savepoints

Next: [14. scope](14-scope.md).
