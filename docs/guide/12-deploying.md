# 12. Putting it on the internet

By the end of this page your task list will be a 6.58 MB container image that
runs its own migrations when it starts, reads every secret from the
environment, and stops cleanly when the host asks it to.

This is the last page of the beginner track. It is longer than the others
because deploying is where five separate things have to be right at once.

## What a deploy is here

`akkar build` reads your application, works out every Lua module and every
native module it needs, and links the whole lot into **one executable**. Not a
folder of files. One file.

That file needs no Lua on the target machine, no LuaRocks, no OpenSSL and no
matching C library. So the image it ships in can be `scratch`, which means an
image containing nothing at all.

You will not run `akkar build` by hand. The `Dockerfile` in the akkar
repository runs it for you, and getting its twenty arguments right is exactly
the work you do not want to repeat.

## Two files you already have

You have been working inside the akkar folder since page 0, so both of these
are already next to your `app.lua`.

**`Dockerfile`** builds the image. It has two useful targets:

| target | contains | size |
|---|---|---|
| default | your binary and a CA bundle | 6.58 MB for this application |
| `slim` | the same binary, plus busybox | about 8 MB more |

Sizes move a little with what your application pulls in. `docs/DEPLOY.md`
measured 6.4 MB for a smaller example and 14.5 MB for its `slim` build.

The default has no shell in it. That is a feature most days and a trap on one
specific day, which has its own section below.

**`railway.json`** describes the deploy to Railway. Other hosts use their own
file, and the three settings in it apply everywhere:

```json
{
  "$schema": "https://railway.com/railway.schema.json",
  "build":  { "builder": "DOCKERFILE", "dockerfilePath": "Dockerfile" },
  "deploy": {
    "healthcheckPath": "/health/ready",
    "healthcheckTimeout": 30,
    "restartPolicyType": "ON_FAILURE",
    "restartPolicyMaxRetries": 10,
    "drainingSeconds": 15,
    "overlapSeconds": 15
  }
}
```

`healthcheckPath` is `/health/ready` and not `/health/live`, for the reason
page 11 spent a section on. The host is asking "may I send this new deployment
traffic yet?", which is a readiness question. Pointing it at liveness would
route real users to an instance whose database connection is not open.

`drainingSeconds` is the one nobody guesses. Railway sends `SIGTERM` and, by
default, gives the process **zero seconds** before killing it. Your
`shutdown_grace = 10` is worth nothing against a zero-second budget, so the
host has to be told to wait. The two numbers are a pair, and the host's must be
the larger one.

## Nothing that is a secret goes in the file

Up to now `app.lua` has had a database password written into it, and a session
secret with a fallback. Neither survives a deploy.

- A password in a file is a password in your git history, forever, including
  after you change it.
- A session secret that changes on restart logs everybody out on every deploy.
- The frontend origin is different in production, and it is not a secret but
  it is still configuration.

All of it moves to the environment, and the app reads it at startup:

```lua no-run
local function required(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    error("this app needs the environment variable " .. name ..
          " and it is not set", 0)
  end
  return value
end
```

**Note what it does not do: there is no default.** A missing secret stops the
process immediately, with the name of what is missing:

```
lua5.4: this app needs the environment variable SESSION_SECRET and it is not set
```

That is a better morning than a server that starts, serves for six hours, and
then hands somebody a session signed with an empty key.

Read them all at the very top, before the app opens anything:

```lua no-run
local SESSION_SECRET  = required "SESSION_SECRET"
local FRONTEND_ORIGIN = required "FRONTEND_ORIGIN"

local settings = {
  host     = required "PGHOST",
  port     = tonumber(os.getenv "PGPORT") or 5432,
  database = required "PGDATABASE",
  user     = required "PGUSER",
  password = required "PGPASSWORD",
}
```

The `PG*` names are not invented. They are the ones Postgres tools have used
for decades, and they are what a managed database on Railway, Render or Fly
gives you when you attach one.

`PGPORT` has a default because 5432 is the standard and it is not a secret.
Nothing else does.

**Generate the session secret once and keep it.** Any 32 random bytes will do:

```sh
lua5.4 -e 'print(require("akkar.crypto").token(32))'
```

Set it as an environment variable on your host, in whatever "variables" or
"secrets" screen it gives you. Do not put it in the repository.

## The host chooses the port, and the host is not localhost

Two lines in `app:run` change, and both are the difference between a deploy
that answers and a deploy that does not:

```lua no-run
app:run {
  host = os.getenv "HOST" or "0.0.0.0",
  port = tonumber(os.getenv "PORT") or 8080,
  timeout = 5,
  shutdown_grace = 10,
  db = connect,
  cache = redis.connect {
    host = os.getenv "REDIS_HOST" or "127.0.0.1",
    port = tonumber(os.getenv "REDIS_PORT") or 6379,
  },
}
```

**`0.0.0.0`, not `127.0.0.1`.** akkar defaults to `127.0.0.1`, which is right
on a laptop and invisible inside a container. The proxy in front of your
container connects from outside the container's own loopback, so a server bound
to loopback accepts nothing and the platform reports that your application
failed to respond. Everything else about the deploy can be perfect and this one
word still breaks it.

**`PORT` comes from the host.** Read it rather than hard-coding a number.
8080 happens to be both akkar's default and what several hosts inject, which is
exactly why hard-coding it is dangerous: it works until the day it does not.

## Migrations, and the trap that has a written history

Your database on the other end starts empty. Something has to create the
tables, and it has to happen on every deploy, before the new code serves a
request.

The obvious approach is to ship the `migrations/` folder and let
`akkar.migrate` read it. **From this image, that does not work.** Somebody hit
it before you and wrote it down in `docs/DEPLOY.md`, with the directory
mounted and readable:

```
akkar.migrate: could not list /migrations:
find "/migrations" -maxdepth 1 -type f -name '*.sql': No such file or directory
```

Read that carefully. It says "No such file or directory" about a directory that
was there the whole time. The missing file is not `/migrations`. It is
**`/bin/sh`**.

`akkar.migrate` lists a directory by running `find`, because Lua has no way to
list a directory and adding a C library to do it would cost more than it saves.
Running `find` needs a shell. This image has no shell. Prove it on your own
machine once the image is built:

```sh
docker exec tasklist-api /bin/sh -c 'echo hi'
```

```
OCI runtime exec failed: exec failed: unable to start container process: exec: "/bin/sh": stat /bin/sh: no such file or directory: unknown
```

So the migrations travel as **data** instead of as files. `migrate.new` takes a
list of `{ name, sql }` pairs, and that list is embedded in the binary along
with everything else:

```lua no-run
local MIGRATIONS = {
  { name = "001_create_tasks.sql", sql = [[
    create table tasks (
      id    serial primary key,
      title text    not null,
      done  boolean not null default false
    ) ]] },

  { name = "002_create_accounts.sql", sql = [[
    create table accounts (
      id            serial primary key,
      email         text not null unique,
      password_hash text not null
    ) ]] },

  { name = "003_tasks_belong_to_accounts.sql", sql = [[
    alter table tasks add column user_id integer references accounts (id);
    delete from tasks where user_id is null;
    alter table tasks alter column user_id set not null ]] },

  { name = "004_welcome_email_sent.sql", sql = [[
    alter table accounts add column welcome_email_sent_at timestamptz ]] },
}
```

Then run them at startup, before `app:run`:

```lua no-run
do
  local one_off = {}
  for key, value in pairs(settings) do one_off[key] = value end
  one_off.pool_size = 0

  local connection = db.connect(one_off)()
  local runner = migrate.new(connection, { files = MIGRATIONS })
  local applied = runner:apply()
  log:info("migrations applied", { count = #applied })
  for _, name in ipairs(applied) do log:info("migrated", { file = name }) end
  connection:close()
end
```

Three details in that block, and each one is a thing that went wrong for
somebody before it was written down.

**`pool_size = 0`** gives a connection that is not from the pool. The runner
takes a database-wide lock so that two instances starting at once cannot both
migrate, and that lock belongs to a session. A pooled connection that goes back
mid-run takes the lock with it.

**No `statement_timeout` on that connection.** `settings` has not been given
one yet at this point in the file, deliberately. A migration is allowed to take
minutes; the five-second timeout from page 11 would cancel it halfway.

**It is safe to run on every boot.** The runner keeps a ledger table of what
has been applied and skips those. Ten instances starting together apply the
migrations once, because the other nine wait at the lock and then find nothing
to do.

There is one honest cost. This list has to stay in step with your `migrations/`
folder by hand, and a hand-copied list is a list that drifts. Keep the `.sql`
files as the thing you edit, and treat this as the mechanism rather than the
daily habit.

If you would rather keep the folder, `docs/DEPLOY.md` describes the other way:
build the same binary into the `slim` target, which does have a shell, and run
migrations from that image before the `scratch` one serves.

## Building it

```sh
docker build --build-arg APP=app.lua -t mytasks .
```

The first build takes about three minutes, most of it compiling C libraries.
Later builds after editing `app.lua` take about fifteen seconds, because
everything above your file is cached.

Near the end you will see what the build actually did:

```
akkar build: 141 Lua modules, 47 native modules -> /build/akkar-app
```

```
akkar dev-1
static, and it starts
```

Those last two lines are the build testing its own output before shipping it. A
binary that cannot start should fail here, not in your host's restart loop.

```sh
docker images mytasks --format '{{.Repository}}:{{.Tag}} {{.Size}}'
```

```
mytasks:latest 6.58MB
```

Six and a half megabytes, containing your application, a Lua interpreter, an
HTTP server, a Postgres driver and OpenSSL.

## Running it

Against your local Postgres and Redis, so you can see it work before a host is
involved. `--network host` lets the container reach `127.0.0.1` services on
your machine; on a real deploy the host names are real.

```sh
docker run -d --name tasklist-api --network host \
  -e PORT=3003 -e HOST=0.0.0.0 \
  -e PGHOST=127.0.0.1 -e PGPORT=55432 -e PGDATABASE=tasklist_deploy \
  -e PGUSER=postgres -e PGPASSWORD=akkar \
  -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
  -e SESSION_SECRET=this-is-thirty-two-bytes-long-ok \
  -e FRONTEND_ORIGIN=http://127.0.0.1:5173 \
  -e INSECURE_COOKIES=1 \
  mytasks
```

`tasklist_deploy` is a new, empty database, with nothing in it at all.
Create it first with `createdb tasklist_deploy`, or with whatever your Postgres
container gives you.

`INSECURE_COOKIES=1` is only for this local test. Session cookies are marked
`Secure` by default, which means the browser will not send them over plain
`http`. In production you have HTTPS and you leave this unset.

```sh
docker logs tasklist-api
```

```
INFO  migrations applied count=4
INFO  migrated file=001_create_tasks.sql
INFO  migrated file=002_create_accounts.sql
INFO  migrated file=003_tasks_belong_to_accounts.sql
INFO  migrated file=004_welcome_email_sent.sql
INFO  listening url=http://0.0.0.0:3003
```

An empty database, migrated by the container itself, on its first boot.

```sh
curl -s http://127.0.0.1:3003/health/ready
```

```
{"cached":false,"status":"pass","uptime":3.8247107550051,"checks":{"db":{"status":"pass","took_ms":1}}}
```

```sh
curl -s -X POST http://127.0.0.1:3003/signup \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}'
```

```
{"id":1,"email":"ada@example.com"}
```

Restart the container and the log tells you it had nothing to do:

```
INFO  migrations applied count=0
INFO  listening url=http://0.0.0.0:3003
```

## The worker is a second image

The `Dockerfile` builds one entry file into one binary, so the worker gets its
own build of the same repository:

```sh
docker build --build-arg APP=worker.lua -t mytasks-worker .
```

It is fast, because everything except the last two layers is already cached.

`worker.lua` needs the same treatment as `app.lua`: read the database settings
from the environment rather than from the file.

```sh
docker run -d --name tasklist-worker --network host \
  -e PGHOST=127.0.0.1 -e PGPORT=55432 -e PGDATABASE=tasklist_deploy \
  -e PGUSER=postgres -e PGPASSWORD=akkar \
  -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
  mytasks-worker
```

Sign somebody up through the API container, then read the worker's log:

```sh
curl -s -X POST http://127.0.0.1:3003/signup \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}'
```

```
{"id":2,"email":"grace@example.com"}
```

```sh
docker logs tasklist-worker
```

```
INFO  worker waiting for jobs
INFO  welcome email sent to=ada@example.com
INFO  welcome email sent to=grace@example.com
```

Two emails, and only one signup happened just now. The other is ada's, queued
before there was any worker to take it, and waiting in Redis the whole time.
That is page 10's "if nobody is listening, the job waits", seen from the other
side.

Two containers, one Redis between them, and neither knows the other exists.

## Stopping without dropping requests

A deploy replaces your container. The host sends `SIGTERM` and expects the
process to finish what it is doing and exit.

akkar does not install a signal handler on its own, because a library that
takes over signals behind your application's back fights with whatever else the
process is doing. In a container it is one line and it is not optional:

```lua no-run
app:handle_signals()
```

Watch it:

```sh
docker stop tasklist-api
```

```
INFO  listening url=http://0.0.0.0:3003
INFO  signal received
INFO  shutdown: no longer accepting connections
INFO  shutdown: stopped cleanly
```

Three lines, in order: the signal arrived, the socket stopped accepting new
connections, and the requests already in flight were allowed to finish.

Without `app:handle_signals()` there is no handler, the default action applies,
and every request in flight is cut off mid-answer. Nobody notices in testing,
because a deploy with no traffic on it drops nothing.

## Putting it on a real host

The local run above is the whole deploy. A host adds three things: it builds
the image for you, it gives you a database and a Redis, and it puts a
certificate and a domain in front.

On Railway, which is what `docs/DEPLOY.md` was written and tested against:

```sh
railway login
railway link
railway up
```

There is no start command to configure. The image has an `ENTRYPOINT`.

Attach a Postgres and a Redis from the host's own menu, set `SESSION_SECRET`
and `FRONTEND_ORIGIN` as service variables, and deploy. `docs/DEPLOY.md` has
the measured details, including which of its claims were run and which were
only read.

TLS is the host's job here. Your app speaks plain HTTP inside the container and
the platform terminates HTTPS at its edge. That is why `Secure` cookies work in
production even though your container never sees a certificate.

## The whole application

`app.lua`. It is longer than page 11's, and every extra line is one of the five
things on this page.

It is the one file in this guide the documentation's own test suite does not
execute, and the reason is the point of the file: it refuses to start without
its environment, and the suite has none to give it. It was verified the way
this page describes instead, by being built into the image above and run
against a real Postgres and a real Redis, which is a better test than the
runner could have given it.

```lua no-run
local akkar   = require "akkar"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local health  = require "akkar.health"
local migrate = require "akkar.migrate"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"
local logging = require "akkar.log"

local log = logging.new()

local function required(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    error("this app needs the environment variable " .. name ..
          " and it is not set", 0)
  end
  return value
end

local MIGRATIONS = {
  { name = "001_create_tasks.sql", sql = [[
    create table tasks (
      id    serial primary key,
      title text    not null,
      done  boolean not null default false
    ) ]] },

  { name = "002_create_accounts.sql", sql = [[
    create table accounts (
      id            serial primary key,
      email         text not null unique,
      password_hash text not null
    ) ]] },

  { name = "003_tasks_belong_to_accounts.sql", sql = [[
    alter table tasks add column user_id integer references accounts (id);
    delete from tasks where user_id is null;
    alter table tasks alter column user_id set not null ]] },

  { name = "004_welcome_email_sent.sql", sql = [[
    alter table accounts add column welcome_email_sent_at timestamptz ]] },
}

local SESSION_SECRET  = required "SESSION_SECRET"
local FRONTEND_ORIGIN = required "FRONTEND_ORIGIN"

local settings = {
  host     = required "PGHOST",
  port     = tonumber(os.getenv "PGPORT") or 5432,
  database = required "PGDATABASE",
  user     = required "PGUSER",
  password = required "PGPASSWORD",
}

do
  local one_off = {}
  for key, value in pairs(settings) do one_off[key] = value end
  one_off.pool_size = 0

  local connection = db.connect(one_off)()
  local runner = migrate.new(connection, { files = MIGRATIONS })
  local applied = runner:apply()
  log:info("migrations applied", { count = #applied })
  for _, name in ipairs(applied) do log:info("migrated", { file = name }) end
  connection:close()
end

settings.statement_timeout = 5
local connect = db.connect(settings)

local app = akkar.new()

local queue = jobs.new(redis.connect {
  host = os.getenv "REDIS_HOST" or "127.0.0.1",
  port = tonumber(os.getenv "REDIS_PORT") or 6379,
}(), "email")

local probe = health.new {
  checks = {
    db = function()
      local conn = connect()
      local answer = conn:one "select 1 as ok"
      conn:release()
      return answer ~= nil
    end,
  },
  timeout = 2,
  cache   = 5,
}

app:get("/health/live", function()
  return probe:live()
end)

app:get("/health/ready", function()
  local result = probe:ready()
  if result.status == "fail" then
    error(akkar.unavailable(result))
  end
  return result
end)

app:use(akkar.cors {
  origin = FRONTEND_ORIGIN,
  credentials = true,
})

local limiter = akkar.limit.rate { per_second = 5, burst = 10 }

app:use(function(req, next)
  if req.path:find("/health/", 1, true) == 1 then
    return next(req)
  end
  return limiter(req, next)
end)

local sessions = session.new {
  secret = SESSION_SECRET,
  secure = os.getenv "INSECURE_COOKIES" ~= "1",
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

app:handle_signals()

app:run {
  host = os.getenv "HOST" or "0.0.0.0",
  port = tonumber(os.getenv "PORT") or 8080,
  timeout = 5,
  shutdown_grace = 10,
  db = connect,
  cache = redis.connect {
    host = os.getenv "REDIS_HOST" or "127.0.0.1",
    port = tonumber(os.getenv "REDIS_PORT") or 6379,
  },
}
```

And `worker.lua`, with the same environment treatment:

```lua no-run
local cqueues = require "cqueues"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local logging = require "akkar.log"

local log = logging.new()

local function required(name)
  local value = os.getenv(name)
  if value == nil or value == "" then
    error("this worker needs the environment variable " .. name ..
          " and it is not set", 0)
  end
  return value
end

local connect = db.connect {
  host     = required "PGHOST",
  port     = tonumber(os.getenv "PGPORT") or 5432,
  database = required "PGDATABASE",
  user     = required "PGUSER",
  password = required "PGPASSWORD",
}

local queue = jobs.new(redis.connect {
  host = os.getenv "REDIS_HOST" or "127.0.0.1",
  port = tonumber(os.getenv "REDIS_PORT") or 6379,
}(), "email")

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

## Checkpoint

You have this if:

- `docker build` produces an image of about six and a half megabytes
- `docker logs` shows four migrations applied on the first run and none on the
  second
- the container answers `/health/ready` and accepts a signup
- `docker stop` prints `shutdown: stopped cleanly`
- there is no password, no session secret and no frontend origin left anywhere
  in your source

## That is the beginner track

Twelve pages ago you had not written a backend. You now have one with a
database, accounts that own their own rows, a frontend that logs in from
another origin, work that happens after the response, limits that keep it
answering under load, and a deploy that carries its own schema.

Where to go next:

- **The recipes** answer one task each: uploading a file, paginating, calling
  another API, accepting a webhook, sending real email.
- **The reference** documents every module and every function.
- **The explanation pages** argue the decisions: why handlers return instead of
  writing, why sessions and not JWTs, why one process per core.
- **`docs/DEPLOY.md`** is the measured version of this page, including what was
  verified and what was only read.
