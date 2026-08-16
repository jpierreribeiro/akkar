# The two windows that kept the C driver switched off

`bench/driver/RESULTS.md` §5.4 is the only thing between `akkar.pq` and being
the default. It reported that across thirty ten-second windows pgmoon produced
no anomalous ones and `akkar.pq` produced two, where a whole window ran at
pgmoon's speed and then went back to being fast. Nothing explained it, so the
default did not move.

This is the investigation. It is written as it happened, including the
hypothesis that looked decisive and was wrong, because the wrong one is the
part worth not repeating.

```
machine  : the study c5.2xlarge, servers on 2 physical cores, generator on 1
target   : /rows/100 at 16 connections unless stated
date     : 2026-08-16
```

---

## What was already known

One fact narrowed it before any new measurement: **in a slow window p50 rose
along with p99.** That is not one request stalling — it is the whole window
being slower. So "a garbage collection pause", "a connection re-established"
and every other single-event explanation were out.

## Hypothesis 1: a Postgres checkpoint — REFUTED

The reasoning was that pgmoon spends so long in the interpreter that Postgres
is never its bottleneck, while `akkar.pq` is fast enough that Postgres is. A
checkpoint would then cost pq throughput and be invisible to pgmoon — and the
"driver inconsistency" would not be the driver at all.

`bench/driver/anomaly.sh` ran forty windows per driver and recorded what
Postgres did during each one. It looked decisive:

| | windows | median | spread | more than 5% below median |
|---|---:|---:|---:|---:|
| pgmoon | 40 | 2,402 req/s | 2.0% | **0** |
| akkar.pq | 40 | 5,134 req/s | 12.3% | **2** |

and **pq's worst window was the one window in which a checkpoint completed**
— window 15, down 11.1%. pgmoon had a checkpoint too, in its window 27, and
showed nothing.

**Then it was forced instead of waited for.** `bench/driver/checkpoint.sh`
alternates a quiet window with a window carrying an explicit `CHECKPOINT`, six
rounds per driver:

```
=== pgmoon ===            quiet     forced      delta
           medians      2404.10    2403.06      -0.0%

=== pq ===                quiet     forced      delta
           medians      5139.44    5143.45      +0.1%
```

**Neither driver moves.** The hypothesis is refuted.

And the refutation was available before the experiment. In the correlated
window, `buffers_checkpoint` was **zero** — that checkpoint wrote nothing, so
there was never a mechanism for it to cost anything. The column was in the
table and was not read. One correlation at n=1, with the mechanism already
contradicted by the next column along, is not evidence.

## Hypothesis 2: the operating point, not the driver — ANSWERED, and it is the harness

The comparison was never fair in one specific way. Both drivers ran at the same
**concurrency**, which put pq at more than twice pgmoon's **throughput** —
5,100 req/s against 2,400. Anything that degrades with load therefore had twice
as many opportunities on pq's side, and the conclusion drawn was about the
driver.

`bench/driver/rate-matched.sh` sweeps concurrency and watches the spread. The
first attempt produced this:

```
driver   conns     median        min        max    spread slow(<5%)
pgmoon      16       2391       2143       2409     11.1%        1
pq           6       3747       2661       3829     31.2%        2
pq          16       5147       5094       5191      1.9%        0
```

which inverts the published claim — pq at sixteen was the *smoothest* of the
three, and **pgmoon produced a slow window**, which §5.4 says it never does.

That run was set aside at the time, because the machine reported load average
1.11 with a five-minute average of 2.52 and this repository already carries a
CORRECTION block about publishing from a busy machine.

**Setting it aside was itself a mistake**, and the next section says why: the
load average on this box does not decay, and the machine had been idle all
along. The run is kept here because its numbers turned out to be right.

### Repeated on a verifiably idle box

The gate was wrong too. `/proc/loadavg` on this machine reads 2.3 while
`vmstat` reports **0 running, 0 blocked, 100% idle** — the load average is not
decaying. A run was discarded for the wrong reason, and the gate now asks
`vmstat` whether the CPU is idle instead of asking what it was doing minutes
ago.

```
driver   conns     median        min        max    spread slow(<5%)
pgmoon      16       2411       2397       2432      1.4%        0
pq           6       3719       2699       3843     30.8%        4
pq          16       5118       5021       5167      2.8%        0
```

**The driver is ragged at LOW concurrency and smooth at high**, which no
property of a driver explains and one property of the harness does.

## The answer: SO_REUSEPORT dividing a small number of connections

`SO_REUSEPORT` hands each connection to a listening process by hashing the
four-tuple. Sixteen connections over two processes is eight and eight, near
enough, every time. Six can be three and three, or four and two, or five and
one — and it is re-drawn every time the generator reconnects, which is every
window. An uneven split leaves one process idle while the other queues.

`bench/driver/distribution.sh` removes the split by removing the second
process:

```
pq /rows/100 @6, TWO processes      3738   2702   3840   30.5%   3 slow
pq /rows/100 @6, ONE process        2725   2687   2762    2.7%   0 slow
pq /rows/100 @16, ONE process       2822   2767   2847    2.8%   0 slow
```

**One process cannot be split, and the raggedness is gone.**

And the control that makes it conclusive — the same six connections, two
processes, on **pgmoon**:

```
pgmoon /rows/100 @6, TWO processes  1881   1239   1941   37.3%   2 slow
pgmoon /rows/100 @6, ONE process    1248   1211   1261    4.0%   0 slow
```

pgmoon is ragged there too, and **more so than pq**. The effect belongs to the
harness and to neither driver.

## And the published anomaly does not reproduce

Measured at the exact configuration §5.4 used — `/users/42`, sixteen
connections, two processes:

```
pq     /users/42 @16, two processes   9088   8993   9156   1.8%   0 slow
pgmoon /users/42 @16, two processes   7112   7079   7161   1.2%   0 slow
```

**1.8% spread and zero anomalous windows**, against the 21.4% and two that were
published.

The likeliest reason is in how the original run was structured rather than in
anything it measured. It alternated drivers **per repetition**, restarting both
servers every time, so each of its five windows measured a freshly started
process with an empty connection pool behind one three-second warm-up. These
runs start the server once and take sixteen to forty consecutive windows, so
only the first is cold — and it is discarded.

Alternating per repetition is the right thing to do when comparing two
variants, because it stops drift being handed to whichever ran second. It is
the wrong thing when the question is how *consistent* one variant is, because
every sample then carries a cold start.

## What was settled along the way

1. **It is not checkpoints.** Forced, they cost both drivers nothing.
2. **"pgmoon never has a slow window" is not a stable property.** Give it six
   connections over two processes and it loses two windows in sixteen, worse
   than pq does. §5.4's zero came from one thirty-window sample, and a zero
   from one sample is not a floor.
3. **`/proc/loadavg` is not an instrument on this machine.** It reads 2.3 while
   `vmstat` reports the CPU 100% idle. A run was discarded on its say-so.

The second of those matters more than it looks. If both drivers occasionally
lose a window to something on the machine, then the thing keeping `akkar.pq`
switched off is not a property of `akkar.pq`.

## What would settle it — nothing further

Nothing. The question is answered: **`akkar.pq` is not less consistent than
pgmoon**, and §5.4 is corrected in place rather than edited away.

## So does the default move?

**No, and the reason changed completely.**

It stays pgmoon because the C half of the driver is a **separate rock**.
`akkar.pq_native` links against libpq, and declaring that in the main rockspec
would make libpq a hard dependency of `luarocks install akkar` for everybody,
including the people who never touch Postgres. A default of `pq` would fail at
the first query on every installation that did not also run
`luarocks install akkar-pq`.

That is a packaging constraint and it has nothing to do with the driver being
good. What changes is the recommendation: **install `akkar-pq` and pass
`driver = "pq"`**. It is 1.27x on a single row and 2.79x on a thousand, its p99
under saturation is a third of pgmoon's, it returns byte-identical rows, and
the consistency objection is withdrawn.

## What this cost, and what it bought

Four experiments, two of which refuted a hypothesis — one of them mine, with
the contradicting evidence already sitting in the next column of the table that
suggested it. The instrument was wrong twice: once measuring correlation at
n=1 and calling it a mechanism, once gating on a load average that does not
decay on this machine.

What it bought is that a 2.79x improvement, already written and already tested,
stops being blocked by a number nobody had checked.
