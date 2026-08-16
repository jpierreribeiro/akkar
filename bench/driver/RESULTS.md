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

## 1. The measurement that reframes the others: the floor

`bench/driver/floor.c` is the same query through blocking `PQexecParams` in a
tight C loop — no Lua, no cqueues, no polling. Whatever it costs is Postgres
plus libpq on this box, and everything above it belongs to us.

```
                        1 row        1000 rows
floor (libpq in C)     274.80 us      1936.25 us
akkar.pq               382.28 us      3622.00 us
pgmoon                 492.47 us     14179.06 us
```

**A single-row round trip costs 275 us here.** That number is the reason this
section exists, because this project has been quoting a comparison that mixes
machines:

> `bench/compare/RESULTS.md`: *"the same query against the same Postgres costs
> 32 us through pgx, 82 us through asyncpg and 330 us through pgmoon"*

Those three were measured against each other on the EC2 box and are sound
relative to one another. What is NOT sound is the inference that has been
drawn from them since — that 330 us is what pgmoon *adds*. On this machine
pgmoon's single-row query costs 492 us of which **275 us is the floor**, so
pgmoon adds 217 us, not 492. A driver cannot be blamed for the round trip.

Subtracting the floor gives the only number that measures the driver:

| | driver cost, 1 row | driver cost, 1000 rows |
|---|---:|---:|
| pgmoon | 217 us | **12,243 us** |
| akkar.pq | 107 us | **1,686 us** |
| reduction | 2.0x | **7.3x** |

## 2. The whole curve, and where it crosses

```
rows   pgmoon      akkar.pq    speedup   verdict
1        492.47 us   382.28 us   1.29x   OVERLAPPING
10       812.92 us   575.01 us   1.41x   OVERLAPPING
100     2538.20 us   953.68 us   2.66x   SEPARATED
1000   14179.06 us  3622.00 us   3.91x   SEPARATED
```

`OVERLAPPING` and `SEPARATED` are not adjectives, they are the gate:
`SEPARATED` means the *fastest* run of the slower driver was still slower than
the *slowest* run of the faster one, across five alternating repetitions. When
the runs interleave, the difference is not claimed.

**The crossover is between 10 and 100 rows**, and it is exactly where
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
  time and where the 7.3x in driver cost lives.
- **Tail latency under load**, because 12,243 us of interpreter work per
  thousand-row query is 12,243 us during which the single-threaded event loop
  is running nothing else. This is the effect worth measuring next and it is
  not measured here.

## 4. What was NOT done, so nobody assumes it was

- **No predictions were recorded before this run**, which `bench/compare/METHOD.md`
  requires. This was written and measured in one sitting. The scoring above is
  therefore against the project's *prior published claims*, which were
  recorded, and not against fresh predictions — a weaker thing, and it is
  labelled as such rather than dressed up.
- **Not run on the study machine.** The `c5.2xlarge` was busy with the
  overnight soak. Until this is repeated there, none of these absolute numbers
  should be compared with anything in `bench/compare/RESULTS.md`.
- **No end-to-end HTTP measurement.** This is the driver in isolation. What a
  request costs is a different question and `akkar/db.lua` still goes through
  pgmoon — the driver is not wired into the adapter yet.
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
