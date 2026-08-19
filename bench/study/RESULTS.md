# The positioning study

What the previous benchmark page could not say, measured properly and on a
machine that survived the run.

```
machine   : AWS c5.2xlarge, Xeon Platinum 8124M @ 3.00GHz
topology  : 4 physical cores x 2 threads
affinity  : servers on 2 whole physical cores, generator on 1
reserved  : 1 whole physical core left to the kernel -- see below
processes : 2 per framework, one per physical core, VERIFIED after every start
pool      : 10 connections per process, all three
load      : wrk, 5 repetitions, alternating order, nearest-rank median
date      : 2026-08-15
```

Semantic equivalence proved before any timing: all four variants return
byte-identical JSON on every route, compared canonically, and a run whose body
contains `"error"` is refused rather than measured.

---

## 0. What HTTP/2, WebSocket and four new bounds cost, 2026-08-19

**Nothing measurable, and that is the number this section exists for.**

Two days added HTTP/2 with full conformance, WebSocket, a guard that keeps one
connection from killing the server, a ceiling on concurrent h2 streams, a
ceiling on socket count, a bound on socket message size, and a fix for a
capability leak on abandoned requests. All of it sits on the request path or
beside it, and the fair question is what it took away.

Measured on a fresh box, five alternating repetitions, restarting between every
one:

| tree | req/s | p50 | p99 | spread | µs/req |
|---|---:|---:|---:|---:|---:|
| `origin/main` `ec2fa93` | 21,727 | 4.50 ms | 6.51 ms | 1.1% | 92.0 |
| this branch `5659f8a` | 21,672 | 4.60 ms | 5.95 ms | 0.7% | 92.3 |

**−0.3%, against spreads of 1.1% and 0.7%.** A difference smaller than the
noise of the run that produced it is not a slowdown, it is a tie, and this page
has a rule about that: a difference below the larger of the two noise floors is
not a result. The p99 moved the other way, 6.51 ms to 5.95 ms, and the same
rule applies to it in the other direction.

So the safety work is free at this load. Not "cheap": free, to the resolution
this harness has.

**AND THIS IS THE FIRST REGRESSION NUMBER SINCE THE HARNESS WAS FIXED**, which
matters more than the number. `bench/study/regression.sh` resolved `ROOT`
through a symlink and `cp -a` copied the symlink, so both trees were the same
repository and every figure it produced compared a tree with itself. It
reported "100.5% of baseline" for months because that is what comparing
something to itself returns. The header of a run now names both commits, and
this one names two different ones:

```
tree-base: ec2fa93   tree-head: 5659f8a
```

Every number on this page below section 0 predates that fix and was taken by
other harnesses. They are not invalidated by it, and they have not been
re-taken either.

---

## 1. What the performance work bought

akkar at `62a40ca`, before any fix, against HEAD. Same harness, same machine,
alternating, zero retries on both rows.

| route | baseline | HEAD | change | floor |
|---|---|---|---|---|
| `/ping` @100 | 18,575 req/s · p50 5.30ms · p99 7.67ms | 21,732 · 4.70ms · **5.59ms** | **+17.0%** | 2.8% |
| `/users/42` @16 | 2,724 · 5.64ms · 11.77ms | 7,758 · **2.04ms** · **2.96ms** | **+184.7%** | 1.7% |

Reproduced on three independent machines across two CPU generations: `/ping`
came out +19.2%, +17.1% and +17.0%; `/users/42` came out 2.85x twice.

The database route improves on **all three** columns — throughput 2.85x, p50
down 64%, p99 down 75%. An earlier run showed the tail getting *worse*, and
that was an artefact of measuring at a concurrency the pool could not serve.
See part 3.

---

## 2. akkar against Gin and FastAPI

This **supersedes** `bench/compare/RESULTS.md`, whose magnitudes were retracted
after an audit found four asymmetries running simultaneously.

### Framework alone — `/ping`, 100 connections

```
framework          req/s        p50        p99   spread   relative
gin            117316.51   631.00us     8.90ms     1.6%      1.00x
fastapi         22009.46     3.60ms     7.42ms     1.2%      0.19x
akkar           20648.03     4.85ms     6.08ms     4.3%      0.18x
akkar-lean      22916.64     4.24ms     6.70ms     0.9%      0.20x
```

### One indexed query — `/users/42`, 16 connections

```
gin             26358.92   562.00us     1.53ms     1.2%      1.00x
akkar            7321.95     2.16ms     3.22ms     1.4%      0.28x
fastapi          5687.87     2.80ms     3.64ms     5.5%      0.22x
akkar-lean       8016.22     1.64ms     3.87ms     0.9%      0.30x
```

### Two hundred rows — `/rows/200`, 16 connections

```
gin              7194.09     1.98ms     7.09ms     1.1%      1.00x
akkar            1450.45    10.92ms    15.93ms     2.2%      0.20x
fastapi           879.68    18.02ms    22.52ms     0.9%      0.12x
```

**akkar is at parity with FastAPI on the framework path and ahead of it on
every route that touches the database** — 29% ahead on one row, 65% ahead on
two hundred. Every earlier conclusion on this subject is reversed: the
retracted page had FastAPI 1.4x ahead on `/ping` and 3.4x ahead on the query.

Gin remains 3x to 5x ahead, and the honest framing is per core: one Gin
process spreads goroutines across every core while one Lua VM is one core.
Per process it is **10,267 against ~58,600 — 5.7x**, and that is the number
that means something.

---

## 2.1 The same comparison with the C driver, which changes the database half

Everything above ran **pgmoon**, akkar's pure-Lua Postgres driver, against
Gin's `pgx` and FastAPI's `asyncpg` — both of which are C underneath. That was
not a decision, it was a default: `driver = "pq"` is opt-in and no benchmark
server in this repository ever passed it. So the table above compared a
pure-Lua database path against two compiled ones and reported the difference
as a framework result.

Re-run the next day with a fifth variant, `akkar-pq`, which is the same tree
and the same routes on `akkar.pq`. Same harness, same gates, same machine, all
five proved to return byte-identical JSON on every target before timing.

```
machine   : the same c5.2xlarge, load 0.11 at start
processes : 2 each, VERIFIED after every restart, and the akkar servers now
            also prove WHICH DRIVER they loaded before the run is allowed
date      : 2026-08-16
```

### Framework alone — `/ping`, 100 connections

```
framework          req/s        p50        p99   spread   relative
gin            116389.66   644.00us     8.74ms     0.7%      1.00x
fastapi         21910.30     3.58ms     7.38ms     0.9%      0.19x
akkar           19453.95     5.11ms     6.09ms     1.1%      0.17x
akkar-lean      21414.96     4.58ms     7.24ms     1.8%      0.18x
akkar-pq        19281.72     5.05ms     6.39ms     1.2%      0.17x
```

`/ping` touches no database and the two akkar rows are 0.9% apart, which is
inside their own spread. That is the control: it says the driver variable is
not leaking into the framework path, and without it every row below would be
suspect.

### One indexed query — `/users/42`, 16 connections

```
gin             26466.47   558.00us     1.57ms     0.3%      1.00x
fastapi          5654.53     2.91ms     4.36ms     4.0%      0.21x
akkar            7090.59     2.30ms     3.60ms     2.2%      0.27x
akkar-lean       7755.48     2.01ms     3.41ms     2.3%      0.29x
akkar-pq         9030.65     1.73ms     2.86ms     1.4%      0.34x
```

### Two hundred rows — `/rows/200`, 16 connections

```
gin              7206.08     1.99ms     7.04ms     1.1%      1.00x
fastapi           880.59    17.92ms    23.94ms     1.9%      0.12x
akkar            1425.37    10.72ms    18.56ms     3.8%      0.20x
akkar-lean       1453.89     9.32ms    23.98ms     0.6%      0.20x
akkar-pq         3482.56     4.57ms     6.53ms     2.0%      0.48x
```

### What it moves

| | pgmoon | akkar.pq |
|---|---:|---:|
| `/users/42` against Gin | 0.27x | **0.34x** |
| `/users/42` against FastAPI | 1.25x | **1.60x** |
| `/rows/200` against Gin | 0.20x | **0.48x** |
| `/rows/200` against FastAPI | 1.62x | **3.95x** |

**On a list endpoint the driver takes akkar from a fifth of Gin to about half
of it, and from 1.6x FastAPI to nearly 4x.** The p99 on that route falls from
18.56 ms to 6.53 ms — below Gin's own 7.04 ms, which is the first row in this
study where akkar's tail is not the worse one.

The framework path does not move, and should not: `/ping` is 0.17x either way.
Whatever separates akkar from Gin on the HTTP path is still there, unchanged,
and no driver was ever going to touch it.

### Two things this does not say

- **It is not a new default.** pgmoon remains the default driver.
  `bench/driver/RESULTS.md` §5.4 has the reason, and it is a measured one: the
  C driver is faster and measurably *less consistent*, with two anomalous
  windows in thirty against pgmoon's zero, unexplained.
- **The `akkar` and `akkar-lean` rows reproduce section 2 rather than replace
  it.** Run a day apart on the same box: Gin 7,194 → 7,206 and FastAPI 880 →
  881 on `/rows/200`, akkar 1,450 → 1,425. That agreement is worth as much as
  the new row, because it says the harness — not the weather — is what these
  numbers come from.

### The defect this run found before it produced a number

The first attempt **refused to run**:

```
REFUSING on /ping (akkar-lean): HTTP-408:{"error":"timed out reading the request body"}
```

`akkar-lean` sets `timeout = 0`, which means "no deadline" everywhere in akkar
except in the body-read budget, which wrote `budget and (...)` — and `0` is
true in Lua. Every request got 408, including a GET with no body. Fixed, and
pinned by a third case in `spec/slow_body_spec.lua`; the numbers above are
from the re-run.

It is worth naming what caught it. `lib.sh` refuses to measure a response
whose body contains `"error"`, a gate added after an earlier run measured two
frameworks agreeing on a 404. A benchmark that only measured speed would have
reported `akkar-lean` as the fastest variant on the page.

---

## 3. Does capacity follow cores?

```
framework procs         req/s        p50        p99   per-proc
akkar    1          10024.38     9.72ms    12.80ms      10024
akkar    2          20534.50     4.84ms     5.81ms      10267
```

**Linear.** akkar's central claim — one VM is one core, so buy capacity with
processes — is measured and true. Slightly superlinear here, as the second
process picks up hyperthread siblings that were idle.

---

## 4. The tail, and where it comes from

`/users/42`, holding the pool fixed and varying only the offered concurrency:

```
configuration                 req/s        p50        p99   spread
pool 10  conns 50          7338.34     5.52ms    22.57ms     2.7%
pool 10  conns 100         7044.75     5.33ms      4.88s     1.1%
pool 30  conns 100         7715.17    11.90ms    23.94ms     4.9%
pool 30  conns 200         7050.82    25.93ms    80.93ms     3.3%
```

**Throughput is flat.** Every configuration serves about seven thousand a
second, and offered concurrency beyond the pool buys nothing but queue — which
the tail pays for, two hundred fold.

The tail was never something the performance work introduced. It is pool-wait,
and it disappears when the connections fit. This is the measurement that
`akkar.limit.concurrent` exists for.

---

## 5. What the per-request deadline costs — **and a suspicion refuted**

An earlier comparison showed akkar at p99 647ms and akkar-lean at 86ms on the
same route, which suggested the deadline was multiplying the tail sevenfold.
That was two separate runs, and it was recorded as a suspicion rather than a
result. The controlled version, same process, alternating, five repetitions:

```
variant               req/s        p50          p99   spread
shipped             7539.71    12.19ms      27.40ms     3.2%
lean                8596.92    10.48ms      27.55ms     1.1%
```

**The deadline costs 12.3% of throughput and nothing at all in the tail** —
27.40ms against 27.55ms, indistinguishable. The suspicion was wrong, and the
discipline that recorded it as a suspicion is what allowed it to be checked.

Twelve percent for a per-request wall-clock budget that neither Gin nor
uvicorn offers is the trade akkar makes, stated rather than hidden. It is one
line to turn off.

---

## 6. How each one degrades as the body grows

```
rows      akkar        gin     fastapi   akkar/gin   akkar/fastapi     bytes
1       7214.06   22362.21     5366.85       0.32x           1.34x        66
10      6070.25   20640.23     4299.32       0.29x           1.41x       618
100     2416.92   10565.29     1520.95       0.23x           1.59x      9846
500      641.84    3561.76      375.53       0.18x           1.71x     51486
1000     332.66    1973.68      191.78       0.17x           1.74x    104799
2000     167.16    1004.03       96.91       0.17x           1.72x    213009
```

**akkar beats FastAPI at every size, and the margin widens with the payload** —
1.34x at one row, 1.74x at a thousand. Against Gin the ratio degrades from
0.32x to 0.17x, and that curve is pgmoon decoding rows in the interpreter:
55% of a thousand-row query, measured by stage.

The retracted page said akkar's degradation was worse than everyone's. It is
worse than Gin's and **better than FastAPI's**.

---

## 7. Forty-five minutes, because everything above is ten seconds

Every other figure in this study is a ten-second window, and a ten-second
window cannot see the three things that actually take a service down
overnight: memory that climbs, descriptors that are never returned, and
throughput that decays. So this run measures **drift** rather than a number —
the last quarter against the first — and samples the resources beside it.

45 minutes, 2 processes, `pool_size = 10`, 16 connections, one sample per
minute, against `/users/42`. Full table in `results/soak.log`.

```
min      req/s      p50      p99   rss_mb   fds   pg   errors
1      7373.63   2.15ms   3.12ms       26    60   17        0
17     7368.77   2.59ms   3.97ms       27    80   21        0
45     7398.22   2.56ms   3.98ms       27    80   21        0
```

| | |
|---|---|
| Throughput drift, last quarter vs first | **+0.048%** |
| Spread across all 45 samples | 0.91%, min 7345.10, max 7412.26 |
| Resident memory | **26 MB → 27 MB, then flat for 44 minutes** |
| Descriptors | 60 → 80 by minute 17, then flat |
| Postgres connections | 17 → 21, then flat |
| Errors | **0**, across roughly 19.9 million requests |

Nothing drifts. The one number that moves is the descriptor count, and it
stops moving: that is the pool filling to its ceiling and staying there, which
is what a pool is supposed to do. The 21 Postgres connections are the whole
capacity — two processes times ten — **plus the `psql` doing the counting**,
so the pools were genuinely full every time they were sampled.

**What this does not answer.** The question that motivated the soak was pool
sizing: `/users/:id` showed a 191 ms p99 at 100 connections against
`pool_size = 10`, where ninety requests queue for a connection. This run used
16 connections against a capacity of 20, so **nothing ever queued** — it
proves the absence of a leak, not the behaviour of a saturated pool. The
sizing guidance is still owed, and it needs a soak run above capacity.

Forty-five minutes is also not a night. It is long enough to rule out a leak
with a slope this flat, and not long enough to say anything about a weekly
one.

---

## 8. Above capacity, which is the run the backlog owed

Section 7 sustained 45 minutes at 16 connections against a capacity of 20, so
nothing ever queued. It proved the absence of a leak and said nothing about
the regime an incident happens in. This holds the pool fixed and sweeps
offered concurrency from half capacity to four times it.

Two processes, `pool_size = 10` each, capacity **20 connections**, 30 s per
point, three repetitions, `/users/42`. Script: `bench/study/saturation.sh`.

```
mult   conns         req/s       p50       p99   errors
0.5x   10          7138.36    1.17ms    1.98ms        0
0.75x  15          7198.57    1.68ms    2.63ms        0
1x     20          7315.41    2.71ms    3.74ms        0
1.25x  25          7349.19    3.24ms    4.35ms        0
1.5x   30          7420.54    3.73ms    4.69ms        0
2x     40          7768.32    5.18ms    6.22ms        0
3x     60          7181.37    6.65ms   37.70ms        0
4x     80          6941.36    9.28ms   82.38ms        0
```

### The predictions, scored

Recorded in the script before the run, per `bench/compare/METHOD.md`. **One of
four was right.**

| | Predicted | Measured |
|---|---|---|
| 1 | Throughput flat from 1.0x onward | **Wrong.** It rises to a peak at 2x (+6% over 1x) and then falls, down 11% from that peak by 4x. There is an optimum, not a plateau |
| 2 | p99 grows roughly linearly past capacity | **Wrong.** It is nearly flat through 2x and then breaks: 6.22 ms → 37.70 ms → 82.38 ms. A knee between 2x and 3x, not a line |
| 3 | Pool wait becomes the majority of p99 above 2x | **Not measured.** The benchmark app does not mount `/metrics`, so the counters added to `Pool:get` for exactly this were never read. Owed |
| 4 | Errors stay at zero | **Right.** Zero at every point |

### The sizing rule, which is what the run was for

> **Offered concurrency up to twice the pool is free. Past that it is paid for
> in the tail, and it buys nothing.**

Below 2x, every extra connection is absorbed: throughput improves slightly and
p99 stays under 7 ms. Above 2x the server does *less* work and answers *worse*
— 3x offers half again the load for 7.5% less throughput and six times the
tail.

So: **size the pool at about half the peak concurrency you intend to accept**,
and use `akkar.limit.concurrent` to refuse the rest rather than queue it. That
is the same conclusion the limiter's own docstring reached from the earlier
numbers, now with the knee located.

### RETRACTION: these numbers are best-of-three, not median-of-three

Written after the fact, in the same voice as the retractions in
`bench/compare/RESULTS.md` and `docs/PERFORMANCE-STUDY.md`, because a number
that overstates itself is worth more as a correction than as a deletion.

The table above says "three repetitions" and this document's header says
"nearest-rank median". `saturation.sh` did neither: the loop that collected the
repetitions kept the run with the HIGHEST throughput, under a comment that said
it was taking the median. Every `req/s` in the table is therefore a **best of
three**, and each `p50`/`p99` is the latency of that best run.

What that does to the conclusions, stated rather than guessed:

- **The bias is upward everywhere, and unequal across rows.** It is largest
  where run-to-run variance is largest, and on a saturation curve that is past
  the knee. So the tail figures at 3x and 4x are the ones least to be trusted,
  and they are optimistic — the real p99 there is worse than 37.70 ms and
  82.38 ms, not better.
- **The knee survives.** A five-fold jump between 2x and 3x is far outside the
  spread that picking a maximum can produce; taking the best of three cannot
  manufacture a break of that size, only soften it.
- **The 2x peak does not survive as a measurement.** It is +6% over 1x, which
  is the same order as the difference between a maximum and a median over
  three runs. Prediction 1 is scored "wrong" on the strength of that peak, and
  that score should be read as unproven rather than as established.
- **The sizing rule is unaffected in direction**, since it rests on the knee,
  and the bias makes it if anything conservative: the tail past 2x is worse
  than published, so refusing that load rather than queueing it is the better
  call, not the worse one.

The script is fixed — it sorts the runs and takes row ceil(n/2) whole, so the
three numbers on a line still come from one run. **The table has not been
re-measured**, because the machine it needs is not currently up; when it is,
this section gets new numbers and this retraction stays.

### The honest limits

- **One route, one shape.** `/users/42` is a single indexed row. A query
  costing ten times as much moves the knee, and this says nothing about where.
- **Errors stayed at zero because the deadline was never reached.** At 4x, p99
  is 82 ms against a 30-second default. A tighter deadline would convert the
  tail into 503s, which is the intended behaviour and is not measured here.
- **The numbers are biased upward.** See the retraction above; the table is a
  best-of-three that was labelled a median.
- **Prediction 3 is still owed**, and the instrumentation to answer it now
  exists — `stats().waits`, `.waited`, `.waited_max`. What is missing is a
  benchmark app that exposes it.

---

## What this study is not

- **Not a claim about developer velocity, ecosystem or maintenance**, which
  decide framework choice far more often than throughput does.
- **Not tuned Postgres, other query shapes, or a realistic mixed workload.**
  Three routes, one box, stock settings.
- **Not a saturated pool over hours.** Section 7 sustains 45 minutes and finds
  no drift, but it runs below pool capacity and nothing queues. The comparison
  figures themselves are still ten-second windows.

## What it cost to get

Four machines. Three of them went unreachable mid-run and were replaced before
the cause was understood; three separate technical hypotheses — descriptor
exhaustion, softirq starvation, spot reclaim — were argued from symptoms and
all three were wrong. The evidence that mattered was that SSH **timed out**
rather than being refused, which is a packet being dropped, which on AWS is a
security group: a `/32` rule pinned to a residential IP that changes every
half hour or so. Nothing was ever wrong with the machines.

The harness carries the scars, and they are the reason these numbers can be
trusted: the process count is verified after every start, each server proves
which tree it loaded, a run whose body says `"error"` is refused, the
concurrency for database routes is derived from the pool rather than chosen,
and one physical core is reserved so the kernel is never starved.

---

## 9. Eight hours, which is what the backlog meant by a soak

Section 7 ran forty-five minutes. That proves a server starts and keeps
answering; it does not prove anything about a leak, because a leak of a
kilobyte a request is invisible in forty-five minutes and fatal in a week.

    480 minutes, 2 processes, pool 10 each, 16 connections, /users/42
    AWS c5.2xlarge, Xeon Platinum 8124M @ 3.00GHz
    started 2026-08-16T01:45:03Z, 96 samples at five-minute intervals

```
                first hour     last hour       min        max
throughput      7181 req/s     7179 req/s      5334       7244
p50             2.25 ms        2.23 ms         2.16       3.86
p99             3.36 ms        3.22 ms         2.99       6.17
rss             28 MB          28 MB           28         28
fds             68             84              59         84
pg connections  19             21              16         21

errors: 0
```

### What it answers

**No memory drift.** 28 MB at minute 5 and 28 MB at minute 480, and 28 MB at
every one of the 96 samples between. Not "roughly flat" -- the same integer,
every time. This is the measurement the whole run existed to take.

**Descriptors settle, they do not climb.** 59 to 84 over the first four hours,
and then **not one change from minute 235 to minute 480**. That shape is a
warm-up: two processes filling pools of ten as concurrency reaches them.  A
leak does not stop, and this one stopped and stayed stopped for four hours.

**Throughput does not decay.** The first hour's median and the last hour's
differ by 2 req/s, which is 0.03%. Eight hours of continuous load moved
nothing.

**Zero errors**, across roughly 200 million requests at that rate.

### The one anomaly, named rather than smoothed

Minute 50 records 5334 req/s against a median of 7179 -- a 26% dip, in one
sample, with p99 at 6.17 ms instead of the usual 3.2 ms. Nothing else in the
run resembles it and every sample after it is normal. It is the single reason
the min/max spread reads 26.6%; without it the spread is under 3%.

It is reported and not explained. A single five-minute sample on a shared
cloud instance has too many candidate causes -- a noisy neighbour, a host
migration, a background task on the box -- and picking one would be a story
rather than a finding. What can be said is what it is not: it did not recur in
the following seven hours, it produced no errors, and it left no trace in
memory or descriptors.

### What this does NOT prove

- **One route, one shape.** `/users/42` is a single indexed row, and the
  driver comparison in `bench/driver/RESULTS.md` shows single-row queries are
  exactly where the least work happens. A soak on a list endpoint would
  exercise the allocator far harder and has not been run.
- **Sixteen connections against a capacity of twenty**, so nothing ever
  queued. This is the same limitation section 7 had and section 8 was written
  to address; the saturation curve is where queueing appears, not here.
- **pgmoon, not the C driver.** `akkar.pq` exists and is opt-in, and this ran
  on the default. A soak of the driver that allocates less per row is a
  different run and the interesting one to compare against.

  Since measured, on this machine and through this harness: the C driver is
  **1.27x on `/users/42` and 2.79x on a thousand rows**, with p99 under
  saturation falling from 1.3 s to 475 ms — `bench/driver/RESULTS.md` §5. What
  is still true is the sentence above: **the soak itself has never run on it**,
  and section 9's whole point is what happens over eight hours rather than ten
  seconds. The driver also turned out to be measurably less consistent than
  pgmoon, which is exactly the property a soak exists to judge.
- **No jobs, no cache, no TLS.** Only the HTTP and database paths.

