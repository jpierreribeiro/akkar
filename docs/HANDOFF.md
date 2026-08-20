# Handoff, 20 August 2026

Written to be read cold, by somebody who was not in the conversation that
produced it. It assumes you know Lua and akkar's shape and nothing about the
last few days.

**Where everything is, and it is NOT lost.** Branch `f4-refused`, 33 commits
ahead of `main`, local and remote identical (`git rev-list --count HEAD...
origin/f4-refused` is `0 0`). Pull request #7 was already MERGED on the 18th --
that is why `gh pr list` shows no open PR -- but 31 commits were pushed to the
branch AFTER that merge and never reached `main`. Everything from the 19th and
20th is in those 33: HTTP/2, WebSocket, the crypto speedup, the pool leak fix,
the audit findings, cache:remember. To land them, open a NEW pull request from `f4-refused`;
the old one is closed and cannot be reused.

**The one-line state:** akkar speaks HTTP/2 and WebSocket, passes 146 of 146
h2spec conformance cases with nothing skipped, survives a CONTINUATION flood
and a decompression bomb, and runs 1,863 tests on Lua 5.4 and 1,814 on Lua 5.5,
head at `a19ea2b`,
green on Linux x86_64, Linux arm64 and macOS.

## What the last day added

- **`cache:remember`** collapses a thundering herd to one computation with a
  condition rather than a mutex, because one cooperative thread has no race to
  guard. Measured: 100 concurrent requests, 100 computations naive, 1 coalesced.
- **The Postgres pool leaked session state** (`SET search_path`, temp tables,
  session GUCs survive a connection's return). `db.connect { reset_on_release =
  true }` runs `DISCARD ALL`, opt-in because it costs 167 us and akkar's own
  `scope` isolation rewrites the query and never touches session state.
- **`crypto.to_hex` was 7.65x too slow** and cost more than the HMAC it renders;
  fixed by reading bytes in bulk with a fast path for the common size.
- **Two attacks fired at the box and held**: a CONTINUATION flood (refused at
  448 KB, GOAWAY, RSS flat) and a decompression bomb (400/415, RSS flat). Both
  came from an external audit; both were run for real, not read.
- **A subprocess-spawn spike proved the design closes** (see the open items).
- **An external research report audited the whole architecture** and, checked
  point by point, validated ten theses already verified here (CONTINUATION
  flood, pool leak, JWT, Amdahl, thundering herd, the determinism tie-break).
  It flagged one half-measured cost -- that `reset_on_release`'s `DISCARD ALL`
  might throw away a Postgres plan cache. Measured: it does not, because pgmoon
  uses the UNNAMED statement and keeps no named plan to lose. The first,
  sequential run said it did (331 us, "plan lost"); interleaved it was noise.
  Fifth time that trap was caught. It also named **Landlock** as the LSM to
  confine the subprocess child, which feeds open item 0.

---

## Waiting on you, and only these

1. **Open a NEW pull request from `f4-refused` to `main`.** PR #7 was merged
   on the 18th and cannot be reused; the 33 commits since then -- everything
   from HTTP/2 onward -- are on the branch and not on `main`. Nothing here
   depends on the merge, but nothing reaches `main` without it.

2. **Isolation against hostile code is a decision about product shape**, not a
   defect, and it is still yours. `akkar/vm.lua` states in its own header that
   a sandbox inside one Lua state is not a security boundary, and
   `spec/vm_spec.lua` covers every escape it does claim. What decides the shape
   is the price of a process per tenant, and that is measured: **28 ms to first
   response, 12.8 MB resident idle**, so 1.22 GB for a hundred idle exercises
   and 6.09 GB for five hundred. Cheap, and the only option that IS a boundary.
   `akkar.vm` keeps the smaller case: a hook published inside an application
   that is otherwise trusted.

3. **Publishing to luarocks.org**, which is a release step nobody has taken,
   and a compatibility policy, which does not exist. Both are decisions rather
   than work.

Everything else below is work, and none of it is blocked on you.

---

## The benchmark box

**It works again.** Address `98.80.193.148`, user `ubuntu`, key
`~/Downloads/colossus.pem`. The old address is dead; this is a fresh instance,
8 cores, `ulimit -n 1024`.

Provisioned with **the CI recipe rather than by hand**, deliberately, so a
number taken there and a number taken in CI mean the same thing: cqueues built
from the pinned commit `c36614982fe07917b2e1ce5a9e7a0e55b81be262` rather than
the 2020 rock. `spec/substrate_spec.lua` is green on it, and that gate runs
before anything is measured.

```sh
ssh -i ~/Downloads/colossus.pem ubuntu@98.80.193.148
cd ~/akkar-git && git fetch && git checkout f4-refused && git reset --hard origin/f4-refused

# two knobs the harnesses need on THIS box, because the checkout is not $HOME/akkar
ROOT=$HOME/akkar-git       bash bench/study/regression.sh origin/main HEAD
AKKAR_SRC=$HOME/akkar-git  bash bench/runtime/deploy.sh   # stages the four services
AKKAR_SRC=$HOME/akkar-git  bash bench/runtime/run.sh      # the four-way table
H2SPEC_CACHE=/tmp/h2       bash bench/h2spec.sh           # conformance
```

`provision.sh` installs the runtimes and `deploy.sh` stages the services. Both
are needed and only the first is obvious; running one without the other is how
the first four-way attempt measured nothing.

---

## What the numbers say now

**Against the neighbours**, all four on one box in one run, three alternating
repetitions, browser shape. `bench/runtime/RESULTS.md`, third run:

| | req/s | spread | p50 | p99 |
|---|---:|---:|---:|---:|
| OpenResty | 91,154 | 0.93% | 1.09 ms | 1.19 ms |
| Luvit | 10,630 | 17.79% | 7.18 ms | 29.7 to 43.7 ms |
| akkar | 10,417 | 0.39% | 9.31 ms | 12.70 ms |
| Lapis | 6,676 | 1.09% | 14.64 ms | 17.85 ms |

OpenResty is **8.75x**. Lapis is **1.56x** the other way. **Luvit is a tie**:
2.0% apart against Luvit's own 17.79% noise floor, and this project's rule is
that a difference below the larger of two floors is not a result. Where they
are not tied is the tail, where akkar's p99 is two to three and a half times
better at the same throughput.

**Against itself**, this branch against `origin/main`: **−0.3% against spreads
of 1.1% and 0.7%**, which is a tie. Two days of protocol and safety work cost
nothing measurable. `bench/study/RESULTS.md` §0.

**Boot**: 68 ms to first answered request, down from 164 ms this morning. See
the next section.

---

## What the last two days added

**HTTP/2**, by reintegration and not implementation: the h2 half of lua-http
0.4 is the same release the h1 half was vendored from. ALPN settles it over TLS
with no configuration; `h2c = true` for cleartext, opt-in because the preface
sniff costs a read on every connection including h1 ones. Multiplexing
measured at 552 ms against 3,071 ms for six half-second requests on one
connection.

**WebSocket**, as a route kind rather than a second programming model. A
handshake is an ordinary GET until it is accepted, so routing, `:params`, query
schemas, middleware and the deadline all apply unchanged. Handlers still
return; a socket is three callbacks and an object. `ws:scope(fn)` acquires
capabilities per MESSAGE, because a pool slot taken when a socket opens is held
until the browser tab closes.

**Bounds that did not exist**: socket message size (via `body_limit`), socket
count (`websocket_max_connections`), concurrent h2 streams
(`h2_max_concurrent_streams`, default 100), and a guard that keeps one
connection's raise from taking the accept loop down.

---

## Defects found, and what each one taught

Listed because the pattern matters more than the list: **of eight real defects,
five were in instruments rather than in akkar**, and the two that were in akkar
had both survived the full suite.

| what | how it was found |
|---|---|
| **Three bytes killed the server.** A short h2 frame header made `string.unpack` raise, the raise left the connection, and the accept loop died with it, HTTP/1.1 included. Upstream lua-http's bug; we are a fork now, so no report | the h2 fuzzer, first run |
| **A capability acquired after its execution ended was leaked, every time.** `provided()` can yield; if the deadline fires while it does, `dispatch` releases and returns, and the resource is registered with nobody | reading the acquisition path, after CI went red and no local reproduction worked |
| **A WebSocket message was unbounded.** 64 MB in, 192 MB of resident memory out, against an app that had set `body_limit = 1 MB` | asking what a message COSTS, not fuzzing it |
| **Ten idle WebSockets took the whole API down.** `max_concurrent` counts connections and a socket is a connection that lasts | measuring density |
| **500 concurrent h2 streams on one connection**, all accepted | the h2spec case that was SKIPPED, because we advertised no limit |
| **WebSocket cost every boot 96 ms**, including apps that never open a socket | profiling the boot path when asked where to improve |
| **CI compared two runs of itself and disagreed**, so every red was ambiguous | noticing the same SHA passing and failing |
| **The determinism claim was platform-dependent** for a reason nobody had | instrumenting rather than reasoning |

**The transferable lesson**, and it cost real time to learn: a measurement that
agrees with expectation is not evidence, and three of the instrument defects
reported success. The `WORKER_IDLE` sweep varied a variable nothing read; the
boot A/B compared a configuration with itself because an empty string is true
in Lua; the noise-floor gate crashed on exactly the input it existed to
describe.

---

## Open, in the order I would do them

### 0. Async subprocess: the design closes, one fd detail remains

**This is the live thread, and it is the answer to process isolation** -- the
teaching platform's second P0, and the "microservice to subprocess" pattern.
`bench/spike/subprocess-spawn.lua` is a spike, not a module, and it proved the
hard part: `luaposix` (installed on the box, a separate rock like akkar-pq) plus
`cqueues` compose to `fork`, `dup2`, and `exec` a real external binary under the
event loop. The child's exec SUCCEEDED -- the debug trace stops at the exec call
with no return, which is exec replacing the image.

What is left is one file-descriptor detail: the parent passed
`child_end:pollfd()` (the cqueues wrapper's fd) where the child needs the RAW
numeric fd to `dup2` onto stdin/stdout, and the parent must close its own copy
so the child sees EOF. Fix that, confirm the counter coroutine keeps advancing
during the call (loop not blocked), and `akkar.subprocess` is a real module.
Then it is a product decision whether to isolate hostile code this way, priced
already at 28 ms boot and 12.8 MB per process.

**And the confinement answer is now named.** The research report points at
`Landlock` -- an unprivileged Linux LSM, no root -- to restrict the child to
specific filesystem paths and TCP/UDP ports, alongside a `seccomp-bpf` filter
for the syscall set. So the child of the spike is not just isolated by being a
separate process; it can be locked down from inside itself. That closes the
"how do I confine it" half of the isolation P0, which was open.


### 1. Latency at low load has never been measured

**The most valuable thing on this list, and it is measurement rather than
code.** Every D4 run is at saturation, where p50 is queueing and not work:
100 connections ÷ 10,417 req/s = 9.6 ms, and the measured p50 is 9.31 ms. That
is Little's law, not akkar. What a real service at 5% utilisation delivers is
unknown, and it is the number most readers actually want.

It also decides whether the OpenResty comparison means what people will read
into it. At saturation akkar is 8.75x behind; at 5% utilisation both are
answering in microseconds of their own code and the difference may be
invisible.

### 2. The rest of the boot path

`require "akkar"` is 66 ms and 69 modules after this morning's fix. 46 ms of
that is the HTTP server: `h1_connection`, `h1_stream`, `h2_connection`,
`lpeg_patterns.http`. The h2 half and HPACK are only needed when a connection
negotiates h2, so the same deferral that just cut 96 ms should be worth another
15 to 20. The profiler is `bench/study/boot-profile.lua`, versioned rather than left in
a scratch directory, with a note about the one column of it that overlaps.

### 3. `akkar doctor` does not check `ulimit`

Verified: no mention of RLIMIT anywhere in `akkar/doctor.lua`. akkar caps
itself at 66% of the soft descriptor limit, so 675 on a box with the usual
1,024, which is exactly what the four-way run measured while the other three
took 800.
That reserve is deliberate and was bought with an incident (18,640 of 111,651
requests answered "Too many open files" on a run that produced a published
number). But an operator on a container with a low limit discovers the cap in
production, and doctor exists to say that first.

### 4. HTTP/2 throughput is unknown

Conformance is proved and multiplexing is measured on a toy case. What h2 costs
per request against h1 under load, counting HPACK, the framing layer and the
per-stream coroutine, has never been measured. If it is expensive, that matters, and
nobody would currently know.

### 5. Determinism on kqueue

**The mechanism is now known**, which is the part that was missing. From the
instrumented CI report on macOS: the difference is purely ordering, the set of
requests is identical, it is an adjacent transposition, and it happens only on
the route that calls `cqueues.sleep(0)`. What varies is how cqueues breaks a
tie between coroutines that became runnable in the same tick, which is its
business rather than something its API promises.

What it costs: the claim that a simulator needs no scheduler of its own came
from Linux-only evidence. Replaying an exact schedule needs control cqueues
does not offer portably. `spec/simulation_spec.lua` does not depend on
interleaving, so L1 stands on its own assertions.

### 6. Smaller, and each is written down where it matters

- **D3's fixed per-process column is unsound** and is withheld rather than
  published: it came back negative for three of four candidates, because two
  points cannot separate a linear model from noise larger than the signal.
- **D5 saturation and D7 dependency-down** have never been run.
- **No independent security review** has happened. The bounds, the fuzzers and
  the conformance suite are real and all internal.
- **`docs/UNKNOWNS.md` §8b** lists what is not known about h2 and WebSocket
  specifically: the framing layers are upstream's and unread line by line,
  nothing has held sockets open for hours, hostile flow control is not covered,
  100 streams on one connection can ask for 100 pool connections and the pool's
  fairness was measured under HTTP/1.1 arrival patterns, and `wss://` at volume
  is unmeasured.
- **LAB L2 to L5**: structured concurrency, adaptive CoDel, a profiler. GC
  tuning was already refused at ≤3.5%. These are the only optional items here.

---

## Things that will bite you if nobody says them

**Run the suite with the environment set explicitly.** `eval "$(luarocks path)"`
is refused inside a worktree-isolated session:

```sh
PATH="$HOME/.luarocks/bin:$PATH" \
LUA_PATH="./?.lua;./?/init.lua;$HOME/.luarocks/share/lua/5.4/?.lua;$HOME/.luarocks/share/lua/5.4/?/init.lua;;" \
LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;" busted
```

Postgres and Redis are `docker start akkar-pg akkar-redis` (ports 55432 and
6379). Without them about thirty tests error, and those errors look like
regressions.

**macOS in CI is the machine that finds time-sensitive defects.** It has been
right four times running and not one was an akkar defect. When it goes red,
read it before assuming the runner is flaky.

**CI runs once per commit now**, on pull requests and `main`, with a
concurrency group. A branch with no pull request is not tested, which is the
trade. A run marked `cancelled` usually means a newer commit superseded it.

**The em dash is banned in prose** by the author's preference; the README was
rewritten to remove all fifty-two of them.

**Never sign commits with a Claude co-author line.** Author is
`jpierreribeiro <canaldopierre0@gmail.com>`.

---

## If you have an hour

Merge #7 and watch `main` go green.

## If you have a day

Item 1: measure latency at low load, publish it beside the saturation numbers,
and say plainly which one a reader should care about.

## If you have a week

Items 1 through 4, and then the honest question this project keeps circling:
akkar is capable of production for a service you operate yourself, and it is
not proven in production. The distance between those is exposure, not features.
The shortest path across it is one real service of yours running on it.
