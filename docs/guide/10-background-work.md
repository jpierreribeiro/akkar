# 10. Background work

By the end of this page, signing up will put a "send the welcome email" job in
a queue and answer the caller straight away. A second program will pick the job
up and do the slow part on its own time.

## Why not just send it in the handler

Say you add the email to `POST /signup`, right after the row is inserted.
Sending an email means calling somebody else's server over the internet, so the
handler now looks like this:

1. write the account row, a millisecond
2. call the email provider, **anything from 200 milliseconds to a timeout**
3. answer the browser

Step 2 is not yours. It is a network call to a company you do not control, and
it decides how long your signup takes. Three things go wrong, and all three are
ordinary:

**The person waits for something they do not care about.** They pressed a
button to make an account. They are now watching a spinner while a mail server
somewhere thinks about it.

**A slow provider becomes a failed signup.** Every request has a deadline. When
the provider takes longer than that, akkar answers `503` and the caller sees an
error, even though the account was created perfectly. Now you have an account
whose owner believes signup failed, and who will press the button again.

**A broken provider becomes a broken signup.** If the email call raises, the
handler raises, and the caller gets a `500` for a thing that worked.

The fix is to separate the two. **The request does the part the caller is
waiting for. Everything else goes in a queue.**

## A queue needs somewhere to live

The job has to survive between "the request put it there" and "something else
picked it up", and those are two different processes. A Lua variable cannot do
that. akkar keeps job queues in Redis.

If Redis is not running yet, one command starts it. This is the same shape as
the Postgres command from page 5:

```sh
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine
```

It prints a long hexadecimal id and returns. That id is the container's, and
you will not need it. `docker ps` should now list `akkar-redis`.

## The column that makes a job safe to repeat

Before the code, one small schema change. The reason for it is in the
at-least-once section further down, and it will make more sense there, but it
is easier to apply it now than to stop halfway.

Create `migrations/004_welcome_email_sent.sql`:

```sql
alter table accounts add column welcome_email_sent_at timestamptz
```

Apply it the same way you applied the first three on page 5. It should report
one file applied. Run it a second time and it should report none, which is the
whole idea of a migration ledger.

## Putting a job in the queue

Two changes to `app.lua`. First, near the top, build the queue:

```lua no-run
local redis = require "akkar.redis"
local jobs  = require "akkar.jobs.redis"

local queue = jobs.new(redis.connect { port = 6379 }(), "email")
```

`"email"` is the queue's name. Jobs pushed under one name are only taken by
workers reading that name, so a slow email queue cannot hold up a fast one.

Note the extra `()` after `redis.connect { ... }`. `redis.connect` hands back a
function that opens connections, and the queue wants one connection rather than
the function.

Leave the `()` out and nothing complains at first. The queue is built, the
server starts, and the mistake only surfaces on the first push:

```
lua5.4: ./akkar/jobs/redis.lua:24: attempt to call a nil value (method 'command')
```

That message names a file inside akkar and not the line in your code, so it
reads like a bug in the framework. It is not. It is the missing `()`, and it is
worth recognising once so that it costs you a minute rather than an evening.

Second, inside the `/signup` handler, after the insert and before the answer:

```lua no-run
queue:push("welcome_email",
           { account_id = account.id, email = req.body.email },
           { id = "welcome:" .. account.id })
```

Three arguments, and each is worth a sentence.

**`"welcome_email"`** is the kind of job. The worker looks the kind up in a
table of handlers, so one worker can serve many kinds.

**The second argument is the payload**, and it is stored as JSON. Put in it
what the handler needs and nothing else. Do not put a database row in it: by
the time the job runs, the row may have changed, and an id that is looked up
fresh is always right.

**`id` is a promise not to queue this twice.** The store refuses a second push
with the same id, and `push` returns `false, "duplicate"` instead. Two clicks
on the signup button therefore queue one email, not two. Notice this only
protects the *pushing* side. It does not stop a job that was pushed once from
*running* twice, which is what the next-but-one section is about.

## Taking a job out of the queue

The worker is a separate program. Put this in `worker.lua`, next to `app.lua`:

```lua server
local cqueues = require "cqueues"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local logging = require "akkar.log"

local log = logging.new()

local connect = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
}

local queue = jobs.new(redis.connect { port = 6379 }(), "email")

local handlers = {
  welcome_email = function(payload)
    local conn = connect()
    local first = conn:one([[
      update accounts
         set welcome_email_sent_at = now()
       where id = $1
         and welcome_email_sent_at is null
      returning id ]], payload.account_id)
    conn:release()

    if not first then
      log:info("this welcome email was already sent, doing nothing",
               { account_id = payload.account_id })
      return
    end

    cqueues.sleep(3)
    log:info("welcome email sent", { to = payload.email })
  end,
}

log:info("worker waiting for jobs")
queue:consume(handlers, { log = log, timeout = 1 })
```

`cqueues.sleep(3)` stands in for the real email provider. Replace it with the
call to whatever service you use. It is three seconds so that the point of this
page is visible in the output below.

`queue:consume` is a loop that does not end. It waits for a job, calls the
handler whose name matches the job's kind, and waits again. Like the server, it
keeps running until you stop it with `Ctrl-C`.

## Watching it work

You now have three things to run. Give each one a terminal:

```sh
lua5.4 app.lua
```

```sh
lua5.4 worker.lua
```

```
INFO  worker waiting for jobs
```

And a terminal for `curl`:

```sh
time curl -s -i -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"turing@example.com","password":"correct horse battery"}'
```

```
HTTP/1.1 201 Created
access-control-allow-origin: http://127.0.0.1:5173
set-cookie: akkar_session=1395e2e93c7d10f7351ec03b243e02aa67df927fc028066b0d653e5de6db4585.eefb438389bed5ff916cb23702fb04c56930fc63ff75858838bfcf8e2e1e92d0; Path=/; Max-Age=1209600; HttpOnly; SameSite=Lax
access-control-allow-credentials: true
x-request-id: bda1226e000001
content-type: application/json
content-length: 37

{"email":"turing@example.com","id":9}

real	0m0,759s
```

Under a second, and most of that second is hashing the password, not the email.

Look at the worker's terminal:

```
INFO  worker waiting for jobs
INFO  welcome email sent to=turing@example.com
```

That line appeared about three seconds after the `curl` finished. **The caller
never waited for it.** That is the whole feature.

## If nobody is listening, the job waits

Stop the worker with `Ctrl-C` and sign somebody else up. The signup still
answers `201`. The job sits in Redis until a worker comes back, which may be
after your next deploy.

That is the right behaviour, and it is worth knowing rather than discovering: a
queue with no worker looks exactly like a queue that is working, from the
caller's side. If welcome emails stop arriving, check that the worker process
is running before you look at anything else.

## At least once, which means a job may run twice

This is the part to read slowly, because it decides what you are allowed to put
in a handler.

akkar's queue promises **at-least-once** delivery when the store supports it,
and Redis does. Here is what that means in practice.

When a worker takes a job, the job is not deleted. It moves to a "being worked
on" list, and it is only removed once the handler has finished. If the worker
is killed halfway through, the job is still there, and it can be put back and
run again.

The alternative would be to delete the job the moment it is handed out. Then a
worker that dies loses the job silently and forever, and nobody finds out.

**So the trade is deliberate: a job that runs twice is better than a job that
vanishes.** One is visible and fixable. The other is invisible.

The price of that choice is on you. **Write every handler so that running it
twice does no harm.**

## Making the handler safe to run twice

Look again at the first thing the handler does:

```lua no-run
local first = conn:one([[
  update accounts
     set welcome_email_sent_at = now()
   where id = $1
     and welcome_email_sent_at is null
  returning id ]], payload.account_id)

if not first then
  return
end
```

The `update` sets the column **only if it is still empty**, and `returning id`
tells us whether it changed anything. So:

- the first run finds an empty column, claims it, and sends the email;
- any later run finds a time already in it, changes no rows, gets `nil` back,
  and does nothing.

The database decides, in one statement, which run is the first. That is what
makes it safe: two workers running the same job at the same instant cannot both
win, because a single `update` is atomic.

You can watch it happen. Stop the worker. Sign somebody up, which queues one
job. Then queue the same job a second time by hand, with this in `twice.lua`:

```lua
local redis = require "akkar.redis"
local jobs  = require "akkar.jobs.redis"

local queue = jobs.new(redis.connect { port = 6379 }(), "email")

queue:push("welcome_email", { account_id = 10, email = "babbage@example.com" })

print("jobs waiting: " .. queue:depth())
```

Use the id and email your signup actually returned.

```sh
lua5.4 twice.lua
```

```
jobs waiting: 2
```

Now start the worker again:

```sh
lua5.4 worker.lua
```

```
INFO  worker waiting for jobs
INFO  welcome email sent to=babbage@example.com
INFO  this welcome email was already sent, doing nothing account_id=10
```

Two jobs, one email. That is what "safe to run twice" looks like, and it is
five lines of SQL rather than a framework feature.

**The general shape.** Before doing the thing that cannot be undone, claim it
in the database in a way that only one attempt can win. A column like this one,
a unique index on a "we already did this" table, or an idempotency key that the
outside service itself understands. Which one depends on what you are calling.

## Two more things the queue offers

You do not need these yet. They are here so you know where to look.

**Retries.** A handler that raises is dropped by default. Ask for retries and a
failed job is put back later, waiting longer each time:

```lua no-run
local queue = jobs.new(redis.connect { port = 6379 }(), "email", {
  retries = 3,
  backoff = { base = 2, max = 300 },
  dead_letter = true,
})
```

Retries are off unless you ask, on purpose. A retry policy nobody chose repeats
whatever the handler already did, and only you know whether that is safe.

**Dead letters.** With `dead_letter = true`, a job that has used up its retries
is kept in a separate list instead of disappearing. `queue:dead_depth()` counts
them. A number that is growing is a thing to look at.

## The whole application

`app.lua`:

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local memory  = require "akkar.cache.memory"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"

local app = akkar.new()

local queue = jobs.new(redis.connect { port = 6379 }(), "email")

app:use(akkar.cors {
  origin = "http://127.0.0.1:5173",
  credentials = true,
})

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
  secure = false,
}

app:use(auth.middleware { sessions = sessions, optional = true })

local function signed_in(req)
  if not req.auth then
    error(akkar.unauthorized "please log in")
  end
  return req.auth.user_id
end

app:post("/signup", { body = { email = "string", password = "string" } },
function(req)
  local taken = req.db:one("select id from accounts where email = $1",
                           req.body.email)
  if taken then
    return akkar.conflict "that email already has an account"
  end

  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) returning id",
    req.body.email, crypto.hash_password(req.body.password))

  queue:push("welcome_email",
             { account_id = account.id, email = req.body.email },
             { id = "welcome:" .. account.id })

  auth.login(req, account.id)
  return akkar.created { id = account.id, email = req.body.email }
end)

app:post("/login", { body = { email = "string", password = "string" } },
function(req)
  local account = req.db:one(
    "select id, password_hash from accounts where email = $1", req.body.email)
  if not account
     or not crypto.verify_password(req.body.password, account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end
  auth.login(req, account.id)
  return { id = account.id, email = req.body.email }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return akkar.no_content()
end)

app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  local rows = mine:many(sql.select("id, title, done"):from "tasks")
  return { tasks = akkar.array(rows) }
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  return akkar.created(mine:one(
    sql.insert_into("tasks", { title = req.body.title }, { "title" })
       :returning "id, title, done"))
end)

app:run {
  port = 3000,
  db = db.connect {
    host = "127.0.0.1", port = 55432, database = "akkar",
    user = "postgres", password = "akkar",
  },
  cache = memory.new(),
}
```

`worker.lua` is the file from earlier on this page, unchanged.

## Checkpoint

You have this if:

- signup answers in well under a second while the worker takes three
- stopping the worker does not stop signup from working
- you can say why a job may run twice, and point at the line in your handler
  that makes that harmless
- `queue:depth()` counts what is waiting

Next in the guide: what your server does when things go wrong at scale.
