# Performance study

## Why this is a study and not a patch

An earlier framework of the owner's proved, twice and with numbers, that
**a symbol's share of a profile is not the gain from removing it**:

- buffer pre-sizing held 10.7% of the encode profile and measured **−2.6%
  ceiling** when done. The note left behind reads *"do not revive builder
  pre-sizing unchanged"*.
- a request-local RTTI cache held 6.86% and regressed **p99 by 17.8%**.

So every fix here has to be certified end-to-end against a noise floor derived
from the machine, not argued from a profile. That is what `bench/certify/`
exists for.

## What is being measured, and where

| | |
|---|---|
| Machine | AWS c5.2xlarge, 4 physical cores × 2 threads, whole cores pinned |
| Noise floor | 0.7% with pinning, derived per run |
| Baseline | `/ping` 28,850 req/s (34.7 µs/req); `/users/:id` 2,744 req/s |
| Peers | Gin 163,014 / 26,212 · FastAPI+uvloop 40,245 / 9,316 |

## The shape of the problem

Payload sweep, three frameworks, byte-equivalent responses:

```
rows    gin r/s   fastapi r/s   akkar r/s   akkar/gin   bytes
1        22,563       8,729      10,808       0.48         60
10       21,373       8,250       7,942       0.37        504
100      13,194       5,798       3,853       0.29      5,187
1000      2,912       1,489         555       0.19     54,690
2500      1,254         663         228       0.18    141,690
```

At one row akkar **beats** FastAPI. From ten rows on it loses, and the ratio
against Gin degrades continuously.

> **Caveat added after an audit of the harness.** These ratios were produced
> while Gin was silently running one process on six vCPUs against akkar's three
> single-threaded ones, and while FastAPI serialised through the Python
> standard library rather than `orjson`. See the warning at the top of
> `bench/compare/RESULTS.md`. **akkar's own degradation shape across payload
> sizes stands** — it is measured against itself — but the peer ratios do not.

## Lines of investigation

Seven, run in parallel, because a single line of enquiry tends to find what it
went looking for.

| | Question |
|---|---|
| 1 | Where does the request path waste time, outside the database? |
| 2 | Why does one query cost 330 µs here against 32 µs through pgx? |
| 3 | What did the previous framework learn, especially about medium JSON? |
| 4 | What does published research say about optimising pure Lua 5.4? |
| 5 | How do we certify a fix end-to-end rather than trusting a profile? |
| 6 | Decomposed by stage, where does the payload degradation come from? |
| 7 | How much of the overhead is `lua-http` and `cqueues` rather than akkar? |
| 8 | What do the fast frameworks do that transfers to Lua? |
| 9 | Is the garbage collector part of the tail, and is generational better here? |

## Rules for this study

Taken from the previous framework's methodology, each earned by a mistake:

1. **Certify end-to-end.** Profile share predicts nothing. A/B the whole
   request against the noise floor.
2. **Read goodput and p50 together.** Two of their campaigns were discarded
   because a change moved the knee and the "ceiling" column started reporting
   the generator's rate rather than the server's capacity. A p50 in the
   hundreds of microseconds with ~100% of offered load served is service time;
   anything else may be queue depth wearing a latency label.
3. **Verify byte identity before comparing.** Their float rendering put 960
   extra bytes on the wire and invalidated an entire comparison row.
4. **Allocation is where a regression assertion can live.** It is exact and
   machine-independent; timing is not. Assert on bytes per request, record
   timing as a baseline.
5. **Look for the redundant pass first.** Their single largest cost was work
   the framework chose to do twice — revalidating what it had just serialised,
   re-tokenising what it had just parsed. That is a class of bug, not an
   instance.

## Findings

### 1. Every parameterised query was a sequential scan — **certified, 3.91x**

pgmoon types every Lua number as `numeric` (OID 1700). Comparing an `integer`
column against a `numeric` parameter is a cross-type comparison Postgres
cannot answer from an index, so it casts the column on every row:

```
$1 numeric   Seq Scan,   Rows Removed by Filter: 10001,   3.287 ms
$1 bigint    Index Scan, Index Cond: (id = '42'::bigint), 0.153 ms
```

Forty-three times on ten thousand rows, and it grows with the table. This was
not a Lua problem, a framework problem or a driver-speed problem. It was a
wrong type on a bound parameter, and it had been there since the day akkar
first spoke to a database.

**Certified end to end**, akkar against akkar, six processes each, identical
configuration on both sides, five repetitions in alternating order:

```
variant      req/s        p50         p99    spread
before     1848.98    49.40ms    209.71ms     11.7%
after      7225.48    10.99ms    270.40ms     12.1%

change : +290.8%  (3.91x)     floor: 12.1%     VERDICT: CERTIFIED
```

Fixed in `akkar/db.lua` by overriding pgmoon's number serializer per
connection — Lua integers become `int8`, floats stay `float8`. Six tests in
`spec/db_spec.lua` pin it, including one asserting the query plan contains no
`Seq Scan`.

### 2. A row-cleaning pass that could never do anything — removed

`akkar/db.lua` walked every field of every row swapping `pgmoon.null` for nil.
`pgmoon.null` does not exist; the module exports only `VERSION`, `Postgres` and
`new`. So the comparison `null ~= nil and val == null` was always false, and the
walk removed nothing on every row of every result.

Measured at 41.4 µs wasted on a hundred rows and 395.4 µs on a thousand — 4.5%
of the database path. Nothing is lost by removing it: pgmoon omits a SQL NULL
from the row table entirely unless `convert_null` is set, which akkar never
set.

### 3. It is not the JSON encoder

Same 1000-row payload, 57,665 bytes:

```
Go encoding/json      327 µs
lua-cjson           1,123 µs
Python json         1,919 µs
```

`lua-cjson` is 1.7x faster than Python's standard library. The "medium JSON"
shape akkar shows is **not** serialisation: decomposed by stage, pgmoon's fetch
and row decoding is **85–99%** of the path at every payload size, and
`cjson.encode` never exceeds 10.6%. Per row, pgmoon costs 10.2 µs against
cjson's 1.28 µs — the driver decode is eight times the encode for the same
data.

Half of pgmoon's cost is the socket layer: `receive_message` does two reads per
message and Postgres sends one DataRow message per row, so a thousand rows cost
**2,006 socket reads averaging 22 bytes each**. The other half is building one
Lua table per row.

### 4. A controller per request tied a hard OS limit to the collector

`with_deadline` created a fresh `cqueues` controller for every request. Three
separate investigations landed on that one object:

- it cost **25 µs of akkar's 34.7 µs** total per-request overhead;
- it contributed to the **2,814 bytes** of garbage a trivial request produced;
- and each controller holds **exactly 2.00 file descriptors**.

The last one is the finding no profile would have surfaced. Confirmed at three
different limits:

```
ulimit -n 256   ->  126 controllers   (2.03 each)
ulimit -n 1024  ->  510 controllers   (2.01 each)
ulimit -n 4096  -> 2046 controllers   (2.00 each)
```

Those descriptors came back **only when the collector ran**. The framework had
quietly coupled a hard operating-system limit to the pace of the garbage
collector, and nothing declared it.

Fixed by pooling controllers, and by stepping before polling — `wrap` only
queues the coroutine, so polling first made every synchronous request wait on
a descriptor for work already ready to run.

**Deterministic evidence**, which needs no quiet machine and has no noise floor
to hide in:

```
controllers created per 500 requests    before: 500      after: 1
file descriptors per request            before: 2.000    after: 0.000
```

The risk a pool introduces is handing the next request an abandoned handler's
controller. Only an empty controller goes back — the same discipline the
connection pool already uses for a transaction left open. Three tests pin it,
including one that abandons a handler by deadline and then asserts five
subsequent requests are clean.

**Timing not yet certified.** The A/B measured +33% but the machine's noise
floor was 71.2% at the time, against 0.7% when it is alone. Inside the noise
is not a result, and it is not being reported as one.

*(more as the remaining lines of enquiry land)*
