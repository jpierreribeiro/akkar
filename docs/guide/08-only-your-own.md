# 8. Only your own tasks

By the end of this page every task will belong to one account, and no account
will be able to see or touch another one's tasks.

You need [page 7](07-accounts.md) working: you can sign up, log in, and call
`/me`.

This page starts with the bug on purpose. It is the most expensive bug in this
kind of software, it is one line long, and nobody writes it deliberately.

## First, tasks need an owner

The `tasks` table has no idea who anybody is. Adding a `user_id` column to it
is a migration, the third one:

```sql
alter table tasks add column user_id integer references accounts (id);
delete from tasks where user_id is null;
alter table tasks alter column user_id set not null
```

Three statements, and the middle one deserves a warning.

**It deletes the tasks you made before accounts existed.** Every task from
page 6 has no owner, and there is no honest way to guess one. A task belonging
to nobody can never be shown to anybody, so it is dead weight in the table.
This deletes it and then makes the column required, so no future row can be
ownerless.

That delete is also the clearest example of why [page 5](05-a-database.md) said
there is no undo. Running this migration destroys those rows. No later
migration can put them back, because nothing anywhere knows what they were.
When a migration deletes, read it twice before you run it on anything that
matters.

`references accounts (id)` is the database keeping the link honest: `user_id`
has to be the id of a real row in `accounts`. Try to store a task for account
999 and Postgres refuses it.

## Now the bug

Here is the application with tasks that have owners. It is complete and it
runs. Read the two task routes closely before running it.

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local migrate = require "akkar.migrate"
local crypto  = require "akkar.crypto"
local session = require "akkar.session"
local auth    = require "akkar.auth"
local memory  = require "akkar.cache.memory"
local v       = akkar.v

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local conn = open()
local runner = migrate.new(conn, {
  files = {
    { name = "003_tasks_belong_to_accounts.sql", sql = [[
      alter table tasks add column user_id integer references accounts (id);
      delete from tasks where user_id is null;
      alter table tasks alter column user_id set not null
    ]] },
  },
})
for _, name in ipairs(runner:apply()) do print("applied " .. name) end
conn:release()

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
}

local app = akkar.new()

app:use(auth.middleware { sessions = sessions, optional = true })

local function require_login(req, next)
  if not req.auth then
    return akkar.unauthorized "log in first"
  end
  return next(req)
end

app:post("/accounts", {
  body = {
    email    = v.string { min = 3, max = 200, match = "^[^@]+@[^@]+$" },
    password = v.string { min = 8, max = 200 },
  },
}, function(req)
  local hash = crypto.hash_password(req.body.password)
  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) " ..
    "on conflict (email) do nothing returning id, email",
    req.body.email, hash)

  if not account then
    return akkar.conflict "that email already has an account"
  end
  return akkar.created(account)
end)

app:post("/login", {
  body = { email = "string", password = "string" },
}, function(req)
  local account = req.db:one(
    "select id, email, password_hash from accounts where email = $1",
    req.body.email)

  if not account or not crypto.verify_password(req.body.password,
                                               account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end

  auth.login(req, account.id)
  return { logged_in_as = account.email }
end)

app:get("/tasks", { before = { require_login } }, function(req)
  local rows = req.db:many "select id, title, done from tasks order by id"
  return { tasks = akkar.array(rows) }
end)

app:post("/tasks", {
  before = { require_login },
  body   = { title = "string" },
}, function(req)
  local task = req.db:one(
    "insert into tasks (title, user_id) values ($1, $2) " ..
    "returning id, title, done",
    req.body.title, req.auth.user_id)
  return akkar.created(task)
end)

app:run { port = 3000, db = open, cache = memory.factory() }
```

```sh
lua5.4 app.lua
```

```
applied 003_tasks_belong_to_accounts.sql
INFO  listening url=http://127.0.0.1:3000
```

You need a second account for this. Sign one up, unless you already made one on
page 7:

```sh
curl -s -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}'
```

Then log both of them in, each into its own cookie file:

```sh
curl -s -o /dev/null -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}' -c ada.txt

curl -s -o /dev/null -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}' -c grace.txt
```

Each of them makes a task:

```sh
curl -s -X POST http://127.0.0.1:3000/tasks -b ada.txt \
  -H "content-type: application/json" -d '{"title":"buy milk"}'
```

```
{"title":"buy milk","done":false,"id":8}
```

```sh
curl -s -X POST http://127.0.0.1:3000/tasks -b grace.txt \
  -H "content-type: application/json" -d '{"title":"call the bank"}'
```

```
{"title":"call the bank","done":false,"id":9}
```

(Your ids will be different numbers. They depend on how many tasks your
database has already seen.)

Now Ada asks for her tasks:

```sh
curl -s http://127.0.0.1:3000/tasks -b ada.txt
```

```
{"tasks":[{"title":"buy milk","done":false,"id":8},{"title":"call the bank","done":false,"id":9}]}
```

**She is reading Grace's task.** And Grace can read Ada's:

```sh
curl -s http://127.0.0.1:3000/tasks -b grace.txt
```

```
{"tasks":[{"title":"buy milk","done":false,"id":8},{"title":"call the bank","done":false,"id":9}]}
```

Nothing crashed. Nothing was logged. Both requests were authenticated, both
were answered `200 OK`, and both handed one person another person's data.

Here is the line that did it:

```lua no-run
req.db:many "select id, title, done from tasks order by id"
```

And here is the line it should have been:

```lua no-run
req.db:many("select id, title, done from tasks where user_id = $1 order by id",
            req.auth.user_id)
```

Five words. That is the whole difference between a working task list and a data
breach, and the wrong version reads perfectly well. In a file with twenty
queries in it, all of which look like that, you are not going to spot the one
that is missing them. Neither is the person reviewing your code. This is how it
actually happens: not through cleverness, but through one route out of two
hundred, written in a hurry, on a Thursday.

So the fix is not "remember the filter". The fix is to make the query that
forgot it impossible to send.

## The scoped handle

`req.db:scope(column, value)` gives you back a database handle that carries a
condition with it:

```lua no-run
local mine = req.db:scope("user_id", req.auth.user_id)
```

Every query that goes through `mine` gets `user_id = <that account>` added
before it runs. Not as a reminder. The unscoped statement is never built, so
there is no moment at which it could be sent.

Reads, updates, deletes and inserts all go through it, which matters: an
unscoped write is worse than an unscoped read.

### Why it refuses raw SQL

Try to hand it a plain string and it will not take it:

```lua
local db = require "akkar.db"

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  pool_size = 0,
}

local conn = open()
local mine = conn:scope("user_id", 1)

local ok, why = pcall(function()
  return mine:many "select id, title from tasks"
end)

print("did it run?", ok)
print(why)

conn:close()
```

```
did it run?	false
db: this handle is scoped to user_id, so it takes an akkar.sql query rather than raw SQL -- a string cannot be scoped without parsing it. Use db:unscoped() if the query genuinely covers every tenant.
```

The reason is in the message. To add a condition to a statement you have to
understand the statement, and a string is just letters. Where does the `where`
go? Is there one already? Is this a `select` inside a `select`? Answering that
means writing a SQL parser inside akkar, and a SQL parser that disagrees with
Postgres about what a query means is worse than no scope at all, because it
would be wrong quietly.

So the scoped handle takes the query builder from [page 6](06-storing-and-reading.md)
and nothing else. The builder knows where its own conditions live, so adding
one is exact. There is no option to pass a string with a promise that you added
the filter yourself, because that option is where the missing filter goes.

### It wins over what the caller sent

On an insert, the scope does not just add the column. It **overrides** it:

```lua
local sql = require "akkar.sql"

-- A row that arrived from a caller, with someone else's user_id in it.
local row = { title = "buy milk", user_id = 5 }

local insert = sql.insert_into("tasks", row, { "title", "user_id" })
insert:scope("user_id", 1)

print(insert:to_string())
for _, value in ipairs(insert:values()) do
  print("value: " .. tostring(value))
end
```

```
insert into tasks (title, user_id) values ($1, $2)
value: buy milk
value: 1
```

The row said account 5. The statement stores account 1, the one holding the
session. A caller cannot write into somebody else's account by putting an id in
the body.

### The escape hatch, and why it is ugly on purpose

Some queries really do cover everybody: a nightly count, an admin report. For
those there is `req.db:unscoped()`, which hands back the plain handle.

It is a wordy name at the call site, and that is the feature.
`grep -rn ':unscoped()'` gives you the complete list of every query in your
application that crosses between accounts. A short list somebody can read beats
a rule nobody can check.

## The whole application

Every task route now goes through the scope. This is `app.lua`, complete.

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local migrate = require "akkar.migrate"
local crypto  = require "akkar.crypto"
local session = require "akkar.session"
local auth    = require "akkar.auth"
local memory  = require "akkar.cache.memory"
local sql     = require "akkar.sql"
local v       = akkar.v

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local conn = open()
local runner = migrate.new(conn, {
  files = {
    { name = "003_tasks_belong_to_accounts.sql", sql = [[
      alter table tasks add column user_id integer references accounts (id);
      delete from tasks where user_id is null;
      alter table tasks alter column user_id set not null
    ]] },
  },
})
for _, name in ipairs(runner:apply()) do print("applied " .. name) end
conn:release()

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
}

local app = akkar.new()

app:use(auth.middleware { sessions = sessions, optional = true })

local function require_login(req, next)
  if not req.auth then
    return akkar.unauthorized "log in first"
  end
  return next(req)
end

app:post("/accounts", {
  body = {
    email    = v.string { min = 3, max = 200, match = "^[^@]+@[^@]+$" },
    password = v.string { min = 8, max = 200 },
  },
}, function(req)
  local hash = crypto.hash_password(req.body.password)
  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) " ..
    "on conflict (email) do nothing returning id, email",
    req.body.email, hash)

  if not account then
    return akkar.conflict "that email already has an account"
  end
  return akkar.created(account)
end)

app:post("/login", {
  body = { email = "string", password = "string" },
}, function(req)
  local account = req.db:one(
    "select id, email, password_hash from accounts where email = $1",
    req.body.email)

  if not account or not crypto.verify_password(req.body.password,
                                               account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end

  auth.login(req, account.id)
  return { logged_in_as = account.email }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return { logged_out = true }
end)

app:get("/tasks", { before = { require_login } }, function(req)
  local mine = req.db:scope("user_id", req.auth.user_id)
  local query = sql.select("id, title, done"):from "tasks"
  query:order_by("id", { "id", "title" })
  return { tasks = akkar.array(mine:many(query)) }
end)

app:get("/tasks/:id", {
  before = { require_login },
  params = { id = "integer" },
}, function(req)
  local mine = req.db:scope("user_id", req.auth.user_id)
  local query = sql.select("id, title, done"):from "tasks"
  query:where("id = ?", req.params.id)
  local task = mine:one(query)
  return task or akkar.not_found "no task with that id"
end)

app:post("/tasks", {
  before = { require_login },
  body   = { title = "string" },
}, function(req)
  local mine = req.db:scope("user_id", req.auth.user_id)
  local insert = sql.insert_into("tasks", { title = req.body.title }, { "title" })
  insert:returning "id, title, done"
  return akkar.created(mine:one(insert))
end)

app:delete("/tasks/:id", {
  before = { require_login },
  params = { id = "integer" },
}, function(req)
  local mine = req.db:scope("user_id", req.auth.user_id)
  local delete = sql.delete_from "tasks"
  delete:where("id = ?", req.params.id)
  if mine:exec(delete).affected_rows == 0 then
    return akkar.not_found "no task with that id"
  end
  return nil
end)

app:run { port = 3000, db = open, cache = memory.factory() }
```

Notice what the four task handlers have in common. Each one starts by narrowing
the handle, and after that line there is nothing left to remember. No handler
mentions `user_id` again. The insert does not set it and the delete does not
check it, because the handle does both.

The list route still wraps its rows in `akkar.array`, for the reason
[page 6](06-storing-and-reading.md) gives, and scoping makes that reason
sharper rather than weaker: an account with no tasks yet is now an ordinary,
everyday case, and it has to answer `[]` like everybody else.

Restarting the server empties the session cache, so log both accounts in again
before trying these.

**Ada sees one task. Grace sees the other:**

```sh
curl -s http://127.0.0.1:3000/tasks -b ada.txt
```

```
{"tasks":[{"id":8,"done":false,"title":"buy milk"}]}
```

```sh
curl -s http://127.0.0.1:3000/tasks -b grace.txt
```

```
{"tasks":[{"id":9,"done":false,"title":"call the bank"}]}
```

**Ada asks for Grace's task by its id, which she can easily guess:**

```sh
curl -s -i http://127.0.0.1:3000/tasks/9 -b ada.txt
```

```
HTTP/1.1 404 Not Found
x-request-id: 959171d7000009
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

**Her own is right there:**

```sh
curl -s http://127.0.0.1:3000/tasks/8 -b ada.txt
```

```
{"id":8,"done":false,"title":"buy milk"}
```

**She tries to delete Grace's:**

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/9 -b ada.txt
```

```
HTTP/1.1 404 Not Found
x-request-id: 959171d700000b
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

```sh
curl -s http://127.0.0.1:3000/tasks -b grace.txt
```

```
{"tasks":[{"id":9,"done":false,"title":"call the bank"}]}
```

Still there. The delete matched no rows, because the scope added
`user_id = 1` and task 9 belongs to account 5.

**And a task Ada creates gets her id without the handler saying so:**

```sh
curl -s -X POST http://127.0.0.1:3000/tasks -b ada.txt \
  -H "content-type: application/json" -d '{"title":"read the guide"}'
```

```
{"id":10,"done":false,"title":"read the guide"}
```

```sh
docker exec akkar-pg psql -U postgres -d akkar -c 'select id, title, user_id from tasks order by id'
```

```
 id |     title      | user_id 
----+----------------+---------
  8 | buy milk       |       1
  9 | call the bank  |       5
 10 | read the guide |       1
(3 rows)
```

## Why `404` and not `403`

Ada asked for task 9. It exists, and it is not hers. akkar answered `404 Not
Found`, which is what "there is no such task" means, rather than `403
Forbidden`, which means "that exists and you may not have it".

`403` is honest and it leaks. It confirms the task exists, and doing that for
ids 1 to 1000 tells a stranger exactly how many tasks your service holds and
which ids are real. For a thing somebody has no right to see, `404` is the
better answer, because it is the answer they would get if it truly did not
exist.

Use `403` when the caller already knows the thing exists and the refusal is the
point: a member trying to change a setting only an owner may change.

Notice that neither handler chose this. The scope removed the row, `mine:one`
gave back `nil`, and the ordinary "not found" path from
[page 4](04-errors.md) did the rest.

## What you have now

A task list where:

- a person signs up, logs in, and logs out
- passwords are stored as PBKDF2 hashes and never as text
- a session can be revoked on the server
- every task belongs to one account
- reading, writing and deleting another account's task is not a mistake you can
  make in a handler, because the handle refuses to build the query

## Checkpoint

You have this if:

- two accounts each see only their own tasks
- asking for another account's task by id returns `404`
- deleting another account's task returns `404` and leaves the task alone
- a new task gets its owner without any handler mentioning `user_id`

And you can say why `scope` refuses a raw SQL string in one sentence: because
adding a condition to a string means parsing SQL, and a parser that disagrees
with Postgres would be wrong silently, so the builder is the only way in.

Next in the guide: talking to all of this from a page in a browser.
