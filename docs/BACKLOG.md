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
busted                      # 57 tests, no database needed, ~2 s
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

**Verify against a running server, not only through `busted`.** Every defect
found so far was invisible to the in-process suite until someone probed a live
server: the oversized-body hole, a `headers:get` returning zero values rather
than `nil` which broke every `GET`, and cjson's null sentinel rejecting
`{"email": null}` on an optional field. `lua-http` and `cjson` behaviour is
only exercised by a real request.

The habit that finds them: pick ten edge cases nothing tests yet, throw them
at a running server, and read the log as well as the responses.

---

## 1. Decisions settled ✅

Recorded in `docs/DECISIONS.md` sections 7 and 8, and enforced in code.

- **The capability boundary.** `req` stays flat, and the capability set is
  **closed** to `db`, `cache`, `log`, `clock`. `app:run{}` and `app:test{}`
  reject unknown options instead of ignoring them, which closes the set and
  also fixes a separate hazard: `app:run { timout = 5 }` used to run silently
  with the 30 s default.
- **Adapters own the contract, not the implementation.** akkar defines what a
  database must offer — `one`, `many`, `exec`, `transaction` — and ships the
  Postgres adapter as the reference, not the only permitted one.
- **The thesis**, now at the top of the README: akkar turns common server
  mistakes into impossible states or explicit errors.

Left open deliberately: whether akkar should verify at startup that a
configured capability satisfies its contract, so a bad adapter fails at boot
rather than on the first request — the way duplicate routes already behave.

---

## 2. HTTP conformance ✅

All of it landed in the router, verified against a running server:

| | |
|---|---|
| `405` with `Allow` | `DELETE /users` → `405`, `allow: GET, POST` |
| `HEAD` | served by the `GET` handler, same headers, zero body bytes |
| `OPTIONS` | answered from the routing table, no handler written: `allow: GET, HEAD, OPTIONS, POST` |
| Trailing slash | `/users/` and `/users/1/` match |
| Percent-decoded params | `/users/%31` resolves to id `1` |
| `req.headers` | a plain lowercase table from both the socket and the test client |

Decoding happens per parameter rather than over the whole path, so `%2F`
cannot smuggle a segment separator into a parameter.

`examples/crud.lua` lost its
`req.headers.authorization or (req.headers.get and req.headers:get "...")`
dance, which was the framework leaking lua-http into user code.

---

## 3. Connection pooling ✅

`akkar.db.connect` pools by default, `pool_size = 10`. `pool_size = 0` opts
out and opens per request.

The two things that decide whether pool code is right:

- **Exhaustion yields, it does not block.** A waiter parks on a
  `cqueues.condition`, so other requests keep running while it waits. There is
  a test asserting an unrelated coroutine runs while a waiter is parked.
- **The release happens on every exit** — normal return, thrown response,
  handler error, deadline — because a connection that leaks on the error path
  leaks exactly when load is highest. It is the framework's job, not the
  handler's.

A connection left inside a transaction, or whose rollback failed, is discarded
rather than returned, so the next request cannot inherit an open `BEGIN`. A
failed open returns its slot instead of wedging the pool.

Verified against a real Postgres: 12 queries of 0.2 s through a pool of 3 took
0.84 s, against 0.80 s predicted by four waves of three, and the backend never
saw more than the cap.

---

## 4. Graceful shutdown ✅

```
RUNNING → STOP_ACCEPTING → DRAINING → CLOSING → STOPPED
```

`app:stop(grace)` stops accepting, drains what is in flight, then closes pools
and the listener. Idempotent.

The rule that matters more than the diagram:

> **A stalled drain publishes a diagnostic and changes no ownership.**

When the grace period expires akkar says so and keeps waiting. It does not
force connections closed, because forcing truncates a response mid-write and
corrupts what the client already received.

Verified against a real server: a 1.2 s request under a 0.3 s grace produced

```
[akkar] shutdown STALLED: 1 request(s) still in flight after 0.3s;
        still waiting, nothing is being forced
```

and the request still completed with 200.

Still missing: nothing installs a `SIGTERM` handler. `app:stop` has to be
called by the embedding program, which is correct for a library but means a
container stop does not yet drain.

---

## 5. OpenAPI from the schemas ✅

`akkar.openapi` generates an OpenAPI 3.1 document from the schemas already
declared for validation. Nothing is described twice.

```lua
local openapi = require "akkar.openapi"
openapi.serve(app, "/openapi.json", { title = "My API", version = "1.0.0" })
```

What carries across, because it reads the same tables `akkar.validate` reads:

| Declared | Appears as |
|---|---|
| `v.string { min = 1, max = 100 }` | `minLength`, `maxLength` |
| `v.integer { min = 1, max = 100 }` | `minimum`, `maximum` |
| `v.string { one_of = {...} }` | `enum` |
| `v.string { match = "..." }` | `pattern` |
| `"string?"` | absent from `required` |
| `default = 20` | `default` |
| `/users/:id` | `/users/{id}` |

Statuses akkar produces on its own — `422` where a schema exists, `500`
everywhere — are documented without anyone declaring them.

A route with no schema still appears, with its path parameters typed as
strings: an undocumented endpoint is worse than a thinly documented one. A
mounted sub-app is documented at the prefix it answers on.

`response` is a new route option describing the success body. It is
**documentation only** — akkar does not yet validate or filter what a handler
returns against it, unlike FastAPI's `response_model`. Doing so is a real
decision, not an oversight, and it is not made yet.

Route options are now checked the same way `app:run{}` options are, so
`app:post("/x", { bdy = ... })` fails at startup instead of leaving a route
that accepts anything while looking validated.

---

## 6. Smaller

### Done

- **Non-JSON bodies.** `application/x-www-form-urlencoded` is accepted,
  because an HTML form cannot send JSON and answering 400 to one was the
  framework calling a normal web request malformed. A `charset` parameter on
  the content type is tolerated. An unrecognised type gets **415**, not 400:
  the body may be perfectly well formed and simply not something this server
  reads, and 400 would blame the client for the wrong thing.
- **CORS**, as `akkar.cors{}` middleware rather than core, because trusted
  origins are policy only the application knows. What akkar contributes is
  that the preflight advertises the router's **real** `Allow` list instead of
  a hardcoded guess.
- **Signals.** `app:handle_signals()` installs `SIGTERM` and `SIGINT` handlers
  that call `app:stop`. Not automatic — a library that installs signal
  handlers behind an application's back fights whatever else the process is
  doing — but one line rather than an exercise. Verified: a `SIGTERM` with a
  request in flight let it finish with 200 before the process exited.

### Still open

- **Prepared statements** over the extended protocol. `akkar/db.lua`
  interpolates `$1` through `escape_literal` — safe against injection, but not
  the right mechanism.
- **Validating handler output against `response`.** Today it is documentation
  only. FastAPI's `response_model` also filters and validates. Whether akkar
  should is a real decision: it catches a handler leaking a field, and it also
  means a handler can fail on the way out.
- **Multipart uploads.** Streaming them properly interacts with the body
  limit, so this is not just another content type.
- **Redis adapter.** The contract question is settled (`DECISIONS.md` §8);
  what remains is choosing a library and writing it.
- **Structured logging**, and `log` as a real capability rather than a slot.
- **Startup contract checks** — verifying a configured capability satisfies
  its contract at boot rather than on the first request, the way duplicate
  routes already fail.
- **Prefix-tree routing.** Dynamic routes are a linear scan. Not urgent — say
  so honestly rather than optimizing early.
- **Where CPU-bound work runs.** `bcrypt` at cost 12 takes ~250 ms *by design*
  and will stall the process. The watchdog reports it; it does not solve it.
  The answers are an external queue or a separate process. Undecided.
- **Lua 5.5.** The blocker is `cqueues`, which pins `lua == 5.4` and has had no
  release since 2020 — **not** `lua-http`, which accepts `>= 5.1`. Not in our
  hands. An argument for the adapter boundary, and eventually for owning the
  substrate.

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
