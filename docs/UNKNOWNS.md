# What we have not looked at

> Written after being asked a fair question — *if the platform matrix was
> missing and nobody noticed, what else is missing that we do not know about?*
> — and after answering the first half of it wrongly by asserting instead of
> checking.

## The pattern this document exists because of

Every defect this project has found was found by pointing a **lens** at it,
and each lens found a class the others could not:

| lens | what it found |
|---|---|
| Resource-lifetime audit | 7 leaks: capabilities, sockets, pool slots |
| Framing fuzz against a real server | a lua-http denial of service costing one header |
| 8-hour soak | that memory does NOT drift — the negative result it was for |
| Saturation sweep | the knee, and the sizing rule that came from it |
| Driver comparison | that "330 µs pgmoon" was being read as what pgmoon *adds* |
| **Writing beginner documentation** | 9 defects, mostly error messages nobody had read |
| **Deploying for real** | migrations cannot run from the binary akkar builds |
| Reading two rival implementations | migrations ordered as text: 2, 9, 10 ran as 10, 2, 9 |
| A cloud review of the branch | 4, two of which were false sentences in our own comments |

The lesson is not that the project is careless. It is that **a defect is
invisible until somebody points the right instrument at it**, and the
instruments applied so far were chosen by whoever happened to be working.

So the honest answer to "what else is missing" is: **the classes no lens has
been pointed at.** Here they are, as far as they can be enumerated.

---

## 1. Platform — MOSTLY CLOSED. See `docs/PLATFORMS.md`

**Status: measured. Linux x86-64, Linux arm64 and macOS arm64 all run the full
suite in CI.**

ARM64 went green on the first run with no changes. macOS took seven, and only
one of the seven was about akkar rather than about the build or the harness: a
cqueues controller costs **three** descriptors on kqueue against two on epoll,
which is most of the number `descriptor_ceiling()` divides by — most, because
the request also holds its own socket, and that was found later and separately:
the divisor was 2 when a request in flight costs 3, so the ceiling promised
half again as much concurrency as the box could serve. `docs/PLATFORMS.md` has
the counts. Three real defects came
out of it — `akkar watch` was silently dead off Linux, `Registry:memory()`
reported a resident size of zero, and the test harness called five Linux-only
commands by name.

The full account, with the numbers, is `docs/PLATFORMS.md`.

What is still genuinely unknown:

- **32-bit.** `lua_Integer` is 64-bit on a 64-bit build and akkar's C driver
  binds integers as `int8` on that assumption; `strtoll` and `size_t` appear
  in `src/akkar_pq.c` without a size audit.
- **musl.** Alpine is the common container base and has not been run.
- **Intel macOS.** The matrix runs Apple Silicon. Prefixes are resolved rather
  than hardcoded, so it should work, and "should" is the word doing the work.
- **Windows.** Almost certainly not, and saying so is better than leaving it
  ambiguous.

## 2. ~~Correctness over time~~ — CLOSED

The soak now captures the answer at startup and compares it byte for byte
every sample, printing both bodies on a divergence. Proven to fire against a
server rigged to drift. What follows is the original statement.

The 8-hour soak measured RSS, descriptors and throughput. **It never checked
that the answers were still right.** A server that starts returning the wrong
row at hour six passes that soak perfectly.

Nothing in the run compared a response body against an expectation after the
first minute.

## 3. Infrastructure failure injection

`akkar/db/memory.lua` can now `:hang()` and `:drop()`, which covers a query
misbehaving. Nothing covers the layer below:

- the database restarted underneath a live pool
- a Redis failover, or a replica promoted mid-request
- DNS failing, or resolving to something new
- the disk filling while logs are being written
- ~~**the clock jumping**~~ — **CLOSED.** Measured, and it was worse than
  feared: one worker's clock stepping forward reaped the whole fleet's live
  claims. The Redis store now reads the server's clock, so the caller's is
  never consulted. Deadlines were always immune, being monotonic.

## 4. Resource exhaustion at the ceiling

What akkar does *approaching* a limit is measured. What it does *at* one is
not: file descriptors exhausted, memory limit reached in a container, the pool
saturated for minutes rather than seconds, a connection count above what
Postgres will accept.

The saturation study went to 4× capacity and stopped, and it stopped because
that was the interesting part of the curve, not because the rest was checked.

## 5. Encoding — CLOSED for encoding, still open for locale and time zone

Ten hostile byte sequences now go through paths, headers and bodies
(`spec/encoding_spec.lua`). It found sixteen real failures: akkar echoed
non-UTF-8 bytes into JSON responses. Fixed at the request boundary rather
than on every response, because validating output measured at 20.8% and 59.9%
overhead. Locale and time zone remain untested. Original statement follows.

No test sends a non-UTF-8 byte sequence in a header, a path, or a JSON string.
No test runs under a non-UTF-8 locale or a non-UTC timezone. `os.date`,
`os.time` and Postgres `timestamptz` all behave differently under those, and
akkar has database timestamps crossing a JSON boundary.

## 6. Scale of shape rather than scale of traffic

Ten thousand routes. A thousand headers. A JSON body nested five hundred deep.
A single header a megabyte long. A result set of a million rows. Each of these
is a different failure from "lots of requests", and the router, the validator
and the encoder have only ever seen small shapes.

## 7. Dependency movement

akkar repairs two lua-http defects. They were runtime monkey-patches in
`akkar/substrate.lua`, and this section used to ask what happens when lua-http
changes the methods being patched. **That unknown is closed by construction:**
the repairs now live in the source of `akkar/vendor/http/h1_stream.lua`
(`docs/substrate/lua-http-wedge.md`), so they cannot silently stop applying —
an upstream that changed shape would produce a merge conflict when the vendored
copy is refreshed, not a patch that quietly no-ops.

More generally: cqueues is pinned to a commit of master, pgmoon and luaossl
are not, and nothing exercises a version bump.

## 8. Observability during an incident

akkar has structured logs, metrics and trace propagation. Nobody has taken an
induced failure and asked whether those three are enough to diagnose it. A
metric that exists and does not answer the question is a metric nobody will
miss until the night they need it.

## 8b. The two protocols that arrived in two days

**Added 2026-08-19, and the fact that this section had to be added is itself
the finding.** HTTP/2 shipped on the 18th and WebSocket on the 19th, and until
this paragraph existed neither appeared anywhere in this document. The README
points here calling it the honest list of what is not known; a list that does
not know about two whole subsystems was not that.

What IS known about them, so the unknowns below are the actual remainder:
h2spec 2.6.0 passes 146 of 146 with nothing skipped; 22 hostile HTTP/2 frame
shapes and 15 hostile WebSocket ones leave the server answering; one connection
is bounded to 100 concurrent streams and a socket message to `body_limit`.

**What is not known:**

- **The h2 and WebSocket framing layers are upstream lua-http 0.4's**, and
  nobody here has read them line by line. Two defects have been found in them
  by accident, both by measurement rather than by review: a frame header read
  that raised on a short read, and a message size nobody bounded. A reviewer
  looking on purpose would probably find more.

- **Nothing has held sockets open for a long time.** The longest WebSocket
  measurement here is seconds. What a thousand sockets look like after six
  hours, whether the idle timeout interacts with a peer that pings just often
  enough, and whether the registry stays consistent across a reload, are all
  unmeasured.

- **h2 under a hostile flow-control peer.** WINDOW_UPDATE games, a peer that
  advertises a window and never reads, and the CONTINUATION flood that has its
  own CVE class in other servers, are not covered by the 22 shapes.

- **The interaction between h2 multiplexing and the pool.** 100 concurrent
  streams on one connection can ask for 100 database connections, and the
  pool's fairness was measured under HTTP/1.1 arrival patterns rather than
  under a burst that arrives on one socket in one event loop turn.

- **WebSocket under TLS at volume.** `wss://` is verified to work. Nothing has
  measured what a thousand of them cost, or what happens to the handshake rate
  when OpenSSL is doing the work.

## 9. Security, reviewed by somebody trying to break it

`akkar.jwt`, `akkar.session`, `akkar.csrf`, `akkar.auth` and `akkar.crypto`
were written carefully and tested against the attacks their authors knew
about, including the two classic JWT confusions in their strong form. That is
not the same as an adversarial review. Self-written security tests find the
attacks you thought of.

## 10. ~~The one that finds what none of the above can~~ — STARTED

**Done once, and it worked.** One vertical slice of a live escrow platform —
eleven endpoints out of 105 — found **six defects in under an hour**, including
one that served an authenticated route with no credential: `app:mount`
discarded the mounted app's middleware entirely. See `docs/PORT-FINDINGS.md`.

The instrument is no longer unpointed, but the sentence below still stands for
everything it has not touched: no worker, no webhooks, no frontend, no load,
and ninety-four routes.

**Porting a real application.** This was named at the start of the hardening
work and remains the largest gap. Engineered exposure finds the class of
defect you know how to look for; a port finds the ten or twenty gaps nobody
planned for, which is exactly the category everything above is trying to
approximate and cannot.

Every gap found in the engineering sessions was found by engineering. The port
changed that: of its six findings, the one that matters most — a mounted app
serving protected routes to anybody — had been sitting in `docs/HANDOFF.md`
for a day, listed beside ergonomic gaps, because nobody had tried to
protect a group of routes.

---

## What this means for 1.0

Not "wait until this list is empty" — it will never be empty, and a list of
unknowns is not a bug list. What it means is narrower:

**Items 1, 2 and 5 are cheap and are answers, not projects.** A CI matrix, an
assertion inside the soak loop, and a handful of hostile encodings. They
should be done before a number that promises stability, because each of them
can only produce a yes or a no.

**Item 10 is the one 1.0 should actually wait for**, and it is the reason
`CHANGELOG.md` recommends `0.1.0`. A version number is a promise about
stability made to people who were not involved in writing it, and nobody
outside this repository has written a line against this framework yet.
