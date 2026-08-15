# akkar

A microframework for JSON APIs in Lua 5.4, on `cqueues` and `lua-http`.

No nginx, no C, no build step. One coroutine per request.

**akkar turns common server mistakes into impossible states or explicit
errors.** Handlers return, so a double response cannot happen. I/O goes through
adapters, so untestable I/O cannot happen. `transaction(fn)` is closure-scoped,
so an abandoned `BEGIN` cannot happen. Validation runs first, so invalid input
never reaches a handler. Bodies and deadlines are bounded by default, so an
unbounded request cannot happen. And when something blocks the event loop —
the one failure Lua servers hide best — it says so, with a file and a line.

```lua
local app = require("akkar").new()
app:get("/", function() return { hello = "world" } end)
app:run()
```

---

## Status

**Under construction, for my own use.** The substrate is proven and the
ergonomics are settled — see `docs/substrate/RESULT.md`. Body limits, request
deadlines, connection pooling, graceful shutdown and OpenAPI generation are in.
See "Known gaps" for what is not.

There is no compatibility policy. The API will change.

## Installing

```sh
luarocks install --local --only-deps akkar-dev-1.rockspec
eval "$(luarocks path --bin)"
busted
```

Needs Lua 5.4 and OpenSSL headers. Tested against OpenSSL 3.0.13.

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

Writing the response twice becomes **structurally impossible** — there is no
`c.JSON()` to call again. And there is no `Abort()` + `return` pair where
forgetting the `return` keeps the handler running.

### 2. All I/O goes through adapters, and akkar owns the contract

A handler never calls `require "pgmoon"`. It receives `req.db`. That is what
makes in-process testing possible, and what keeps the substrate replaceable.

akkar defines the contract — for a database, four methods — and ships a
Postgres adapter as the reference, not as the only permitted one. Owning every
driver would make akkar the bottleneck.

`req` stays deliberately small. Capabilities come from a **closed set** — `db`,
`cache`, `log`, `clock` — because `req` accumulating `req.mailer`,
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

Measured: 0.16–0.35 µs per switch, under 2% overhead. It stays on in
production. Go does not warn about this; neither does Node.

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

**Closure-scoped transactions.** Commit at the end, rollback on any error —
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
prefix — and it stays testable on its own, unaware of where it lives:

```lua
local health = akkar.new()
health:get("/live", function() return { status = "live" } end)
app:mount("/health", health)

health:test():get "/live"            -- standalone
app:test():get "/health/live"        -- mounted
```

**A `response` schema is enforced, not just documented.** Declaring the shape
filters undeclared fields out of the body — a handler doing `select *` cannot
leak `password_hash` — and a mismatch is a 500, because a response that breaks
its own contract is the server's fault, not the client's:

```lua
app:get("/users/:id", {
  response = { id = "integer", name = "string", email = "string?" },
}, function(req)
  return req.db:one("select * from users where id = $1", req.params.id)
end)
```

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
validation is the schema in the document — no route describes itself twice:

```lua
local openapi = require "akkar.openapi"
openapi.serve(app, "/openapi.json", { title = "My API", version = "1.0.0" })
```

`v.string { min = 1, max = 100 }` becomes `minLength`/`maxLength`, `one_of`
becomes `enum`, `match` becomes `pattern`, `/users/:id` becomes
`/users/{id}`, and the `422` akkar itself produces is documented without
anyone declaring it.

**In-process testing.** No socket, no port, no database — but through the same
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

| | |
|---|---|
| `docs/PLAN.md` | objective, the verified ladder, invariants, risks, milestones |
| `docs/DECISIONS.md` | nine design decisions, with alternatives side by side |
| `docs/BACKLOG.md` | what is done, what is next, and what is deliberately not built |
| `docs/substrate/RESULT.md` | substrate proof: TLS, driver concurrency, CRUD |
| `examples/crud.lua` | ten scenarios against a real Postgres |

## Safe defaults

`app:run()` with no arguments is already production-shaped. Configuration
appears only when you disagree with the default.

| Default | Value | Override |
|---|---|---|
| Request body limit | 1 MB | `app:run { body_limit = 5 * 1024 * 1024 }` |
| Request deadline | 30 s | `app:run { timeout = 5 }` |
| Connection pool size | 10 | `db.connect { pool_size = 25 }` |
| Shutdown grace | 10 s | `app:run { shutdown_grace = 30 }` |

Configured capabilities are checked against their contracts at startup, so a
misconfigured adapter fails at boot rather than on the first request that
touches it. This means **the server refuses to start when the database is
unreachable** — right for a service whose every route needs it, wrong for one
that should come up degraded, so `app:run { check_capabilities = false }` opts
out. Capabilities are acquired on first use, so a route that never queries
takes no connection and keeps answering while the database is down.

Signals are opt-in, because a library that installs handlers behind an
application's back fights whatever else the process is doing:

```lua
app:handle_signals()      -- SIGTERM and SIGINT call app:stop()
app:run()
```

An oversized body is rejected with `413` before it is buffered — both when
`Content-Length` declares it and when a chunked body simply keeps arriving. A
request that overruns its deadline answers `503`.

The deadline is cooperative: it fires while the handler is yielding on I/O. A
handler burning CPU in a tight loop is not interrupted by it — that is what the
watchdog reports instead. The two cover different failures on purpose.

Timeout arbitration follows one rule: **the winner is decided by the first
arbitrating event and a late event never overturns it.** A handler that
finishes at 4.99 s against a 5 s deadline has completed, and is never reported
as a timeout.

## Known gaps

| | |
|---|---|
| Uploads are buffered, not streamed | a multipart body is held in memory under `body_limit`; streaming parts to disk is a separate feature |
| Linear scan for dynamic routes | measured: 33 µs worst case at 50 routes, against ~4000 µs for one query. A prefix tree would buy 0.8% of a request; revisit past ~500 dynamic routes |
| `bcrypt` and other C calls still stall the process | `work.yielding` only helps loops written in Lua; a C function that does not return cannot be yielded. Run N processes or move it behind the queue |
| Pinned to Lua 5.4 | the blocker is `cqueues`, which pins `lua == 5.4` and has had no release since 2020 — not `lua-http`, which accepts `>= 5.1` |

## License

MIT.
