# Results

A number without the machine it came from is not a result.

---

## 2026-08-15 — AWS c5.2xlarge

```
machine   : AWS c5.2xlarge, Intel Xeon Platinum 8275CL @ 3.00GHz
cores     : 8 vCPU
memory    : 15 GB
os        : Ubuntu 26.04 LTS, kernel 7.0.0-1006-aws
lua       : 5.4.8
postgres  : 16-alpine in Docker, on the same box
redis     : 7-alpine in Docker, on the same box
generator : wrk 4.1.0, ALSO on the same box
ulimit -n : 65535
```

**Everything is co-located.** The load generator, both databases and the server
share eight cores. That is stated up front because it is the limit in two of the
three measurements below, and reading them without it produces the wrong
conclusion.

The full suite — 139 tests — passes on this machine.

### Noise floor

Ten repetitions of one identical configuration:

```
n=10  min 2388  p50 2407  p95 2450  max 2450 req/s
spread (p95-min)/p50 = 261 basis points = 2.6%
```

**Any difference below 2.6% on this machine is not a result.** Every comparison
below is checked against that line.

For contrast, the project this methodology came from measured **±57.6%** on its
hardware, which invalidated a comparison it had been about to base a design
decision on. A dedicated instance earns its cost here alone.

---

### 1. Multicore scaling, no database — `/ping`

```
processes        req/s        p50        p99   req/s/process   scaling
1              8934.16    11.04ms    14.34ms            8934     1.00x
2             18036.18     5.45ms     7.98ms            9018     1.01x
4             31862.03     3.12ms     4.97ms            7966     0.89x
8             35971.55     2.67ms     6.30ms            4496     0.50x
```

**One to two processes is 2.02x. One to four is 3.57x.** Per-process throughput
holds at 1.01x and 0.89x — linear within, and just outside, the noise floor.

The fall to 0.50x at eight is **the load generator, not the server**: `wrk` runs
four threads on the same eight cores it is measuring. Scaling is demonstrated to
four; past that this box cannot answer, and the honest fix is a second machine.

**This is the answer to CPU-bound work.** One Lua VM is one core; capacity is
processes, and processes scale.

### 2. The realistic path — `/users/:id`, one indexed query

```
processes        req/s        p50        p99   req/s/process   scaling
1              2401.00    40.44ms   208.13ms            2401     1.00x
2              2698.36    36.76ms   119.25ms            1349     0.56x
4              2682.58    35.97ms    92.17ms             671     0.28x
8              2642.46    35.05ms   116.03ms             330     0.14x
```

Throughput gains 12% from one to two processes — above the noise floor, so real
— then flattens at about 2,700 req/s. p99 improves markedly, 208 ms to 92 ms.

**The framework is not the limit; Postgres is.** `/ping` reaches 35,972 req/s
where `/users/:id` reaches 2,642: the framework is thirteen times faster than
the path that touches the database, on a box where Postgres is competing for the
same eight cores.

That confirms over HTTP and under load what every measurement in this project
has said — in a real request the database dominates and the framework is noise.
Optimising the router would be optimising the 7%.

### 3. What one blocking handler costs the neighbours

`/ping` under load while `/expensive` burns ~200 ms of CPU per call:

| arrangement | processes | /ping req/s | p50 | **p99** |
|---|---:|---:|---:|---:|
| nothing blocking | 1 | 9,444 | 5.24 ms | **7.69 ms** |
| blocking | 1 | 8,891 | 5.26 ms | **74.67 ms** |
| blocking | 8 | 34,964 | 1.26 ms | **38.07 ms** |
| `work.yielding` | 1 | 8,625 | 5.74 ms | **8.15 ms** |
| `work.yielding` | 8 | 34,429 | 1.23 ms | **4.28 ms** |

Three findings, in order of how much they change what to do:

1. **One blocking handler multiplies neighbour p99 by ten** — 7.69 ms to
   74.67 ms — while barely moving p50 or throughput. It is a tail problem,
   which is exactly why this project reports p99 and never a mean.

2. **`work.yielding` all but erases it**: 74.67 ms back to 8.15 ms against a
   7.69 ms baseline. For a loop written in Lua, a nine-fold improvement in what
   everyone else feels.

3. **Yielding beats adding processes for this case.** One process with yielding
   (8.15 ms) is better than eight without it (38.07 ms). Processes divide the
   damage; yielding removes it. Both together give 4.28 ms, below the
   single-process baseline.

**The limit that survives all of it:** `work.yielding` needs a Lua loop. A C
function that runs 250 ms without returning — `bcrypt` at cost 12 — offers no
point at which Lua regains control, so only the middle row applies. Eight
processes make one blocked worker an eighth of capacity, and that is the whole
of the answer there.

---

## The first run of this benchmark was wrong

Recorded because the failure is more instructive than the numbers.

The first scaling run reported a perfectly flat line: 2,433 req/s at one process
and 2,424 at eight. Flat, well inside the noise floor, and entirely believable —
the obvious reading was "Postgres is saturated".

Seven of the eight processes had died instantly with `EADDRINUSE`, because akkar
never passed `reuseport` through to lua-http. The single survivor answered every
request correctly, so the run passed its own *verify every response* gate and
produced a plausible number labelled **8 processes**.

Two things came out of it:

- akkar now supports `SO_REUSEPORT`. Without it multi-process deployment is not
  possible at all — and multi-process is this framework's answer to CPU-bound
  work, so the hole was in the thing being measured, not only in the
  measurement.
- The harness verifies the **configuration**, not just the responses, and
  refuses to run when fewer processes are alive than were asked for.

The borrowed methodology already warned that a load generator being rejected
still reports a number. The generalisation it did not make, and this run
supplied: **a configuration that is not the configuration reports a number too,
and that one is harder to see.**

---

## What this box cannot answer

- **Scaling past four processes.** `wrk` shares the cores. Needs a second
  machine before eight-process figures mean anything.
- **Postgres tuned.** Stock settings, in Docker, competing with the thing
  benchmarking it. 2,700 req/s says nothing about what it can do otherwise.
- **Sustained load.** Everything here is fifteen seconds. Connection churn,
  memory growth and GC behaviour over hours are unmeasured.
