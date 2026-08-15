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

**Certified**, once the machine was quiet and the harness was made to prove
which tree it had loaded:

```
variant      req/s        p50        p99    spread
before    33884.17     2.91ms     4.57ms      1.1%
after     41071.65     2.38ms     3.58ms      2.5%

change : +21.2%  (1.21x)      floor: 2.5%      VERDICT: CERTIFIED
```

Goodput and latency moved together — p50 down 18%, p99 down 22% — so this is
service time rather than queue depth wearing a latency label.

### 5. Every body was walked twice looking for nulls that were not there — **certified, 1.47x**

The wire decoder stripped cjson's null sentinel, and then the request handler
stripped the same body again. Two full walks of every field of every row, on
every request, and the second could never find anything the first had not
already removed.

The remaining walk now runs only when it *can* find something. A JSON null can
exist in the decoded value only if the literal bytes `null` appear in the
document, so a substring scan in C decides it. The test is conservative in the
safe direction: `"nullable"` matches and the walk happens anyway, which is
exactly the old behaviour, and no document containing a null can be missed.

```
variant      req/s        p50        p99    spread
before    14480.24     6.45ms    10.74ms      0.9%
after     21249.37     4.24ms     6.92ms      2.0%

change : +46.7%  (1.47x)      floor: 2.0%      VERDICT: CERTIFIED
```

On a 4,530-byte body — the "medium JSON" shape this study exists for.

### 6. Allocation is not throughput — **measured, reverted**

Three per-request allocations were removed: the guard objects (a table, a
metatable and three closures, for an object that is immutable and carries no
identity), the two RNG calls behind the request id, and the watchdog's hook
closure. Allocation fell from **2,814 to 2,166 bytes per request, −23%**,
measured exactly with the collector stopped.

Throughput: **+2.1% against a 3.4% noise floor. Not a result.**

The watchdog pool — the only part that added machinery — was taken back out
and the reasoning recorded in the source, because it was the same reasoning
that made the deadline controllers worth pooling, and someone will have it
again. The guards and the request id stayed, on the grounds that they are
simpler code rather than faster code: sharing a guard needs `__newindex`,
which turns `req.user.id = 1` on an unauthenticated request from a silently
lost write into an error, and a counter cannot collide within a process where
two 48-bit draws can.

This is the third time this project has been taught that a profile share is
not a gain, and the first time it has been taught that an allocation cut is
not one either.

### 7. Two claims from earlier in this study were wrong

**"2,006 socket reads averaging 22 bytes."** True as written, but it was read
as syscalls, and pgmoon opening the connection with `setmode("bn", "bn")` —
unbuffered — made that reading look obvious. Counted with `strace`, a
thousand-row query costs about **a hundred read syscalls in the whole
process**, not two thousand: cqueues buffers internally whatever the mode
says. Asking cqueues for full buffering measured *slower*.

So the socket cost is not I/O. It is 2,006 Lua-level calls and the strings
they allocate. Decomposed against a live Postgres:

```
total 1000-row query        10,360 us
  receive_message            4,650 us  (44.9%)   1,003 calls
    of which socket reads    3,085 us  (29.8%)   2,006 calls
  row decoding and tables    5,710 us  (55.1%)
```

**"The framework is not the limit; Postgres is."** Already retracted in
`bench/compare/RESULTS.md`. What replaces it: the limit is pgmoon decoding
rows in the interpreter, and 55% of a thousand-row query is that decoding —
not reachable without a driver written in C. The socket half is reachable,
and that is what finding 8 measures.

### 8. Serving pgmoon's socket reads from one buffer — **certified, 1.05x**

The recoverable part of the 30%. pgmoon asks the socket for five bytes and
then a body, once per protocol message, and Postgres sends one message per
row: 2,006 Lua-level calls for a thousand rows. Serving them out of one large
read, on a 200-row query:

```
variant      req/s        p50         p99    spread
before     2433.52    38.20ms    106.16ms      1.4%
after      2543.76    36.61ms     84.91ms      1.6%

change : +4.5%  (1.05x)      floor: 1.6%      VERDICT: CERTIFIED
```

The throughput is the smaller half of it. **p99 fell 20%**, 106 ms to 85 ms,
which is what removing two thousand small allocations from a request tends to
look like.

It is the only place akkar reaches into a dependency's internals, so it lives
in the file whose whole job is isolating pgmoon, it has an off switch that
needs no fork, and what it produces is proven identical rather than assumed:
row counts of 1, 100 and 2,000 straddling the 64 KB read, plus a single
200 KB field that forces the refill loop.

## Where this leaves the numbers

Each fix is certified against its own before and after. **There is no single
"akkar is N times faster" figure, and multiplying these together would be
wrong**, because they act on different paths: `/ping` never decodes a body or
touches the database, and the parameter-typing fix does nothing for a route
that has no parameters.

Per path, against the state at the top of this document:

| path | what moved it | certified |
|---|---|---|
| any parameterised query | parameter typing | **3.91x** |
| the database path, again | buffered socket reads | **1.05x**, p99 −20% |
| a body of any size | the double null walk | **1.47x** |
| every request | the deadline controller pool | **1.21x** |

**Not measured: the old baseline against current HEAD, end to end.** That is
one A/B and nobody has run it.

**Not measured either: anything against another framework.** The comparison in
`bench/compare/RESULTS.md` is retracted — four asymmetries ran simultaneously
under every number on that page — and the re-run it promises has not happened.
So the honest statement today is that akkar is measurably faster **than
itself**, and where it stands against Gin or FastAPI is currently unknown.

### 9. Concurrency has a hard ceiling, and it is descriptors — **measured**

Deterministic, so it needs no quiet machine and has no noise floor to hide in:

```
concurrent in flight      open fds      per request
1                                8             8.00
16                              38             2.38
64                             134             2.09
128                            262             2.05
256                            518             2.02
512                           1030             2.01
```

Every in-flight request holds a controller for its deadline, and a controller
costs **exactly two descriptors**. Against the common default of `ulimit -n
1024`, that is a wall at about **500 concurrent requests per process** — and
reaching it is not a clean error. `accept` starts failing, every socket
operation starts failing, and the process flails. The benchmark machine was
lost this way during a 512-connection sweep, which is how this was found.

Pooling the controllers does not help. The pool serves *sequential* reuse;
five hundred requests in flight at once need five hundred controllers whatever
its size.

**Shipped:** the ceiling is read from `/proc/self/limits` at boot and declared
to lua-http, which stops accepting beyond it and lets the kernel queue. Forty
requests against a ceiling of eight: all forty answered, none failed.

**Not shipped, and the reason matters.** The real fix is to stop spending a
controller per request. A `condition` does the same arbitration for **0.00
descriptors** — measured alongside the above. It is not a drop-in: today an
abandoned handler sits in an orphaned controller nothing ever steps, so it is
inert. Move it to the outer controller and it keeps running, wakes after the
503, and touches a connection that has already gone back to the pool. That
trades a descriptor leak for a data bug, and the data bug is worse.

### 10. The harness was taking the machines off the network — **methodology**

A benchmark box went unreachable mid-run and never came back. The first
diagnosis pointed at finding 9: 512 concurrent requests, 1,030 descriptors,
`ulimit -n 1024`. It was wrong, and what disproved it is that **the previous
project lost machines the same way** — a compiled Odin server with no
controllers, no cqueues and no descriptor per request. A cause that cannot
explain both is not the cause.

What the two harnesses share:

```
Odin  : taskset -c "${URUQUIM_SOAK_SERVER_CPUS:-0-7}"
akkar : GENERATOR="0,4"   SERVERS="1,5,2,6,3,7"
```

**Both gave every vCPU to the benchmark.** Inbound packet processing runs in
softirq context on some CPU, and with all of them saturated by pinned work
`ksoftirqd` never gets scheduled, so SYN packets for new connections are
dropped. SSH then **times out rather than being refused**, which is precisely
the symptom, and the serial console keeps working because `ttyS0` is a
hypervisor path that never touches the network stack.

Every observation fits: no kernel panic, no OOM, no reboot, a console sitting
at a healthy login prompt, and a machine that answers nothing on the wire.

An earlier inference here was also unsound and is withdrawn: *"silence on ICMP
suggests the instance is gone."* AWS security groups drop ICMP by default, so
that box had almost certainly never answered a ping. Absence of a reply was
read as evidence when it was the normal behaviour all along.

**Fixed** in `bench/study/lib.sh`: one physical core is reserved for the
system, the reservation is asserted rather than assumed, and a host with
fewer than three physical cores is refused outright. It costs a third of the
server capacity on an eight-vCPU host, and it buys runs that survive — plus
measurements not contaminated by a starving kernel, which were never fair
measurements of anything.

*(more as the remaining lines of enquiry land)*
