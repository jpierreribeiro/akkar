# akkar against Gin and FastAPI

Method fixed before any of this existed: `METHOD.md`. Read it first — it also
records what was predicted in advance, and two of those predictions were wrong.

```
machine   : AWS c5.2xlarge, Xeon Platinum 8275CL @ 3.00GHz
topology  : 4 physical cores x 2 threads
affinity  : services on 3 whole physical cores, generator on 1
postgres  : 16-alpine in Docker, same box, stock settings, max_connections 100
go        : 1.25.0, Gin 1.10.0, pgx/v5 5.10.0
python    : 3.14.4, FastAPI 0.141.1, uvicorn 0.52.3 + uvloop + httptools, asyncpg
lua       : 5.4.8, akkar, cqueues + lua-http, pgmoon
each      : 3 processes, pool 10 per process, logging off, validation on
```

Semantic equivalence was proven before any timing: same JSON, same statuses,
same validation, same error bodies, diffed rather than assumed.

---

## Framework alone — `/ping`

```
framework          req/s        p50        p99   relative    spread
gin            163014.67   280.00us     4.42ms      1.00x      0.8%
fastapi         40245.08     2.01ms     4.11ms      0.25x      0.8%
akkar           28850.78     3.69ms     5.61ms      0.18x      2.3%
```

Per request, that is **6.1 µs for Gin, 24.8 µs for FastAPI, 34.7 µs for
akkar**.

## With one indexed query — `/users/:id`

```
framework          req/s        p50        p99   relative    spread
gin             26212.32     3.74ms     4.99ms      1.00x      0.3%
fastapi          9316.00    10.44ms    28.76ms      0.36x      1.5%
akkar            2744.91    35.74ms   103.98ms      0.10x      0.6%
```

Subtracting the framework cost above, the **same query against the same
Postgres** costs:

| | per request |
|---|---:|
| Gin, pgx | **32 µs** |
| FastAPI, asyncpg | **82 µs** |
| akkar, pgmoon | **330 µs** |

---

## The finding, and it corrects an earlier claim of this project

`bench/RESULTS.md` said, from measuring akkar alone: *"The framework is not the
limit; Postgres is."* That was drawn from akkar's own `/ping` at 31.8k against
`/users/:id` at 2.7k, and reading the gap as the database.

**It was wrong.** Gin gets 26,212 req/s and FastAPI 9,316 from that same
Postgres, on that same box, with the same pool size and the same query. Postgres
was never the limit at 2.7k.

The limit is **pgmoon**, which speaks the Postgres wire protocol in pure Lua —
parsing every row in the interpreter. asyncpg is C-accelerated and pgx is
compiled, and they are 4x and 10x cheaper per query respectively.

Ruled out before blaming the driver: the pool. akkar is flat at ~2,740 req/s
with 10 or 25 connections per process, while Gin climbs from 26k to 32.6k over
the same range. A pool that is too small does not stay flat when it is
enlarged.

This is the single largest thing standing between akkar and any real
throughput, and it is squarely inside the adapter boundary — which is the one
piece of good news in it. Swapping pgmoon for libpq behind a C host would
rewrite `akkar/db.lua` and nothing else. That boundary was justified on
principle; this is the first time it has been justified by a number.

## Predictions, scored honestly

`METHOD.md` recorded four in advance.

| | prediction | outcome |
|---|---|---|
| 1 | Go wins `/ping` by a large margin | **Right.** 5.7x over akkar. |
| 2 | The gap narrows sharply on `/users/:id` | **Wrong.** It widened: akkar went from 0.18x to 0.10x of Gin. |
| 3 | FastAPI slowest on `/ping`, closest on `/users/:id` | **Wrong on both halves.** FastAPI beats akkar on both. |
| 4 | akkar sits between them on `/ping` | **Wrong.** akkar is last. |

Three of four wrong. The prediction was built on the belief that the database
dominates and equalises — the measurement says the database only equalises when
your driver can keep up with it.

## The number that was nearly published, and was wrong

The first `/ping` run had FastAPI at **2,433 req/s**, sixteen times slower than
its corrected figure and slower than akkar's *database* route. That was not
FastAPI; it was `pip install uvicorn` instead of `uvicorn[standard]`, so it ran
on asyncio and h11 rather than uvloop and httptools.

It would have made akkar look 11.8x faster than FastAPI. The corrected number
is that FastAPI is **1.4x faster** than akkar.

`METHOD.md` says differences between the three are removed rather than excused.
Nothing in the gate catches a competitor being accidentally handicapped —
equivalence checks that the work is the same, not that each is configured as
its own community would configure it. That check is a human one, and it nearly
did not happen.

---

## What this does not say

- **That akkar is unusable.** 2,744 req/s per three processes is more than most
  internal services ever see. It says where the ceiling is, not that the
  ceiling is low.
- **That Lua is slow.** akkar's own overhead is 34.7 µs against FastAPI's
  24.8 µs — the same order. The gap is the *driver*, not the language.
- **Anything about developer velocity, ecosystem or maintenance**, which decide
  framework choice far more often than throughput does.
- **Anything about tuned Postgres, other query shapes, or a realistic mixed
  workload.** One query, one box, one afternoon.
