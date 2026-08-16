# 6. Storing and reading rows

By the end of this page your task list will keep its tasks in Postgres. You
will be able to stop the server, start it again, and find your tasks still
there.

You need the database from [page 5](05-a-database.md): the container running,
and the `tasks` table created by the migration.

## First, the mistake that ends companies

There is one way of writing database code that is easy, obvious, and
catastrophic. It is worth meeting before anything else, because once you have
seen it you will recognise it for the rest of your life.

Here is a handler that saves a task. It builds the SQL by gluing the title into
the middle of it.

**Do not run this block.** It is here to be read and nothing else. It is marked
so that the guide's own test suite refuses to execute it, because running it
against a database destroys that database, which is the entire point being
made.

```lua skip
app:post("/tasks", { body = { title = "string" } }, function(req)
  local task = req.db:one(
    "insert into tasks (title) values ('" .. req.body.title .. "') " ..
    "returning id, title, done")
  return akkar.created(task)
end)
```

It looks fine. It works. Every title you try in testing comes back correct.

Now someone sends this as the title:

```
'); drop table tasks; --
```

Glue that into the string and look at what the database is handed:

```
insert into tasks (title) values (''); drop table tasks; --') returning id, title, done
```

Read it the way Postgres reads it. The caller's first two characters, `')`,
closed the value and closed the statement. Then comes a new statement:
`drop table tasks`. Then `--`, which means "ignore the rest of this line", so
everything after it, including the whole `returning` part you wrote, is thrown
away before Postgres even looks at it.

**Postgres runs both statements. Your table is gone.**

That is not a story. Here is the same trick run against a throwaway database
while writing this page. The little script that ran it left the `returning`
part out, since the `--` deletes it anyway:

```
rows before: 1
the SQL that gets sent:
insert into tasks (title) values (''); drop table tasks; --')
after: ok=false err=db: ERROR: relation "tasks" does not exist (32)
```

The table existed. One request later, the table did not exist.

This is called **SQL injection**. The reason it happens is not carelessness. It
is that the database is handed one long piece of text, and by then there is no
way to tell which parts were written by you and which parts arrived from a
stranger. The letters look the same.

`drop table` is the loud version. The quiet version reads every row of every
other user and sends them back to the caller. You would not notice at all.

## The fix, and it is one character per value

Never put a value into the text of a statement. Write a **placeholder**
instead, and pass the value separately:

```lua no-run
req.db:one("insert into tasks (title) values ($1) returning id, title, done",
           req.body.title)
```

`$1` means "the first value I am about to give you". `$2` is the second, and so
on. The statement goes to Postgres, then the values go to Postgres, and they
travel as two different things.

Postgres plans the statement first, before it has seen any value. By the time
your title arrives, there is no longer any place in that plan where text could
turn into a command. A title containing `drop table` is a title containing
`drop table`, the same way a title containing `hello` is a title containing
`hello`.

There is no version of this you have to get right. You either wrote `$1`, or
you did not.

## Wiring the database into the app

Two lines connect the two halves.

```lua no-run
local open = db.connect { ... }     -- makes the function that opens connections
app:run { port = 3000, db = open }  -- hands that function to akkar
```

akkar then puts a connection on `req.db` for every request that uses one, and
takes it back afterwards. Your handler never opens anything and never closes
anything.

Here is the whole thing, small enough to see at once. Create it as `app.lua`.

```lua
local akkar = require "akkar"
local db    = require "akkar.db"

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local app = akkar.new()

app:get("/tasks", function(req)
  return { tasks = req.db:many "select id, title, done from tasks order by id" }
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  return akkar.created(req.db:one(
    "insert into tasks (title) values ($1) returning id, title, done",
    req.body.title))
end)

app:run { port = 3000, db = open }
```

```sh
lua5.4 app.lua
```

```
INFO  listening url=http://127.0.0.1:3000
```

Two differences from the connection on page 5.

**There is no `pool_size = 0`.** Left out, akkar keeps a pool of ten
connections and shares them between requests. Opening a connection takes real
time, so a server that opened one per request would spend most of its life
opening connections.

**`statement_timeout = 30` is new.** It tells Postgres to give up on any single
query that runs longer than 30 seconds. Leave it out and akkar prints this at
startup:

```
WARN  db has no statement_timeout, so a request deadline does not stop the query consequence=an abandoned query keeps a backend busy after the 503 fix=db.connect { statement_timeout = <seconds> }, matching the deadline request_deadline_s=30
```

akkar can stop waiting for a slow query, but only Postgres can stop running
one. Without this setting, a query nobody is waiting for keeps working anyway.
Page 11 is about deadlines properly. For now, the line is there and the warning
is not.

### The error if you forget `db = open`

This is a complete file, and the mistake in it is that `app:run` was never told
about a database:

```lua
local akkar = require "akkar"

local app = akkar.new()

app:get("/tasks", function(req)
  return { tasks = req.db:many "select id, title, done from tasks order by id" }
end)

app:run { port = 3000 }
```

```sh
curl -i http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 500 Internal Server Error
x-request-id: e5f4904d000001
content-type: application/json
content-length: 33

{"error":"internal server error"}
```

And in the server's terminal:

```
ERROR handler raised at=app.lua:5 detail=app.lua:6: req.db is not configured; pass db = ... to app:run{} request_id=e5f4904d000001
```

The message says the fix. It is worth knowing that `req.db` behaves this way on
purpose: reading a capability that was never configured gives you a sentence,
not `attempt to index a nil value`.

## The four things you can do with `req.db`

| Call | Gives you | Use it for |
|---|---|---|
| `db:one(sql, ...)` | the first row, or `nil` | one thing, by id |
| `db:many(sql, ...)` | a list of rows | a list |
| `db:exec(sql, ...)` | a result you usually ignore | insert, update, delete |
| `db:transaction(fn)` | whatever `fn` returns | several statements, all or nothing |

A row is a plain Lua table, with one field per column: `row.id`, `row.title`,
`row.done`. There is nothing else to learn about the shape.

`db:one` returning `nil` when nothing matched is why `or akkar.not_found "..."`
appears so often. That pattern is from [page 4](04-errors.md) and it does not
change now that the data is real.

`db:exec` gives back a table with `affected_rows` in it, which is how you tell
"deleted one row" from "there was nothing to delete".

### Getting the row back after you insert it

Postgres has one feature worth knowing on day one: `returning`.

```lua no-run
req.db:one("insert into tasks (title) values ($1) returning id, title, done",
           req.body.title)
```

Without `returning` you would insert, and then have to run a second query to
find out what id the database gave the row. With it, the insert answers with
the finished row. One round trip instead of two, and no guessing.

### One thing about empty lists

An empty table in Lua becomes `{}` in JSON, not `[]`:

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":{}}
```

Lua has one kind of table, so an empty list and an empty object are the same
value, and the encoder has to pick one. It picks `{}`. Nothing is wrong, and
your own code reading `#tasks` still sees zero. Keep it in mind for the day a
frontend calls `tasks.map(...)` on it and complains, because that code is
expecting a list and `{}` is not one.

## Several statements that must all happen, or none

Say you want to add three tasks in one request. Two of them work, the third has
a blank title, and you refuse it. Without help you now have two tasks stored
from a request that failed, which is a mess nobody asked for.

`db:transaction` is the answer. Everything inside the function either happens
or does not:

```lua no-run
app:post("/tasks/bulk", { body = { titles = "table" } }, function(req)
  return req.db:transaction(function(tx)
    local created = {}
    for _, title in ipairs(req.body.titles) do
      if type(title) ~= "string" or title:match "^%s*$" then
        error(akkar.bad_request "every title must be text and not blank")
      end
      created[#created + 1] = tx:one(
        "insert into tasks (title) values ($1) returning id, title, done", title)
    end
    return akkar.created { tasks = created }
  end)
end)
```

Inside the function you use `tx`, not `req.db`. `tx` is the same connection
with the transaction open on it. Using `req.db` there would be a second
connection outside the transaction, and it would not be undone.

akkar sends `commit` when the function returns and `rollback` if it raises.
There is no way to leave a transaction open by forgetting, because there is no
line for you to forget.

### The part that will catch you

Look at the refusal again. It is `error(akkar.bad_request "...")`, not
`return akkar.bad_request "..."`.

**Returning from inside the function ends the transaction successfully.** akkar
cannot tell the difference between "here is your answer" and "here is your
refusal": both are values coming back from a function that did not fail. So it
commits, and the rows written before the refusal stay.

This is [page 4](04-errors.md)'s trick doing real work. A response thrown with
`error(...)` reaches the caller exactly as if it had been returned, and on the
way out it rolls the transaction back.

The difference is easy to see. The lists below come from a database that
already had four tasks in it, made by the steps at the bottom of this page, so
yours will show your own tasks instead. What matters is which one gains a row.

With `error(...)`:

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks/bulk \
  -H "content-type: application/json" -d '{"titles":["call the bank","   "]}'
```

```
HTTP/1.1 400 Bad Request
x-request-id: 3292fc5800000e
content-type: application/json
content-length: 50

{"error":"every title must be text and not blank"}
```

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"title":"buy milk","done":false},{"id":2,"title":"walk the dog","done":false},{"id":4,"title":"read the guide","done":false},{"id":5,"title":"water the plants","done":false}]}
```

No "call the bank". Now change that one word to `return` and send the same
request. The answer is identical:

```
HTTP/1.1 400 Bad Request
x-request-id: 0a51984b000001
content-type: application/json
content-length: 50

{"error":"every title must be text and not blank"}
```

But the list is not:

```
{"tasks":[{"id":1,"done":false,"title":"buy milk"},{"id":2,"done":false,"title":"walk the dog"},{"id":4,"done":false,"title":"read the guide"},{"id":5,"done":false,"title":"water the plants"},{"id":7,"done":false,"title":"call the bank"}]}
```

There it is, id 7, stored by a request that was answered `400 Bad Request`.
Nothing crashed and nothing looked wrong. **Inside a transaction, raise to
refuse.**

(The ids skip numbers, and that is normal. Postgres hands out the next number
even when the row is rolled back or deleted, because the alternative is making
everybody wait their turn for an id.)

## Queries that are not the same every time

Filtering and sorting are where handwritten SQL goes wrong, because the
statement now depends on what the caller asked for. That is exactly the shape
that tempts you back into gluing strings.

`akkar.sql` builds the statement from pieces instead:

```lua
local sql = require "akkar.sql"

local query = sql.select("id, title, done"):from "tasks"
query:where("done = ?", false)
query:order_by("title", { "id", "title" })
query:limit(10)

print(query:to_string())
for _, value in ipairs(query:values()) do
  print("value: " .. tostring(value))
end
```

```sh
lua5.4 builder.lua
```

```
select id, title, done from tasks where done = $1 order by title asc limit $2
value: false
value: 10
```

Look at what it produced. The `?` in your condition became `$1`, and `false`
went into the list of values. **The builder cannot put a value into the text
even if you want it to.** There is no method that takes raw SQL and no escape
hatch, because an escape hatch is where the injection goes.

Hand the query straight to `db:many`, with no `build()` step:

```lua no-run
return { tasks = req.db:many(query) }
```

### Column names are not values

`$1` works for a value. It does not work for a column name: Postgres cannot
plan `order by $1`, because the plan depends on which column it is.

So a column name coming from a caller has to be checked against a list you
wrote:

```lua no-run
query:order_by(req.query.sort, { "id", "title" })
```

That second argument is the whole allowed list. Anything else is refused:

```lua
local sql = require "akkar.sql"

local query = sql.select("id, title"):from "tasks"

local ok, why = pcall(function()
  query:order_by("password_hash", { "id", "title" })
end)

print("allowed?", ok)
print(why)
```

```
allowed?	false
akkar.sql: order column 'password_hash' is not in the allowed list (id, title)
```

(`pcall` runs a function and catches the error instead of stopping the program,
which is how the example can print the refusal rather than crash on it.)

Do the same check in the route's schema, with `one_of`, and the caller gets a
clean `422` instead of a `500`:

```lua no-run
sort = v.string { optional = true, one_of = { "id", "title" }, default = "id" }
```

```sh
curl -s -i "http://127.0.0.1:3000/tasks?sort=password_hash"
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 3292fc5800000a
content-type: application/json
content-length: 81

{"fields":{"query.sort":"must be one of: id, title"},"error":"validation failed"}
```

Both checks, for two different reasons. The schema is there to give the caller
a good answer. The allow-list is there because a schema you forget to write
should not be the only thing between a stranger and your columns.

## The whole application

Everything above in one file. This is `app.lua`.

```lua
local akkar = require "akkar"
local db    = require "akkar.db"
local sql   = require "akkar.sql"
local v     = akkar.v

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local app = akkar.new()

app:get("/tasks", {
  query = {
    done = "boolean?",
    sort = v.string { optional = true, one_of = { "id", "title" }, default = "id" },
  },
}, function(req)
  local query = sql.select("id, title, done"):from "tasks"
  if req.query.done ~= nil then
    query:where("done = ?", req.query.done)
  end
  query:order_by(req.query.sort, { "id", "title" })
  return { tasks = req.db:many(query) }
end)

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  local task = req.db:one(
    "select id, title, done from tasks where id = $1", req.params.id)
  return task or akkar.not_found "no task with that id"
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  return akkar.created(req.db:one(
    "insert into tasks (title) values ($1) returning id, title, done",
    req.body.title))
end)

app:post("/tasks/bulk", { body = { titles = "table" } }, function(req)
  return req.db:transaction(function(tx)
    local created = {}
    for _, title in ipairs(req.body.titles) do
      if type(title) ~= "string" or title:match "^%s*$" then
        error(akkar.bad_request "every title must be text and not blank")
      end
      created[#created + 1] = tx:one(
        "insert into tasks (title) values ($1) returning id, title, done", title)
    end
    return akkar.created { tasks = created }
  end)
end)

app:delete("/tasks/:id", { params = { id = "integer" } }, function(req)
  local gone = req.db:exec("delete from tasks where id = $1", req.params.id)
  if gone.affected_rows == 0 then
    return akkar.not_found "no task with that id"
  end
  return nil
end)

app:run { port = 3000, db = open }
```

Run it, and work through these in order.

**An empty list, because the table is empty:**

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":{}}
```

**Make one:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"buy milk"}'
```

```
HTTP/1.1 201 Created
x-request-id: 3292fc58000002
content-type: application/json
content-length: 40

{"id":1,"title":"buy milk","done":false}
```

**And another:**

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"walk the dog"}'
```

```
{"id":2,"title":"walk the dog","done":false}
```

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"title":"buy milk","done":false},{"id":2,"title":"walk the dog","done":false}]}
```

**Now send the attack, on purpose:**

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d "{\"title\":\"'); drop table tasks; --\"}"
```

```
{"id":3,"title":"'); drop table tasks; --","done":false}
```

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"title":"buy milk","done":false},{"id":2,"title":"walk the dog","done":false},{"id":3,"title":"'); drop table tasks; --","done":false}]}
```

It is a task. It has an id. The table is still there. That string is now the
most boring row in your database, and that is exactly what should happen to it.

**Sort by title, which goes through the allow-list:**

```sh
curl -s "http://127.0.0.1:3000/tasks?sort=title"
```

```
{"tasks":[{"id":3,"title":"'); drop table tasks; --","done":false},{"id":1,"title":"buy milk","done":false},{"id":2,"title":"walk the dog","done":false}]}
```

Sorted by text, so the title starting with an apostrophe comes first.

**Delete it, then delete it again:**

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/3
```

```
HTTP/1.1 204 No Content
x-request-id: 3292fc5800000b
content-length: 0

```

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/3
```

```
HTTP/1.1 404 Not Found
x-request-id: 3292fc5800000c
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

`affected_rows` was 1 the first time and 0 the second, which is how the handler
knows the difference.

**Several at once:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks/bulk \
  -H "content-type: application/json" \
  -d '{"titles":["read the guide","water the plants"]}'
```

```
HTTP/1.1 201 Created
x-request-id: 3292fc5800000d
content-type: application/json
content-length: 107

{"tasks":[{"id":4,"title":"read the guide","done":false},{"id":5,"title":"water the plants","done":false}]}
```

Now stop the server with `Ctrl-C` and start it again. Ask for the list once
more. **The tasks are still there.** That is the sentence this whole page was
for.

## Checkpoint

You have this if:

- posting a task and restarting the server leaves the task in place
- `'); drop table tasks; --` is stored as a title and your table survives
- `?sort=password_hash` gives `422`, not `500` and not a stack trace
- a bulk request with a blank title in it creates nothing at all

And you can say why placeholders exist in one sentence: because the value never
becomes part of the statement, so text can never turn into a command.

Right now every caller sees every task, because there is no such thing as a
user yet. That is next: [7. Accounts](07-accounts.md).
