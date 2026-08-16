# The C driver, measured — and a comparison this project had been making wrong

```
machine   : this laptop, Linux 6.8, Postgres 16 in Docker on 127.0.0.1:55432
lua       : 5.4, cqueues
drivers   : pgmoon (pure Lua) vs akkar.pq (libpq + C, async via cqueues)
load      : alternating order, warmup discarded, nearest-rank median of 5
date      : 2026-08-16
```

> **This is NOT the machine `bench/compare/RESULTS.md` used.** That ran on a
> reserved `c5.2xlarge` with its own Postgres; this is a laptop with Postgres
> in a container and a test suite that had been running minutes earlier. Every
> absolute number below belongs to this machine and to no other. What travels
> is the *shape*, and the shape is the point.

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
- **No end-to-end HTTP measurement.** This is the driver in isolation, and
  what a request costs is a different question. The driver IS wired into
  `akkar/db.lua` now (`db.connect { driver = "pq" }`), with pgmoon still the
  default until a soak says otherwise, so the end-to-end number is measurable
  and has not been measured.
- **No pooled or concurrent measurement.** Every number is one connection,
  one query at a time. The concurrency property is pinned by
  `spec/pq_spec.lua` ("two 0.4s queries take the time of one") but its cost
  under a saturated pool is unmeasured.

## 5. Reproducing it

```sh
# The floor.
gcc -O2 -I<libpq-include> -o floor bench/driver/floor.c <libpq.so>
./floor 3000 "select 42 as id, 'ada'::text as name"

# The comparison, at any row count.
lua5.4 bench/driver/compare.lua <rows> <iterations> <repetitions>
```

`compare.lua` verifies that both drivers return identical rows before it times
anything. A comparison between two things that disagree about the data is not
a comparison, and the check costs one query.
