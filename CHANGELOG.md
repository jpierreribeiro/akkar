# Changelog

akkar has not been released yet. Everything below is `Unreleased`, and the
version number is deliberately not chosen here — see **Choosing the first
number** at the bottom.

The format follows [Keep a Changelog](https://keepachangelog.com/). Dates are
the day the work landed on `main`.

## Unreleased

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

### Known limitations

Stated rather than discovered:

- **No `down` migrations, ever.** A down migration is written against a schema
  and run against data.
- **`akkar.compress` ships no compressor.** There is no zlib in this
  environment and adding a C dependency for it was refused; the encoder is
  supplied by the application, and a compressor-less configuration fails at
  registration rather than silently not compressing.
- **Lua 5.5 is blocked** on luaossl.
- **One core per process.** akkar answers more CPU with more processes and
  `SO_REUSEPORT`, measured linear across physical cores.
- **`akkar.pq` is opt-in**; pgmoon remains the default until a soak says
  otherwise.

## Choosing the first number

This is the one decision in this file that is not mine to make, so it is
written as a recommendation rather than as an entry.

**`0.1.0` is the honest number.** Not `1.0.0`: that promises the API will not
break, and several things here are two days old and have never been used by
anybody outside this repository. Not `0.0.1` either — that reads as a sketch,
and 874 tests, a soak and a measured deployment are past a sketch.

What `0.1.0` commits to, and what it should say in the release notes:

- the API may change before `1.0.0`, and changes will be listed here;
- what is measured is measured, and corrections appear rather than edits;
- the substrate repairs are carried until upstream moves.

`1.0.0` is worth waiting for one thing in particular: **a real application
built on this by somebody who did not write it.** Every gap found this session
was found by engineering exposure rather than by use, and the ones use finds
are the ones nobody plans for.
