# 11. Making it not fall over

By the end of this page your server will refuse work it cannot do instead of
accepting it and getting slower, and it will be able to tell a host the
difference between "restart me" and "do not send me traffic yet".

Three ideas, one screen each. They are independent, so read them in any order.

## 1. Deadlines, and the half you do not control

Every request akkar handles has a deadline. It is 30 seconds by default, and
you saw it on page 4: a handler that takes too long gets `503` and the caller
gets an answer instead of a hung connection.

Here is the part page 4 did not say. **The deadline stops akkar waiting. It does
not stop Postgres working.**

When the deadline fires, akkar gives up on the handler and answers. The query
that handler was running is still running, on a database connection, inside
Postgres. Postgres only notices that nobody is listening the next time it tries
to write something back, and a query that produces no output until it finishes
may not try for minutes.

So under load, a timeout can leave your database **busier** than no timeout at
all. Requests give up, callers retry, each retry starts another query, and the
abandoned ones are still going.

akkar tells you about this at startup. You have probably been seeing it since
page 5:

```
WARN  db has no statement_timeout, so a request deadline does not stop the query consequence=an abandoned query keeps a backend busy after the 503 fix=db.connect { statement_timeout = <seconds> }, matching the deadline request_deadline_s=30
```

Read it as three parts: what is missing, what goes wrong because of it, and the
exact line that fixes it.

The fix is to give Postgres its own deadline, and to make the two numbers
agree:

```lua no-run
local connect = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}
```

```lua no-run
app:run {
  port = 3000,
  timeout = 5,
  db = connect,
}
```

Now both sides give up at the same moment. akkar stops waiting, and Postgres
cancels the query rather than finishing work nobody will read.

Restart, and the warning is gone.

Why five and not thirty? Because a number you never think about is a number
that is wrong. Pick the slowest thing a request of yours legitimately does,
add some room, and use that. Five seconds is generous for a task list.

One warning about the migration runner: hand it a connection with **no**
`statement_timeout`. A long migration is supposed to take a long time, and the
setting would cancel it in the middle. Page 12 opens a separate connection for
exactly this reason.

## 2. Rate limits, or refusing fast instead of accepting slowly

A server past its capacity does not get faster by accepting more work. It gets
slower at the work it already took. akkar's own measurements are blunt about
this: doubling the number of clients against a fixed database pool changed
throughput by almost nothing and made the slowest one percent of requests
sixty times slower.

So the honest answer to more load than you can serve is to say no immediately.

```lua no-run
local limiter = akkar.limit.rate { per_second = 5, burst = 10 }
```

Two numbers, and they are a pair. Think of a bucket holding `burst` tokens.
Every request takes one. The bucket refills at `per_second` tokens a second.
So a caller may make a short run of 10 requests, and after that gets 5 a second
for as long as they like.

Install it as middleware and it applies to everything:

```lua no-run
app:use(limiter)
```

Send eleven requests quickly and the eleventh is refused:

```sh
curl -s -i http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 429 Too Many Requests
access-control-allow-credentials: true
access-control-allow-origin: http://127.0.0.1:5173
ratelimit-reset: 2
ratelimit-limit: 10
retry-after: 1
ratelimit-remaining: 0
x-request-id: 35e8f1a2000026
content-type: application/json
content-length: 45

{"error":"too many requests","retry_after":1}
```

`429` means "too many requests". The four headers are not decoration:

| header | means |
|---|---|
| `ratelimit-limit` | the size of the bucket |
| `ratelimit-remaining` | tokens left after this request |
| `ratelimit-reset` | seconds until the bucket is full again |
| `retry-after` | wait this long before trying again |

They are sent on successful requests too, so a well-behaved client can slow
itself down before it is refused. A limit a client cannot see is a limit it can
only discover by tripping over.

**Who gets counted.** By default the bucket is per logged-in user, and per IP
address when there is no user. Never per path, because a caller who is limited
per path can simply work through your paths in turn.

### The trap: you just rate limited your own health checks

Leave the limiter as `app:use(limiter)` and send twelve requests to the
liveness endpoint, which is what a host does on a schedule:

```sh
for i in $(seq 1 12); do
  curl -s -o /dev/null -w "%{http_code} " http://127.0.0.1:3000/health/live
done
```

```
200 200 200 200 200 200 200 200 200 200 429 429
```

Read what that means. Your host asks "are you alive?", your server answers
"too many requests", and the host reads a non-200 as a failure. A rate limiter
installed to keep the service up has just told the orchestrator to restart it.

Exempt the probes. Middleware is an ordinary function, so this is four lines:

```lua no-run
app:use(function(req, next)
  if req.path:find("/health/", 1, true) == 1 then
    return next(req)
  end
  return limiter(req, next)
end)
```

`req.path:find("/health/", 1, true) == 1` means "the path starts with
`/health/`". The `true` turns off pattern matching, so the text is compared
literally.

Same twelve requests:

```
200 200 200 200 200 200 200 200 200 200 200 200
```

And a real route still refuses, which is the point:

```sh
for i in $(seq 1 12); do
  curl -s -o /dev/null -w "%{http_code} " -X POST http://127.0.0.1:3000/login \
    -H "content-type: application/json" \
    -d '{"email":"nobody@example.com","password":"wrong"}'
done
```

```
401 401 401 401 401 401 401 401 401 401 429 429
```

### The limiter needs a shared place to count

The counting happens in `req.cache`. Which cache you gave `app:run` decides
whether you have a real limit:

- **`akkar.cache.memory`** counts inside one process. Run four processes and
  your fleet allows four times what you configured. That is a fine default
  while you are learning, and it is not rate limiting.
- **Redis** counts in one place that every process shares. That is a real
  limit.

You already started Redis on page 10 for the job queue, so switching means
changing the `cache` line of `app:run` and nothing else:

```lua no-run
app:run {
  port = 3000,
  timeout = 5,
  db = connect,
  cache = redis.connect { port = 6379 },
}
```

This has a second effect you will like: sessions live in `req.cache` too, so
they now survive restarting the server. Since page 7, every restart has logged
everybody out. That stops now.

## 3. Liveness and readiness, which are not the same question

A host asks your process two questions, and confusing them causes outages.

**Liveness: is this process still working?** If the answer is no, the host
**kills and restarts** the container.

**Readiness: should this process be sent traffic right now?** If the answer is
no, the host **stops routing to it** and leaves it alone.

Different questions, different consequences, so two endpoints:

```lua no-run
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
```

A check returns `true` to pass, or `false` plus a reason to fail. `timeout` is
how long one check may take. `cache` is how long a result is reused: a
readiness endpoint polled once a second by twenty instances must not turn a
struggling database into a hammered one, so the answer is remembered for five
seconds, failures included.

Both work while everything is fine:

```sh
curl -s http://127.0.0.1:3000/health/live
```

```
{"status":"pass","uptime":9.7806364339995,"checks":{}}
```

```sh
curl -s http://127.0.0.1:3000/health/ready
```

```
{"status":"pass","uptime":9.7931252540002,"cached":false,"checks":{"db":{"status":"pass","took_ms":1}}}
```

Notice `"checks":{}` on the liveness answer. It ran nothing, and that is the
next section.

### Why liveness must not touch the database

**`live()` checks nothing.** It opens no connection, runs no query, and calls
none of the functions in your `checks` table. It answers from two numbers the
probe has held since it was created.

That sounds lazy. It is the most important line on this page, so here is the
reasoning in full.

Suppose your liveness probe ran `select 1`. Now your database gets slow. Not
down, just slow, the way a database gets when a query is missing an index.

1. Every instance's liveness probe times out, **at the same moment**, because
   they all depend on the same database.
2. The host reads that as "these processes are broken" and restarts **all of
   them at once**.
3. Every restarting instance opens fresh connections to the database that was
   already struggling.
4. Nothing is serving traffic. The instances that could have answered from
   cache, or served routes that never touch the database, were killed too.

**One slow dependency became a fleet with nothing running in it, and the
restarts made the dependency worse.** Restarting a process does not fix a slow
database, and doing it to every process at once is how a small problem becomes
an outage.

Readiness is where a dependency belongs. A failing readiness check takes one
instance out of the load balancer and leaves the process alive, so it can come
back the moment the database does, without a restart.

There is also nothing useful liveness could check. A process whose event loop
has stopped cannot answer the probe at all: the connection hangs and the probe
times out. That is the signal. Anything cleverer is a check pretending to be a
proof.

### What it looks like when the database is down

You can see this without breaking anything real. Change two lines in
`app.lua`: point the database at a port with nothing on it, and let the app
start anyway.

```lua no-run
local connect = db.connect {
  host = "127.0.0.1", port = 55499, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}
```

```lua no-run
app:run {
  port = 3000,
  timeout = 5,
  check_capabilities = false,
  db = connect,
  cache = redis.connect { port = 6379 },
}
```

`check_capabilities = false` is what lets the process start with a dependency
that is not answering. Without it, akkar refuses to boot, which is the right
default: on an ordinary day a missing database is a mistake in your
configuration, and failing loudly at startup beats discovering it on the first
request. Turning it off is how you get a process that comes up degraded and can
still say so.

Liveness, with no database at all:

```sh
curl -s -i http://127.0.0.1:3000/health/live
```

```
HTTP/1.1 200 OK
access-control-allow-credentials: true
access-control-allow-origin: http://127.0.0.1:5173
x-request-id: db2ef11b000001
content-type: application/json
content-length: 54

{"checks":{},"status":"pass","uptime":8.5785176360005}
```

Readiness, same server, same moment:

```sh
curl -s -i http://127.0.0.1:3000/health/ready
```

```
HTTP/1.1 503 Service Unavailable
access-control-allow-credentials: true
access-control-allow-origin: http://127.0.0.1:5173
x-request-id: db2ef11b000002
content-type: application/json
content-length: 307

{"error":{"uptime":8.5937886770043,"checks":{"db":{"took_ms":1,"status":"fail","reason":"db: could not connect to 127.0.0.1:55499 (database \"akkar\", user \"postgres\") -- \/home\/jp\/.luarocks\/share\/lua\/5.4\/pgmoon\/cqueues.lua:18: socket:connect: Connection refused"}},"status":"fail","cached":false}}
```

`200` and `503`, from one process, at the same instant, and both are correct.
The process is fine, so do not restart it. Its database is not, so do not send
it traffic. The `reason` names the failing check, which is what you want at
3am, and the path in it will look different on your machine.

Put the port back to `55432` and remove `check_capabilities = false` before
moving on.

**When you deploy, point the host's restart policy at `/health/live` and its
traffic routing at `/health/ready`.** Never the other way round. Page 12 does
this for you.

## The whole application

`app.lua`, with everything from this page in it. `worker.lua` from page 10 is
unchanged.

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"
local health  = require "akkar.health"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"

local app = akkar.new()

local connect = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

local queue = jobs.new(redis.connect { port = 6379 }(), "email")

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
  origin = "http://127.0.0.1:5173",
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

app:handle_signals()

app:run {
  port = 3000,
  timeout = 5,
  db = connect,
  cache = redis.connect { port = 6379 },
}
```

Two lines near the bottom have not been explained yet.

**`app:handle_signals()`** makes `Ctrl-C` and a container stop finish the
requests already in flight before the process exits, rather than cutting them
off. akkar does not install signal handlers by itself, because a library that
does that behind your back fights with whatever else your process is doing. In
a container it is not optional, and page 12 says why.

**`timeout = 5`** is the request deadline from the first section, now matching
the `statement_timeout` on the connection.

## Checkpoint

You have this if:

- the `statement_timeout` warning is gone from your startup output
- twelve fast requests to `/tasks` end in a `429`, and twelve to
  `/health/live` do not
- `/health/live` and `/health/ready` both answer `200` right now
- you can say, in one sentence, what happens to a fleet whose liveness probe
  queries the database when that database gets slow

Next in the guide: putting all of this somewhere other than your laptop.
