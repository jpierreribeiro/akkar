# The suite segfaults, intermittently, inside cqueues

## SOLVED, 2 September 2026 — the backtrace, the trigger, and the mechanism

A symbolized core dump from CI ends the guessing. It was got by running the
suite EXACTLY as CI runs it (bare `busted`, see "the flag that hid it" below),
looping on arm64, dumping core, and reading it with debuginfod disabled so gdb
did not hang. Three runners, three crashes on the first run, one full
backtrace:

```
#0  fileno_cmp (b=0xffda00014807, a=<optimized out>)            cqueues.c:1195
#1  table_LLRB_FIND (head=0xab5729b34c88, key=...)              cqueues.c:1195
#2  fileno_find (fd=-1, Q=0xab5729b34a68)                       cqueues.c:1536
#3  cqueue_cancelfd (Q=0xab5729b34a68, fd=-1)                   cqueues.c:2428
#4  cstack_cancelfd (CS=..., fd=-1)                             cqueues.c:2780
#5  cqs_cancelfd (L=..., fd=-1)                                 cqueues.c:2817
#6  lso_closefd (fd=0xab572a0948d8, arg=...)                    socket.c:702
#7  so_closesocket (fd=..., opts=...)                           lib/socket.c:875
#8  so_socket_ (so=...)   error = 65535                         lib/socket.c:1449
#9  so_exec (so=...)                                            lib/socket.c:1745
#10 so_connect (so=...)                                         lib/socket.c:2107
#11 lso_connect2 (L=...)                                        socket.c:983
```

The faulting instruction is `ldr w1, [x20]` with `x20 = 0xffda00014807` — a
tree node whose child pointer points into a shared-library mapping, i.e. a
wild pointer. `table` is the fileno tree, as this page always said. What was
missing is the **trigger** and the **amplifier**, and they are both in the
frames above.

**The trigger is a socket connect that FAILS.** Frame 11→8 is
`socket.connect` running its handshake; `so_socket_` carries `error = 65535`.
A failed connect closes its own socket, and cqueues' close handler for a
Lua socket is `lso_closefd` (frame 6):

```c
static int lso_closefd(int *fd, void *arg) {
        struct luasocket *S = arg;
        if (S->mainthread) {
                cqs_cancelfd(S->mainthread, *fd);   /* <- frame 5 */
                cqs_closefd(fd);
        }
        return 0;
}
```

The no-services CI runner refuses every Postgres and Redis connection, so the
suite performs this failing-connect-then-close **thousands of times per run**.
That is why the crash lives on the no-services arm and not in `integration`,
which has both services and never fails a connect this way.

**The amplifier is that cqueues cancels an fd across EVERY live controller.**
`cqs_cancelfd` → `cstack_cancelfd` walks the whole process's controller list
and does one `fileno_find` — one red-black-tree walk — per controller:

```c
static void cstack_cancelfd(struct cstack *CS, int fd) {
        struct cqueue *Q;
        LIST_FOREACH(Q, &CS->cqueues, le)
                cqueue_cancelfd(Q, fd);            /* fileno_find on each */
}
```

So **every socket close in the process walks the fileno tree of every
controller alive at that moment.** If any one of those trees is corrupt, the
next failing connect anywhere crashes on it. The crash is in Q =
0xab5729b34a68 — not necessarily the controller the socket belonged to, just
one that happened to be on the list.

**Why a tree gets corrupt, and why ASan never saw it** — unchanged from below
and now explained by the above. cqueues frees fileno nodes to its own object
pool (`pool_put`), not to the allocator, so a node freed while another
controller's tree still links it is reused as a different fileno and the stale
link becomes a wild pointer — invisible to AddressSanitizer, which only sees
`malloc`/`free`. The freelist is the reason ASan came back clean, confirmed
this session by rebuilding cqueues with the freelist removed (`pool_put`→
`free`, `pool_get`→`malloc`) and running the whole suite under ASan on arm64:
still zero reports, because catching it needs the crash to fire and the crash
is layout-dependent (below).

### This is a cqueues design limit, amplified by how akkar uses it

The dangerous line is cqueues': a socket close cancels its fd, by NUMBER,
across every controller in the Lua state. In ordinary cqueues use there is one
controller and this is free. akkar is the unusual caller: it keeps **many
controllers alive at once** — one per in-flight request (`akkar/execution.lua`),
one per health probe (`akkar/health.lua:132`, which explicitly ABANDONS the
controller with its coroutine still inside when a check times out), and more.
Every one of those stays on the cstack until GC, and every one is walked on
every socket close. The more concurrent controllers, and the more failing
connects, the larger the window for one tree to be mid-corruption when the
next close walks it.

**This corrects the 2 September update below.** That update concluded "the
crash outlived the pool, so it is not controller reuse." Right about the
POOL — recycling is not it. Wrong about controllers: it is controller
**multiplicity**, not controller recycling. The `962ceaa` retirement removed
the pool but not the per-request controller, and left the per-probe ones
untouched. So the leading suspect was never eliminated, only renamed.

### What akkar should do

1. **The real fix is B1 / F2**: carry the per-request deadline as a number
   enforced at the adapter boundary, with no per-request `cqueues.new()`. No
   per-request controller means the cstack holds one long-lived controller
   instead of dozens, and `cstack_cancelfd` walks one tree. This backtrace is
   direct evidence FOR that plan, not merely a second reason for it.
2. **`akkar/health.lua` should stop abandoning controllers.** A timed-out
   probe drops its controller with a coroutine suspended inside; that
   controller cannot be `:close()`d (cqueues refuses to close a running
   controller) and lingers on the cstack until GC, contributing a tree to
   every socket close in between. It needs a design that does not strand a
   controller — the same shape as F2.
3. **Report it upstream.** `wahern/cqueues` master is alive (commits to
   2026-03-18) and the pinned commit IS its tip — there is no released fix
   waiting, confirmed this session by `git log c366149..origin/master` being
   empty. The upstream-worthy report is: `cqs_cancelfd` fans a single fd
   cancellation across all controllers by fd number, so any one corrupt or
   stale fileno tree turns every subsequent socket close into a crash, and fd
   numbers are reused across concurrent controllers.

Until 1 and 2 land, CI carries a **bounded, honest mitigation** (this commit):
the no-services suite step retries ONCE and ONLY on a death by signal
(exit ≥ 128), announces both the retry and a double-crash, and leaves an
ordinary test failure red on the first try. Residual red rate ≈ 1 in 9.

### The flag that hid it — why four prior sessions could not reproduce it

Every probe before this one looped `busted --output=plainTerminal`; the CI
step that crashes runs bare `busted`. On a redirected stdout the flag is a
**semantic no-op** — `busted/runner.lua:17` already selects `plainTerminal`
when stdout is not a tty, and both paths then `require` the same handler. It
changes only the contents of `arg` and the allocations the CLI parser makes.

Yet on one commit, one runner image, one freshly built cqueues:

| invocation | arm64 runs | crashes |
|---|---:|---:|
| `busted --output=plainTerminal` | 48 | **0** |
| `busted` (bare, as CI runs it) | 6 | **6** |

Six-for-six against zero-for-forty-eight, Fisher exact p ≈ 1.7e-6. A change
with no logical effect moves the crash from certain to absent — the signature
of memory corruption whose firing is decided by heap layout. It also explains
the "intermittent" character: the bug is nearly deterministic per tree, and
every commit reshuffles the layout, so it looks like it comes and goes. The
observed CI rate is ~7% of arm64 runs (two SIGSEGVs in ~30), all clustered,
because most commits happen to land on a surviving layout.

x86 has still never crashed: 28 no-services runs this session plus every
`integration` job. Same epoll backend as arm64, so the platform sensitivity is
itself layout — arm64's allocator and 64 KB pages land the wild pointer on an
unmapped page more often.

### Do NOT re-run, already established this session

- The pin is upstream master's tip; no upstream fix exists to pull.
- The nine-test window is not the reproducer — restricting to three spec files
  skips the load phase of the other sixty; 318 windowed runs found nothing.
- Rebuilding cqueues without its freelist and running under ASan: still clean,
  for the reason above.

---

## (Original investigation follows, including the 2 September update this
## section corrects. Kept verbatim: its reproducers, its pricing of the pool,
## and its dead ends are all still valid as recorded.)


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

## The experiment, and its result

**The controller pool is implicated.**

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
