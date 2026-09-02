# The production scorecard: what Lua lacks, and what the runtime does about it

The case against Lua for a production backend is a list, and most of it is
correct about the language. No static types. Five incompatible runtimes. A
standard library with no HTTP, no JSON and no event loop. No durable
workflows, no circuit breaker, no ORM, no observability standard, and a
compiled competitor that is faster.

This page takes that list one item at a time and checks it against the tree
as of 2 September 2026. Each item gets one of two verdicts. **Neutralized**
means the runtime makes the choice the language refuses to make, and the page
says where in the tree that choice lives. **Real risk** means the hole is
still there, and the page says how big it is and what, if anything, is in
flight to close it. Nothing here is claimed as shipped unless a file is named
beside it; work that is planned or half-built is marked *in progress*, and
that marker is the honest part.

The thesis the list tests: **akkar answers "Lua does not scale" by being an
opinionated runtime.** One Lua version, one event loop, one validator, one
HTTP stack, batteries in the box. The language leaves those choices open, the
ecosystem has argued about them for twenty years, and a runtime that makes
them is what a team actually needs from a platform. Where that thesis holds,
the critique is neutralized; where it does not, the gap is a feature akkar
has not built yet, not a property of Lua.

| # | Critique | Verdict | Where to look |
|---|---|---|---|
| 1 | No static typing; Teal, Luau, LuaLS and Pluto fragment the answer | **Neutralized for safety; a DX gap remains** | `akkar/gen.lua`, `akkar/openapi.lua`, `akkar.validate` in `akkar/init.lua` |
| 2 | Runtime fragmentation: 5.1 to 5.5, LuaJIT, Luau | **Neutralized, and it is a strength** | `akkar-0.1.0-1.rockspec`, `docs/substrate/LUAJIT.md`, `docs/substrate/LUAU.md` |
| 3 | Minimal standard library | **Neutralized, with a maintenance cost that is instrumented** | `akkar/vendor/http/PROVENANCE.md`, `spec/vendor_provenance_spec.lua` |
| 4 | No standard event loop; cqueues is stagnant and Unix-only | **Real risk, the largest one** | `docs/substrate/CQUEUES.md`, `docs/substrate/SEGFAULT.md` |
| 5 | No durable workflows | **Real gap, closable by composition** | `akkar/jobs.lua` |
| 6 | No circuit breaker, no resilience primitives | **One primitive missing** | `akkar/limit.lua`, `akkar/execution.lua`, `akkar/http.lua` |
| 7 | No typed ORM | **Out of scope, deliberately** | `akkar/sql.lua`, `docs/why/what-akkar-does-not-do.md` |
| 8 | Observability is not standardised | **Partial, ahead of the assumption, one gap named** | `akkar/trace.lua`, `akkar/metrics.lua`, `akkar/log.lua` |
| 9 | Performance: V8 and Go beat the interpreter; OpenResty is 8.75x faster | **Neutralized as positioning; the ceiling is real and scoped** | `bench/study/WHERE-THE-GAP-IS.md`, `docs/why/slower-than-openresty.md` |

The rest of the page is the argument behind each row.

---

## 1. Static typing — neutralized for safety; a DX gap remains

The critique is correct twice over. Lua has no compiler that checks intent
before the program runs, and the ecosystem's answers — Teal, Luau, LuaLS
annotations, Pluto — are four dialects that do not agree with each other.
`types/akkar.d.tl` opens by conceding the point rather than arguing with it.

What akkar does instead is make the type live in one place and project it
everywhere else. A route declares its schema once:

```lua no-run
app:post("/transfers", {
  body     = { to = "string", amount = akkar.v.integer { min = 1 } },
  response = { id = "string", status = "string" },
}, function(req)
  return { id = "tr_1", status = "posted" }
end)
```

Three things read that table, and none of them can disagree with the others
because they read the same table through the same expansion:

- **The validator enforces it at runtime.** `akkar.validate` in
  `akkar/init.lua` coerces `params` and `query`, rejects a bad `body` with a
  422 whose `fields` map names the offending path, and checks the `response`
  on the way out. It is cheap: validating four fields allocates 152 bytes,
  which is exactly the size of the cleaned output table and nothing more
  (`bench/study/HTTP-OPTIMISATION.md`).
- **The document describes it.** `akkar/openapi.lua` turns the same tables
  into an OpenAPI 3.1 document served at `/openapi.json`, including the
  shapes of the 422 and 500 akkar itself produces (`openapi.VALIDATION_FAILED`,
  `openapi.INTERNAL_ERROR`).
- **The client is generated from it.** `akkar gen` (`akkar/gen.lua`) reads
  that document and emits a TypeScript client: one interface per input a
  route declares, `?` on optional fields, an `AkkarError<TBody>` typed per
  route as the union of its error responses, and a comment above each route
  listing every constraint the server enforces that a TypeScript type cannot
  express — TypeScript has no integer and no range, so `amount: -3`
  type-checks and only the 422 refuses it. Where a route declared no
  `response`, the return type is `unknown`, never `any`, so the gap is
  visible in the checker rather than checked against nothing.

That last projection is the one that answers the complaint as it is usually
made, which is really about tRPC: a wrong call to your own API should be red
in the editor, not a 422 in production. `spec/gen_spec.lua` proves it with a
real `tsc`: a typo'd key is a compile error, a correct call is not, and
renaming a field on the server turns a previously-correct client red once
regenerated. `examples/typed-client/` is the smallest complete loop, and
`.github/workflows/ci.yml` runs `akkar gen … --check` against it so a schema
change nobody regenerated fails the build. `akkar doctor` warns about a route
that validates its input and declares no `response`, because that is a
contract typed on the way in and untyped on the way out
(`untyped_responses` in `akkar/doctor.lua`).

**What this is not.** tRPC infers; akkar generates. The generated file is
only as current as the last `akkar gen`, and `--check` in CI is a process
guarantee, not a compiler property — `examples/typed-client/README.md` says
so in its second paragraph. And there is no static check inside the handler
body: `types/akkar.d.tl` types `req.params` as `{string: any}` and `req.body`
as `any`, so a Teal handler is checked against akkar's API and not against
its own route's schema. Per-route Teal records and LuaLS `---@` annotations
projected from the same source are **in progress**; today there are zero
`---@` annotations under `akkar/`, and saying so is more useful than implying
otherwise. `docs/substrate/LUAU.md` records why the answer is codegen and
annotations rather than a typed dialect on the substrate.

---

## 2. Runtime fragmentation — neutralized, and it is a strength

The critique: Lua 5.1, 5.2, 5.3, 5.4, 5.5, LuaJIT and Luau are mutually
incompatible in syntax, semantics and C ABI, and a library author has to pick
a subset of the language to reach all of them.

akkar picks one. `akkar-0.1.0-1.rockspec` declares `lua >= 5.4, < 5.6` and
nothing below it, and the two alternatives people ask about have each been
answered with a measurement rather than a preference:

- **LuaJIT was measured and refused.** `docs/substrate/LUAJIT.md`: 1.62x on
  `/ping` against a bar of 2x written down before the run. The deeper reason
  is not throughput. LuaJIT has no integer subtype, so `math.type` cannot
  exist honestly, and `db.lua:57` uses it to bind a whole number as `int8`
  rather than `float8`, the line `docs/substrate/LUAJIT.md` singles out as the
  one a lying shim breaks silently. Under LuaJIT `v.integer` becomes
  advisory, which is the exact defect it exists to prevent. That is a
  property of the runtime, not of a shim.
- **Luau cannot host the substrate at all.** `docs/substrate/LUAU.md`: every
  native module akkar stands on is compiled against PUC-Lua 5.4's `lua.h`,
  and Luau ships its own.
- **Lua 5.5 builds and passes.** `docs/substrate/LUA-55.md`, and CI runs that
  build as a blocking job. What keeps 5.4 the default is packaging alone: no
  distribution ships 5.5 yet.

Choosing one runtime is what lets the code use the language it is written in:
`math.type`, `string.pack`, `<close>`, bitwise operators, `goto` in
`akkar/jobs.lua`, all without a compatibility layer. The one shim in the tree,
`akkar/bitwise.lua`, exists because the LuaJIT experiment needed it. Its own
header prices the two sites that run per request at about 0.04% of one, and
`docs/substrate/LUAJIT.md`'s earlier estimate was 0.07%; either is an order of
magnitude under the 1.16% noise floor the project measures against. It stays
as a record of what portability would cost, not as a promise to be portable.

---

## 3. Minimal standard library — neutralized, with a cost that is instrumented

The critique: `require "http"` is not a thing. Lua ships string, table, math,
io and os, and everything a backend needs comes from LuaRocks in a dozen
competing versions.

akkar's answer is the rockspec's module table: routing, validation, JSON,
an HTTP client and server, TLS, sessions, CSRF, crypto, a Postgres adapter,
a Redis adapter, connection pooling, jobs, metrics, tracing, structured logs,
SQL composition, migrations, object storage, email, WebSocket, a sandbox, a
file watcher, a health module, a build tool. The application chooses none of
these and configures few of them.

The part that deserves scrutiny is the HTTP stack, because it is the one
where "batteries included" means "we own the battery". `akkar/vendor/http/`
carries 22 files and about 10,350 lines of lua-http 0.4, of which 11 files are
patched — with akkar's own denial-of-service repairs (a three-byte frame header
that killed the accept loop, an enforced `MAX_CONCURRENT_STREAMS`, a
rate-accounted `RST_STREAM` for CVE-2023-44487, a bounded WebSocket message)
and two post-release upstream fixes backported by hand. That is an orphan
adopted, not a dependency pinned: upstream's last release is 2021 and its last
commit 2024-09-08.

The cost of adopting an orphan is being its only maintainer, and the project
has already paid for that once in the smallest possible way: the first
provenance file was wrong within twenty-four hours, certifying two files as
unmodified while five commits put security repairs into exactly those two.
The repair is the instrument, and it is the pattern this whole page argues
for. `akkar/vendor/http/PROVENANCE.md` is the ledger;
`spec/vendor_provenance_spec.lua` fails CI, naming the commit, if any patch is
missing from the file the ledger says holds it, if the two columns disagree,
or if a file has no row. Prose that nothing executes is how it went wrong
once already.

**What this is not.** It is not a promise that the unmodified files are
byte-identical to upstream — that check needs the upstream tag, CI has no
network, and the ledger says so. And it is not a standard library for the Lua
ecosystem; it is akkar's, and `docs/why/what-akkar-does-not-do.md` lists what
was left out on purpose.

---

## 4. No standard event loop — real risk, the largest one

The critique: Lua has no event loop, and the one akkar chose, cqueues, has
not had a release since 2020 and does not run on Windows.

Both facts check out, and this is the row where the runtime's answer is
"owned" rather than "neutralized". `docs/substrate/CQUEUES.md` carries the
full account; the summary is:

- The last published rock is `rel-20200726`. Upstream master is alive — its
  latest commits are from 18 March 2026 and add Lua 5.5 — but the whole
  delta since the release is sixteen commits across twelve files, and
  LuaRocks cannot express a commit, so **what `luarocks install akkar` gets
  and what CI proves are not the same build.** The rockspec says so at lines
  46–51 and names it as the strongest argument for `akkar build`.
- Windows is not a gap for this runtime's positioning. `docs/PLATFORMS.md`
  lists it as "not supported, and not planned". Capacity is one process per
  core behind `SO_REUSEPORT` (`docs/why/one-process-per-core.md`), deployment
  is a static binary in a `scratch` container (`docs/DEPLOY.md`), and CI
  tests Linux x86-64, Linux arm64 and macOS. cqueues would be only the first
  of several Unix-shaped dependencies to stand in Windows' way.
- The mitigation is `akkar build`: `akkar archive cqueues` builds the pinned
  commit into a static archive and the host links it, so the artefact that
  ships contains the cqueues CI tested and the 2020 rock never enters.
  `Dockerfile` pins the same `CQUEUES_COMMIT` as `.github/workflows/ci.yml`.
- akkar carries **no patches** to cqueues, which is why it is not forked the
  way lua-http was. The trigger conditions for a fork are written down.

The risk is not theoretical. One native-layer crash has already been hit:
`docs/substrate/SEGFAULT.md` records an intermittent segfault inside cqueues'
descriptor tree, diagnosed from a core dump on 2 September 2026. The site is
cqueues' `cstack_cancelfd` walking every controller on a failing `connect`;
the corrupt tree belonged to a controller `akkar/health.lua` abandoned with a
timed-out probe still inside it. The cause is akkar's, the crash is native,
and the fix — running the probe as a worker on the controller it is already
inside, with the deadline carried as a bare number in `cqueues.poll`, the way
`akkar/execution.lua` runs handlers — is in `akkar/health.lua` (commit
`8bf1a21`). It cannot be proved locally; the proof is the CI matrix going
green with it in, and at the time of writing the latest completed runs on
both branches carrying it (`feat/typed-contract`, `recover/night-work`) had
failed on every unit job — x86-64 and macOS included, not arm64 alone —
which says the matrix has a problem of its own before it can say anything
about this fix. Until a green run exists, the fix is a diagnosis with a
patch, not a closed defect.

---

## 5. Durable workflows — real gap, closable by composition

The critique: no Temporal, no Inngest, nothing that survives a process
restart mid-flow.

What exists is a job queue whose semantics are separated from its storage.
`akkar/jobs.lua` holds the logic and states the store contract in its header:
three required methods, and optional ones that buy retries with backoff,
delayed jobs, deduplication at the door (`push` with an `id` returns `false,
"duplicate"` the second time), dead-lettering, a reaper for jobs whose lease
expired, and a delivery guarantee that has to be asked for by name —
`delivery = "at_least_once"` is refused at construction over a store that
cannot lease, because silently downgrading to at-most-once is the failure the
module exists to avoid. Every job carries a `uid` minted once and preserved
through retries, so a handler has one stable key to write its already-did-this
marker under. `spec/jobs_delivery_spec.lua` exercises the guarantee. Two
stores ship: `akkar/jobs/memory.lua` and `akkar/jobs/redis.lua`.

What does not exist, and the size of the hole:

- **No Postgres store.** A team with Postgres and no Redis has no durable
  queue today. The store contract is fourteen methods and the Postgres recipe
  (`SELECT … FOR UPDATE SKIP LOCKED`, `LISTEN/NOTIFY`) is well known; it
  reuses all of the retry, backoff, dead-letter and lease logic unchanged.
  **In progress.**
- **No step memoization.** A workflow that charges a card, then sends an
  email, then updates a ledger has no way to resume after the second step if
  the process dies before the third. The planned shape is Inngest's, not
  Temporal's — `ctx:step(name, fn)` persisting each step's result in the same
  `db:transaction`, `ctx:sleep` as a scheduled continuation — because
  deterministic replay needs a sandboxed VM, and `akkar/vm.lua` is explicit
  that it is not that. **In progress**, and it depends on the store above.

This is the row where "closable by composition" is doing real work: the
primitives — `pq`, closure-scoped transactions with savepoints in
`akkar/db.lua`, the `uid`, the claim-and-replay pattern from
`akkar/idempotency.lua` — all exist, and the workflow is the thing that has
not been written on top of them.

---

## 6. Resilience — one primitive missing

The critique: no timeouts by default, no bulkhead, no retry policy, no
circuit breaker.

Three of the four are present, and the first is ahead of what the critique
assumes:

- **Timeouts.** Every request has a deadline whether or not anyone asked for
  one — `akkar.defaults.timeout` is 30 seconds in `akkar/init.lua`, and
  `akkar/execution.lua` carries it as a number the whole execution can read
  rather than as an object someone has to pass. The outbound HTTP adapter
  (`akkar/http.lua`) takes an absolute deadline rather than a per-call
  timeout, and its header records why the per-call version was the defect it
  shipped with. `akkar doctor` warns when the database has no
  `statement_timeout` matching the request deadline, because akkar's deadline
  stops akkar waiting and does not stop Postgres working.
- **Bulkhead.** `akkar.limit.concurrent` bounds how many requests one caller
  may hold in flight, `akkar.limit.rate` bounds the rate, and
  `akkar.limit.shed` refuses under load — all in `akkar/limit.lua`, all
  shared across processes through Redis so the limit is the deployment's
  and not the process's.
- **Retry.** Off unless asked for, in both places it exists: `akkar/jobs.lua`
  (`retries`, `backoff`) and `akkar/http.lua` (`retries`, and
  `retry_unsafe = true` before a non-idempotent method may be retried, so
  nobody double-charges by accident).
- **Circuit breaker.** Absent. A search of `akkar/` for `breaker` or
  `circuit` finds nothing but the word "short-circuit" in a comment of the
  vendored HTTP. `akkar.breaker` — Closed, Open, Half-Open,
  composing with the deadline that already exists — is **in progress**. Until
  it lands, a dead upstream is handled by deadlines alone, which bounds the
  damage per request and does nothing to stop the next request paying it.

---

## 7. No typed ORM — out of scope, deliberately

The critique is accurate and the answer is a refusal, recorded with its
reasons in `docs/why/what-akkar-does-not-do.md`. An ORM is an opinion about
modelling, and akkar declines to have one.

What it has instead is narrower and aimed at the mistake that matters:
`akkar/sql.lua` composes conditions from data with `?` placeholders numbered
into `$1, $2` once at assembly, and has no `where_raw`, because an escape
hatch is where the injection goes. `db:transaction` in `akkar/db.lua` is
closure-scoped, so an orphaned `BEGIN` is unrepresentable, and nested calls
become savepoints. Tenant scope (`akkar/scope.lua`) refuses raw SQL
altogether, on the grounds that a string cannot be scoped without parsing it.
Migrations were excluded alongside the ORM and then built —
`akkar/migrate.lua`, up-only, advisory-locked — because a runner is a ledger
and a lock, not a modelling opinion, and the exclusion page records the
reversal.

---

## 8. Observability — partial, ahead of the assumption, one gap named

The critique: no OpenTelemetry, no standard metrics, logs that are strings.

The three legs each exist, and the trace leg has a property the critique's
usual reference implementations do not:

- **Traces.** `akkar/trace.lua` speaks W3C Trace Context in both directions —
  an inbound `traceparent` is validated rather than trusted, exposed as
  `req.trace`, echoed on the response and forwarded on outbound calls — and
  exports OTLP spans over `akkar.http`. Its one rule: **a request is never
  blocked on an export.** `record` appends to a bounded queue; when the
  queue is full the span is dropped and counted; a failed batch is dropped,
  not retried. `spec/trace_spec.lua` proves it by handing the exporter a
  client that raises on contact and serving 200s through it.
- **Metrics.** `akkar/metrics.lua` renders Prometheus text with no dependency,
  labelled by route pattern and never by request path, so `/users/:id` is one
  series and not three million.
- **Logs.** `akkar/log.lua` emits one JSON object per line or a human format,
  and `req.log` is a logger already bound to the request id, so correlation
  is a property of the logger rather than a discipline every call site has
  to remember. `app:on_error` (`akkar/init.lua`) is the hook an error
  reporter attaches to.

The gaps, in order of value:

- **Logs and traces have no common key.** `akkar/execution.lua` binds
  `request_id` and the caller's `client_request_id` into `req.log`; it does
  not bind `trace_id` or `span_id`, and the span does not carry the request
  id. Today a log line and a span from the same request cannot be joined.
  Small fix, high value, **in progress**.
- **Only traces leave the process in OTLP.** Metrics are Prometheus text and
  logs are stderr. OTLP exporters for both, reusing `trace.lua`'s
  never-on-the-request-clock pattern, are **in progress**.
- **Error reporting is a hook, not an exporter.** A Sentry-shaped exporter
  over `app:on_error` is **in progress**.

---

## 9. Performance — neutralized as positioning; the ceiling is real and scoped

The critique: V8 and Go beat the interpreter, OpenResty is 8.75x faster on
`/ping`, and a Lua framework starts every comparison behind.

The 8.75x is real and current (`docs/why/slower-than-openresty.md`). What is
inside it is the useful part, and `bench/study/WHERE-THE-GAP-IS.md` measured
it rather than reasoning about it:

- **The language is not the ceiling.** A minimal real HTTP/1.1 server in
  interpreted Lua 5.4 — request line, headers, body, routing — runs at 1.69x
  Gin on the same two cores. The Lua event loop costs 11.6 µs per request;
  Gin costs 19.6.
- **OpenResty's speed is nginx, not LuaJIT.** LuaJIT accounts for 1.62x of
  the 9.4x gap; nginx's C event loop and parser account for the rest. Making
  akkar as fast as OpenResty is a proposal to write nginx.
- **The gap is widest where the work is smallest.** On `/ping` akkar is 0.19x
  of Gin. On `/rows/200`, two hundred rows out of Postgres with the C driver
  (`akkar.pq`), it is 0.48x of Gin with a p99 of 6.53 ms against Gin's 7.04.
  The more a request does, the less the framework costs relative to it.

The ceiling is stated as arithmetic, with its label: replacing lua-http's hot
path reaches about 0.35x of Gin on `/ping`, halving akkar's own cost on top of
that reaches about 0.6x, and parity would need akkar's own 44.6 µs to become
8, which is the router, the chain, the deadline and the JSON encoder — the
things akkar exists to provide. So parity on `/ping` is not a target and
0.35x to 0.6x is. The positioning that follows is `docs/why/what-the-runtime-is-for.md`'s:
boot time, density, isolation and a single artefact, with throughput a number
that is published and not chased.

---

## The thesis, restated against the evidence

Five rows are neutralized or refused by decision, and in every one of them
the mechanism is the same: the runtime chose. One version, so
`math.type` and `<close>` are simply available. One event loop, so a deadline
is a number and a watchdog can exist. One validator, so a document and a
client can be projected from it. One HTTP stack, owned, so a CVE is a patch
with a ledger row and not a wait for upstream.

Four rows carry real gaps — the substrate risk, durable workflows, the
breaker, the correlation key — and none of them is a property of Lua. Each,
except the substrate, is a module that has not been written, with a design
that composes existing primitives, and each is marked *in progress* above
rather than claimed. The substrate one is owned rather than closed, and
`docs/substrate/CQUEUES.md` says what owning it means. When they land, this page should say so with a file beside each; a
row that changes verdict without a file beside it should be treated as an
opinion.

## What this page does not say

- **Nobody has built an application on akkar.** Every defect named on this
  page was found by engineering an exposure, and every verdict is a statement
  about the tree rather than about a team's experience with it. That is the
  largest gap in the evidence and no scorecard closes it.
- **The in-progress rows are plans.** A Postgres job store, `akkar.breaker`,
  `akkar.workflow`, OTLP metrics and logs, log-to-trace correlation, per-route
  Teal and LuaLS declarations: none is in the tree, and the page marks each
  one rather than rounding it up.
- **The substrate row is not closed by this page.** The fix to
  `akkar/health.lua` is in the tree and unproved: no CI run carrying it had
  gone green at the time of writing, and the only proof that will count is
  the one CI gives.
- **The numbers are borrowed.** Every figure here is cited from the page that
  measured it, with that page's own caveats — three repetitions on the floors,
  a fixture retired on 2026-08-18, boxes that no longer exist. Read the source
  before quoting the number.
