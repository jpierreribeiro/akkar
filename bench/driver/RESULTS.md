# The C driver, measured — and a comparison this project had been making wrong

```
machine   : this laptop, Linux 6.8, Postgres 16 in Docker on 127.0.0.1:55432
lua       : 5.4, cqueues
drivers   : pgmoon (pure Lua) vs akkar.pq (libpq + C, async via cqueues)
load      : alternating order, warmup discarded, nearest-rank median of 5
date      : 2026-08-16
```

> **TWO MACHINES, and the header above describes only the first.** Sections 1
> to 4 are the driver in isolation on a laptop, with Postgres in a container
> and a test suite that had been running minutes earlier. **Section 5 is the
> driver through HTTP on the `c5.2xlarge` the study uses**, and carries its own
> header. Absolute numbers do not cross between them; the two are compared only
> where the text says so and only as ratios.

> ## CORRECTION, and every number below it was re-measured
>
> **The first run of this benchmark was taken on a machine with twenty-two
> spinning processes on it.** They were wedged lua-http servers, left behind by
> `spec/substrate_repair_spec.lua` — a test that deliberately wedges a server
> and, in its first version, called `stop()` on its last line, so any failing
> assertion above skipped the cleanup. A wedged lua-http server does not idle,
> it spins. Twenty-two of them, five hours old, load average 23.
>
> Nothing in the benchmark could have detected this. It ran, it produced a
> consistent curve, and every figure in it was wrong.
>
> The measurement was repeated with the machine quiet (load 2.2). What changed:
>
> | | contaminated | quiet |
> |---|---:|---:|
> | floor, 1 row | 274.80 us | **165.99 us** |
> | floor, 1000 rows | 1,936.25 us | **996.70 us** |
> | pgmoon, 1000 rows | 14,179.06 us | **4,931.94 us** |
> | akkar.pq, 1000 rows | 3,622.00 us | **1,639.70 us** |
> | speedup at 1000 rows | 3.91x | **3.01x** |
> | driver cost reduction, 1000 rows | 7.3x | **6.1x** |
>
> **The contamination INFLATED the advantage**, and the direction makes sense:
> pgmoon does its work in the interpreter, so it loses more to CPU contention
> than a driver that spends its time in libpq and in the kernel. A noisy
> machine flatters the thing being sold, which is the worst way for a benchmark
> to be wrong.
>
> What survives unchanged is the conclusion that mattered: at one row the
> difference does not clear the gate, and `/users/:id` is a one-row query.
>
> The test that leaked now cleans up in `finally` and escalates to SIGKILL —
> a wedged server cannot answer SIGTERM, because `app:handle_signals` installs
> the handler as a cqueues coroutine and the wedge is precisely that no
> coroutine gets scheduled.

## 1. The measurement that reframes the others: the floor

`bench/driver/floor.c` is the same query through blocking `PQexecParams` in a
tight C loop — no Lua, no cqueues, no polling. Whatever it costs is Postgres
plus libpq on this box, and everything above it belongs to us.

```
                        1 row        1000 rows
floor (libpq in C)     165.99 us       996.70 us
akkar.pq               200.96 us      1639.70 us
pgmoon                 219.63 us      4931.94 us
```

**A single-row round trip costs 166 us here.** That number is the reason this
section exists, because this project has been quoting a comparison that mixes
machines:

> `bench/compare/RESULTS.md`: *"the same query against the same Postgres costs
> 32 us through pgx, 82 us through asyncpg and 330 us through pgmoon"*

Those three were measured against each other on the EC2 box and are sound
relative to one another. What is NOT sound is the inference that has been
drawn from them since — that 330 us is what pgmoon *adds*. On this machine
pgmoon's single-row query costs 220 us of which **166 us is the floor**, so
pgmoon adds 54 us, not 220. A driver cannot be blamed for the round trip.

Subtracting the floor gives the only number that measures the driver:

| | driver cost, 1 row | driver cost, 1000 rows |
|---|---:|---:|
| pgmoon | 53.6 us | **3,935 us** |
| akkar.pq | 35.0 us | **643 us** |
| reduction | 1.53x | **6.1x** |

## 2. The whole curve, and where it crosses

```
rows   pgmoon      akkar.pq    speedup   verdict
1        219.63 us   200.96 us   1.09x   OVERLAPPING
10       359.47 us   289.64 us   1.24x   SEPARATED
100      789.42 us   457.41 us   1.73x   SEPARATED
1000    4931.94 us  1639.70 us   3.01x   SEPARATED
```

Ten rows separates on the quiet machine and did not on the noisy one, which is
the only place the correction moved a verdict rather than a number. One row
still does not separate, across two independent runs at different iteration
counts.

`OVERLAPPING` and `SEPARATED` are not adjectives, they are the gate:
`SEPARATED` means the *fastest* run of the slower driver was still slower than
the *slowest* run of the faster one, across five alternating repetitions. When
the runs interleave, the difference is not claimed.

**The crossover is between 1 and 10 rows**, and it is exactly where
`docs/PERFORMANCE-STUDY.md` said it would be: the study decomposed a query and
found row materialisation — crossing the boundary and allocating one Lua table
per row — at 55% of a thousand-row query. Below ten rows there is almost
nothing to materialise, so there is almost nothing to win.

## 3. THE UNCOMFORTABLE PART, stated first rather than buried

> **SCORED, and it did not survive — see section 5.2.** The prediction below
> was measured end to end and came out wrong: `/users/42` moves 1.27x through
> HTTP and separates. It is kept as written, because a prediction edited after
> the fact is not a prediction.

**`/users/:id` is a single-row query.** It is the route in
`bench/compare/RESULTS.md`, the route in the saturation study, and the route
in the soak. On this machine, at one row, the C driver's advantage does not
clear the noise gate.

So the honest prediction for the headline number is: **the C driver will not
move `/users/:id` throughput much**, and anybody expecting the 2,744 req/s to
approach Gin's 26,212 because the driver changed is going to be disappointed.
What moves is:

- **List endpoints**, which is where real applications spend their database
  time and where the 6.1x in driver cost lives.
- **Tail latency under load**, because 3,935 us of interpreter work per
  thousand-row query is 3,935 us during which the single-threaded event loop
  is running nothing else. This is the effect worth measuring next and it is
  not measured here.

## 4. What was NOT done, so nobody assumes it was

- **The machine was not verified quiet before the first run**, and that is
  the finding worth carrying forward more than any number here. `bench/study/lib.sh`
  has gates for topology, core reservation and process count; this benchmark
  had none of them, and paid for it. A load check belongs in `compare.lua`
  before it times anything.
- **No predictions were recorded before this run**, which `bench/compare/METHOD.md`
  requires. This was written and measured in one sitting. The scoring above is
  therefore against the project's *prior published claims*, which were
  recorded, and not against fresh predictions — a weaker thing, and it is
  labelled as such rather than dressed up.
- **Not run on the study machine.** The `c5.2xlarge` was busy with the
  overnight soak. Until this is repeated there, none of these absolute numbers
  should be compared with anything in `bench/compare/RESULTS.md`.
- ~~**No end-to-end HTTP measurement.**~~ **CLOSED — see section 5**, and the
  prediction this page made about it was wrong.
- ~~**No pooled or concurrent measurement.**~~ **CLOSED — see section 5.**
  Section 5 runs a pool of ten per process under sixteen and a hundred
  concurrent connections, and concurrency turns out to be the thing this page
  could not see.

## 5. The same driver through HTTP, on the study machine

```
machine   : AWS c5.2xlarge, Xeon Platinum 8124M @ 3.00GHz, load 0.04 at start
topology  : servers on 2 whole physical cores, generator on 1, 1 reserved
processes : 2 akkar processes, SO_REUSEPORT, count VERIFIED every restart
pool      : 10 connections per process
load      : wrk, 10s, 5 repetitions, order alternating EVERY repetition
gates     : bench/study/lib.sh -- topology, reservation, process count,
            error-body refusal, and both drivers proved byte-identical JSON
            on all six targets before anything was timed
retries   : 0
date      : 2026-08-16
```

Run with `bench/driver/end-to-end.sh`. The server prints which driver it
loaded and the harness refuses to measure unless every process says the
expected one — `db.connect` opens lazily, so a server asked for `pq` without
`pq_native.so` would otherwise run happily until the first request.

### 5.1 The result

| route | pgmoon | akkar.pq | ratio | verdict | pgmoon p99 | pq p99 |
|---|---:|---:|---:|---|---:|---:|
| `/ping` @100 | 19,241 | 19,392 | 1.01x | **OVERLAPPING** | 6.01 ms | 6.26 ms |
| `/users/42` @16 | 7,040 | 8,969 | **1.27x** | SEPARATED | 3.36 ms | 2.87 ms |
| `/rows/10` @16 | 5,919 | 8,279 | **1.40x** | SEPARATED | 4.19 ms | 3.20 ms |
| `/rows/100` @16 | 2,392 | 5,031 | **2.10x** | SEPARATED | 10.43 ms | 5.62 ms |
| `/rows/1000` @16 | 333 | 928 | **2.79x** | SEPARATED | 77.77 ms | 23.22 ms |
| `/rows/1000` @100 | 322 | 861 | **2.68x** | SEPARATED | 1300.00 ms | 475.34 ms |

`/ping` is the control and it is listed first on purpose: it touches no
database, and if the two variants differed there the harness would be
measuring itself and every other row would be void. They do not differ.

### 5.2 The prediction on this page was wrong, and in the useful direction

Section 3 predicted, from the isolated measurement, that **the C driver would
not move `/users/:id`** — one row was `OVERLAPPING` at 1.09x, and a single-row
route is what the comparison, the saturation sweep and the soak all use.

Through HTTP it moves 1.27x and it **separates**. That verdict took a
re-measurement to earn: at five repetitions the gate said `OVERLAPPING`, so
the route was re-run alone at eight, where the worst pq window (7,197) clears
the best pgmoon window (7,109) by 1.2%. A margin that thin is reported as what
it is — the weakest `SEPARATED` on the page.

**The driver's advantage is LARGER through a whole request than it was over a
bare query, which is backwards from what dilution would predict.** A framework
wrapped around a query should shrink the share the driver owns. Instead:

| | isolated, 1 query at a time | through HTTP, 16 concurrent |
|---|---:|---:|
| 1 row | 1.09x | **1.27x** |
| 1000 rows | 3.01x | 2.79x |

The mechanism this page already named is the candidate, and it is stated as a
hypothesis rather than a conclusion because nothing here isolates it: **akkar
runs one thread per process, so driver CPU is not paid by the request that
spends it.** Every microsecond pgmoon spends in the interpreter materialising
rows is a microsecond the event loop is not serving the other fifteen
connections. Under concurrency that cost is multiplied rather than diluted,
which is exactly the effect section 3 called "worth measuring next".

At 1000 rows the two effects cross: the driver's share is already dominant, so
framework overhead dilutes it back down slightly.

### 5.3 Latency, which is the stronger half of this result

Throughput is the headline; the tail is the part an operator feels.

| route | p50 | p99 |
|---|---|---|
| `/users/42` @16 | 2.25 → **1.73 ms** (−23%) | 3.36 → **2.87 ms** (−15%) |
| `/rows/100` @16 | 6.49 → **3.21 ms** (−51%) | 10.43 → **5.62 ms** (−46%) |
| `/rows/1000` @16 | 47.29 → **17.75 ms** (−63%) | 77.77 → **23.22 ms** (−70%) |
| `/rows/1000` @100 | 231.13 → **98.19 ms** (−58%) | 1300 → **475 ms** (−63%) |

The saturated row is the one worth reading twice. At a hundred connections
against a pool that can serve twenty, a thousand-row query on pgmoon has a p99
of **1.3 seconds**. The same route on the C driver is 475 ms. Both are bad
numbers — that is what saturation looks like — but the difference between them
is the difference between a slow page and a timeout.

### 5.4 The finding that argues AGAINST flipping the default

> ## CORRECTED — the finding below did not survive being investigated
>
> **`akkar.pq` is not less consistent than pgmoon.** Measured at the exact
> configuration this section used — `/users/42`, sixteen connections, two
> processes — pq comes back at **1.8% spread with zero anomalous windows**,
> against the 21.4% and two reported here.
>
> The one raggedness that does reproduce belongs to the harness. Six
> connections over two processes makes `SO_REUSEPORT` split them three-and-three
> or five-and-one, re-drawn every window, and it hits **pgmoon harder than pq**
> — 37.3% spread against 30.5%. One process cannot be split and both are smooth.
>
> A Postgres checkpoint was the first hypothesis and it is refuted: forced, it
> costs pgmoon −0.0% and pq +0.1%.
>
> The likeliest source of the original number is this page's own method:
> alternating drivers per repetition restarts both servers every time, so all
> five of its windows measured a cold connection pool behind one three-second
> warm-up. Alternating is right for comparing two variants and wrong for
> measuring how consistent one is.
>
> `bench/driver/ANOMALY.md` has the four experiments, including the two that
> refuted a hypothesis. The section is kept as written because it is what was
> believed, and because the correction is the point.
>
> **The default still does not move**, for a reason that has nothing to do with
> this section: `akkar.pq_native` is a separate rock, so a default of `pq`
> would fail at the first query for anyone who installed only `akkar`.

**The C driver is faster and less consistent, and consistency is not a
secondary property.**

Spread across repetitions, which this project treats as the noise floor:

| | routes with spread > 10% | windows more than 10% below their own median |
|---|---|---|
| pgmoon | none — every route 0.9% to 3.5% | **0 of 30** |
| akkar.pq | `/users/42` 21.4%, `/rows/100` 14.2% | **2 of 30** |

Twice in thirty ten-second windows, pq ran a whole window at roughly pgmoon's
speed and then went back to being fast. It is not one stalled request: in the
slow window p50 rose with p99 (2.57 ms against a usual 1.73 ms), so the entire
window was slower rather than one request hanging in it.

**No explanation is offered here, because none has been measured.** It is not
row-count dependent — `/rows/10` sits between the two affected routes and is
clean at 2.8%. It never happened to pgmoon on the same machine in the same
alternating runs, which is the reason it is being reported as a property of
the driver rather than of the box.

That is the honest blocker: a driver becomes the default by proving itself,
and an unexplained intermittent loss of its entire advantage is not proof. The
next instrument is a long run with per-request timing rather than per-window
throughput, which is the only thing that can say whether the window contains
one long stall or a hundred thousand slightly slower requests.

### 5.5 What section 5 still does not prove

- **One machine, one shape of data.** Four `text` columns and an integer.
  Wide rows, `bytea`, `numeric` and `timestamptz` are where the two drivers'
  type handling actually differs, and none of them is here.
- **Ten seconds is not a soak.** `docs/UNKNOWNS.md` asks for correctness over
  time, and the soak that answers it ran pgmoon. The C driver has never run
  for eight hours.
- ~~**The comparison against Gin and FastAPI still stands on pgmoon.**~~
  **CLOSED the same day** — `bench/study/RESULTS.md` §2.1 re-runs the
  three-way comparison with `akkar-pq` as a fifth variant. On two hundred rows
  it moves akkar from 0.20x of Gin to **0.48x**, and from 1.6x FastAPI to
  **3.95x**, with a p99 of 6.53 ms against Gin's own 7.04 ms. The framework
  path does not move, which is what says the driver variable is not leaking.

## 6. Reproducing it

```sh
# The floor.
gcc -O2 -I<libpq-include> -o floor bench/driver/floor.c <libpq.so>
./floor 3000 "select 42 as id, 'ada'::text as name"

# The driver in isolation, at any row count (sections 1-3).
lua5.4 bench/driver/compare.lua <rows> <iterations> <repetitions>

# The driver through HTTP, on a machine with three or more physical cores
# (section 5). Needs the study's Postgres seeded and wrk on the box.
bash bench/driver/end-to-end.sh

# One route on its own, more repetitions -- how 5.2 earned its verdict.
TARGETS="/users/42:16:4" REPS=8 bash bench/driver/end-to-end.sh
```

Both harnesses verify that the drivers return identical rows before they time
anything. A comparison between two things that disagree about the data is not
a comparison, and the check costs one query. In the HTTP harness the check is
against canonical JSON, because libpq returns numerics as strings unless told
otherwise and `{"id":42}` against `{"id":"42"}` would make one variant look
faster for having encoded less.
