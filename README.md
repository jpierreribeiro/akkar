# akkar

**A backend runtime for Lua that boots in 29 milliseconds, speaks HTTP/2 with
no nginx in front of it, and will not let you write the bugs that page you at
three in the morning.**

One coroutine per request. One thread per process. A whole application, with
Postgres, Redis, background jobs, sessions and metrics, answers its first
request 29 milliseconds after you start it.

```sh
akkar new my-api && cd my-api && akkar run
```

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/", function() return { hello = "world" } end)

return app
```

| | |
|---|---:|
| boot to first response, full stack | **29 ms** |
| memory per idle connection | 9.2 KB |
| tests, Lua 5.4 and Lua 5.5 | **1,852** |
| HTTP/2 conformance, h2spec 2.6.0 | **146 of 146** |
| platforms every commit is tested on | Linux x86_64, Linux arm64, macOS |

Every number on this page came off a machine. Where one is missing, the page
says so.

---

## Five failures you have shipped before

Not hypotheticals. These are the ones that survive code review, pass staging,
and then wake somebody up.

**The double response.** A handler writes a reply, then an error path writes
another. In most frameworks that is a runtime error at best and a corrupted
response at worst. Here a handler *returns* its response and never holds the
socket, so there is nothing to write twice.

```lua
app:post("/charges", function(req)
  if not req.body.amount then
    return akkar.bad_request { error = "amount is required" }
  end
  return akkar.created { id = 42 }         -- one value out, always
end)
```

**The connection that never came back.** A request is abandoned mid query, its
handler is dropped, and the pool slot it borrowed is gone for good. Enough of
those and the service stops answering with no error anywhere. akkar releases
every capability a request acquired on every exit path, including the deadline
and including a raise, and a machine checks that under generated fault
schedules rather than trusting the claim.

**The abandoned transaction.** A `BEGIN` with no matching `COMMIT` holds locks
until something times out. `transaction(fn)` is closure scoped: the transaction
cannot outlive the function, because there is no handle to leave open.

```lua
req.db:transaction(function(tx)
  tx:query("update accounts set balance = balance - $1 where id = $2", 100, 1)
  tx:query("update accounts set balance = balance + $1 where id = $2", 100, 2)
end)                                        -- commits, or rolls back, here
```

**The request with no ceiling.** A body that arrives forever, a query with no
deadline, a WebSocket message of arbitrary size. Bodies, deadlines and socket
messages are bounded before you configure anything, at 1 MB and 30 seconds.
Two more ceilings are one line each, how many sockets may be open and how many
instructions a handler may run without returning, and `akkar doctor` tells you
when you have not set them.

**The blocked event loop.** One synchronous call in one handler stalls every
other request on the process, and the usual symptom is latency nobody can
explain. akkar notices and tells you which file and which line did it.

```
WARN  event loop blocked for 240ms at handlers/report.lua:31
```

---

## Sixty seconds to a running service

```sh
luarocks install https://raw.githubusercontent.com/jpierreribeiro/akkar/main/akkar-0.1.0-1.rockspec
akkar new my-api && cd my-api && akkar run
```

Needs Lua 5.4 and OpenSSL headers. Tested against OpenSSL 3.0.13. Lua 5.5 works
too and CI runs the whole suite on it; `docs/runtime/lua55-stack.sh` builds that
stack from source in one command.

`akkar new` writes a project that already has routes, a schema, migrations,
tests and a Dockerfile. `akkar run` reloads on save. `akkar doctor` checks the
configuration and tells you what will bite you in production.

---

## What it costs to run

Measured on a c5.2xlarge, and reproducible from `bench/`:

| | |
|---|---:|
| boot, `akkar` alone | 21 ms |
| boot, plus Postgres, Redis, jobs, auth, metrics | 29 ms |
| allocation per request | 5,376 B |
| idle HTTP connection | 9.2 KB |
| idle WebSocket | 10.2 KB |
| capacity model | one process per core, `reuseport = true` |

Small enough that a hundred idle exercises fit in 1.2 GB, which is why the
runtime is also the substrate for a teaching platform. Small enough that a
container image is 6.4 MB.

---

## HTTP/2 and WebSocket, without a proxy

Serve TLS and a browser negotiates HTTP/2 through ALPN. There is no option to
turn on and no second listener:

```lua
app:run { port = 443, tls = { certificate = "cert.pem", key = "key.pem" } }
```

Measured here, six half second requests over one connection: **552 ms over
HTTP/2 against 3,071 ms over HTTP/1.1**. That is multiplexing, and your handlers
do not change to get it.

WebSocket is a route kind rather than a second programming model. Handlers still
return, so nothing about the guarantees above is suspended for sockets:

```lua
app:websocket("/chat/:room", {
  open    = function(ws) ws:send("welcome to " .. ws.params.room) end,
  message = function(ws, text)
    ws:scope(function(req)                  -- capabilities for THIS message
      req.db:query("insert into messages (room, body) values ($1, $2)",
                   ws.params.room, text)
    end)                                    -- released here, on every path
    ws:send(text)
  end,
})
```

That `ws:scope` is one line of ceremony, and it is the line that decides whether
a pool slot is held for a message or for as long as a browser tab stays open.

HTTP/3 is not here. QUIC is a UDP transport with its own congestion control, and
it is terminated at the edge in practice.

---

## How the guarantees are checked

Every claim above is machine checked, and the checks are the interesting part.

**1,852 tests**, on Lua 5.4 and Lua 5.5, on three platforms, on every commit.

**HTTP/2 conformance** through h2spec 2.6.0: **146 of 146, nothing skipped**,
run after run. `bench/h2spec.sh` fetches the tool and runs it against a live
server, so you can check the claim rather than believe it.

**Generated fault schedules.** A seed picks the workload, the faults and the
deadlines, and the pool invariants are asserted after every run. When
`execution.release` was emptied to prove the test bites, the suite did not go
red, it *hung*, which is exactly the outage the pool code has on record from a
study box.

**Hostile bytes.** Twenty-two malformed HTTP/2 frame shapes and fifteen
malformed WebSocket ones go at a live server, and the property asserted is not
"no crash" but "the next ordinary client is still answered".

---

## What a bug costs here

On its first run, the HTTP/2 fuzzer found a remote denial of service in
upstream lua-http: a frame header that arrives three bytes short makes
`string.unpack` raise, the raise leaves the connection, and the accept loop dies
with it. Process alive, socket open, nothing ever accepted again, including
HTTP/1.1. Three bytes, no credentials.

Two things came out of that, and the second matters more.

The parser now checks the length it was handed, which upstream already does
twenty lines below for the payload and not for the header.

And `add_socket` now runs every connection under `xpcall`, so the next parser
bug, the one nobody has found, costs one connection instead of the service. It
was demonstrated by putting the original defect back: the server logs the
traceback and keeps answering.

That is the working method. Find the defect, fix the defect, then ask why the
defect was fatal and fix that too.

---

## Is Lua fast enough for this

For a JSON API, yes, and the honest comparison is on the page rather than in a
footnote.

akkar answers a JSON request in about 93 microseconds of CPU. Against OpenResty
it is 8.75 times slower, and OpenResty is nginx: the request pipeline is C and
Lua only runs your handler. Against Lapis, the other Lua framework in the same
shape, akkar is 1.56 times faster. Against Luvit, on libuv, the two are level
on throughput and akkar's p99 is two to three times better.

What that means in practice: an endpoint that spends four milliseconds in
Postgres spends about a tenth of a millisecond in akkar. The runtime is not
where your latency is, and if it ever becomes where your latency is, the
profiler in `bench/` will say so with a number.

Several things that would make it faster were measured and refused, with the
arithmetic written down: LuaJIT at 1.62x against a bar of 2x, a tokeniser in C
at 1.09x, generated validators at 1.04x. `docs/why/` has each one.

---

## Where akkar is today

akkar runs its author's services. It is young, and these are the three things
worth knowing before you put it in front of your own customers:

**The API will change.** There is no compatibility policy yet. Pin the rockspec.

**No independent security review has happened.** The bounds, the fuzzers and the
conformance suite are real and they are all internal.

**It is not on luarocks.org yet**, so installing means pointing LuaRocks at the
rockspec URL above. That is a release step, not an obstacle.

What is settled: the substrate, the ergonomics, and the production shape. Body
limits, deadlines, pooling, graceful shutdown, structured logs, metrics,
tracing, OpenAPI, migrations, jobs, sessions, an in memory adapter for every
capability, Teal declarations and a strict mode that turns an accidental global
into an error.

`docs/UNKNOWNS.md` is the full list of what is not known, kept current.

---

## Everything in the box

Thirty-six modules and eight commands, each row linking to its reference page.

**The command line.** Installing the rock puts `akkar` on your PATH.

| | |
|---|---|
| [`akkar new`](docs/reference/cli.md) | a project that runs: app, spec, migrations, README |
| [`akkar run`](docs/reference/cli.md) | start it; `--watch` restarts on a change |
| [`akkar test`](docs/reference/cli.md) | busted over `spec/`, with the path set for you |
| [`akkar doctor`](docs/reference/doctor.md) | what is installed, and whether it answers |
| [`akkar build`](docs/RUNTIME.md) | one executable, no Lua needed to run it |
| [`akkar archive`](docs/RUNTIME.md) | the static archives `build` consumes |
| [`akkar watch`](docs/reference/cli.md) | restart any command when files change |
| `akkar version` | the version, and the Lua under it |

**Handling a request**

| | |
|---|---|
| [`akkar`](docs/reference/akkar.md) | routes, the request table, responses, `app:run`, `app:test` |
| [`akkar.v`](docs/reference/akkar.md#akkarv) | schemas for params, query, body and response |
| [`akkar.openapi`](docs/reference/openapi.md) | the document, from the schemas already written |
| [`akkar.etag`](docs/reference/etag.md) | `If-Match`, so a second writer cannot erase the first |
| [`akkar.idempotency`](docs/reference/idempotency.md) | the same `Idempotency-Key` charged once |
| [`akkar.limit`](docs/reference/limit.md) | concurrency and rate, decided inside Redis |
| [`akkar.compress`](docs/reference/compress.md) | gzip on the way out |
| [`akkar.static`](docs/reference/static.md) | files, with caching headers |
| [`akkar.multipart`](docs/reference/multipart.md) | uploads |

**The capabilities a handler receives.** A closed set, so `req` cannot become
a global by another name.

| | |
|---|---|
| [`req.db`](docs/reference/db.md) | Postgres, four methods, pooled |
| [`req.cache`](docs/reference/redis.md) | Redis, or an in-process implementation |
| [`req.log`](docs/reference/log.md) | structured, with the request id bound in |
| [`req.clock`](docs/reference/time.md) | the clock, so a deadline test need not sleep |
| [`req.http`](docs/reference/http.md) | outbound HTTP, pooled, with a ceiling |

**Data**

| | |
|---|---|
| [`akkar.db`](docs/reference/db.md) | the adapter and the connection factory |
| [`akkar.pq`](docs/reference/db.md#the-pq-driver) | the C driver over libpq, opt-in |
| [`akkar.sql`](docs/reference/sql.md) | a builder where a value can never become SQL |
| [`akkar.scope`](docs/reference/scope.md) | a tenant a query cannot escape |
| [`akkar.pool`](docs/reference/pool.md) | connection pooling, used by db and http |
| [`akkar.migrate`](docs/reference/migrate.md) | migrations, from a directory or as data |
| [`akkar.redis`](docs/reference/redis.md) | the cache adapter |
| [`akkar.json`](docs/reference/json.md) | encoding, with `null` and empty-array handling |

**Identity**

| | |
|---|---|
| [`akkar.auth`](docs/reference/auth.md) | session, bearer and API key, one middleware |
| [`akkar.session`](docs/reference/session.md) | server-side sessions behind a signed cookie |
| [`akkar.jwt`](docs/reference/jwt.md) | verify only, on purpose |
| [`akkar.csrf`](docs/reference/csrf.md) | double-submit, for cookie sessions |
| [`akkar.crypto`](docs/reference/crypto.md) | hashing, HMAC, password hashing, random |

**Work that outlives the request**

| | |
|---|---|
| [`akkar.jobs`](docs/reference/jobs.md) | at-least-once queues, retries, dead letters |
| [`akkar.work`](docs/reference/work.md) | native work that would block the loop |
| [`app:task`](docs/reference/akkar.md#apptaskname-fn) | a supervised loop in the server's own process |

**Operating it**

| | |
|---|---|
| [`akkar.health`](docs/reference/health.md) | liveness and readiness, separately |
| [`akkar.metrics`](docs/reference/metrics.md) | Prometheus, with the request path instrumented |
| [`akkar.trace`](docs/reference/trace.md) | W3C trace context, propagated and exported |
| [`akkar.log`](docs/reference/log.md) | JSON or text, with redaction |
| [`akkar.config`](docs/reference/config.md) | environment, typed and validated at boot |
| [`akkar.doctor`](docs/reference/doctor.md) | the library combination, checked |

**Reaching outward**

| | |
|---|---|
| [`akkar.http`](docs/reference/http.md) | a client with a pool, retries and a body ceiling |
| [`akkar.email`](docs/reference/email.md) | SMTP |
| [`akkar.storage`](docs/reference/storage.md) | S3-compatible object storage, signed |

**The runtime itself**

| | |
|---|---|
| [`akkar.build`](docs/RUNTIME.md) | the single-executable host |
| [`akkar.watch`](docs/reference/cli.md#akkar-watch----command) | file watching for development |
| [`akkar.strict`](docs/reference/strict.md) | an accidental global becomes an error |
| [`akkar.substrate`](docs/substrate/lua-http-wedge.md) | the lua-http defects akkar repairs at runtime |
| [`akkar.time`](docs/reference/time.md) | the clock the framework reads |
| [`akkar.vm`](docs/reference/vm.md) | a sandbox for untrusted Lua; read its limits first |

**Adapters that need nothing running.** Every capability ships one, so tests
and small deployments need no infrastructure.

| | |
|---|---|
| [`akkar.db.memory`](docs/reference/db.md#akkardbmemory) | programmed queries, and `:hang()`, `:fail()`, `:drop()` |
| [`akkar.cache.memory`](docs/reference/redis.md) | a real cache with expiry, per process |
| [`akkar.jobs.memory`](docs/reference/jobs.md#memorynewname) | a queue in one process |
| [`akkar.jobs.redis`](docs/reference/jobs.md#redisnewcache-name) | a queue a fleet shares |

---

## The idea

Three things akkar does differently, each one coming from a concrete defect in
a framework that exists.

### 1. Handlers return the response; they never mutate a context

```lua
app:get("/users/:id", function(req)
  local user = req.db:one("select id, name from users where id = $1", req.params.id)
  return user or akkar.not_found "user not found"
end)
```

Writing the response twice becomes **structurally impossible**, because there is no
`c.JSON()` to call again. And there is no `Abort()` + `return` pair where
forgetting the `return` keeps the handler running.

### 2. All I/O goes through adapters, and akkar owns the contract

A handler never calls `require "pgmoon"`. It receives `req.db`. That is what
makes in-process testing possible, and what keeps the substrate replaceable.

akkar defines the contract (for a database, four methods) and ships a
Postgres adapter as the reference, not as the only permitted one. Owning every
driver would make akkar the bottleneck.

`req` stays deliberately small. Capabilities come from a **closed set** of `db`,
`cache`, `log`, `clock` and `http`, because `req` accumulating `req.mailer`,
`req.payments` and `req.storage` is how a request object becomes a global by
another name. Unknown options are rejected at startup rather than ignored:

```
unknown app:run{} option 'timout'; did you mean 'timeout'?
```

And reading something that was never configured gives a useful message rather
than `attempt to index a nil value`:

```
req.user is not set; this route is missing the authentication middleware
req.db is not configured; pass db = ... to app:run{}
```

### 3. A blocking watchdog

The number one failure mode of Lua on a server is a blocking call that freezes
the process silently. akkar tells you:

```
[akkar] WARNING: handler blocked the loop for 102 ms without yielding
  at handlers/auth.lua:14
stack traceback:
	handlers/auth.lua:16: in function <handlers/auth.lua:14>
  this stalls every request in this process.
```

Measured: 0.16 to 0.35 µs per switch, under 2% overhead. It stays on in
production. Go does not warn about this; neither does Node.

**What it cannot see, stated because this page overpromised until somebody
checked.** The watchdog counts Lua instructions, so it notices Lua code that
runs too long. A single call into C is one instruction and stays one
instruction no matter how long it takes.

The example that matters is password hashing: `akkar.crypto.hash_password` is
PBKDF2 inside OpenSSL, it took **771 ms** in a measurement taken while writing
the beginner guide, and the watchdog said nothing at all. The whole process
was stopped for three quarters of a second in silence.

That is why `akkar.crypto` points at `akkar.work` in its own docstring, and it
is a real limit rather than a missing feature: there is no point at which Lua
regains control during a C call, so there is nothing for a Lua-level watchdog
to interrupt. `akkar/work.lua` says the same thing about native work in
general.

---

## The ladder

The rule: **climbing a rung never requires editing code written on the rung
below.**

```lua
-- 0. three lines
app:get("/", function() return { hello = "world" } end)

-- 1. parameters
app:get("/users/:id", function(req) return { id = req.params.id } end)

-- 2. request body
app:post("/users", function(req) return akkar.created { name = req.body.name } end)

-- 3. validation
app:post("/users", {
  body = { name = "string", email = "string?" },
}, function(req) return akkar.created(req.body) end)

-- 3b. expressive validation; "string?" is sugar for v.string{optional=true}
app:put("/users/:id", {
  params = { id = v.integer { min = 1 } },
  body   = { name = v.string { min = 1, max = 100 },
             role = v.string { optional = true, one_of = { "admin", "user" } } },
}, handler)

-- 4. middleware; `next` returns the response, so post-processing works
app:use(function(req, next)
  local res = next(req)
  log(req.method, req.path, res.status)
  return res
end)

-- 5. database
app:get("/users/:id", function(req)
  return req.db:one("select id, name from users where id = $1", req.params.id)
end)

-- 6. configuration
app:run { port = 3000, db = require("akkar.db").connect { ... } }
```

Every transition was checked one by one in `docs/PLAN.md`, section 2.

---

## Things worth knowing

**A deep layer can signal HTTP without threading a return value back.** The
same value works as a return and as an error:

```lua
local function find_or_404(db, id)
  local user = db:one("select ... where id = $1", id)
  if not user then error(akkar.not_found "does not exist") end
  return user
end
```

`return akkar.not_found()` and `error(akkar.not_found())` both produce a 404.
A genuine error still becomes a 500, with no traceback leaked to the client.

**Closure-scoped transactions.** Commit at the end, rollback on any error.
including a response thrown from inside. There is no path where a `BEGIN` stays
open because someone forgot.

```lua
return req.db:transaction(function(tx)
  local from = find_or_404(tx, req.params.id)
  tx:exec("update ...", from.id)
  return { ok = true }
end)
```

**Sub-applications, not groups.** A sub-app is an ordinary app mounted under a
prefix, and it stays testable on its own, unaware of where it lives:

```lua
local health = akkar.new()
health:get("/live", function() return { status = "live" } end)
app:mount("/health", health)

health:test():get "/live"            -- standalone
app:test():get "/health/live"        -- mounted
```

**A `response` schema is enforced, not just documented.** Declaring the shape
filters undeclared fields out of the body, so a handler doing `select *` cannot
leak `password_hash`. A mismatch is a 500, because a response that breaks
its own contract is the server's fault, not the client's:

```lua
app:get("/users/:id", {
  response = { id = "integer", name = "string", email = "string?" },
}, function(req)
  return req.db:one("select * from users where id = $1", req.params.id)
end)
```

**Adapters you can run without infrastructure.** Every capability ships an
in-memory implementation next to the real one, so tests need nothing running
and a small deployment can skip Redis entirely:

```lua
local app_client = app:test {
  db    = require("akkar.db.memory").factory(function(fake)
            fake:on("from users", { id = 1, name = "ada" })
          end),
  cache = require("akkar.cache.memory").factory(),
}
```

The cache one is a real implementation with expiry, not a stand-in. The
database one matches programmed queries and does not parse SQL, because a fake
SQL engine would be a second database whose disagreements show up as tests
that pass and production that does not.

**Types, if you want them.** Lua checks nothing before the program runs, and
writing akkar carefully does not change that. `types/akkar.d.tl` means a
handler written in [Teal](https://github.com/teal-language/tl), a typed
dialect compiling to plain Lua, is checked without akkar being rewritten:

```
invalid key 'parms' in record 'req' of type akkar.Request
in local declaration: n: got string, expected integer
unknown field timout
```

It does not check whether a schema matches what a handler returns; schemas are
runtime values, and validation is what checks those.

**Accidental globals are an error, not a surprise.** On a server a global
written inside a handler outlives the request and is visible to the next one:

```lua
app:run { port = 8080, strict = true }
```

```
assignment to undeclared global 'total' at handlers/cart.lua:14
  a global written in a handler outlives the request and is visible to the next one
  did you mean `local total`?
```

akkar itself measures clean, with zero global writes across every module,
checked in the bytecode, and the whole test suite runs under strict mode so that stays
true.

**Sockets have bounds of their own, and they are the ones people forget.**
`max_concurrent` counts connections, and a WebSocket is a connection that
lasts: ten idle sockets against `max_concurrent = 10` and the eleventh client,
an ordinary GET to an ordinary route, is never accepted at all. Measured.

```lua
app:run {
  port = 8080,
  websocket_max_connections = 500,   -- refused past this with 503 + retry-after
  websocket_idle_timeout    = 300,   -- a quiet socket is closed and forgotten
  body_limit                = 1024 * 1024,   -- also bounds a socket MESSAGE
}
```

`body_limit` covers a WebSocket message too, on the length the peer declares and
on the sum of its fragments, and the refusal is close code 1009. Before that
bound existed, one 64 MB message cost **192 MB of resident memory** against an
application that had set `body_limit = 1 MB`. `akkar doctor` warns when an
application serves sockets and has not set a ceiling for them.

**Several processes, one port.** One Lua VM is one core, so capacity is
processes. `SO_REUSEPORT` lets them share a port with no proxy in front:

```lua
app:run { port = 8080, reuseport = true }
```

Measured on a c5.2xlarge: **linear across physical cores** at 1.00x, 1.00x,
1.00x per process at one, two and three, varying by less than the 0.7% noise
floor. Hyperthreads add about 18% more. See `bench/RESULTS.md`.

**Logs that correlate without being asked to.** A request id is taken from
`x-request-id` or generated, echoed on the response, and bound into `req.log`:

```lua
app:post("/charges", function(req)
  req.log:info("charged", { amount = 10 })   -- request_id attached for you
  return akkar.created {}
end)
```

```json
{"level":"info","message":"charged","amount":10,"request_id":"minha-trace-123","time":1786757421}
```

**OpenAPI, generated from what you already wrote.** The schema declared for
validation is the schema in the document, so no route describes itself twice:

```lua
local openapi = require "akkar.openapi"
openapi.serve(app, "/openapi.json", { title = "My API", version = "1.0.0" })
```

`v.string { min = 1, max = 100 }` becomes `minLength`/`maxLength`, `one_of`
becomes `enum`, `match` becomes `pattern`, `/users/:id` becomes
`/users/{id}`, and the `422` akkar itself produces is documented without
anyone declaring it.

**In-process testing.** No socket, no port, no database, and still through the same
middleware, validation and dispatch chain a real request travels:

```lua
local res = app:test():post("/users", { body = { email = "x@y.z" } })
assert.equal(422, res.status)
assert.equal("required", res.body.fields["body.name"])
```

The whole suite runs in about two seconds, most of which is deliberate
sleeping in the deadline tests.

---

## Running the examples

The examples need a database:

```sh
docker run -d --name akkar-pg \
  -e POSTGRES_PASSWORD=akkar -e POSTGRES_DB=akkar \
  -p 55432:5432 postgres:16-alpine
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine

docker exec -i akkar-pg psql -U postgres -d akkar <<'SQL'
create table if not exists users (
  id serial primary key, name text not null, email text);
insert into users (name, email) values
  ('ada','ada@example.com'), ('alan','alan@example.com');
SQL

PORT=8099 lua5.4 examples/crud.lua
```

## Documentation

**Learning it**

| | |
|---|---|
| [`docs/guide/`](docs/guide/) | thirteen pages for somebody new to backends, in order |
| [`docs/sql/`](docs/sql/) | SQL and migrations, from nothing to a schema that changes |
| [`docs/recipes/`](docs/recipes/) | nineteen tasks, each one page |
| [`docs/reference/`](docs/reference/) | every module, every symbol |
| [`docs/why/`](docs/why/) | the decisions, with the alternatives beside them |
| [`examples/crud.lua`](examples/crud.lua) | ten scenarios against a real Postgres |

**Deploying and operating it**

| | |
|---|---|
| [`docs/DEPLOY.md`](docs/DEPLOY.md) | Railway, Docker, and what breaks in a scratch container |
| [`docs/RUNTIME.md`](docs/RUNTIME.md) | `akkar build`, and what it still needs by hand |
| [`docs/reference/cli.md`](docs/reference/cli.md) | the eight commands |

**What is measured, and what is not**

| | |
|---|---|
| [`bench/study/RESULTS.md`](bench/study/RESULTS.md) | against Gin and FastAPI, saturation, an eight-hour soak |
| [`bench/study/WHERE-THE-GAP-IS.md`](bench/study/WHERE-THE-GAP-IS.md) | the gap attributed: cqueues 11%, lua-http 46%, akkar 43% |
| [`bench/driver/RESULTS.md`](bench/driver/RESULTS.md) | pgmoon against the C driver, isolated and through HTTP |
| [`bench/driver/ANOMALY.md`](bench/driver/ANOMALY.md) | four experiments, two of which refuted a hypothesis |
| [`docs/PERFORMANCE-STUDY.md`](docs/PERFORMANCE-STUDY.md) | ten findings, including the ones that were wrong |
| [`docs/UNKNOWNS.md`](docs/UNKNOWNS.md) | **what nobody has looked at** |

**Where it is going**

| | |
|---|---|
| [`docs/RUNTIME-1.0.md`](docs/RUNTIME-1.0.md) | what stays in Lua, what earns C, what ships together |
| [`docs/PORT-FINDINGS.md`](docs/PORT-FINDINGS.md) | nine defects a real service found, and how |
| [`docs/HANDOFF.md`](docs/HANDOFF.md) | where things stand, and what to do next |
| [`docs/PLAN.md`](docs/PLAN.md) | the verified ladder, invariants, milestones |
| [`docs/BACKLOG.md`](docs/BACKLOG.md) | done, next, and deliberately not built |
| [`types/`](types/) | Teal declarations, checked on every test run |

## Safe defaults

`app:run()` with no arguments is already production-shaped. Configuration
appears only when you disagree with the default.

| Default | Value | Override |
|---|---|---|
| Request body limit | 1 MB | `app:run { body_limit = 5 * 1024 * 1024 }` |
| Request deadline | 30 s | `app:run { timeout = 5 }` |
| Connection pool size | 10 | `db.connect { pool_size = 25 }` |
| Shutdown grace | 10 s | `app:run { shutdown_grace = 30 }` |
| Statement timeout | unset | `db.connect { statement_timeout = 5 }` |
| Concurrent requests | from `ulimit -n` | `app:run { max_concurrent = 500 }` |
| Trusted proxies | none | `app:run { trusted_proxies = { "10.0.0.0/8" } }` |

**`req.ip` is the socket's peer, not a header.** `X-Forwarded-For` is a string
the client typed, and akkar believes it only when the connection came from a
proxy the application named in `trusted_proxies`, and then walks the chain
from the *right*, past every trusted hop, because the leftmost entry is
whatever the client chose to send. An unparseable address is never trusted, so
the failure is closed.

**Concurrency is bounded by file descriptors, and the bound is declared.** Every
in-flight request holds a `cqueues` controller for its deadline, and a controller
costs exactly two descriptors, measured at 1,030 descriptors for 512 concurrent
requests. Against the common `ulimit -n 1024` that is a wall at about 500 per
process, and hitting it is not a clean failure: `accept` starts failing and the
process flails. So akkar reads the limit at boot and tells lua-http to stop
accepting before it, which turns collapse into backpressure. Slow is a state a
server can be in; out of descriptors is not.

**The deadline stops akkar waiting; it does not stop Postgres working.** The
server notices a departed client only when it next tries to write, and a query
producing no output until it completes may not try for minutes, so under load
a timeout can leave the database busier than no timeout would. Set
`statement_timeout` to match the request deadline and the server enforces it
too. akkar asks once at boot and warns if a deadline exists without one; it is
not on by default because turning it on silently would cancel somebody's
migration.

Configured capabilities are checked against their contracts at startup, so a
misconfigured adapter fails at boot rather than on the first request that
touches it. This means **the server refuses to start when the database is
unreachable**, which is right for a service whose every route needs it and wrong for one
that should come up degraded, so `app:run { check_capabilities = false }` opts
out. Capabilities are acquired on first use, so a route that never queries
takes no connection and keeps answering while the database is down.

Signals are opt-in, because a library that installs handlers behind an
application's back fights whatever else the process is doing:

```lua
app:handle_signals()      -- SIGTERM and SIGINT call app:stop()
app:run()
```

An oversized body is rejected with `413` before it is buffered, both when
`Content-Length` declares it and when a chunked body simply keeps arriving. A
request that overruns its deadline answers `503`.

The deadline is cooperative: it fires while the handler is yielding on I/O. A
handler burning CPU in a tight loop is not interrupted by it. That is what the
watchdog reports instead. The two cover different failures on purpose.

Timeout arbitration follows one rule: **the winner is decided by the first
arbitrating event and a late event never overturns it.** A handler that
finishes at 4.99 s against a 5 s deadline has completed, and is never reported
as a timeout.

## Queries a tenant cannot escape

Two of akkar's invariants are about the database, and both work the same way as
the rest: the mistake is not discouraged, it is unavailable.

```lua
local sql = require "akkar.sql"

app:get("/documents", { query = { sort = "string?" } }, function(req)
  local db = req.db:scope("project_id", req.user.project_id)

  local q = sql.select("id, title"):from "documents"
  if req.query.sort then
    q:order_by(req.query.sort, { "id", "title", "created_at" })
  end

  return db:many(q:limit(50))
end)
```

**A value can never become SQL.** `?` marks a value; the numbering into
`$1, $2` happens once at assembly, so conditions added in different places
compose without anyone tracking indices, which is the reason people give up and
concatenate. There is no `where_raw`; an escape hatch is where the injection
goes.

**A column name is not a value**, because Postgres has no placeholder for one.
So sorting by a client-supplied field is checked against a list the route
declares: the pattern rejects a crafted string, and the list rejects a real
column the route never meant to expose.

**A scoped handle refuses raw SQL.** A string cannot be scoped without parsing
it, so `db` above takes a query and applies `project_id` itself. The unscoped
statement is never assembled. An insert overrides a `project_id` the client
supplied, a `nil` tenant id raises instead of matching every row, and a
transaction hands the closure the scoped handle so nothing inside can reach
past it.

Crossing tenants is real work, so it is possible, but it has to be said out
loud, which makes `grep -rn ':unscoped()'` the complete list:

```lua
req.db:unscoped():many "select count(*) from documents"
```

Likewise an `UPDATE` or `DELETE` with no `WHERE` is refused until you call
`:all_rows()`. That shape is legitimate in a migration and almost never in a
handler.

## Jobs that survive failing

Retries are **off unless asked for**, which is the same position the old
"logged and dropped" behaviour was defending: a retry policy nobody chose
hides the failure and repeats whatever side effects already happened. The fix
was to make the choice explicit, not to leave the capability out.

```lua
local queue = jobs.new(store, "email", {
  retries = 3,                       -- attempts after the first
  backoff = { first = 60, factor = 2, max = 4 * 3600 },  -- 60s, 120s, 240s ... capped at four hours
})

queue:push("charge", { order = 41 }, { id = "charge:order:41" })  -- once only
queue:push("digest", { user = 7 }, { delay = 3600 })              -- in an hour
```

Backoff carries **full jitter** by default: a hundred jobs that failed against
a database which has just come back would otherwise all retry on the same
second and knock it over again.

What finally fails is kept rather than dropped, capped so the dead-letter
queue cannot become a memory leak with a respectable name, and readable with
`queue:dead_letters()`. A job with no registered handler goes the same way,
that is usually a deploy in progress, and dropping it loses work that
finishing the deploy would have run.

The store contract stays three methods; scheduling, claiming, peeking and
trimming are optional. Asking for a retry policy, a delay or an idempotency
key that the store cannot honour is **an error at the call**, never a feature
that quietly does nothing.

## `akkar doctor`

The question a Lua project actually gets stuck on is not "is my code right",
it is **"is this machine's combination of libraries one that works?"** This
project paid that cost three times before writing any framework code, and
each one was an afternoon:

- `pgmoon` requires `mime`, from luasocket, **without declaring it**. A clean
  install dies with a `require` traceback naming a module nobody asked for.
- `cqueues` pins `lua == 5.4` exactly and has had no release since 2020.
- `luaossl` builds against OpenSSL 3 with deprecation warnings that look like
  failures and are not.

```sh
akkar doctor                     # what is installed, and what will bite
akkar doctor app.lua             # and this application's configuration
akkar doctor app.lua --json      # for something that parses
akkar doctor app.lua --no-probe  # without touching the database
```

`app.lua` is any file returning `app`, or `app, config`, the same table
`app:run{}` takes.

It reports the runtime and every library with the version **the library
itself declares** (never guessed from a directory name), the route count
across mounts and hosts, routes that can never match, the limits actually in
force as numbers, and whether each configured capability answers its contract.

**A doctor that cries wolf gets ignored**, so a finding is one of three things
and they are not interchangeable:

| | |
|---|---|
| `FAIL` | broken now. **Exit code 1**, so a deploy step can gate on it |
| `warn` | works today, will bite. Exit code 0 |
| `ok` | checked and fine, shown so that a missing check is visible |

A missing optional library is a warning; "luaossl is not installed" must not
block a service that speaks plain HTTP. An unreachable database the app
declares is a failure, because the server refuses to boot in that state
anyway, and reporting it as a warning would be the doctor disagreeing with the
framework.

Duplicate routes are not checked: they already fail at startup naming both
sites. What is checked is the case no invariant catches, `/users/:id` and
`/users/:name` compile to the same pattern, and the second can never match.

## Refusing fast instead of accepting slowly

The study measured `/users/42` at four configurations, changing only how much
concurrency was offered against a fixed pool:

```
60 pool conns,  50 clients   10,933 req/s   p99    6.79ms
60 pool conns, 100 clients   10,302 req/s   p99  396.09ms
180 pool conns, 100 clients  10,923 req/s   p99   13.58ms
```

Throughput is **flat**. Past capacity, accepting more work does not produce
more answers. It produces a queue, and the tail pays for it sixtyfold.

```lua
app:use(akkar.limit.concurrent { limit = 5 })          -- at once, per caller
app:use(akkar.limit.rate { per_second = 10, burst = 20 })
```

The concurrency limiter is the one those numbers argue for, and the one most
frameworks leave out. A caller making ten requests a second is fine; the same
caller holding fifty open against a pool of twenty is that 396 ms for
everybody else.

The decision runs **inside Redis**, as a Lua script sent with `EVAL`. Each
limiter is read-then-write, and between the read and the write another process
can decide the same thing, which is a limit that is not a limit. Redis runs a script
atomically, so the decision happens where the state is. Timestamps come from
Redis too, so a client with a wrong clock cannot move the window.

The slot is released on **every** exit, whether that is a normal return, a thrown response
or a handler error, and entries older than a TTL are dropped on acquire, so a
handler that dies without releasing costs one slot for one TTL rather than
forever. A limiter that leaks slots is worse than no limiter.

**The limit that must be stated:** these are only as strong as the store. With
`akkar.cache.memory` the counters are per process, so a fleet of six enforces
six times the configured limit. That is a development default, not rate
limiting. `akkar.limit.scriptable(cache)` says which one you have.

## The same request twice, charged once

A client cannot tell "the request never arrived" from "the response never came
back", so it retries, and the card is charged twice. Only the server can tell
the difference, and only if it remembers.

```lua
app:use(akkar.idempotency { ttl = 86400 })
```

```
POST /charges
Idempotency-Key: 8f14e45f-ea6e-4b3f-9c2a-1d2f3e4b5a60
```

Three of the four cases are the interesting ones. A repeat **after
completion** replays the stored status and body, with `idempotent-replay:
true` so the client knows its retry did nothing new. A repeat **while the
first is still running** gets **409**. Returning nothing is wrong and running
it twice is worse. The **same key with a different body** gets **422**, because
the key is a promise about *which* request this is, and silently replaying
would hide a client bug exactly where it matters.

**A failed handler releases the key** rather than storing the failure. Caching
a 500 would mean the retry, the entire point, can never succeed. Only 2xx is
remembered.

**What it is not:** deduplication at the door, not an idempotent handler. If
the handler charges a card and then crashes before returning, the charge
happened and nothing here knows. That needs the payment processor's own key
underneath this one. And the guarantee is only as strong as the store: with
`akkar.cache.memory` it is per process, which is not deduplication at all.

## The write that vanishes

Two clients read the same record. Both edit it. Both save. The second
overwrites the first and **nothing anywhere reports an error**. Both saw 200,
and one person's work is gone, found weeks later if ever.

HTTP has had the answer since 1997 and almost nobody switches it on.

```lua
app:use(akkar.etag { require_on = { "PUT", "PATCH" }, current = load_document })
```

```
GET /documents/7            ->  200, ETag: "a3f1c9..."
PUT /documents/7            ->  428   no If-Match, and this route demands one
PUT + If-Match: "stale"     ->  412   the resource moved since you read it
PUT + If-Match: "a3f1c9..." ->  200
```

**428 is the line between a feature and an invariant.** Without it a client
that simply forgets the header races silently, and the mechanism is optional in
practice. The precondition is checked *before* the handler runs, so a refused
write never reaches the database, and checking afterwards would mean the write
happened and then the client was told it did not.

`If-None-Match` gets the cheap half: a client that already holds the current
version gets **304** and no body.

**The limit:** a body-derived ETag is not a row version. Two edits producing
the same body are indistinguishable, so A-then-B-then-A can let a stale write
through. The strong form is a version column compared inside the write's own
transaction, and only the application knows which column that is. This is the
transport half: correct, free, and a great deal better than what almost every
JSON API has today, which is nothing.

## The boundary, drawn on purpose

Every line here is a decision with a reason, and most of them have a number.
Nothing on this list is waiting to be discovered by you in production.

| | |
|---|---|
| No HTTP/3 | HTTP/1.1 and HTTP/2 are both here; QUIC is a UDP transport with its own congestion control and TLS integration, and neither cqueues nor lua-http has it. Behind a proxy this costs nothing, which is where h3 is terminated in practice |
| WebSocket holds no capability between messages | `ws:scope(fn)` is how a callback reaches the database, and the ceremony is deliberate: a pool slot acquired when a socket opens would be held until the browser tab closes. The unit of acquisition is a message, which is what a request already is |
| HTTP/2 is fuzzed and conformance tested, in two separate places | `spec/h2_framing_spec.lua` throws 22 hostile frame shapes at a live server and requires it to keep answering; its first run found a three-byte denial of service in upstream lua-http, fixed in the vendored copy. What it does not establish is h2 conformance, which `bench/h2spec.sh` answers separately |
| Uploads are buffered, not streamed | a multipart body is held in memory under `body_limit` |
| `akkar.cache.memory` is per-process | two processes have two caches, and akkar's answer to more CPU is more processes |
| Teal does not check schemas against handler output | schemas are runtime values; validation is what checks those |
| Linear scan for dynamic routes | measured: 33 µs worst case at 50 routes against ~4000 µs for one query. Revisit past ~500 dynamic routes |
| Lua 5.5 works, but you build the stack yourself | The suite passes under 5.5 with **1814 passing, 0 failures**, against **1852** on 5.4. The 38-test difference is entirely tooling: 32 are the C driver, skipped because `akkar/pq_native.so` is one path that two Lua ABIs want, and 6 are the Teal declarations, skipped because `tl` is not installed in the 5.5 tree. What is missing is packaging, not portability: no distribution ships Lua 5.5 yet, `luaossl`'s makefile has no 5.5 rung (its C compiles clean, in one `cc`), and `cqueues` needs the `lua-compat-5.3` it vendors refreshed from v0.9. `docs/runtime/lua55-stack.sh` does all of it into a prefix; 5.4 stays the default because `luarocks install akkar` cannot |
| `akkar.vm` is a sandbox, not an isolated VM | Lua 5.4 cannot make a separate state from Lua. Real within its stated limits; against hostile code, use a separate process |
| Streaming holds its capabilities open | a slow client reading a streamed export keeps a pool slot for as long as it reads |
| The database path is pgmoon **by default** | decoding rows in the interpreter is 55% of a thousand-row query. `akkar-pq` moves it, at 2.79x on a thousand rows, and is a separate rock so libpq stays optional |

## License

MIT.
