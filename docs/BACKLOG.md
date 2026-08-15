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
busted                      # 183 tests with Postgres, Redis and tl available, no database needed, ~2 s
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

### Done, continued

- **Parameter binding over the extended protocol.** pgmoon already implemented
  it; `akkar/db.lua` was hand-rolling `escape_literal` interpolation on top.
  Deleting that removed a real defect as well as the redundancy: the old binder
  substituted `$n` from highest to lowest, so a value bound to `$2` containing
  the text `$1` was rewritten on the next pass.

  Honest about what it is not: pgmoon sends an **unnamed** statement, so the
  parse happens per call and there is no server-side plan caching between
  calls. That is correct binding, not a named prepared statement.

  `spec/db_spec.lua` covers it against a live Postgres and skips cleanly when
  none is reachable, because binding done by the server cannot be tested
  against a fake.

- **The pool lives in `akkar/pool.lua`**, not inside the Postgres adapter.
  Whether a returned resource is fit for reuse is passed in as a predicate,
  because "still inside a transaction" means something to Postgres and nothing
  to Redis. The existing pool tests passed unchanged, which is the only real
  evidence that a refactor was a refactor.

- **Redis adapter**, `akkar/redis.lua`, RESP2 over a cqueues socket. Written
  rather than depended upon because no non-blocking client exists for Lua 5.4
  on cqueues — see `DECISIONS.md` §8. Reuses `akkar.pool` unchanged.

- **`response` filters and validates**, not just documents. A handler doing
  `select *` no longer leaks whatever the table holds: undeclared fields are
  removed before the body is serialised. A mismatch is a **500**, not a 422 —
  a response that breaks its own contract is a server bug, and blaming the
  client would be a lie about whose fault it is. Arrays are out of scope;
  `response` describes an object.

  `examples/crud.lua` now does `select *` deliberately, with a real
  `password_hash` column in the table, so the filtering is demonstrated rather
  than asserted.

- **Startup contract checks.** Each configured capability is acquired once at
  boot, checked against its contract (`db` needs `one`/`many`/`exec`/
  `transaction`, `cache` needs `get`/`set`/`del`), and released. A
  misconfigured adapter now fails at startup the way a duplicate route does.

  A real consequence, stated plainly: **the server refuses to start when the
  database is unreachable.** That is right for a service whose every route
  needs it and wrong for one that should come up degraded, so
  `app:run { check_capabilities = false }` opts out.

- **Capabilities are acquired lazily**, on first read of `req.db` rather than
  on every request. Found while testing the opt-out above: with the database
  down, *every* route failed — including `/health/live`, which never touches
  it — so the opt-out did not actually let anything come up degraded. Eager
  acquisition was also taking a pool slot for requests that never queried.

- **Structured logging and request correlation.** `akkar.log` has levels, JSON
  or text output and an injectable sink. A request id comes from
  `x-request-id` when the client sends one — so a trace survives across
  services — and is generated otherwise; it lands on `req.id` and on the
  response header.

  `req.log` is the logger already bound to that id, so a handler writes
  `req.log:info("charged", { amount = 10 })` and correlation happens without
  the call site doing anything. A rule nobody has to follow beats a rule
  everybody has to.

  `log` is the one capability with a **default** rather than a guard, because
  diagnostics that need configuring before they appear are diagnostics nobody
  sees. Every `io.stderr:write` inside the framework is gone; the only one left
  is the logger's own default sink.

- **Multipart uploads.** A parsed body reaches the handler as an ordinary
  table, so handlers and schemas learn no new shape: `req.body.avatar.filename`,
  `.content_type`, `.data`, `.size`.

  **Buffered, not streamed.** The body is held in memory, bounded by
  `body_limit`. A 200 MB upload needs `body_limit` set to 200 MB and then costs
  200 MB of RSS per concurrent upload. Streaming parts to disk is a different
  feature with a different shape, and pretending otherwise would be the
  framework lying about what it does.

  Tests build wire bytes by hand, because what matters is framing: a browser
  picks its own boundary and may use characters Lua patterns treat as magic,
  and file contents may contain CRLF.

- **CPU-bound work**, `akkar/work.lua`, two answers and an honest account of
  what neither fixes.

  `work.yielding(budget, fn)` gives the scheduler turns inside a Lua loop you
  control. Measured on a ~200 ms loop:

  | budget | the task | worst neighbour wait |
  |---|---:|---:|
  | no yielding | 202 ms | 200.5 ms |
  | every 50000 | 520 ms | 28.7 ms |
  | every 2000 | 557 ms | 0.9 ms |

  Neighbour latency falls by two orders of magnitude and the task itself gets
  about **2.7x slower**, because each yield costs a trip through the
  scheduler. The first draft of this module claimed the CPU cost was
  unchanged; measuring it said otherwise, and the docs now carry the numbers.

  `work.queue(cache, name)` is a Redis list — `LPUSH` to enqueue, `BRPOP` to
  consume, blocking server-side rather than polling. Deliberately not a job
  framework: no retries, no scheduling, no dead-letter queue. A failing job is
  logged and dropped, because a retry policy nobody chose hides the failure
  and repeats the side effects.

  **Neither fixes `bcrypt`.** A C function that runs 250 ms without returning
  to Lua cannot be yielded — there is no point where Lua regains control. The
  real answers are N processes, a lower cost factor chosen knowingly, or
  moving authentication behind the queue and changing what the endpoint
  promises.

- **Prometheus metrics**, `akkar/metrics.lua`, text format with no
  dependency. Counters by method/route/status, a latency histogram, and gauges
  read at scrape time so pool occupancy costs nothing until asked for.

  **Labelled by route pattern, never by request path.** `/users/:id` is one
  series; `/users/1`, `/users/2`, … would be one per user. Unbounded label
  cardinality is the standard way to take down a metrics backend, and a
  framework that offers `req.path` as a label is handing that over. Verified:
  six distinct paths including a probe for `/wp-admin/…` produce four series.

  Also added `akkar.raw(body, content_type)`, since `/metrics` is text rather
  than JSON — useful for a CSV export or an SVG too.

- **Benchmarks**, `bench/`, run on a c5.2xlarge — see `bench/RESULTS.md`.
  Methodology borrowed from `uruquim-odin`'s `planning/benchmark-methodology.md`:
  verify every response, alternate the order, discard a warm-up, derive the
  noise floor from the machine, pin whole physical cores.

  Results: **linear scaling across physical cores** (1.00x, 1.00x, 1.00x),
  with hyperthreads worth about 18% more. `/ping` reaches 31.8k req/s against
  `/users/:id` at 2.7k, so the database dominates a real request twelve to
  one. One blocking handler multiplies neighbour p99 by ten and
  `work.yielding` takes it back to baseline.

  Two runs were wrong first, both instructively: seven of eight processes had
  died with `EADDRINUSE` while the survivor answered correctly, which found
  the missing `SO_REUSEPORT`; and an affinity mask that split sibling threads
  read as poor scaling when it was contention. Both are written up.

- **Strict mode**, `akkar/strict.lua`, and the whole suite runs under it.

  Global-by-default is the most common criticism of Lua at scale, and on a
  server it is worse than a typo: a global written inside a handler outlives
  the request and is visible to the next one, in the same process, for another
  user.

  `PLAN.md` invariant 9 has said "nothing global" since the beginning and
  nothing enforced it. akkar measures clean — **zero global writes across every
  module, checked in the bytecode** — but that was discipline, and discipline
  does not extend to handlers someone else writes.

  Now `app:run { strict = true }` turns an undeclared global into an error
  where it happens, with a message that says why it matters rather than only
  that it happened. Opt-in, because a false positive taking down a live server
  is worse than the bug it was hunting. `spec/000_strict_first_spec.lua`
  installs it before every other spec, so the invariant is checked against
  akkar's own code on every run.

- **Teal type declarations**, `types/akkar.d.tl`.

  The strongest criticism of Lua for anything carrying real responsibility is
  that nothing checks your intent before the program runs. Writing akkar
  carefully does not answer that. Teal — a typed dialect compiling to plain Lua
  — does, and the ecosystem already has the pattern: a `-tl-type` package
  carrying declarations for a library written in ordinary Lua. akkar is not
  rewritten; a handler written in Teal simply gets checked.

  Verified against a handler written to fail in three specific ways:

  ```
  invalid key 'parms' in record 'req' of type akkar.Request
  in local declaration: n: got string, expected integer
  unknown field timout
  ```

  That last one is now caught in **three layers**: Teal at compile time,
  config validation at startup, strict mode at runtime.

  `spec/teal_spec.lua` runs the compiler against the declarations and both
  example handlers, so they cannot drift. A declaration file that has drifted
  is worse than none — it asserts guarantees that no longer hold. Skipped when
  `tl` is absent, so nobody needs Teal to work on akkar.

  **What it still cannot catch**, said so nobody assumes otherwise: whether a
  schema matches the table a handler actually returns. Schemas are values built
  at runtime; validation is what checks them. Types narrow the gap, they do not
  close it.

- **In-memory adapters**, `akkar.db.memory` and `akkar.cache.memory`, taken
  from the pattern in `druse-crystals` where every capability ships a
  `_memory` alongside its real backend.

  The point is not to have a fake. It is that **the fake is a real, tested,
  shared implementation of the same contract** instead of something each test
  file reinvents. The specs had been writing `fake_db` inline: every copy
  drifts, none is checked against the contract, and nobody outside the
  repository gets one at all.

  The two are honestly different, and the docs say which is which.
  `akkar.cache.memory` is a **real implementation** — a cache is a table with
  expiry, and that is buildable in memory — so it obeys the whole contract,
  including Redis's `-1`/`-2` ttl semantics, and is usable in a single-process
  deployment that does not want to run Redis. `akkar.db.memory` is a
  **stand-in**: it matches queries against programmed responses and does not
  parse SQL, because pretending to execute SQL would be a second, worse
  database whose disagreements with Postgres surface as tests that pass and
  production that does not.

  A query nobody programmed raises rather than returning nil, since a test
  silently receiving nil from an unplanned query is asserting the wrong thing.
  Swapping the inline fake for the real adapter immediately caught a spec
  calling `req.db:many()` with no SQL at all — something no handler does, which
  the old fake had been hiding by ignoring its argument.

- **Memory metrics.** `akkar_lua_heap_bytes` and
  `akkar_process_resident_bytes` are in every scrape. Two numbers because they
  answer different questions: the Lua heap says whether the application is
  holding tables, RSS says what the OS thinks the process costs including the
  C side. A leak in one and not the other says which half to look at.

- **The job queue split from its storage**, `akkar.jobs` with
  `akkar.jobs.redis` and `akkar.jobs.memory`. The second half of the crystals
  pattern: `jobs` holds the logic, a store holds only persistence.

  `work.queue` had the two fused, which meant a Postgres-backed queue could
  not exist without reimplementing the semantics beside it — and the two would
  then be free to disagree. A store now answers three methods, `enqueue`,
  `dequeue` and `depth`, and everything else is semantics.

  The justification is visible in the tests: the same six semantic checks run
  against **both** stores, memory and Redis, from one description. If the
  semantics lived in the backend that would be impossible to write.

  `work.queue(cache, name)` still works and forwards, so nothing breaks.

- **Comparison against Gin and FastAPI**, `bench/compare/RESULTS.md`.

  | `/ping` | | `/users/:id` | |
  |---|---:|---|---:|
  | gin | 163,014 | gin | 26,212 |
  | fastapi | 40,245 | fastapi | 9,316 |
  | akkar | 28,850 | akkar | 2,744 |

  **The headline is a correction.** This project had concluded from akkar alone
  that "the framework is not the limit; Postgres is". Gin gets 26k from that
  same Postgres, so it never was. The same query costs 32 µs through pgx,
  82 µs through asyncpg and **330 µs through pgmoon**, which parses the wire
  protocol in pure Lua. Pool size was ruled out first: akkar is flat at 2,740
  whether the pool is 10 or 25, while Gin climbs from 26k to 32.6k.

  akkar's own overhead is 34.7 µs against FastAPI's 24.8 µs — the same order.
  **The gap is the driver, not the language**, and it sits squarely inside the
  adapter boundary, which is the first time that boundary has been justified by
  a number rather than by principle.

  Three of the four predictions recorded in advance were wrong, and they are
  scored in the results rather than quietly dropped.

  One near-miss worth keeping: the first run had FastAPI at 2,433 req/s,
  because it was installed without `uvloop` and `httptools`. That would have
  published akkar as 11.8x faster than FastAPI when it is in fact 1.4x slower.
  The equivalence gate does not catch a competitor being accidentally
  handicapped — that check is human, and it nearly did not happen.

### Still open

Nothing here blocks using akkar. Two items are closed by measurement rather
than by work, the soak has now been run and left one question behind it, and
the milestone everything else was clearing the way for is still the milestone.

- **Port a real service off Gin.** `docs/PLAN.md` names this as the milestone
  never reached, and it is the only honest test of completeness — it will
  surface ten to twenty gaps no planning predicts. Everything since has been
  closing the gaps already known to block it, and none remain.

- **Performance comparison against Gin and FastAPI**, `bench/compare/`.
  `METHOD.md` was written before any service existed and before any number
  did, because a threshold picked after seeing the result is a
  rationalisation.

  The three services are semantically equivalent and `equivalence.sh` proves
  it before any clock starts — same JSON, same statuses, same validation, same
  error shapes. It has already earned its place: it caught akkar reporting
  `min is 1` for `/users/0` where the other two said `expected integer`. Zero
  *is* an integer, so akkar was the precise one, and the fix levelled the other
  two **up** rather than degrading akkar to match.

  Predictions are recorded in `METHOD.md` in advance, so the result cannot be
  retrofitted into a story afterwards.

- ~~**Soak test.**~~ **Run**, 45 minutes — `bench/study/results/soak.log`, written
  up as section 7 of `bench/study/RESULTS.md`.

  Throughput drifted **+0.048%** from the first quarter to the last, resident
  memory went 26 MB → 27 MB and then sat there for forty-four minutes,
  descriptors climbed 60 → 80 by minute seventeen and stopped, and there were
  **zero errors in roughly 19.9 million requests**. No leak of memory, of
  descriptors or of database connections — which is the one thing this
  project's ten-second measurements were never able to assert.

  **The specific question it was supposed to answer is still open.**
  `/users/:id` p99 was 191 ms at one process with 100 concurrent connections
  against `pool_size = 10`, so ninety requests were queuing for a connection.
  The soak ran 16 connections against a capacity of 20, so nothing queued: it
  proves the absence of a leak and says nothing about a saturated pool. Pool
  sizing against concurrency remains undocumented, and the run that produces
  the guidance has to push past capacity.

  Forty-five minutes also is not a night. The slope is flat enough to rule out
  a leak at this timescale and not long enough to speak about a weekly one.

- **Prefix-tree routing — measured, and the answer is no.** Worst-case dynamic
  match is 33 µs at 50 routes and 95 µs at 200, against roughly 4000 µs for one
  Postgres query. A prefix tree would buy 0.8% of a request. Revisit past ~500
  dynamic routes; until then this is optimising noise.
- **Lua 5.5 — blocked, and not by a decision.** `cqueues` pins `lua == 5.4`
  and has had no release since 2020. Supporting 5.5 would mean building Lua
  5.5, forking `cqueues`, possibly adapting its C to 5.5 API changes, and
  repeating for `luaossl`. That is taking on maintenance of a C library, not a
  backlog item. It is the strongest argument yet for the adapter boundary, and
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

- ~~**`akkar doctor`**~~ — **built**, `akkar/doctor.lua` and `bin/akkar`.

  What it turned into, beyond the sketch: three levels rather than a list,
  because a doctor that cries wolf gets ignored. `FAIL` exits 1 so a deploy
  step can gate on it; a missing optional library is a warning, since
  "luaossl is not installed" must not block a service speaking plain HTTP;
  an unreachable declared database is a failure, since the server refuses to
  boot in that state anyway.

  Duplicate routes were dropped from the sketch — they already fail at
  startup naming both sites, so there was nothing to add. What replaced them
  is the case no invariant catches: `/users/:id` and `/users/:name` compile
  to the same pattern and the second can never match.

  Two defects it found in itself on the first run. The shadow check compared
  routes by pattern, which excluded exactly the case above, since those two
  patterns are identical. And the OpenSSL version printed as `805306576` —
  a true fact nobody can use — because luaossl returns the packed
  `OPENSSL_VERSION_NUMBER`.
- **Generated clients and generated test data**, downstream of OpenAPI.
