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

  **The question it was supposed to answer is now answered**, by a second run
  above capacity — `bench/study/saturation.sh`, written up as section 8 of
  `bench/study/RESULTS.md`. The rule:

  > Offered concurrency up to **twice** the pool is free. Past that it is paid
  > for in the tail, and it buys nothing.

  Throughput peaks at 2x capacity and *falls* beyond it, while p99 goes from
  6.22 ms to 37.70 ms to 82.38 ms. So size the pool at about half the peak
  concurrency you intend to accept, and refuse the rest with
  `akkar.limit.concurrent` rather than queue it.

  Three of the four predictions recorded before that run were wrong, and they
  are scored in the results rather than quietly dropped.

  Forty-five minutes also is not a night. The slope is flat enough to rule out
  a leak at this timescale and not long enough to speak about a weekly one.

- **Prefix-tree routing — measured, and the answer is no.** Worst-case dynamic
  match is 33 µs at 50 routes and 95 µs at 200, against roughly 4000 µs for one
  Postgres query. A prefix tree would buy 0.8% of a request. Revisit past ~500
  dynamic routes; until then this is optimising noise.
- **Lua 5.5 — done, and this entry was wrong twice on the way there.** akkar's
  whole suite passes under Lua 5.5: **1792 passing, 0 failures**,
  against 1830 on 5.4. The 38-test difference is tooling, measured rather than
  assumed: 32 are `akkar.pq`'s half, which skips because one `pq_native.so`
  path serves two Lua ABIs, and 6 are `teal_spec`, which skips because `tl` is
  not installed in the 5.5 tree. Nothing in akkar had to change for any of it.

  Two named blockers, both innocent. The first version of this entry said
  "`cqueues` pins `lua == 5.4`… supporting 5.5 would mean forking it". The
  second said the fork was unnecessary but **"the real blocker is `luaossl`",**
  on the evidence that its makefile declares `KNOWN_APIS = 5.1 5.2 5.3 5.4`.

  That was reading a build system and calling it a compiler. luaossl's C
  compiles against Lua 5.5 with zero errors and zero warnings:

      cc -O2 -std=gnu99 -fPIC -shared -o _openssl.so \
         -I$PREFIX/include src/openssl.c -lssl -lcrypto

  One translation unit, no makefile, no patch. **The library was never the
  problem; its `KNOWN_APIS` ladder was.** cqueues was the same shape one level
  down: the 5.5 target exists, in the very commit akkar pins, and the compile
  still fails because the `lua-compat-5.3` it vendors is v0.9, whose header
  hard-errors past 5.04. Refreshing that one file to v0.15.1 is the whole fix.

  **The lesson worth keeping is not about Lua.** Twice, a dependency was
  declared blocking because a version list did not mention us. A list is a
  claim about what upstream tests, not about what compiles, and the two were
  never checked against each other until someone ran `cc`.

  What remains is genuinely packaging, and it is not akkar's to write: no
  distribution ships Lua 5.5, so `luarocks install akkar` cannot reach it. 5.4
  stays the default for that reason and no other.
  `docs/runtime/lua55-stack.sh` builds the stack from source into a prefix,
  and CI runs that same script so this entry cannot go stale a third time.

---

## 7. The Postgres driver, and what measuring it corrected

**Built and measured, not yet wired.** `akkar.pq` is libpq with the waiting
done in Lua: `src/akkar_pq.c` speaks the protocol and materialises rows,
`akkar/pq.lua` does every wait with `cqueues.poll`. `bench/driver/RESULTS.md`
has the numbers and `spec/pq_spec.lua` pins the behaviour, including the one
property that matters more than speed -- two concurrent 0.4 s queries finish
in 0.4 s.

**The correction is worth more than the driver.** This project had been
quoting "32 us pgx, 82 us asyncpg, 330 us pgmoon" and reading the 330 as what
pgmoon *adds*. `bench/driver/floor.c` -- the same query through blocking
`PQexecParams` with no Lua at all -- costs **274.80 us on this laptop**. Those
three figures were measured against each other on the EC2 box and are sound
relative to one another; the inference drawn since is not. A driver cannot be
blamed for the round trip.

Driver cost, floor subtracted:

| | 1 row | 1000 rows |
|---|---:|---:|
| pgmoon | 217 us | 12,243 us |
| akkar.pq | 107 us | 1,686 us |

**And the part that changes what to expect:** at one row the advantage does
not clear the noise gate, and `/users/:id` -- the route in `bench/compare`, in
the saturation study and in the soak -- is a one-row query. This will not move
the headline throughput.

### Owed on the driver

- **Wire it into `akkar/db.lua`**, which still goes through pgmoon. The
  adapter boundary is the whole reason this is one file's worth of work, and
  that claim is now testable rather than asserted.
- **Re-run on the study machine.** Every number above is a laptop with
  Postgres in a container. Until it is repeated on the `c5.2xlarge`, none of
  it may be compared with `bench/compare/RESULTS.md`.
- **Measure the tail, not the mean.** 12,243 us of interpreter work per
  thousand-row query is 12,243 us in which the single-threaded event loop runs
  nothing else. That is the effect that should show up as p99 under load, and
  it is unmeasured.
- **A static libpq recipe for `akkar build`.** The Debian `libpq.a` drags in
  pgcommon, pgport, curl, ssl, gssapi and ldap. Same class as the cqueues and
  luaossl recipes; not started.
- **Prepared statements.** Every query is an unnamed parse, exactly as pgmoon
  does it. Named statements are where the remaining single-row gap probably
  lives, and they bring a cache-invalidation problem with them.

## 8. Astra, the competitive reference

Astra (Rust + Tokio + Axum + SQLx, hosting Lua via mlua) is the closest thing
to what akkar is trying to be, and it is treated as a reference rather than a
threat. Three claims about it were **verified against the source** at commit
`885586c`, v0.51.2, and all three are confirmed:

- **`sql.leak()` per query.** `src/components/database.rs:251`, inside a macro
  expanded for both Postgres and SQLite, reached by five Lua methods. The
  `String` comes from the Lua argument on every call; there is no
  `Box::from_raw` anywhere in the repository and no interning.
- **Unbounded request body, with a limit knob that does not apply.**
  `to_bytes(body, usize::MAX)` runs before any Lua. `DefaultBodyLimit` is
  configurable and does *not* cover this path, because the handler takes the
  raw `Request` extractor whose `from_request` is the identity; only
  `Bytes`-based extractors read the limit. No `RequestBodyLimitLayer` exists.
- **One global Lua VM serialises CPU work.** mlua's `ReentrantMutex` is taken
  at the start of `poll` and held across `resume_inner`, so a handler that
  never yields holds it for the whole request and other Tokio workers block on
  it. `thread_pool_size` is a coroutine object pool, not parallelism.

**What this does NOT license.** All three are implementation defects fixable
in a patch, not consequences of choosing Rust. Positioning against them as
permanent failings ages badly. What they are evidence about is process.

### The experiments worth running

- **Soak both runtimes side by side with RSS plotted.** The leak is the only
  one of the three that draws itself on a graph, and the study machine exists
  to produce that graph.
- **Prove akkar's body limit cuts.** Astra's defect is not a missing limit; it
  is a configurable limit that does not cover the hot path. A test that proves
  akkar's knob actually truncates is worth more than the knob.
- **Audit every concurrency knob akkar exposes** for the `thread_pool_size`
  failure mode: a number that reads as parallelism and delivers a cache. If
  the documentation does not say what a knob does *not* do, it is the same
  trap.

## 9. WebAssembly components — studied, measured, not decided

`docs/wasm/DECISION.md` has the full study and `docs/wasm/akkar.wit` the world
it produced. **The decision is blocked on one number, not on an argument**, and
the order stands: the Postgres driver first.

The premises broke in both directions. WASI 0.3 is real (11 June 2026,
ratified). A C host **can** instantiate components today — Wasmtime's C API
has 154 `wasmtime_component_*` symbols and a minimal C host was compiled and
run to confirm it. But **WASI 0.3 does not reach the C API** (zero `wasip3`
symbols; issue #13705 open and unanswered), and `wit-bindgen` is guest-side
only, so host marshalling is hand-written against a 23-case union.

**The number: 5.08 MB today against a 24.8 MB stripped C host that merely
touches the component API.** Six times, in the dimension `docs/RUNTIME.md`
sells. WAMR and wasm3 are small and have no Component Model at all; without
components the story shrinks to "a plugin in C or Rust with an integer ABI".

**The single experiment**, on the study machine: build `wasmtime-c-api` from
source with the minimum set that still runs components, link a trivial C host,
and ask whether it comes in under ~10 MB. Under 10, the rest is engineering.
Still 25, akkar keeps `vm.lua` for untrusted-but-not-hostile hooks and puts
hostile code in another process.

**Two things worth keeping whatever the answer is.** First, `epoch_deadline_
async_yield_and_update` **preempts a Wasm guest**, which is strictly more than
akkar can do to a C function — `akkar/work.lua` documents that impossibility —
so Wasm beats C on the very axis where C is feared. Second, and this holds
even if Wasm is never adopted: **the plugin database interface cannot take a
SQL string.** `akkar/scope.lua:15` refuses raw SQL because "a string cannot be
scoped without parsing it", so the interface is builder-shaped and the scope
is not a parameter anywhere in it — the host takes it from the running
request. Any extension mechanism akkar grows, in any technology, has to be
builder-shaped for that reason.

## 10. The outbound path, which does not exist

Found by inventory, verified in the code: `CAPABILITIES` in `akkar/init.lua`
is `db`, `cache`, `log`, `clock` — **none of which leaves the process** — and
nothing under `akkar/` requires an HTTP client.

**akkar is complete on the inbound path and empty on the outbound one.**
Routes, validation, pooling, jobs, cache, rate limit, idempotency, metrics,
OpenAPI, scope, streaming, shutdown: every one of them is about *receiving* a
request. Nothing in akkar *makes* one.

That is why it never surfaced. The whole suite and every benchmark tests a
server, so the missing half was never exercised by anything.

Stated without softening: **akkar does not yet serve a service that calls
another service**, which is most real backends. It is not a quality problem
with what exists; it is the boundary of what was built.

| | state | severity |
|---|---|---|
| HTTP client (`req.http`) | absent | **high** — blocks every external integration |
| Password hashing | absent; OpenSSL already linked via luaossl | high *if* the app authenticates |
| JWT | absent; HMAC/RSA already available | high *if* the app authenticates |
| Response compression | absent | low — the proxy does it |
| Cookies / sessions | absent | low for a JSON API on bearer tokens |
| WebSocket | absent | depends on the application |

**None of these is an architectural hole.** They are modules, and the
primitives for most of them are already inside the binary: password hashing
and JWT need PBKDF2/HMAC/RSA, and OpenSSL is already a dependency through
luaossl; a client needs sockets, TLS and a pool, and cqueues, luaossl and
`akkar/pool.lua` all exist.

### The choice the client forces, and it mirrors the driver's

Wrapping lua-http's client is the fast path and means **inheriting lua-http**
— the library this project found a denial of service in, whose last commit is
September 2024 and which `akkar/substrate.lua` now carries a repair for.

The answer is probably the same one the driver just demonstrated: the value is
in the **adapter** — deadline, pool, retry, metrics, and the client sitting
behind the capability boundary the way `db` does — not in the transport. Wrap
what exists, and swap the transport underneath if it hurts. `spec/db_spec.lua`
running one contract against two drivers is the evidence that swapping costs
one file.

### Order

1. **HTTP client as a capability** (`req.http`), with deadline and pool.
2. **`akkar.crypto`** — password hashing and JWT over the already-linked OpenSSL.
3. The rest when a real need appears.

## 11. What writing the guide found, and what is still open

Nine defects came out of writing beginner documentation, and none of them was
caught by a thousand tests. The reason is structural and worth keeping: **a
test never has to READ an error message, and never uses the API as somebody
who has not seen it before.** Every one of these was found by an author who
could not write an honest sentence about what the reader would see.

Six are fixed: the bind error that did not name its port, `req.body` being nil
with no explanation, `akkar.log` printing an id as `7.0`, the connection
failure whose message was unreachable code, an empty list encoding as `{}`,
and the README promising a watchdog that cannot see a C call.

### Still open

- **A job store fails at first push, not at construction.**
  `jobs.new(redis.connect{...}, "email")` — note the missing call parentheses
  — builds happily. The server starts, and the error arrives at the first
  `push` as `attempt to call a nil value (method 'command')`, pointing inside
  `akkar/jobs/redis.lua` rather than at the line that was wrong. akkar already
  checks capability contracts at boot for this exact reason; the job store
  does not get the same treatment.

- **A global rate limiter throttles the health checks into a restart loop.**
  Twelve requests to `/health/live` answer 429, an orchestrator reads that as
  a failed probe, and it restarts a process that was healthy. The framework
  has no built-in exemption, and this is the failure mode where a protective
  feature causes the outage. Guide page 11 shows the 429 first and then the
  four lines that fix it, which is a workaround in documentation for something
  that should probably be a default.

- ~~**No supported way to run a background loop in the same process as
  `app:run`.**~~ **Built** as `app:task(name, fn)`; the decisions it was
  waiting on are in the commit and in the module docstring. Original
  statement kept below, because the reasoning for the shape came from it. It ends in `assert(s:loop())`, or -- when `handle_signals` was
  called -- in a controller wrapping exactly two tasks, the server loop and
  the signal task. Neither is reachable from outside, and `SETTINGS` has no
  key for one, so there is nothing an application can pass.

  The cost showed up as a documentation cost, which is how it was found. The
  smallest honest example of "the request should not wait for the email" is
  one process, an in-memory queue, and a consumer sharing the event loop.
  That is not expressible, so the guide's first working example needs Redis
  and a second process -- a `docker run` and a third terminal before a
  beginner has seen one job run. Redis is right for anything real and heavy
  for the idea.

  Two things for whoever takes it. The workaround that exists today is
  `cqueues.running():wrap(fn)` from inside a handler, which attaches to the
  server's own controller; it works, and it stayed out of the guide because
  "start your worker from inside a request" teaches a beginner something they
  should unlearn. And `akkar.jobs.memory` already implements `claim_pop`,
  `ack` and `reap`, so `Queue:reliable()` is true for it -- the store half is
  not the gap, the place to run the consumer is.

  Deliberately not designed here: a task-registration hook has real questions
  in it about shutdown ordering and about whether a failing task should take
  the server down, and those deserve a decision rather than a guess.

- **`docs/DEPLOY.md` is not re-run by anything.** Its Dockerfile numbers and
  its Railway transcript are true of a tree from one afternoon that has since
  moved. `spec/docs_spec.lua` covers `docs/guide/` only, deliberately, and
  this file is the one page outside it that makes measured claims.

- **An `env` marker for the docs runner.** Page 12's application is `no-run`
  because it refuses to start without `SESSION_SECRET`, `FRONTEND_ORIGIN` and
  the `PG*` variables, and the runner has none to give it. It is verified by
  being containerised instead, which the page says.

  Two halves, and the second is the one that would be skipped: the block runs
  with a supplied environment and stays up, AND the same block with one
  variable removed exits non-zero and names that variable. A runner proving
  only the first would leave the refusal untested while looking thorough —
  the same shape as the skip guard this project once shipped that never
  checked anything.

## 12. Open after HTTP/2, and after the CI it turned red

Recorded on 2026-08-18, in the order they cost. Nothing here is a decision
deferred for comfort; each one names what would settle it.

### 12.1 The pool leak the simulation found — FOUND AND FIXED, 2026-08-19

**Status: closed, by reading the acquisition path rather than by reproducing
the failure.**

`spec/simulation_spec.lua` — the machine-checked invariant from L1 — went red
on CI twice on the same assertion: `live=4 idle=1` on seed 19 on a Linux
runner, `live=4 idle=3` on seed 16 on macOS. Resources checked out of the pool
that never came back, which is the exact defect class the file was built to
hunt, and the exact shape `akkar/pool.lua` records from the study box:
`live=2 idle=0` and a permanent outage.

**It does not reproduce here.** Thirty runs of seed 19; deadline budgets from
20 ms down to 0.1 ms; pool sizes 4, 2 and 1 with up to 48 requests; the
collector stopped outright so no finalizer could run. Every one clean, with
`live=4 idle=4` before `reap` was even called.

What the investigation established, which is worth more than the guesses it
killed:

- **`Pool:reap()` did nothing in any of those runs.** It returns 0 immediately
  when `reserved()` is zero, and after a drain it always is — so the two
  collections it performs, the ones its own comment says are what "finally
  drops the coroutine", are skipped precisely when an abandoned handler's
  release might be waiting on a finalizer. Measured, not inferred.
- **The spec could not tell a slow machine from a broken pool.**
  `cq:loop(30)` returns truthy whether it drained or ran out of time, and a
  timed-out loop leaves coroutines still holding resources. That reads as a
  leak and is not one.
- **The spec measured before the last releases could happen.** Its comment
  claimed everything in flight "has had its chance"; nothing in the code gave
  it one, because anything scheduled after `cq:loop` returned never ran.

All three are fixed: the spec now asserts `cq:empty()` separately with its own
message, collects unconditionally, and runs the loop once more before reading
stats. **Whether that makes CI green is not yet known**, and if it goes red
again the message will now say which of the two things happened.

**WHAT IT WAS.** `execution.release` is called from exactly one place --
`dispatch`, once -- and it clears `record.released`. `M.acquire` calls
`provided()`, and **`provided()` is allowed to yield**: opening a connection,
or waiting for a pool slot. If the deadline fires while it is yielding, the 503
goes out, dispatch runs the release, and dispatch RETURNS. The coroutine is
resumed later, receives its resource, appends it to a freshly created list, and
nothing ever calls release again.

One leaked resource per request abandoned while acquiring, and self-reinforcing
in the way `akkar/pool.lua` records from the study box: each leaked slot
lengthens the wait, and a longer wait abandons more handlers inside it.

`M.release` now marks the record before it walks the list, and an acquisition
that comes back to a marked record releases its resource immediately instead of
registering it with nobody. `spec/late_acquisition_spec.lua` reproduces the
original deterministically -- a capability that takes five times its budget to
open, which needs no pool and no slow machine -- and mutation-testing the guard
away returns the exact original symptom, `opened 1, released 0`.

**And the reap suspicion below was wrong**, which is worth keeping. `reserved()`
counts `self.opening` -- coroutines abandoned while a resource is being OPENED
-- so a pool with nothing opening has nothing for `reap` to recover, and its
short-circuit is correct for the job it claims. The leaked resources were
already open, which is exactly why `reserved` was 0 while `live` was 4.

**What is still open here:** whether `spec/simulation_spec.lua` goes green on
CI now. The defect it was reporting is fixed and its measurement was repaired,
but the two were established separately and only CI can say the first was the
whole of it.

### 12.2 Determinism is established on epoll, not on kqueue

**Status: narrowed, with the narrowing in the assertion.**

`spec/determinism_spec.lua` claimed forty concurrent requests reproduce byte
for byte. On macOS CI they did not — two traces differed, with gaps in the id
sequence. The order a cooperative scheduler resumes coroutines in comes from
the kernel's polling mechanism, and `spec/support/portable.lua` already
records that kqueue and epoll differ enough for one cqueues controller to cost
two descriptors on one and three on the other.

The test is now `pending` off Linux with that reason, and the file's own claim
says "on epoll". **Establishing it on kqueue is real work**: it means either a
scheduler of akkar's own on top of cqueues, or accepting that replay is a
Linux property. L1's value — a seed makes a counterexample re-runnable — is
intact on the machine the simulation runs on.

### 12.2b macOS is the machine that finds the time-sensitive specs

Worth naming as a pattern rather than as three incidents. The same commit,
`ff16765`, was run twice by CI: the push run passed on macOS and the pull
request run failed on it. Same tree, opposite verdicts — so macOS is not
broken here, it is **less forgiving**, and each time it has been right about
something.

Three specs so far, and none of the three was an akkar defect:

| spec | what macOS found |
|---|---|
| `simulation_spec` | a measurement that could not tell a slow machine from a leaking pool |
| `determinism_spec` | a byte-for-byte claim that only ever held on epoll |
| `deadline_propagation_spec` | `(t + 0.2) - t'` compared to 0.2 exactly, in doubles |

The last returned **0.20000000000005** — fifty femtoseconds of overshoot, and
a property of binary floating point rather than of `bounded`. It now carries a
one-nanosecond tolerance, nine orders of magnitude below the observed error,
so a budget that leaked a millisecond would still fail.

**The sweep, done 2026-08-19.** Every assertion in `spec/` that compares a
clock-derived value against a literal: **42 candidates, one real**, and it was
found before CI reached it.

The 41 that are fine are fine for reasons worth stating, because "looks like a
clock" is not the same as "is one":

- `spec/time_spec.lua`'s exact equalities read the MANUAL clock, which returns
  the integer it was handed. No arithmetic, nothing to round.
- `spec/config_spec.lua`'s durations are parsing — `"30s"` to `30` — and never
  touch a clock at all.
- The loose bounds (`elapsed < 2`, `< 3`, `waited < 10`) assert a guarantee
  with seconds of slack; float noise cannot reach them.

The one that was wrong is `spec/deadline_propagation_spec.lua:45`,
`left > 4.9 and left <= 5` after `begin(5)` — the identical shape to the
assertion macOS broke, `(t + 5) - t'` compared to 5 as though doubles were
exact. Fixed with the same nanosecond, which leaves `left > 4.9` carrying the
real content: the budget counts DOWN.

**The rule this leaves**, worth applying to anything written later: an
assertion may compare a clock reading to a bound the CLOCK cannot cross, and
may not compare it to the number the arithmetic was built from.

### 12.3 HTTP/2 fuzzing — BUILT, and it found a three-byte denial of service

**Status: `spec/h2_framing_spec.lua` exists, 22 hostile frame shapes, and the
first run found a remote denial of service in upstream lua-http 0.4.**

`read_http2_frame` reads a nine-byte frame header with `xread(9)`, which
returns what it HAS when the peer goes away. Three bytes and a hang up produce
a three-byte string; it is not nil, so every error branch is skipped, and
`sunpack(">I3 B B I4", ...)` raises "data string too short".

That raise travels out of the connection, out of the server loop, and out of
`app:run`. The process stays up, the listening socket stays open, and
**nothing is ever accepted again — HTTP/1.1 included**, because what died is
the accept loop rather than the connection. Three bytes from one unauthenticated
peer, permanently.

Upstream checks for exactly this on the PAYLOAD twenty lines below —
`if payload and #payload < size then -- hit EOF` — and not on the header. The
vendored copy now mirrors it: a short header is EILSEQ, which is what the
branch above it already uses for a protocol error. No unget, because unlike
the payload case a retry cannot help; the peer sent half a header and left.

Mutation-testing the guard away returns both original symptoms.

**AND CONFORMANCE IS NOW MEASURED TOO**, by `bench/h2spec.sh` -- h2spec 2.6.0,
146 cases straight out of RFC 7540 and RFC 7541, against a server in its own
process. Five runs:

| | runs |
|---|---:|
| 145 passed, 1 skipped, **0 failed** | 3 |
| 144 passed, 1 skipped, **1 failed** | 2 |

**The intermittent one is 3.8, GOAWAY.** h2spec sends a GOAWAY and then a PING
and expects a clean close or a PING ACK; twice in five it got `connection reset
by peer`. That is a deviation rather than a flaky measurement, and the
mechanism is ordinary: closing a socket with unread inbound data makes the
kernel send RST rather than FIN, so whether h2spec's PING has landed by the
time the server closes decides which the peer sees.

**Open, and small.** It is a deviation and not a hazard -- the connection is
ending either way, and what an RST costs is data in flight on a connection the
peer asked to close. Fixing it means draining before closing in the vendored
`h2_connection` GOAWAY path, which is upstream's code and deserves more care
than a conformance point is worth on its own.

**And it should go upstream.** The bug is not akkar's and every lua-http user
serving h2 has it.

### 12.4 The historical benchmarks are still unrepeated

Every number published before 2026-08-17 came from `bench/study/regression.sh`
while it was comparing a tree with itself — `ROOT` resolved into a symlink and
`cp -a` copied the symlink. The harness is fixed and re-verifies its refs after
both prepares. **The numbers have not been re-taken**, and the D4 table
against the neighbours is the one that matters.

Blocked on access rather than on work: the study box answers on port 22 and
refuses this machine's key.

### 12.4b One connection can no longer kill the server

Found by asking why the h2 defect above was fatal rather than local, which is a
better question than "what was the parser bug".

`cq:wrap` gives every connection its own coroutine in the server's controller,
and cqueues propagates a raise out of `cq:loop()`. So ANY unexpected error
under `handle_socket` took the accept loop with it: process up, listening
socket open, nothing ever accepted again. Twice in this tree, from opposite
directions -- `Content-Length: banana` on h1, three bytes of h2 frame header --
each a one-line parser bug and each a total outage.

`add_socket` now runs `handle_socket` under `xpcall`, gives the connection slot
back by hand (`handle_socket` decrements `n_connections` on its last line, so a
raise skipped it, and a count that only climbs walls the server off at
`max_concurrent` just as completely, only slower), closes the socket, and
reports `op = "connection"` -- which `akkar/init.lua` logs at ERROR with the
traceback, because a connection that raised is a bug and everything else
reaching `onerror` is a peer that went away.

**Demonstrated against the real defect rather than a synthetic one.** With the
h2 short-header bug reintroduced and the guard in place, the server logs
`connection failed` with its traceback and keeps answering -- h2 and h1 -- on
both hostile shapes that used to end it. Two independent layers now: the parser
checks its input, and a parser that does not is one dropped connection.

`spec/connection_containment_spec.lua` asserts all four properties, and
mutation-testing the guard away fails all four with the right diagnoses.

**What this does not do** is make a raise acceptable. It makes the next unknown
parser bug cost one connection instead of the service, and it makes it visible
-- which the silent version never was.

### 12.5 ~~WebSocket~~ — BUILT — and HTTP/3

**WebSocket is done, 2026-08-19.** The lifecycle question was the real one, and
both halves of it had the same answer: the unit of work is a MESSAGE.

Capabilities are acquired per message through `ws:scope` rather than for the
life of the socket — a pool slot held until a browser tab closes is the known
streaming gap at hours instead of seconds — and `app:stop` sends every open
socket a 1001 close frame rather than draining on connections that will never
end by themselves. Handlers still return: a socket is three callbacks and an
object, and `ws:send` / `ws:close` are the only mutations.

It cost **no new dependency**. `basexx`, `lpeg` and `lpeg_patterns` were
already declared for the vendored `request.lua`, and `websocket.lua`'s
`compat53` requires are guarded behind `string.pack`, which Lua 5.4 has
natively. The first assessment of this item said four new dependencies and was
wrong.

`spec/websocket_spec.lua` pins five properties, including the one easiest to
lose: two messages must open the capability twice and release it twice.

HTTP/3 is the exclusion that the argument actually fits: QUIC is a UDP
transport with its own congestion control and TLS integration, neither cqueues
nor lua-http has it, and there is no half of anything on disk to vendor.
Terminated at the edge in practice.

### 12.6 Isolation against hostile code is a decision about product shape

Not an akkar defect, and the inventory says so: `akkar/vm.lua` states in its
own header that a sandbox inside one Lua state is not a security boundary, and
`spec/vm_spec.lua` covers every escape it does claim — bytecode, the unhooked
coroutine, the pcall that swallows the budget, the single allocation that
outruns the sampler, the shared string metatable.

So what decides it is the price of a process per tenant, and that is measured:
**28 ms to first response, 12.8 MB resident idle** — 1.22 GB for a hundred
idle exercises, 6.09 GB for five hundred. Cheap, and the only option that *is*
a boundary. `akkar.vm` keeps the smaller case: a hook published inside an
application that is otherwise trusted.

### 12.7 LAB L2–L5

Structured concurrency, adaptive CoDel, and a profiler. GC tuning already came
back measured at ≤3.5% and is refused. These are the only items on this page
that are optional.

## What is deliberately not being built

Written down because the list keeps trying to grow.

| Not building | Why |
|---|---|
| ORM, ~~migrations~~, templating, HTML, admin, scaffolding | Out of scope in `PLAN.md` §1, permanently — **except migrations, and that exclusion is retracted.** It was grouped with the ORM and it does not belong there: an ORM is an opinion about modelling, which akkar refuses, while a migration runner is a ledger of applied files and a lock, with no opinion about a schema at all. And `akkar build` produces a binary whose whole promise is "copy it to a server" — a binary that cannot bring its own schema forward has an incomplete promise. Built as `akkar/migrate.lua`; see `docs/ROADMAP.md` §2.1. |
| Adapters for payments, storage, mail | Past "JSON API framework". Own the contract, let libraries implement. |
| ~~`akkar build` producing a self-contained binary~~ | **Retracted — the reason was wrong.** It read "Redbean is a *different substrate*, and `cqueues` is a C module. That is a substrate change, not a packaging step." True of Redbean, and it does not follow for a C module: static linking changes no substrate. Measured since — cqueues runs an event loop inside a single 1.5 MB binary. See `docs/RUNTIME.md`. |
| ~~CI, docs site, semantic versioning, compatibility policy, ADRs~~ | **Retracted with the audience.** These were excluded because "the audience is my own use". The audience changed; see `docs/PLAN.md` §1. |
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
