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

## 1. Platform — the one that was found by being asked

**Status: a real gap, now being measured rather than assumed.**

CI runs `ubuntu-24.04` and nothing else. There is no mention of `arm64`,
`aarch64`, `macos`, `darwin` or `windows` anywhere in `.github/workflows/`,
`docs/RUNTIME.md` or `docs/DEPLOY.md`. Every measurement in this repository
was taken on Linux, glibc or musl, x86-64.

What that leaves unknown, in rough order of likelihood to bite:

- **ARM64.** Now the default on Apple laptops and cheap on every cloud. The C
  dependencies — cqueues, luaossl, lua-cjson, lpeg, and akkar's own libpq
  binding — have never been compiled for it here.
- **macOS.** Different libc, different `kqueue` rather than `epoll` (cqueues
  supports both, unverified here), different OpenSSL provenance.
- **32-bit.** `lua_Integer` is 64-bit on a 64-bit build and akkar's C driver
  binds integers as `int8` on that assumption; `strtoll` and `size_t` appear
  in `src/akkar_pq.c` without a size audit.
- **Windows.** Almost certainly not, and saying so is better than leaving it
  ambiguous.

## 2. Correctness over time, as opposed to resources over time

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
- **the clock jumping** — NTP stepping backwards, which every deadline in the
  framework is exposed to and which `akkar.time` was built to make testable
  and has never been tested against

## 4. Resource exhaustion at the ceiling

What akkar does *approaching* a limit is measured. What it does *at* one is
not: file descriptors exhausted, memory limit reached in a container, the pool
saturated for minutes rather than seconds, a connection count above what
Postgres will accept.

The saturation study went to 4× capacity and stopped, and it stopped because
that was the interesting part of the curve, not because the rest was checked.

## 5. Encoding, locale and time zone

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

`akkar/substrate.lua` repairs two lua-http defects by patching its methods at
runtime. Nothing checks what happens when lua-http changes those methods —
the patch is guarded against an unrecognised shape, which is honest, but no
test pins the guard firing.

More generally: cqueues is pinned to a commit of master, pgmoon and luaossl
are not, and nothing exercises a version bump.

## 8. Observability during an incident

akkar has structured logs, metrics and trace propagation. Nobody has taken an
induced failure and asked whether those three are enough to diagnose it. A
metric that exists and does not answer the question is a metric nobody will
miss until the night they need it.

## 9. Security, reviewed by somebody trying to break it

`akkar.jwt`, `akkar.session`, `akkar.csrf`, `akkar.auth` and `akkar.crypto`
were written carefully and tested against the attacks their authors knew
about, including the two classic JWT confusions in their strong form. That is
not the same as an adversarial review. Self-written security tests find the
attacks you thought of.

## 10. The one that finds what none of the above can

**Porting a real application.** This was named at the start of the hardening
work and remains the largest gap. Engineered exposure finds the class of
defect you know how to look for; a port finds the ten or twenty gaps nobody
planned for, which is exactly the category everything above is trying to
approximate and cannot.

Every gap found this session was found by engineering. **None was found by
use.**

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
