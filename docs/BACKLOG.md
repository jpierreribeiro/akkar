# Backlog

Ordered and actionable. `docs/PLAN.md` holds the reasoning; this file holds the
work. Read section 0 first — the environment is the part that is not obvious.

---

## 0. Getting a working environment

LuaRocks is **not** installed system-wide. It was built from source into
`~/.local`, and rocks live in `~/.luarocks`. Nothing works without these two
lines:

```sh
export PATH="$HOME/.local/bin:$PATH"
eval "$(luarocks path --bin)"
```

Then:

```sh
busted                      # 17 tests, no database needed, ~2 s
```

Only the examples and the substrate scripts need Postgres:

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
```

**Verify against a running server, not only through `busted`.** Both defects
found so far were invisible to the in-process suite: the oversized-body hole,
and a `headers:get` call that returned zero values rather than `nil` and broke
every `GET`. `lua-http` behaviour is only exercised by a real request.

---

## 1. Decisions to settle before writing more

These are cheap now and expensive later. None of them needs a study; they need
a choice, recorded in `docs/DECISIONS.md`.

### 1.1 The boundary between request data and request capabilities

`req` carries two different kinds of thing today:

```lua
method, path, query, body, headers    -- request data, derived from HTTP
db, user                              -- capabilities, injected from app:run{}
```

The risk is that `req` grows into a service locator: `req.cache`, `req.queue`,
`req.mail`, `req.storage`, `req.metrics`, and on.

This is urgent for one specific reason: **if `req.db` ever becomes `ctx.db`, it
breaks the ladder rule**, because every handler already written would have to
be edited. It is the one open question that cannot be deferred.

Recommendation: keep `req.db` flat, but close the set by rule — only
infrastructure capabilities declared in `app:run{}` appear on `req`, never
anything belonging to the application domain. `req.mailer` does not qualify. It
is the admission criterion that prevents the sprawl, not the syntax.

### 1.2 Adapters: own the contract, not the implementation

The README currently says "all I/O goes through adapters the framework owns".
Owning implementations for Postgres, Redis, S3, SMTP and queues makes akkar the
ecosystem's bottleneck.

Better: **akkar owns the contract; libraries implement it.** akkar defines
lifecycle, testability and error semantics for a capability, and ships a
Postgres adapter as the reference — not as the only permitted one.

### 1.3 The thesis in the README

Today: *"A microframework for JSON APIs in Lua 5.4."* True, but it says what it
is rather than why it should exist. What the code actually does is closer to:

> akkar turns common server mistakes into impossible states or explicit errors.

Handlers return, so double responses cannot happen. Adapters exist, so
untestable I/O cannot happen. `transaction(fn)` exists, so an abandoned `BEGIN`
cannot happen. Validation exists, so invalid input never reaches a handler. The
watchdog exists, so silent blocking gets reported. Body limits and deadlines
exist, so an unbounded request cannot happen.

---

## 2. HTTP conformance

All of it lives in the router, so it is one sitting. Confirmed by probing a
running server:

| Today | Should be |
|---|---|
| `POST` to a `GET`-only route → `404` | `405` with an `Allow` header |
| `HEAD /users` → `404` | the `GET` handler, headers only, no body |
| `OPTIONS /users` → `404` | a preflight answer; CORS is impossible without it |
| `/users/` → `404` | matches `/users` |
| `/users/%31` → param is `"%31"` | param is `"1"`; query strings already decode |

Normalize `req.headers` in the same pass: it is a `lua-http` object on the
server and a plain table in the test client, which is why `examples/crud.lua`
has to write `req.headers.authorization or (req.headers.get and
req.headers:get "authorization")`. That is ugly and it is the framework's
fault.

---

## 3. Connection pooling

`akkar/db.lua` opens a connection per request — roughly 4 ms of handshake on
every call, and under load it will exhaust the Postgres `max_connections`.

What it has to get right:

- a cap plus a waiting queue, **yielding the coroutine when full**, never
  blocking;
- returning the connection to the pool at the end of the request **including
  when the handler raised** — the same discipline `transaction` already has, so
  a connection cannot leak;
- discarding a connection left inside an open transaction or otherwise
  unhealthy;
- a test that covers exhaustion, which is where this kind of code is usually
  wrong.

---

## 4. Graceful shutdown

The state machine was worked out on an earlier project and is worth reusing:

```
RUNNING → STOP_ACCEPTING → CANCELLING → DRAINING → CLOSING_BACKEND → STOPPED
```

with stalled variants of `DRAINING` and `CLOSING_BACKEND`, and one rule that
matters more than the diagram:

> A stalled state publishes a diagnostic and **changes no ownership**. It never
> releases the backend, a VM, a task or a buffer.

In other words: when the drain hangs, warn and keep waiting. Forcing the close
is what corrupts things.

---

## 5. OpenAPI from the schemas

The highest-return item on this list, and the one that changes who akkar is
compared against.

The schema is already declared for validation:

```lua
app:post("/users", {
  body = { name = "string", email = "string?" },
}, handler)
```

The principle worth stealing from FastAPI is not `Depends`. It is that **one
declaration by the programmer should be reused by the framework as many times
as possible**. Today that declaration feeds validation and nothing else. It
should also produce the OpenAPI document, and it must never require declaring
the same information twice.

This probably needs a `response` schema alongside `body`, `params` and `query`.

---

## 6. Smaller, unordered

- **Prepared statements** over the extended protocol. `akkar/db.lua`
  interpolates `$1` through `escape_literal` — safe against injection, but not
  the right mechanism.
- **Non-JSON bodies**: form-urlencoded and multipart both answer `400` today.
- **Redis adapter**, once 1.2 has settled the contract.
- **Structured logging.**
- **Prefix-tree routing.** Dynamic routes are a linear scan. Not urgent — say
  so honestly rather than optimizing early.
- **Where CPU-bound work runs.** `bcrypt` at cost 12 takes ~250 ms *by design*
  and will stall the process. The watchdog reports it; it does not solve it.
  The answers are an external queue or a separate process. Undecided.
- **Lua 5.5.** The blocker is `cqueues`, which pins `lua == 5.4` and has had no
  release since 2020 — **not** `lua-http`, which accepts `>= 5.1`. Being a
  version behind is awkward for something calling itself modern stock Lua, and
  this is not in our hands. It is an argument for the adapter boundary, and
  eventually for owning the substrate.

---

## What is deliberately not being built

Written down because the list keeps trying to grow.

| Not building | Why |
|---|---|
| ORM, migrations, templating, HTML, admin, scaffolding | Out of scope in `PLAN.md` §1, permanently. |
| Adapters for payments, storage, mail | Past "JSON API framework". Own the contract, let libraries implement. |
| `akkar build` producing a self-contained binary | Attractive, but Redbean is a *different substrate*, and `cqueues` is a C module. That is a substrate change, not a packaging step. |
| CI, docs site, semantic versioning, compatibility policy, ADRs | The audience is my own use. Each costs before it pays. |
| A DX laboratory implementing the same API in eight frameworks | The cheap version captures most of the value: compare against Gin and FastAPI, which I already write daily and which need no toolchain. Read the docs for the rest. |

## Ideas parked, not rejected

- **`akkar doctor`** — one command reporting runtime versions, route count,
  duplicate routes, unconfigured dependencies, database reachability and which
  production defaults are active. Attractive specifically for Lua, where "which
  combination of libraries and versions actually works" is a real and recurring
  pain: `pgmoon` needs `mime` without declaring it, `luaossl` compiles with
  deprecation warnings against OpenSSL 3, `cqueues` pins an exact Lua version.
- **Generated clients and generated test data**, downstream of OpenAPI.
