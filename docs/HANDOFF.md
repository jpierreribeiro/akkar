# Handoff, 22 August 2026

This is written to be read cold by somebody who knows Lua and akkar's shape,
but did not follow the work that produced this branch.

## Where the work is

Everything is on branch `f4-refused`. The implementation head for this round
is `fdc0919`; the request-id fix is `38d512a` and the Redis HyperLogLog work is
`fdc0919`. At that point the branch is 40 commits ahead of `origin/main` and 2
commits ahead of `origin/f4-refused`. This handoff is one additional local
commit. Nothing in this round was pushed, merged, or opened as a pull request.

PR #7 was merged on 18 August and cannot be reused. Most of the work on this
branch happened after that merge, so landing it requires a **new pull request
from `f4-refused` to `main`**.

> **Done, and not to be done again.** `f4-refused` (`7781c10`) is an ancestor of
> `origin/main` as of `ec74364`, 22 August. It landed without changing a byte:
> `git diff 7781c10 origin/main` covers only the two commits after it. This
> paragraph is left standing because the rest of the section is still accurate;
> only this item is closed.

The current one-line state: akkar speaks HTTP/2 and WebSocket, passes all 146
h2spec conformance cases, survives the recorded CONTINUATION-flood and
decompression-bomb tests, and the complete Lua 5.4 suite at this tip passes
`1869 successes / 0 failures / 0 errors / 0 pending`.

## This round

### Request IDs no longer wrap after 16 million requests

`akkar.execution.id()` used a monotonic counter but masked it with `0xffffff`
before formatting it. The 16,777,217st request in a process therefore reused
the first request's suffix, contradicting the collision-free design comment.

The mask is gone. `%06x` remains a minimum width, so existing IDs keep their
shape through `ffffff` and then grow naturally to seven hexadecimal digits.
Request IDs are opaque values, so preserving uniqueness is more important than
freezing their length. A boundary test seeds the private counter at `0xfffffe`
and verifies the `ffffff` to `1000000` transition without doing 16 million
calls. The unused bitwise dependency was removed from the module.

### Redis HyperLogLog is exposed directly

`akkar.redis.Redis` now has thin `pfadd`, `pfcount`, and `pfmerge` methods. They
delegate through `conn:command`, so the existing deadline, timeout, socket, and
pool-health behavior remains the single implementation path.

Tests cover the exact RESP command and argument order without a service, plus
a live Redis example with overlapping sketches and a merged destination. The
reference documents register-change semantics for `PFADD`, multi-key cost,
destination participation in `PFMERGE`, serialization, expiry, and when an
exact set is the right choice. Redis' dense representation is about 12 KB and
its reported 0.81% figure is a standard error, not a hard per-answer bound.

## Audit reconciliation

The findings that prompted the review were real, but they were already fixed
on this branch before this round:

| finding | state |
|---|---|
| mounted-app authorization bypass | fixed with regression coverage in `e827aea` |
| unknown validator constraints and integer/float handling | fixed in `e827aea` |
| Redis-dependent specs skipped incorrectly | fixed in `b8eec7f` |
| CLI packaging, rockspec, and CI gaps | fixed in `f0fec14` |
| shared empty DB state file | removed in `a6d3e34` |
| README and reference inconsistencies | cleaned up in the later `f4-refused` documentation work |

The previously directed audit set passed 59 tests before this round. After the
new work, the live-service directed set passed all 81 tests.

The system-call and bgfx preprocessor material supplied with the HLL note was
not part of this repository change. There was no matching finding or requested
feature to implement from it.

## Verification on this checkout

All results below are from Linux x86_64, Lua 5.4, at this branch tip.

| check | result |
|---|---:|
| execution and random directed specs | 30 successes, 0 failures |
| Redis and documentation without Redis running | 621 successes, 0 failures, 1 expected pending |
| changed areas with Redis and PostgreSQL running | 81 successes, 0 failures |
| complete suite with Redis and PostgreSQL | 1869 successes, 0 failures, 0 errors, 0 pending |
| `luac -p` over `akkar`, `spec`, `examples`, and `bench` | passed |
| `luarocks lint` for both rockspecs | passed |
| `git diff --check` | passed |

The first complete-suite attempt used this laptop's default soft descriptor
limit of 1024. `spec/http_pool_spec.lua` exhausted it, then module and rockspec
opens failed in a 42-error cascade. This was an environment/harness failure,
not a changed-area failure. Repeating the exact suite after `ulimit -n 8192`
passed all 1869 tests and passed the earlier failure point. The containers used
for validation are `akkar-redis` on 6379 and `akkar-pg` on 55432; they were
stopped again after verification to restore the initial machine state.

## Waiting on the maintainer

1. Open a new pull request from `f4-refused` to `main`, review it, and let CI
   validate the pushed tip. Do not try to reopen PR #7.
2. Decide the product boundary for hostile tenant code. `akkar.vm` deliberately
   is not a security boundary. A process per tenant measured 28 ms to first
   response and 12.8 MB resident when idle; a process plus Landlock and
   seccomp-bpf is the direction if hostile code is in scope.

> **Both numbers are withdrawn, 1 Sep 2026.** Neither survived being checked
> against the tree.
>
> **28 ms has no source.** It appears in three handoffs and traces to nothing —
> not to a bench script, not to a results file, not to the commit it is
> attributed to. The measured figures are `bench/runtime/RESULTS.md:167-174`:
> **21 ms** for `akkar` alone and **29 ms** for a complete application, five
> runs each on the study box with a 2 ms poll. `docs/labs/DALIVIM-INTEGRATION.md`
> already said 29. Nothing depended on the difference, which is why nobody
> caught it.
>
> **12.8 MB is a PEAK under grading, relabelled as idle.** `4020210` measured
> 12.8 MB *peak* RSS against a 256 MB address-space cap while grading, at
> 40-100 ms per grading, in `~/Desktop/akkar-exercise-spike/` — a directory
> outside this repository that no longer exists. Measured idle RSS (D2) is
> 11.4 MB, 13.3 MB and 14.1 MB across three runs; 12.8 is none of them. A peak
> and an idle figure are not interchangeable.
>
> And neither figure was ever about the thing being decided. Both describe an
> akkar HTTP server booting and answering. The decision is about a forked child
> under Landlock and seccomp, which has no implementation, so its cost has not
> been measured by anyone.
3. Decide the compatibility policy and publish to luarocks.org. Neither is a
   code defect, and no release was made here.

## Open work, in recommended order

### 1. Finish the async subprocess round trip

`bench/spike/subprocess-spawn.lua` already proves that luaposix and cqueues can
compose `fork`, `dup2`, and `exec` under the event loop. The remaining problem
is file-descriptor ownership around the socketpair. The child must receive the
raw fd for `dup2` and close its inherited copy of the parent end; the parent
must close its child end so EOF is observable. The spike contains that
diagnosis, but the end-to-end round trip still needs confirmation on a
responsive Linux box. Also confirm that a counter coroutine advances during
the child call before promoting the spike to `akkar.subprocess`.

If hostile-code isolation is selected, apply unprivileged Landlock filesystem
and network rules plus a seccomp-bpf syscall filter inside the child. A separate
process is the boundary; `akkar.vm` remains for trusted in-application hooks.

### 2. Lazy-load the rest of the HTTP boot path

`require "akkar"` was measured at 66 ms and 69 modules after WebSocket loading
was deferred. Roughly 46 ms is in the HTTP server stack. The h2 connection and
HPACK pieces are only needed after h2 negotiation, so the same deferral should
be measured. The profiler is `bench/study/boot-profile.lua`.

### 3. Teach `akkar doctor` about descriptor limits

There is no RLIMIT check in `akkar/doctor.lua`. akkar intentionally caps itself
at 66% of the soft fd limit, which is only 675 descriptors at the common 1024
default. The full-suite observation above is another concrete reason to report
the soft and hard limits before production.

### 4. Measure HTTP/2 throughput

Conformance and a six-request multiplexing case are established. Per-request
h2 cost under load, including HPACK, framing, and stream coroutines, is still
unknown relative to HTTP/1.1.

### 5. Resolve portable deterministic scheduling

The macOS difference is an adjacent ordering swap on a route that calls
`cqueues.sleep(0)`. cqueues does not promise the same tie-break between runnable
coroutines on epoll and kqueue. The simulation assertions remain valid, but an
exact cross-platform replay requires scheduling control above cqueues.

### 6. Retain the explicitly unknown areas

- D3's fixed per-process memory column is withheld because two noisy points do
  not support the claimed linear model.
- D5 saturation and D7 dependency-down have not been run.
- There has been no independent security review.
- `docs/UNKNOWNS.md` section 8b records the remaining h2 and WebSocket risks:
  upstream framing code has not been audited line by line, long-lived sockets
  and hostile flow control are unmeasured, 100 h2 streams can ask for 100 pool
  connections, and `wss://` at volume is unmeasured.
- LAB L2 to L5 remain optional work: structured concurrency, adaptive CoDel,
  and a profiler. GC tuning was already rejected at an effect of 3.5% or less.

## Benchmark facts worth retaining

The four-way browser-shaped comparison on the benchmark box used three
alternating repetitions:

| runtime | req/s | spread | p50 | p99 |
|---|---:|---:|---:|---:|
| OpenResty | 91,154 | 0.93% | 1.09 ms | 1.19 ms |
| Luvit | 10,630 | 17.79% | 7.18 ms | 29.7 to 43.7 ms |
| akkar | 10,417 | 0.39% | 9.31 ms | 12.70 ms |
| Lapis | 6,676 | 1.09% | 14.64 ms | 17.85 ms |

Akkar and Luvit are a throughput tie under the measured noise floor; akkar's
tail was substantially tighter. Against `origin/main`, this branch measured
-0.3% with spreads of 1.1% and 0.7%, also a tie. Low-load service time was
14.5 us for `GET /ping`, 20.1 us for `GET /users/:id`, and 21.5 us for
`POST /orders`, so saturation figures should not be presented as ordinary
request latency. Detailed results live in `bench/runtime/RESULTS.md` and
`bench/study/RESULTS.md`.

The benchmark host recorded in the previous handoff was `98.80.193.148`, user
`ubuntu`, key `~/Downloads/colossus.pem`, with the checkout at `~/akkar-git`.
Confirm the instance still exists before relying on it. Provision through the
CI recipe and stage the runtime services before running comparisons:

```sh
ROOT=$HOME/akkar-git       bash bench/study/regression.sh origin/main HEAD
AKKAR_SRC=$HOME/akkar-git  bash bench/runtime/deploy.sh
AKKAR_SRC=$HOME/akkar-git  bash bench/runtime/run.sh
H2SPEC_CACHE=/tmp/h2       bash bench/h2spec.sh
```

The pinned cqueues commit on that host is
`c36614982fe07917b2e1ce5a9e7a0e55b81be262`. Run
`spec/substrate_spec.lua` before accepting numbers from a new environment.

## Operational reminders

Set the LuaRocks environment explicitly inside a worktree and raise the soft fd
limit for the complete suite on this laptop:

```sh
eval "$(luarocks path --bin)"
ulimit -n 8192
docker start akkar-pg akkar-redis
busted
docker stop akkar-pg akkar-redis
```

macOS CI is especially good at exposing time-sensitive assumptions; inspect a
red run before treating it as runner noise. CI runs once per pull-request or
`main` commit with a concurrency group, so this unpushed branch has not been
validated by CI. Prose in this repository avoids the em dash. Commits are not
signed with a Claude co-author line; the project author is
`jpierreribeiro <canaldopierre0@gmail.com>`.
