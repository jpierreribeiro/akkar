# The suite segfaults, intermittently, inside cqueues

> **Resolved 2 September 2026 by a core dump — see "RESOLVED" below.** A failing
> `connect` makes cqueues cancel that fd across *every* controller in the state
> (`cstack_cancelfd`), and one of them has an unclean descriptor tree: a
> controller `akkar/health.lua` abandoned, probe socket still inside, when a
> probe timed out. Not the freelist or the controller pool this page spends most
> of its length on — both of those are already gone (`962ceaa`, and F2 in
> `fb61b07`). Everything before the resolution is the investigation as it
> happened, kept as record; read the resolution first.

Found on 17 August 2026 while running the suite for an unrelated change. Not
caused by that change — the timestamps rule it out, and they are the first
thing recorded here because "did I break this" is the only question that
matters before anything else gets written.

## What happened

`busted` died with `Segmentation fault (core dumped)` after roughly 1,612 of
1,699 tests. The next full run passed 1,699 with exit 0. So it is
**intermittent**, and re-running until it passes is exactly what must not be
done with it.

`coredumpctl` shows this is not new and not rare:

```
12:12:42  SIGBUS   lua5.4
12:17:49  SIGBUS   lua5.4
12:23:09  SIGSEGV  lua5.4
12:44:32  SIGSEGV  lua5.4
```

Four crashes in half an hour of test runs. **Three of them predate the change
being worked on** (`akkar/execution.lua` did not exist until 12:32), and two
predate that session's first commit. Two distinct signals, which is usually
one memory bug seen from two angles rather than two bugs.

## Where — and it is the same instruction every time

```
$ addr2line -f -C -e ~/.luarocks/lib/lua/5.4/_cqueues.so 0x1423b
table_LLRB_FIND
src/cqueues.c:1192
```

Every recorded crash resolves to that one address:

| pid | signal | frame 0 |
|---|---|---|
| 1543389 | SIGBUS | `table_LLRB_FIND` +0x1423b |
| 1547847 | SIGBUS | `table_LLRB_FIND` +0x1423b |
| 1552159 | SIGSEGV | `table_LLRB_FIND` +0x1423b |
| 1569745 | SIGSEGV | `table_LLRB_FIND` +0x1423b |

One bug, deterministic in place and nondeterministic in trigger. Two signals
from one instruction is what a garbage pointer looks like: sometimes it lands
on an unmapped page (SIGSEGV), sometimes on a misaligned address (SIGBUS).

`table` here is not the timer tree. `cqueues.c` generates two:

```c
LLRB_GENERATE_STATIC(table, fileno, rbe, fileno_cmp)   /* <- this one */
LLRB_GENERATE_STATIC(timers, timer, rbe, timer_cmp)
```

So the crash is a lookup in the **file-descriptor table of a pollset**,
walking a red-black tree whose nodes are `struct fileno`. A segfault in a tree
*find* means the tree is corrupt: a node freed while still linked, or mutated
from underneath the walk.

## Why this points at the controller pool

`akkar/execution.lua` (formerly `akkar/init.lua`) keeps a pool of up to 64
cqueues controllers and hands one to every in-flight request for its deadline.
The pool already carries a guard, and the comment beside it describes half of
this problem:

> Only an empty controller goes back. A handler abandoned by the deadline is
> still running inside its controller, and reusing that would hand the next
> request someone else's unfinished work.

`cq:empty()` says the controller has no coroutines left. It does not say the
fileno table is in a state fit for reuse. A descriptor registered with a
pollset and closed elsewhere — by a pool returning a connection, by a stream
shutting down — leaves the pollset holding a node for an fd that is gone, and
the next `find` on that tree walks it.

And the reason a use-after-free here does not fault immediately, which is the
same reason it is intermittent:

```c
static int fileno_del(struct cqueue *Q, struct fileno *fileno, _Bool update) {
        ...
        LLRB_REMOVE(table, &Q->fileno.table, fileno);
        LIST_REMOVE(fileno, le);
        pool_put(&Q->pool.fileno, fileno);      /* <- cqueues' own freelist */
```

A removed node goes back to a cqueues object pool, not to the allocator. So a
node used after removal reads plausible memory that has since become a freelist
link, and the tree walk follows it. The crash happens later, somewhere else,
under load — which is exactly what is observed.

**This is a hypothesis, not a diagnosis**, and three attempts to confirm it
have not.

## Three things that did NOT confirm it

Recorded because a negative result that goes unwritten gets re-run by the next
person.

**1. A minimal reproducer did not reproduce.** Pure cqueues, no akkar: a pool
of 64 controllers, real sockets registered inside them, a `with_deadline` copied
in shape from `akkar/execution.lua`, deadlines firing on a third of the rounds
and abandoning coroutines mid-read, all driven from an outer controller through
`cqueues.poll` exactly as akkar nests them. **8,000 rounds, 2,666 abandoned,
5,333 controller reuses, no crash.** So the pattern alone is not sufficient, and
whatever the suite adds — TLS, lua-http streams, `akkar/substrate.lua` patching
lua-http's internals, signals, threads — is part of it.

**2. AddressSanitizer found nothing.** cqueues rebuilt at the pinned commit with
`-fsanitize=address -fno-omit-frame-pointer -O1 -g3`, loaded ahead of the
installed copy, whole suite run under it: 1,699 passing, zero reports. That is
**not an exoneration.** ASan changes allocation layout and slows everything
down, which is the classic way to hide a race, and this bug needs a race to
show. It does mean ASan is the wrong instrument here, not that the bug is
absent.

**3. The pinned commit is not the fix.** This was the tempting explanation --
the machine runs the 2020 release, so surely the pin repairs it. `cqueues.c`
differs by **seven lines** between `rel-20200726` and `c366149`:

```
> (void)status; (void)ctx;                                    x2, unused-arg warnings
> if (NULL == lua_pushvfstring(L, fmt, ap)) lua_error(L);      a Lua 5.5 concern
```

Nothing touches the fileno tree, the pollset, or memory management. Upgrading
would not fix this, and saying otherwise would have sent somebody down a
packaging path for a memory bug.

## UPDATE, 2 September 2026: the pool was retired and the crash outlived it

The experiment below implicated the controller pool, and the pool is gone --
`962ceaa` retired it the same day, and `akkar/execution.lua` now keeps
`AKKAR_CONTROLLER_POOL` only as a no-op read so an environment that still sets
it does not look like it is doing something. There are no nested controllers.

**The crash is still here.** `unit (ubuntu-24.04-arm, 5.4)` exits 139 on every
CI run since 1 September, at `table_LLRB_FIND`, the same function this file
records. So the hypothesis below is refuted by elimination: whatever corrupts
that tree, it is not controller reuse.

Two facts frame what replaced it. First, the arm64 job was green at `ec74364`
and has failed since, which looks like a regression and is not one: the only
change to `akkar/execution.lua` across that range is Lua code adding a second
field to a log table. It touches no socket, no descriptor and no controller,
and cannot corrupt a pollset.

Second, the suite grew from **1205 tests to 1501** across the same range, a
quarter more. This file already says the bug is intermittent, load-dependent,
and that "re-running until it passes is exactly what must not be done with it."
A load-dependent memory bug surfaces more often when the load rises. The
likeliest reading is that we did not introduce it -- we made it likely enough
to see every time, on the slowest of the three platforms.

That is a worse position than a regression, not a better one. A regression has
a commit to revert. This has an intermittent use-after-free in a C dependency,
now firing reliably enough to block CI, with its leading suspect eliminated.

**What is still true from below, and worth not re-running:** the minimal
reproducer did not reproduce (8,000 rounds), ASan found nothing and is the
wrong instrument for a race, and the pinned cqueues commit differs by seven
lines that touch nothing relevant.

**What is newly testable:** the crash is now reproducible on demand on arm64 in
CI, where before it needed half an hour of local runs to catch four. A
platform that fails every time is a better laboratory than one that fails
sometimes.

## RESOLVED, 2 September 2026: the core dump, and it is neither hypothesis on this page

The arm64 job "reproducible on demand" turned out to be a better laboratory than
half an hour of local runs: it produced a symbolised core dump, saved beside
this file as `segfault-backtrace-2026-09-02.txt`. It settles the diagnosis and
retracts the two standing hypotheses, the freelist one below included.

**Finding the trigger first.** Four sessions could not reproduce this crash, and
the reason was the harness, not the bug: `busted` in CI writes to a pipe, and
redirecting stdout to a file changes the heap layout enough to hide it. **48
arm64 runs to a file, 0 crashes; 6 runs to the pipe, 6 crashes.** So the bug is
real, load- and layout-sensitive exactly as this page always said, and the pipe
is what makes it fire every time.

**Frame 0 is the tell.** The crash is `fileno_cmp` — the comparator this whole
page is about — called with `b=0xffda00014807`, a heap pointer sitting in the
`fd` slot of a red-black-tree node. A live `struct fileno` holds a small integer
there. A node whose memory is no longer a `struct fileno` holds whatever now
occupies that word. The tree walk is comparing against freed memory.

**Frames 3 through 11 are the mechanism, and it is not the pool.**

```
#0  fileno_cmp                          cqueues.c:1195
#3  cqueue_cancelfd (fd=-1)
#4  cstack_cancelfd                     cqueues.c:2780   LIST_FOREACH over CS->cqueues
#5  cqs_cancelfd
#7  so_closesocket                      errno 65535
#10 so_connect
#11 lso_connect2
```

Read bottom-up: a socket `connect` FAILS, `so_closesocket` tears the fd down,
and `cqs_cancelfd` asks cqueues to cancel it. `cstack_cancelfd` then does the
thing that matters — it walks **every controller in the whole Lua state**
(`LIST_FOREACH(cqueue, &CS->cqueues, le)`), calling `cqueue_cancelfd` on each so
no pollset is left holding a stale reference to that fd. One of those
controllers has a corrupt fileno tree, and its root faults the next failing
connect anywhere in the process.

So the corrupting condition is a controller the cstack still walks whose
descriptor tree is not clean — and the akkar-specific source of that is a
controller **abandoned with work still inside it**. Two earlier suspects are
already gone and are NOT it: `962ceaa` retired the controller pool (the update
above eliminated reuse), and `fb61b07` (F2) removed the per-request deadline
controller outright — `akkar/execution.lua` now carries the deadline as a bare
number in `cqueues.poll` on the controller it is already inside, so a request no
longer creates a controller at all. That correction matters: an earlier draft of
this section blamed execution.lua, and the code had already moved.

What is left is `akkar/health.lua`. It takes a fresh `cqueues.new()` per probe
(line 138) and, on timeout, **drops it without reuse while the probe coroutine
is still parked inside it** (line 169) — the socket of the failed probe is still
registered in that controller's pollset when it is abandoned. Those controllers
sit on the cstack until they are collected, and `cstack_cancelfd` walks every
one of them on each failing connect.

**Why the no-services job specifically, and it fits health.lua exactly.** That
job refuses every Postgres and Redis connection, so its health probes against
absent services *time out* — which is the one path that abandons a controller —
and they do so continuously through the run. `integration`, which has both
services, has its probes answered, abandons nothing, and almost never crashes.
The crash was never about what the suite computes; it is about a job whose
health checks cannot connect, piling up abandoned pollsets for the next failing
connect to walk.

**The freelist hypothesis below is retracted, and it was mechanically
impossible.** It required `fileno_del` to return a node to cqueues' object pool
while the tree still linked it. `fileno_del` has exactly one call site, inside
`cqueue_destroy` — the node is freed only as its whole controller is torn down,
so there is no live tree left to walk it from. The real fault is a *different*
controller's tree, reached through the cstack, not a recycled node in the same
one.

**The fix is akkar's own, and F2 was half of it — the other half is
health.lua.** F2 already did to the request path what needs doing here: it stops
creating a controller and carries the deadline as a number, running the handler
as a worker on the controller it is already inside (`akkar/execution.lua`'s
`run_on_worker`). `health.lua` still allocates a fresh `cqueues.new()` per probe
purely to arbitrate the timeout, and on timeout DROPS it with the probe still
inside (line 168) — that is the abandoned pollset. The in-server branch today
only *polls* that nested controller from the ambient one (line 156); the fix is
to not create it at all — wrap the probe coroutine onto the ambient controller
the way `run_on_worker` does, so an abandoned probe wakes and finishes on the
shared loop rather than leaving a controller on the cstack. Until that lands,
the crash's remaining fuel is health probes that cannot connect.

It is not a mechanical port, and that is why it is written up rather than done
in passing: the nested controller also ISOLATES a hung probe from the server's
hot controller, and a check function is arbitrary — not every one is bounded by
an adapter deadline the way `db.ping` is. Moving probes onto the ambient
controller trades that isolation against this multiplicity, which is a judgment
to make deliberately. And the fix cannot be proven locally: the crash reproduces
only on arm64 under a pipe, so the confirmation that it is gone is the arm64 CI
job going green, not a local red-to-green.

The cqueues pin is already upstream master's tip, so there is no released fix to
pull. The endorsed upstream fix (cqueues issue #42) deletes the
cancel-across-all-controllers walk entirely — it would remove the crash site
rather than starve it, and is the durable fix if abandoning a controller ever
becomes unavoidable again.

Everything below is left as written — the hypotheses, the pool experiment, the
price of turning recycling off — because the record of what was tried and what
it cost is the point of this file. It is history now, not the diagnosis.

## The experiment, and its result

**The controller pool is implicated.** (Superseded -- see the update above.)

| arm | crashes | runs |
|---|---:|---:|
| pool ON (64, the default) | **3** | 6 |
| pool OFF (`AKKAR_CONTROLLER_POOL=0`) | **0** | 6 |

Alternating, same machine, same suite, twelve runs. A crash is exit 135
(SIGBUS) or 139 (SIGSEGV); the OFF arm's exit 1 every time is the allocation
ceiling failing on purpose, not a crash.

**The comparison is fair, and this was checked rather than assumed:** every OFF
run reported 1,698 successes and 1 failure — the full 1,699 tests — so it had
exactly the same opportunity to crash as the ON arm. An arm that aborted early
would have had less exposure and the result would have meant nothing.

**Honest about the statistics:** 3-of-6 against 0-of-6 is a one-sided Fisher
exact p of about 0.09. That is suggestive, not conclusive at any conventional
threshold, and saying otherwise would be dressing up six runs as proof. What
raises it above suggestive is that it agrees with the mechanism: the crash is in
a pollset's descriptor tree, recycling pollsets is what the pool does, and
turning recycling off is what stopped it.

### Then the fix was priced, and not bought

Turning recycling off was made the default for about an hour. Then the cost
came in, isolated to that one commit on the study box, five alternating
repetitions with the machine at 99% idle:

| | req/s | p50 | p99 | spread |
|---|---:|---:|---:|---:|
| pool on | 19,409 | 5.14 ms | **6.19 ms** | 1.6% |
| pool off | 18,078 | 5.09 ms | **8.48 ms** | 1.3% |

**−6.9% of throughput and a 37% worse tail**, permanently, against evidence at
p ≈ 0.09. For a runtime that argues about predictability, the p99 is the worse
half of that.

So the default went back to recycling. Writing down why, because reverting a
safety fix looks careless without it:

- **p ≈ 0.09 does not buy 6.9%.** Six runs an arm is enough to justify more
  runs, not enough to justify a permanent regression on the hot path.
- **The crash is not new.** It predates every change made this week. A
  pre-existing bug does not become urgent enough to buy at that price merely
  because somebody finally looked at it.
- **The mechanism is inferred, not understood.** Two targeted reproducers
  failed. Paying a known cost to fix an unknown thing is how you end up with
  both.

**What would change the answer:** twenty runs an arm. If pool-off stays at
zero, the price is worth paying and this page should say so. Better still, the
actual cqueues defect — with a mechanism in hand, the fix is probably neither
719 bytes nor 6.9%.

**The definitive test is still F2**, and it is half-blocked. After F2 there is
no controller per request and therefore no pool — but only for I/O akkar
mediates. `spec/akkar_spec.lua` has a handler calling `cqueues.sleep(2)`
against a 0.15 s budget that must answer 503, and `sleep` goes through no
adapter, so the controller cannot simply be deleted. That is a correction to
the plan, which assumed it could.

## The experiment as run

`AKKAR_CONTROLLER_POOL=0` makes every execution take a fresh controller and
return none, which turns pollset recycling off without changing anything else.
Two arms, alternating, six repetitions each, exit codes recorded:

    pool ON  (64, the default)   vs   pool OFF (0)

The next suspect, if F2 does not settle it, is `akkar/substrate.lua` — it
patches lua-http's stream internals and is the other thing akkar does that
nobody else does.

### A number the experiment produced on its way past

The OFF arm fails `spec/allocation_spec.lua` — not a crash, the ceiling doing
its job:

```
allocation through the real server regressed: 15,427 bytes/request, ceiling 14,900
```

Against 14,708 with the pool on. **So recycling controllers is worth 719 bytes
per request**, which is what a fresh `cqueues.new()` costs, and nobody had put a
figure on it before.

That is a lower bound on what F2 buys, not an upper one: F2 does not make the
controller cheaper, it stops allocating one at all, so it collects these 719
bytes *and* the pooling machinery *and* the two descriptors — three on kqueue.

It also means the OFF arm cannot be run as a permanent configuration, only as
an experiment. Which is fine: it exists to answer one question.

## What it is NOT

**It is not the release-versus-pin mismatch**, and that hypothesis was checked
before being repeated. The 14 commits between `rel-20200726` and the pinned
`c366149` are libressl 3.5.0 opaque bio structs, Lua 5.5 support, compiler
warnings, `thread.c` fixes and freebsd inotify. **None touches the LLRB code or
the pollset.** Upgrading to the pin would not fix this.

## The related defect, which is real and separate

The development machine does not run the cqueues it pins either:

```
$ lua5.4 -e 'local c = require "cqueues" print(c.VERSION, c.COMMIT)'
20200726   nil
```

`COMMIT` is only set when built with `-DCQUEUES_COMMIT`, which the pinned build
passes and the release rock does not. So this machine is running the July 2020
release, and the crashing `_cqueues.so` was built by luarocks from
`/tmp/luarocks_cqueues-20200726.54-0-.../cqueues-rel-20200726/`.

This is the same defect fixed in CI on 17 August — luarocks pulling the release
rock as a dependency of `http` and moving the hand-built one aside — now shown
to be true locally as well. **Every local test run this project has ever done
tested cqueues 2020**, and `akkar/substrate.lua` patches cqueues internals on
the assumption of the pin.

Fixing that is worth doing on its own merits. It will not fix this crash.

## Why F2 matters here

There is a plan item that removes the suspect entirely.

F2 of the runtime programme replaces the per-request cqueues controller with a
deadline carried as a number in the execution scope, enforced at the adapter
boundary. No controller per request means no controller pool, which means no
recycled pollset. If the hypothesis above is right, F2 deletes this bug rather
than repairing it.

So this is recorded, its priority is noted, and F2 gains a second reason to
exist beyond the concurrency ceiling. If the crash survives F2, it was never
about the pool and this page should say so.

## What to do when it happens again

```sh
coredumpctl list | tail
coredumpctl info <pid>
addr2line -f -C -e ~/.luarocks/lib/lua/5.4/_cqueues.so <offset>
```

And record the offset here. Two data points are a pattern; one is an anecdote,
and this page currently has one address seen once.

---

## What the pool is actually worth — 18 August 2026

The controller pool is the leading suspect on this page, and the argument for
keeping it has always been its price: turning recycling off cost 6.9% of
throughput and a 37% worse p99, which was judged too much to pay against
evidence at p ≈ 0.09.

That number has been re-taken, and the shape of the trade is now known in both
directions. `AKKAR_CONTROLLER_POOL` swept at `-c100`, default `ulimit`, five
alternating repetitions, **run twice on different revisions**:

| pool | median req/s | spread | fd peak | eventpoll peak |
|---:|---:|---:|---:|---:|
| 0 | 11,006 | 2.2% | 272 | 61 |
| **64** (default) | 11,837 | 4.0% | 284 | 90 |
| 128 | 12,106 | 2.4% | 284 | 90 |
| 256 | 12,007 | 1.8% | 284 | 90 |

**Turning it off costs 7.6–8.4%** — consistent across both sweeps, and the
only comparison here that clears its floor. So the earlier 6.9% stands, if
anything understated.

**And raising it above 64 buys nothing.** 64 → 128 is +2.2% and +2.3% against
floors of 4.2% and 4.0% — **not a result** by rule 3, independently in both
sweeps. 128 → 256 is −0.1% and −0.8%, also not a result. The curve is flat
from 64 upward.

**Nor does a bigger pool buy descriptors.** fd and eventpoll peaks are
identical at 64, 128 and 256. At this concurrency the binding term is requests
in flight, not the pool ceiling — the pool is never the thing that fills.

So the exposure this page describes cannot be reduced by shrinking the pool
without paying about 8%, and cannot be traded for anything by growing it.
**64 is the only defensible position, and it is where it already is.**

The real escape is not a pool size at all: `bench/study/deadline-without-controller.lua`
shows a per-request deadline that creates no controller, using a bare number
in `cqueues.poll`. No controller means nothing to recycle and nothing to
suspect. See `docs/PERFORMANCE-PLAN.md` B1.
