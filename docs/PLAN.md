# Plan

## 1. Objective

An **application runtime for backend services in Lua**, with safe and
predictable defaults — good enough to replace Go + Gin in the services I
maintain, and good enough for someone else to depend on.

### The objective changed, and the old one is kept here

This read "a microframework for JSON APIs in Lua 5.4" and the audience read
"my own use — no public docs, no semantic versioning, no compatibility
policy". Both were honest when written and both stopped describing the thing.

What is in the tree is no longer a microframework. Routing, middleware,
validation, database, pooling, Redis, jobs, metrics, OpenAPI, streaming,
idempotency, rate limiting, structured logging, testing doubles, tenant scope
and safe SQL is a runtime, whatever the README calls it. And "no public docs"
sat beside a 26 KB public README for as long as both existed.

Naming it a runtime is not ambition. It is what decides whether the next
question — should this be one binary? should the substrate be swappable? — is
in scope or out of it.

Three decisions are settled:

| Decision | Choice | Consequence |
|---|---|---|
| Audience | **Public, and my own services first** | Semantic versioning, a compatibility policy, and docs that answer someone who did not write it. Still aggressively opinionated; opinions are now promises. |
| Substrate | **Lua 5.4 + cqueues / lua-http, behind a contract** | No nginx, native coroutines. The substrate is a *detail*: what akkar promises is `app:get`, `req.db`, `akkar.stream` — never that cqueues is underneath. The contract in `spec/` is what makes that true rather than aspirational. |
| Shape | **One artefact** | `akkar run app.lua`, and eventually a binary. Proved feasible in `docs/RUNTIME.md`; not yet designed. |

### The rule that follows from calling it a runtime

> **The public API must never depend on the implementation of the substrate.**

`app:get`, `app:post`, `req.db`, `req.cache`, `req.log`, `akkar.stream`,
`akkar.jobs`, `akkar.sql` are akkar. `cqueues`, `lua-http`, `pgmoon`,
`lua-cjson` and `luaossl` are replaceable details.

The boundary is not intact today, and the three breaches are named rather than
assumed: `akkar.null` re-exports cjson's C sentinel as public API and compares
it by identity; five modules require cjson directly, serialization being the
one capability with no contract; and `ctx` hands a luaossl context and
lua-http's expectations straight into application configuration. Closing those
is part of the contract work, not separate from it.

### The requirement that governs the design

> As simple and as foolproof as possible. Something a first-day student could
> play with. Complexity either climbs progressively or moves somewhere else.

This coexists with "production" because the two live on different axes:
**simplicity is about the surface, reliability is about the default.** The easy
path has to also be the correct one.

### What this is not

Permanently out of scope:

- an ORM — plain SQL through the adapter;
- migrations — a separate tool;
- templating and HTML — this is a JSON API framework;
- authentication — a middleware package, not the core;
- admin panels, scaffolding, generators.

The core is routing, request/response, middleware, errors and I/O adapters.
Nothing else.

---

## 2. The complexity ladder

"Progressive complexity" only means something if it has a checkable rule:

> **Climbing a rung must never require editing code written on the rung below.**

Every rung is additive. If adding validation forced a change to the handler
signature, the ladder would be broken.

### Rung 0 — three lines, zero concepts

```lua
local app = require("akkar").new()
app:get("/", function() return { hello = "world" } end)
app:run()
```

No config, no port, no schema. `app:run()` binds `:8080` and prints where it is
listening. Returning a table becomes JSON with status 200.

### Rung 1 — parameters and status codes

```lua
app:get("/users/:id", function(req)
  return { id = req.params.id }
end)

app:delete("/users/:id", function(req)
  return akkar.no_content()
end)
```

Handlers now take `req`. **Rung 0 handlers keep working**, because Lua ignores
extra arguments.

### Rung 2 — the request body

```lua
app:post("/users", function(req)
  return akkar.created { name = req.body.name }
end)
```

`req.body` arrives decoded. Malformed JSON becomes a 400 before the handler
runs, so a handler never sees an invalid body.

### Rung 3 — validation, optional

```lua
app:post("/users", {
  body = { name = "string", email = "string?", age = "integer?" },
}, function(req)
  return akkar.created(req.body)
end)
```

A three-argument form. The two-argument form still works. The schema is an
ordinary Lua table — no tags, no classes, no codegen. This is where OpenAPI
would come from, if it is ever generated.

### Rung 4 — middleware

```lua
app:use(function(req, next)
  local started = os.clock()
  local res = next(req)
  log(req.method, req.path, res.status, os.clock() - started)
  return res
end)
```

`next` takes the request and **returns the response**. That allows
post-processing — logging a status, measuring latency, wrapping an error —
which Gin's `c.Next()` does not. No existing handler changes.

### Rung 5 — the database

```lua
app:get("/users/:id", function(req)
  local user = req.db:one("select id, name from users where id = $1", req.params.id)
  return user or akkar.not_found "user not found"
end)
```

`req.db` is injected, not global. Injected means testable: a test hands over a
fake `db` and never starts Postgres.

**Non-negotiable rule:** a handler never calls `require "pgmoon"`. All I/O goes
through a framework-owned adapter. That is what makes swapping the substrate
real rather than aspirational — see section 4.

### Rung 6 — configuration

```lua
app:run { port = 3000, db = os.getenv "DATABASE_URL" }
```

`app:run()` with no argument keeps working. Config is a table with defaults
that work.

### Rung 7 — production

```lua
app:use(akkar.timeout(5))
app:use(akkar.request_id())
app:run { port = 3000, db = ..., shutdown_grace = 10 }
```

Timeouts, correlation, graceful shutdown. All of it either `use()` or an option
to `run()`.

### Checking the rule

| Transition | Requires editing earlier code? |
|---|---|
| 0 → 1 | No. Lua ignores extra arguments. |
| 1 → 2 | No. `req.body` is a new field. |
| 2 → 3 | No. Dispatch on the type of the second argument. |
| 3 → 4 | No. `use()` never touches a handler. |
| 4 → 5 | No. `req.db` is a new field. |
| 5 → 6 | No. `run()` takes zero or one argument. |
| 6 → 7 | No. Everything is additive. |

The ladder holds.

### Where the ladder breaks elsewhere

Worth knowing this is not trivial — most frameworks get it wrong:

- **Express** — error handling requires a **four**-argument middleware,
  `(err, req, res, next)`. A different signature you only discover later, and
  one that fails silently if you get the arity wrong. Broken rung.
- **Flask** — `g` and `current_app` are thread-locals. You learn them late,
  they are magic, and they rearrange your mental model after the fact.
- **Gin** — entering a group swaps `r.GET` for `g.GET`, and middleware ordering
  turns subtle.
- **FastAPI** — genuinely good at this. `Depends` and `response_model` are
  additive. It is the model to copy, and not by coincidence the one I already
  use by preference.

---

## 3. Foolproof by default

Simplicity is a small surface. Foolproof is the default being right and the
error being loud. The invariants:

1. **Writing the response twice is impossible.** Handlers return; they do not
   mutate a context. Gin's structural defect does not exist here.
2. **`error()` in a handler becomes a 500**, with a traceback in the log and
   **never** in the response body.
3. **An unknown route becomes a 404 in JSON**, not an HTML page or a stack
   trace.
4. **Malformed JSON becomes a 400** before the handler.
5. **A duplicate route fails at startup**, naming both conflicting sites — not
   on the first request, and not with an obscure panic.
6. **Returning nothing becomes a 204**, not a hang.
7. **Returning an unserializable value gives an error naming the type**, not a
   `cjson` stack trace.
8. **Using `req.db` without configuring it** says `req.db is not configured;
   pass db = ... to app:run{}` — not `attempt to index a nil value`.
9. **Nothing global.** The framework offers no convenient place to keep mutable
   state between requests, because that is the number one Lua-on-a-server trap.

### 10. The blocking watchdog

This is the one worth the most, and it comes straight out of measurement.

The number one failure mode of Lua on a server is **a blocking call that
freezes the process silently**. A beginner never notices; a veteran loses hours
to it.

`lua_sethook` with `LUA_MASKCOUNT` catches it: when a handler runs past a
budget without yielding, the framework **logs a loud warning with a traceback**
pointing at the line.

```
[akkar] WARNING: handler blocked the loop for 253 ms without yielding
  at handlers/auth.lua:14  (bcrypt.digest)
  this stalls every request in this process.
```

Measured: a switch costs 0.16–0.35 µs, and overhead stays under 2% with
2,000-instruction slices. **It can stay on in production.**

Go does not warn about this. Node does not warn. It is a real advantage, and it
exists because the measurement was taken.

---

## 4. The adapter boundary

The project's only architectural constraint:

> A handler never touches an I/O library. All I/O goes through an adapter the
> framework owns.

**Why:** the substrate is replaceable, the API is not. If this ever migrates to
a C host — for a single static binary and true multicore in one process — the
handlers, routing, middleware and schemas survive intact. Only the adapters get
rewritten.

Without that boundary from day one, the migration stops being possible and
"we'll swap it later" becomes a lie.

It also hedges the known substrate risk: if `cqueues` stalls, the cost is the
adapter, not the framework.

**Planned adapters:** HTTP (server), Postgres, Redis, clock, log. Clock and log
are on the list because deterministic tests need both injectable.

---

## 5. Risks

| Risk | Severity | Status |
|---|---|---|
| cqueues/luaossl against OpenSSL 3.0.13 | High — kills the substrate | **Cleared.** TLS 1.3 confirmed by an external client. |
| A non-blocking Postgres driver outside OpenResty | High | **Cleared.** pgmoon yields, 7.56x out of 8x. |
| cqueues maintenance | Medium | **Confirmed real** — no release since 2020. Mitigated by the adapter boundary. |
| bcrypt freezing the process | Medium | Known. The way out is an external queue or a separate process. Undecided. |
| Multicore only across processes | Low for this use | Known, and already lived with under FastAPI. |
| LuaRocks is weak at pinning | Low | Pin versions, commit the rockspec. |

---

## 6. Milestones

No hour estimates. A prior survey guessed 36 hours for an entire framework,
which is wrong by an order of magnitude; I am not going to repeat the mistake
in the other direction.

### Done

- **Substrate proof** — see `docs/substrate/RESULT.md`.
- **Core** — router, `req`, response-by-return, and the invariants above.
- **Adapter boundary** — Postgres adapter, injected `req.db`.
- **Middleware and validation** — rungs 3 and 4.
- **In-process test client.**
- **Request body limit** — 1 MB by default, rejected before buffering, for
  both a declared `Content-Length` and a chunked body.
- **Request deadline** — 30 s by default, with immutable-winner arbitration.

The sketch overshot the original milestones: validation, middleware, mounting
and the test client all landed earlier than planned. What remains is less
glamorous and more important.

### Next

The ordered, actionable list lives in `docs/BACKLOG.md`, which also records
what is deliberately *not* being built. This section only states the shape:

1. Three design decisions that are cheap now and expensive later, chiefly the
   boundary between request data and request capabilities on `req`.
2. HTTP conformance, all inside the router.
3. Connection pooling and graceful shutdown.
4. OpenAPI generated from the schemas already declared.
