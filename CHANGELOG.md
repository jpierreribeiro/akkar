# Changelog

The first release is `0.1.0`, tagged 16 August 2026. The reasoning for that
number rather than `1.0.0` is at the bottom and has not changed.

The format follows [Keep a Changelog](https://keepachangelog.com/). Dates are
the day the work landed on `main`.

## Unreleased

Reconciling `ecommerce-validation` into `main`. The two lines of work left the
same base and never met: 216 commits one way, 15 the other. Each item below is
one commit with a spec that failed before it and passes after.

### Changed — these break code that works today

- **`akkar.idempotency` requires `namespace`.** The idempotency key is a header
  the CLIENT chooses, so one global keyspace let a tenant replay another
  tenant's stored response body. Pass a resolver, or `namespace = false`
  (`idempotency.GLOBAL`) to state that the application is single-tenant.
- **`req.id` is akkar's own and is never the caller's `x-request-id`.** It is
  the concurrency limiter's slot identity and every log line's `request_id`, so
  a client choosing it collapsed limiter slots and wrote fields into the
  operator's log. What the caller sent is `req.client_request_id`, validated.
- **`Queue:reap(now)` takes an instant, not a window.** Staleness is the
  queue's `visibility` setting now. `reap(300)` on a fresh claim becomes
  `reap()`; `reap(-1)` becomes `visibility = 0` and a bare `reap()`. Omitted,
  the store reads its own clock, so the NTP-step fix is the default rather than
  something a caller can defeat.
- **`db.connect { ssl = true }` now REQUIRES TLS.** Postgres negotiates in
  cleartext and pgmoon continued over a plain socket unless `ssl_required` was
  set, reporting success. `ssl_required` follows `ssl` unless given; opportunistic
  TLS is `ssl_required = false`, said out loud.
- **`strict.off()` needs the key `strict.on()` returned.** It was a
  process-wide switch anything could throw.
- **A multipart body with two parts under one name is refused** (400) instead of
  last-wins, which is parameter pollution: the checker reads one, the handler
  uses the other.
- **`v.integer` refuses a float at or past 2^53**, and `inf`, `1e308` and `nan`.
  The old test asked for a fractional part, which every large float passes.
  Note what this costs: JSON has one number type, so an id above 2^53 sent as a
  JSON NUMBER is now refused rather than silently rounded. Send it as a string.
  A Lua integer that arrived exactly -- out of a query string, say -- is still
  accepted at any magnitude, because it is the integer it says it is.
- **A job queue states its delivery guarantee.** `delivery` is a field; asking
  for `at_least_once` over a store that cannot lease is refused rather than
  silently becoming at-most-once.
- **`repair_substrate` is gone, and `akkar.substrate` with it.** If you have
  `repair_substrate` in your `app:run{}` config, DELETE THE LINE — `App:run`
  now rejects unknown settings, so leaving it there is an error at boot.
  Nothing else changes: **you keep the repair either way, including if you had
  set it to `false`.** That is the whole reason this landed. The setting once
  gated a runtime monkey-patch of `http.h1_stream`; the repair moved into the
  source of akkar's vendored `h1_stream` some time ago, akkar stopped loading
  the upstream module, and the flag was left guarding a call that returned a
  constant. So `repair_substrate = false` had not opted anybody out of anything
  for a while — it read as a switch and was documented as one, which is worse
  than no switch at all. There is no replacement setting and there will not be
  one: a server that one header can stop is not a configuration.
  `akkar.substrate` (the module, its reference page, `M.apply`, `M.applied`,
  `M.rescued`) is deleted; its account of the defect — the reproduction, the
  measurements, the two repairs that do not work, and why the guard is written
  the way it is — is now in `docs/substrate/lua-http-wedge.md`.

### Added

- **`akkar.errors`** — the other end of `app:on_error`, which has documented
  `sentry:capture(err, ...)` since early on against nothing. Captures the
  request id, trace id, span id, route PATTERN, method, status and a sanitised
  message; delivers to a function or to any URL that reads JSON, on the
  background loop `akkar.trace` already had. Not the Sentry envelope protocol.
  The 500 is unchanged: the hook declines, so the client still gets the bare
  `{"error": "internal server error"}`.
- `job.uid`, stable across every retry and redelivery — the key a handler dedups
  on, without which "your handler will sometimes run twice" is unusable advice.
- `max_lifetime` and `idle_timeout` on the connection pool, so a socket the
  other end has already closed is retired rather than handed out.
- `read_timeout`, and `App:run` checking what every setting IS rather than only
  that its name is allowed.
- `name` and `namespace` on both rate limiters; `Registry:counter` on metrics;
  `for_update`, `skip_locked` and typed casts on `akkar.sql`.

### Fixed

- **A tenant scope that was present in the text and absent from the meaning.**
  Conditions were joined with " and " and never parenthesised, so a handler's
  own `or` captured the scope. Reproduced against Postgres reading and deleting
  another tenant's rows.
- **Join values bound in call order while the text was emitted in clause
  order**, so an ACL check ran against the tenant id.
- **A mount cycle recursed until the process died**, on one unauthenticated
  `GET /openapi.json`.
- **A middleware's header writes landing on a hoisted response**, so one
  client's `Set-Cookie` reached the next.
- **A middleware that forgot to return became a silent 204** rather than a 500
  naming it.
- **A nested transaction that was no transaction**: the inner `commit` ended the
  outer one and the outer `rollback` was a no-op. Savepoints now.
- **The pool handing out connections that had died**, and a refused websocket
  decrementing an in-flight count it never raised, which let a drain finish
  early.
- **`max_concurrent` counting connections rather than requests**, and
  `STOP_ACCEPTING` that only stopped `accept()`, so a drain could not end.
- **An unparseable RESP header read as a nil reply**, leaving the body in the
  socket for the next caller's question.
- **The rate limiter sharing one bucket across every route and tenant.**
- **The logfmt writer having no escaping at all**, so any value reachable from a
  request could forge fields, and a newline could forge a whole line.
- **`work.chunked` building a yield and discarding it.**
- **A multipart boundary matched as a substring of any parameter**, and parts
  delimited by `--boundary` anywhere rather than at a line start.
- **An unbounded `method` label on metrics**, chosen by the client.
- **The in-memory database fake matching SQL needles as Lua patterns**, so
  `count "insert into ledger (order_id, amount)"` answered 0 for a query that
  ran.
- **Idempotency answering 500 with no `retry-after`** when its store could not
  answer, instead of 503.
- **HTTP/2 accepted a header list HTTP/1.1 would have refused.** `h1_stream`
  has capped header lines at 100 since it was vendored; the h2 half had no
  counterpart anywhere and advertised `SETTINGS_MAX_HEADER_LIST_SIZE` as
  infinity, leaving one bound: 400 KB of *compressed* block. HPACK is a
  compressor -- an indexed header field is one byte and appends a whole
  name/value pair -- so a single HEADERS frame that seeds a 4,000-byte value and
  then references it reached ~400,000 fields inside that cap, unauthenticated.
  Measured: 20,008 bytes decoded to 16,001 fields carrying 64 MB. h2 now enforces
  the same `max_header_lines = 100`, inside `hpack:decode_headers` rather than
  on its result, because by the time it returns the fields are already
  allocated. A request carrying more than 100 header fields over h2 is now
  refused, exactly as it already was over h1.
- **Duplicate header values were joined quadratically.** `req.headers` built
  repeats of one name with `existing .. ", " .. value`, rebuilding the whole
  accumulation each time -- in a count the peer chooses, on a path `req.ip` and
  therefore the default rate-limit key both take. Measured with 4,000-byte
  values: 1,000 repeats 1.8 s, 2,000 repeats 9.2 s, 16,000 repeats 364 s, none
  of it yielding. Collected and joined once now: the same 1,000 repeats cost
  0.043 s, and doubling the count doubles the cost instead of quintupling it.
- **HTTP/2 Rapid Reset, CVE-2023-44487, was open.** A peer could open a stream
  and cancel it at line speed for ever: `RST_STREAM` freed the stream slot
  before the next frame was read, so `MAX_CONCURRENT_STREAMS` was never
  approached by construction, while every cycle still cost a full HPACK decode.
  One million resets were accepted in 5.3 s with the active-stream count back at
  zero after each. `RST_STREAM` frames are now rate-accounted per connection --
  a token bucket, burst 100 (nginx's floor) or the advertised concurrency
  ceiling if higher, refilled at 33/s (nghttp2's rate) -- and a peer past it
  gets `ENHANCE_YOUR_CALM` (the code Go's `net/http2` uses for the same attack)
  as a connection error.

## 0.1.0 — 2026-08-16

### Added

**The outbound half of the framework, which did not exist.** akkar was complete
at receiving a request and empty at making one: the capability set was `db`,
`cache`, `log` and `clock`, none of which leaves the process. It now has

- `akkar.http` — an HTTP client as a capability, with a response ceiling
  enforced in the read loop, retries that refuse to repeat a POST unless asked,
  and `traceparent` propagation.
- `akkar.crypto` — PBKDF2 password hashing, HMAC, constant-time comparison and
  a CSPRNG, over the OpenSSL that luaossl already linked for TLS.
- `akkar.session` — server-side sessions behind a signed, opaque cookie.
- `akkar.auth` — sessions, bearer tokens and API keys, resolved once before the
  handler runs.
- `akkar.jwt` — **verify only**. There is no way to issue a token, on purpose.
- `akkar.csrf` — for cookie-authenticated requests, and only those.
- `akkar.migrate` — plain SQL files, applied once, in numeric order, under an
  advisory lock, with the ledger row written in the same transaction.
- `akkar.health` — liveness that does not touch the database, readiness that
  may.
- `akkar.config` — typed configuration with secrets that cannot be printed by
  accident.
- `akkar.compress` and `akkar.static` — response compression with a pluggable
  encoder, and file serving with the path-traversal surface closed.
- `akkar.trace` — span export that never blocks a request and drops rather than
  waits.
- `akkar.pq` — a Postgres driver on libpq, asynchronous through cqueues,
  opt-in with `db.connect { driver = "pq" }`.
- `akkar.substrate` — repairs for two defects in lua-http (below).
- `akkar.watch` — restart on save, for development.
- `akkar build`, `akkar archive`, `akkar run` — a single self-contained binary.

**A deployment story that was tested rather than described.** `Dockerfile`,
`railway.json`, `docs/DEPLOY.md`. The final image is `scratch` with two files
in it and measures **6.4 MB**; it serves HTTP, resolves DNS and queries
Postgres with no libc present.

**Documentation for people who have not built a backend before**, in
`docs/guide/`, with a test that executes every example in it.

### Fixed

**Two denial-of-service defects in lua-http**, both reachable with a single
header and neither fixable upstream — its last commit is September 2024.
`Content-Length: banana` leaves the server SPINNING inside `stream:shutdown`,
starving the accept loop while the port stays open; `Content-Length: -5`
raises out of the same call and exits the process. `akkar.substrate` repairs
both, and a test proves the repair is the reason by starting a server without
it and requiring that one to die.

**A rate limiter that failed closed.** `akkar.limit` sent its EVAL without a
pcall, so an unreachable Redis produced a 500 on every request — a cache
outage became a total outage, caused by the module whose job is keeping the
service up.

**Three places that wrote onto the table a handler returned**, which is shared
when a handler returns a hoisted or memoised response: `akkar.limit`,
`akkar.etag`, and the session cookie in `akkar.auth`. For an etag the
consequence has a name — a cached payload keeps the first caller's tag after
the payload changes, so every client holding the old version is told 304 for
ever.

**A `401` that was answered `200`.** `akkar.auth` returned the refusal as a
bare table, and akkar treats anything without `__response` as a JSON body. A
client checking `status == 200` read a rejected credential as accepted.

**Migrations ordered as text**, so `2`, `9` and `10` ran as `10`, `2`, `9`.
Now ordered by numeric id, with duplicate ids and missing ids refused.

**Migrations could not run from the binary akkar builds.** Listing a directory
needs `/bin/sh`, which a scratch container does not have. They may now travel
as data.

**Error messages that named neither the mistake nor the fix** — a bind failure
that did not say which port, and `req.body` being nil producing only "attempt
to index a nil value". Both found by writing documentation for beginners.

**Five defects found by people reading the source to document it**, none of
which a test had caught:

- **The idempotency fingerprint differed between processes.** It hashed
  `cjson.encode(body)`, and cjson walks a Lua table in hash order with a
  per-process seed — twelve processes produced twelve fingerprints for one
  body. In a fleet sharing one Redis, a retry landing on another worker was
  answered 422 "already used for a different request": the module refusing the
  honest retry it exists to make safe. Canonical now, and whole floats are
  normalised so `7` and `7.0` are the same request.
- **`Queue:consume` spun instead of waiting** when the store was told not to
  block. Against Redis it never showed, because `BRPOP` waits server-side and
  yields; against the in-memory store the loop had nothing to yield to and took
  a whole core, and the server sharing the process stopped answering.
- **The job stores dropped every option.** `memory.new("emails", { retries = 3 })`
  produced a queue with `retries = 0` in silence, because the constructors
  never forwarded options to `jobs.new`.
- **`Registry:gauge` raised on every labelled call**, so the metrics renderer
  carried complete label support that could not be reached.
- **`akkar.limit.rate` throttled health checks**, so twelve probes answered 429
  and an orchestrator restarted a healthy process.

**Jobs, pools and capabilities**, from an earlier audit: a capability leaked on
write failure, a Redis socket leak, job destruction from a non-atomic
`ZREM`/`LPUSH`, a pool whose `live` count could go negative, and an
undecodable job that cycled between the queue and the processing set for ever
while logging that it had been discarded.

### Changed

- **`akkar.limit` now fails open** when its store is unreachable, and counts
  the failures so an operator can alert on them. A store that is *absent* is
  still an error, because that means the application believes it is limited
  and is not.
- **Migration files require a numeric id prefix.** A timestamp is recommended
  over a counter: two people branching from the same commit both pick `007`,
  and two timestamps cannot collide.

### Corrected

Measurements this project published and then found to be wrong. They are listed
because a corrected number is worth more than a quiet edit.

- **The driver benchmark ran on a machine with twenty-two spinning processes
  on it**, left by a test that wedges a server on purpose and cleaned up on its
  last line. Re-measured quiet, the speedup at a thousand rows fell from 3.91x
  to 3.01x. The contamination flattered the thing being sold.
- **"330 us through pgmoon" was being read as what pgmoon adds.** The floor —
  the same query through blocking libpq with no Lua at all — is 166 us on that
  machine, so pgmoon adds 54 us on a single row, not 220.
- **A saturation table labelled median-of-three was best-of-three.**
  `bench/study/RESULTS.md` §8 carries the retraction and says which conclusions
  move.
- **`akkar build` could not support Lua 5.5 "because cqueues needs a fork"** —
  false; the blocker is luaossl having no 5.5 target.
- **And then: "the blocker is luaossl"** — also false, and this file said it
  above before the line was ever tested. luaossl has no 5.5 *target*; its C
  compiles against 5.5 with zero changes and zero warnings, which one `cc`
  shows. Built that way, with `cqueues`'s vendored compat shim refreshed, the
  **entire suite passes under Lua 5.5: 1763 passing, 0 failures**, against
  1801 on 5.4. The 38-test difference is tooling and not the language: 32 are
  the C driver, which skips until its `.so` is rebuilt for the other ABI, and 6
  are the Teal declarations, which skip because `tl` is not installed there.
  Twice this project
  named a blocker by reading a build system instead of running a compiler, and
  both times the named library was innocent. `docs/runtime/lua55-stack.sh` is
  the recipe, and CI runs that same script so the claim cannot go stale again.

### Known limitations

Stated rather than discovered:

- **No `down` migrations, ever.** A down migration is written against a schema
  and run against data.
- **`akkar.compress` ships no compressor.** There is no zlib in this
  environment and adding a C dependency for it was refused; the encoder is
  supplied by the application, and a compressor-less configuration fails at
  registration rather than silently not compressing.
- **Lua 5.5 runs, but nothing packages it.** The suite passes complete under
  5.5; `luarocks install akkar` still cannot get you there, because the C layer
  needs building from source. 5.4 remains what a user gets by default.
- **One core per process.** akkar answers more CPU with more processes and
  `SO_REUSEPORT`, measured linear across physical cores.
- **`akkar.pq` is opt-in**; pgmoon remains the default until a soak says
  otherwise.

## Why 0.1.0 and not 1.0.0

**`0.1.0` is the honest number.** Not `1.0.0`: that promises the API will not
break, and several things here are two days old and have never been used by
anybody outside this repository. Not `0.0.1` either — that reads as a sketch,
and 1,619 passing tests -- 603 of them documentation examples that are
executed rather than read -- an eight-hour soak and a measured deployment
are past a sketch.

What `0.1.0` commits to, and what it should say in the release notes:

- the API may change before `1.0.0`, and changes will be listed here;
- what is measured is measured, and corrections appear rather than edits;
- the substrate repairs are carried until upstream moves.

`1.0.0` is worth waiting for one thing in particular: **a real application
built on this by somebody who did not write it.** Every gap found so far was
found by engineering exposure rather than by use, and the ones use finds are
the ones nobody plans for.

The evidence for that is a few hours old. Four people were sent to write
documentation by reading the source, and they found **five defects in code
carrying a thousand passing tests** — an idempotency fingerprint that differed
between processes, a job consumer that spun instead of waiting, job stores
that dropped every option they were given, a metrics gauge that raised on
every labelled call, and a rate limiter that throttled health checks into a
restart loop. None of those was found by a test. All of them were found by
somebody trying to use the thing and write down what happened.

`docs/UNKNOWNS.md` lists the instruments that have not been pointed at akkar
yet. A version number promising stability, published before those, would be
promising something nobody has checked.

### What 0.1.0 does and does not promise

- **Does:** everything in this file is measured or corrected, never asserted.
  1,619 tests pass, 603 of them documentation examples that are executed. Eight hours of
  soak show no memory drift. It builds and passes on Linux x86-64 and on
  aarch64/musl.
- **Does not:** promise a stable API. It will change, and changes will be
  listed here.
- **Untested, and named rather than implied:** macOS, Windows, 32-bit, and
  every platform outside Linux. See `docs/UNKNOWNS.md`.
