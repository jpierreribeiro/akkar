# akkar

A microframework for JSON APIs in Lua 5.4, on `cqueues` and `lua-http`.

No nginx, no C, no build step. One coroutine per request.

```lua
local app = require("akkar").new()
app:get("/", function() return { hello = "world" } end)
app:run()
```

---

## Status

**Under construction, for my own use.** The substrate is proven and the
ergonomics are settled — see `docs/substrate/RESULT.md`. What is missing is the
production layer: connection pooling, timeouts, graceful shutdown.

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

### 2. All I/O goes through adapters the framework owns

A handler never calls `require "pgmoon"`. It receives `req.db`. That is what
makes in-process testing possible, and what keeps the substrate replaceable.

Reading something that was never configured gives a useful message rather than
`attempt to index a nil value`:

```
req.user is not set; this route is missing the authentication middleware
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

**In-process testing.** No socket, no port, no database — but through the same
middleware, validation and dispatch chain a real request travels:

```lua
local res = app:test():post("/users", { body = { email = "x@y.z" } })
assert.equal(422, res.status)
assert.equal("required", res.body.fields["body.name"])
```

The whole suite runs in 0.11 s.

---

## Running the examples

The examples need a database:

```sh
docker run -d --name akkar-pg \
  -e POSTGRES_PASSWORD=akkar -e POSTGRES_DB=akkar \
  -p 55432:5432 postgres:16-alpine

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
| `docs/DECISIONS.md` | seven design decisions, with alternatives side by side |
| `docs/substrate/RESULT.md` | substrate proof: TLS, driver concurrency, CRUD |
| `examples/crud.lua` | ten scenarios against a real Postgres |

## Known gaps

Audited by probing a running server, not written from memory.

| | |
|---|---|
| **No request body size limit** | a 5 MB body was accepted and written straight to Postgres — a denial-of-service vector |
| **No request timeout** | nothing stops a handler from hanging forever |
| `405` answers `404` | a `POST` to a `GET`-only route should answer `405` with `Allow` |
| `HEAD` and `OPTIONS` answer `404` | no CORS preflight is possible |
| Trailing slash | `/users/` does not match `/users` |
| Route params are not percent-decoded | query strings are; paths are not |
| No connection pool | one connection per request, ~4 ms of handshake every time |
| No graceful shutdown | |
| Interpolated literals, not prepared statements | safe against injection, but the extended protocol is the right answer |
| `req.headers` is inconsistent | a lua-http object on the server, a plain table in the test client |
| No Redis adapter | |
| Non-JSON bodies answer 400 | no form-urlencoded, no multipart uploads |
| Linear scan for dynamic routes | a prefix tree is the fix, but this is not urgent |

## License

MIT.
