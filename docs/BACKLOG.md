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
busted                      # 41 tests, no database needed, ~2 s
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
- **Redis adapter**. The contract question is settled (`DECISIONS.md` §8);
  what remains is choosing a library and writing the adapter.
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
