# Completing akkar — everything that is missing, in the order it should be built

> Written 16 Aug 2026, after an inventory of the repository rather than from
> memory. `docs/PLAN.md` remains the statement of what akkar *is*; this is the
> statement of what it does not yet *have*.

> **Superseded in part, 1 Sep 2026.** Tier 0 and Tier 1 were built. `akkar.http`,
> `akkar.crypto`, `akkar.jwt`, `akkar.auth`, `akkar.session` and `akkar.csrf` all
> exist and are documented in `docs/reference/`; `req.http` is a capability like
> any other. `docs/UNKNOWNS.md` section 9 already treated them as shipped code
> needing an adversarial review, one day after this page was written, and the
> README documented them the day after that. The diagnosis below is the state on
> 16 August and is kept because the ORDER it argues for is what was followed.
> Read the tier list as a record of the reasoning, not as a list of what is
> missing.

## The diagnosis, in one line

**akkar is complete on the inbound path and empty on the outbound path.**

Everything it owns — routing, validation, pooling, jobs, cache, rate limiting,
idempotency, metrics, OpenAPI, tenant scope, streaming, graceful shutdown — is
about *receiving* a request. Nothing in it *makes* one. That is why the gap
went unnoticed for two days: the entire suite and every benchmark exercise the
server.

The practical consequence is worth stating plainly: **akkar does not yet serve
a service that calls another service**, which is most real backends.

## Scope, decided rather than left open

**akkar is complete when it is complete for JSON APIs.** Tiers 0-4 below are
that, and there is no Tier 5.

The other reading of "a complete web framework" -- templates, HTML forms,
CSRF on form posts, flash messages, an asset pipeline, scaffolding -- was
considered on 16 Aug 2026 and **rejected**, which confirms what `PLAN.md` §1
has said from the beginning rather than reversing it.

The reason is not scope timidity. It is that reading is not an increment; it
is a **second product sharing a runtime**, and the thing it changes is the
invariant every other property rests on. akkar's handler *returns* a response
instead of mutating a context, and that single fact is what makes writing the
response twice structurally impossible, what makes OpenAPI derivable from the
schemas, and what keeps tenant scope enforceable because every read goes
through a builder. Template rendering erodes all three at once -- a renderer
wants to stream into a response that is still being assembled, which is
precisely the mutation the design refuses.

So a server-rendered akkar would not be akkar with more features. It would be
a different framework that happened to share the event loop, and it should be
decided as one -- with its own name and its own invariants -- rather than
arrived at by adding a template engine to this one.

## The rules every module below obeys

These are not new; they are what the existing modules already cost, and a new
module that skips them is how the invariants stop being invariants.

1. **Reached as a capability, never required from a handler.** The set is
   closed today — `db`, `cache`, `log`, `clock` — and each addition widens it
   deliberately, with a contract checked at boot (`CONTRACTS` in `init.lua`).
2. **A real in-memory implementation, not an inline fake.** `akkar.cache.memory`
   and `akkar.db.memory` are the precedent: the same contract tests run against
   both, so a test cannot prove a property the real adapter lacks.
3. **Deadline-aware.** Anything that yields takes the request's budget, or it
   becomes the next `read_body` — a place where a slow peer holds resources
   with nothing bounding it.
4. **Scope-aware where it touches tenant data**, and builder-shaped rather than
   string-shaped for the reason `akkar/scope.lua:15` gives.
5. **Under the allocation ceiling.** `spec/allocation_spec.lua` fails above
   2600 bytes per trivial request. It has caught two regressions of exactly
   this kind and it decides, not the author.
6. **No module ships without a spec that fails before the module exists.**

---

# Tier 0 — The outbound path

The diagnosed hole. Nothing else in this document is more urgent, because
every integration, every webhook, every third-party API and half of Tier 3
depends on it.

### 0.1 `akkar.http` — an HTTP client as a capability

`req.http`, pooled, deadline-bound, instrumented. What makes this a module
rather than a `require "http.request"` is everything around the transport:

- **Connection pooling per host**, on `akkar/pool.lua`, which already exists
  and already handles reservation-before-open and abandoned coroutines.
- **The request's deadline**, inherited. An outbound call that outlives the
  inbound request is a leak with a different name.
- **Retry with backoff, and idempotency awareness.** A POST is not safely
  retryable and the module must not pretend otherwise; `akkar.idempotency`
  already encodes that distinction for inbound and the same rule applies out.
- **Metrics and log correlation** — the request id propagates as
  `traceparent`, which akkar already parses inbound and has never emitted.
- **A response size limit.** The inbound side learned this the hard way
  (`body_limit`); an outbound call to a hostile or broken server has exactly
  the same failure and no limit today.

**Transport decision, stated because it will come up.** The fast path is
wrapping `lua-http`'s client — which means inheriting the library where this
project found a one-header denial of service on 15 Aug. The alternative is
binding libcurl, as `akkar.pq` binds libpq.

Recommendation: **wrap first, bind later if it hurts.** The value is in the
adapter, not the transport, and `akkar.pq` just demonstrated that swapping a
transport behind an adapter boundary costs one file. Deciding transport before
the adapter exists is the wrong order.

Proof: a spec against a real server in a subprocess (the `raw_client` harness
exists), including a peer that hangs — the `:hang()` seam added on 16 Aug is
the same idea one layer out.

*Size: one substantial session. Pooling and deadline are the work; the
transport is not.*

### 0.2 `akkar.crypto` — the primitives auth needs

OpenSSL is **already linked** via luaossl, so this is a module over primitives
that ship in the binary today, not a new dependency:

- password hashing (Argon2id if available, PBKDF2-HMAC-SHA256 as the floor)
- constant-time comparison — the detail whose absence is a real vulnerability
  and whose presence nobody notices
- HMAC, RSA/ECDSA signing
- cryptographically secure random tokens

**Password hashing blocks the event loop by design** — it is expensive on
purpose. `akkar/work.lua` exists for exactly this and this is its first real
customer. A hash that runs inline stalls every other request on the process,
which is the same failure as a slow query with none of the excuses.

*Size: half a session, plus care.*

### 0.3 `akkar.jwt`

On top of 0.2. Verification is the part that matters and the part usually got
wrong: reject `alg: none`, reject algorithm confusion (an RS256 key used as an
HS256 secret), check `exp`/`nbf`/`aud`/`iss`, and use the constant-time compare
from 0.2. `akkar.time` supplies the clock so expiry is testable without
sleeping.

*Size: half a session.*

---

# Tier 1 — Authentication, which everything above assumes

### 1.1 `akkar.auth`

Middleware, composable, in akkar's return-don't-mutate shape: a strategy
returns a principal or a 401, and never writes to the request.

- bearer tokens (JWT via 1.0, or opaque tokens via `cache`)
- API keys, compared in constant time and looked up by hash, never by value
- HTTP Basic, for the internal endpoints where it is still the honest answer

### 1.2 `akkar.cookie` and sessions

Parsing and setting, with signing over 0.2. Sessions backed by `cache`, which
means the memory and Redis adapters already give the two implementations.

**CSRF belongs here and only here.** A JSON API using bearer tokens does not
need it; a cookie-authenticated one absolutely does, and the module that
introduces cookies is the module that owes the defence.

### 1.3 Authorization

Deliberately thin: a permission check helper and a documented pattern. Roles
and policies are application decisions, and a framework that guesses them
produces the abstraction everyone fights. **`akkar.scope` already does the
part that must be structural** — tenant isolation — and the rest can be
functions.

*Size: one session for 1.1 and 1.2 together; 1.3 is mostly documentation.*

---

# Tier 2 — Data lifecycle

### 2.1 `akkar.migrate` — AND THIS REVERSES A DOCUMENTED DECISION

`docs/BACKLOG.md` lists migrations under "what is deliberately not being
built", permanently, alongside ORM and templating. That entry should be
retracted in the same voice the others were, or this should not be built.

The argument for reversing it: an ORM is a modelling opinion and akkar refuses
opinions about modelling, but a migration runner is **not** an ORM. It is a
ledger of applied files and a lock — a hundred lines of infrastructure with no
opinion about schemas at all. And `akkar build` produces a single binary whose
whole promise is "copy it to a server"; a binary that cannot bring its own
schema forward has an incomplete promise.

Scope, kept deliberately small: plain SQL files, up only, applied in order,
recorded in a table, guarded by an advisory lock so two instances starting
together cannot both run them. No down-migrations — they are usually wrong
under real data and encourage pretending a deploy is reversible.

*Size: one session. Small module, and the lock is the only subtle part.*

---

# Tier 3 — Production surface

### 3.1 Response compression
gzip via zlib, negotiated on `Accept-Encoding`, with a size floor below which
compressing costs more than it saves. Interacts with `akkar.etag` — the ETag
must be of the uncompressed body — and with streaming.

### 3.2 Health and readiness
Two endpoints, and the distinction is the point: **liveness must not touch the
pool**. `akkar/init.lua:1382` already records why — a health check that takes a
connection competes with real traffic exactly when the pool is exhausted, and
so reports unhealthy at the moment the answer needs to be "degraded and still
serving".

### 3.3 Tracing export
akkar parses `traceparent` inbound and emits nothing. With 0.1 in place, an
OTLP exporter over HTTP is a small module, and spans around the boundaries
that already exist — handler, query, cache, outbound call.

### 3.4 Config and secrets
Typed configuration from environment and file, validated at boot with the same
schema machinery routes use, failing at startup the way a duplicate route
already does. Secrets read from file or environment, and **redacted in logs by
construction** — a config value marked secret must not be printable, or the
first incident report leaks it.

*Size: one session for 3.1–3.2, one for 3.3–3.4.*

---

# Tier 4 — Delivery surface

Each of these is independently useful and none blocks the others.

| | notes |
|---|---|
| **Static files** | Range requests, ETag, `sendfile` if cheap. Small. Not a step toward server-rendered HTML -- serving a file and rendering a page are unrelated jobs. |
| **WebSocket** | lua-http has an implementation. Real question is lifecycle: a long-lived connection outside the request/response model needs its own capability and shutdown story. **Not small.** |
| **Email** | Over 0.1, to an HTTP API. SMTP is a protocol implementation and a different-sized job; `BACKLOG` currently excludes mail adapters and that exclusion is about *vendor* adapters, not about the capability. |
| **Object storage** | S3 over 0.1 plus SigV4 from 0.2. Mostly signing. |

*Size: static half a session; storage half; email half; WebSocket a full one on
its own.*

---

# Sequencing

```
0.2 crypto ──┬── 0.3 jwt ── 1.1 auth ── 1.2 cookies/sessions
             └── 4.3 storage signing

0.1 http ────┬── 3.3 tracing export
             ├── 4.3 storage
             └── 4.4 email

2.1 migrate      (independent)
3.1 compression  (independent)
3.2 health       (independent, trivial)
3.4 config       (independent)
4.1 static       (independent)
4.2 websocket    (independent, largest single item)
```

`0.1` and `0.2` are the two roots and neither blocks the other. Everything
worth having is within two steps of them.

**Rough total: eight to ten focused sessions**, WebSocket being the one item
that could double on its own. That is the whole of it -- there is nothing
after Tier 4, by decision rather than by omission.

# Risks, stated before they are discovered

- **Every module grows the binary and the allocation budget.** The ceiling is
  the judge and it has already refused two changes. A tier that pushes past
  2600 bytes per request does not get waved through.
- **`akkar.http` inherits lua-http's quality**, and this project has already
  paid for that once. The mitigation is that the adapter boundary makes libcurl
  a one-file swap — the same claim `akkar.pq` just made good on.
- **Auth is where a mistake is a vulnerability rather than a bug.** Constant-
  time comparison, algorithm confusion and token lookup by hash are the three
  that are silent when wrong. They get adversarial tests, not example tests.
- **Widening the capability set is not free.** Four is a set a person can hold
  in their head; ten is a framework like any other. Each addition should be
  argued for individually, and `http` is the only one below that is obviously
  worth it.
