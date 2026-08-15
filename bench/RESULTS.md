# Results

A number without the machine it came from is not a result.

---

## 2026-08-15 — AWS c5.2xlarge

```
machine    : AWS c5.2xlarge, Intel Xeon Platinum 8275CL @ 3.00GHz
topology   : 8 vCPU = 4 PHYSICAL cores x 2 threads
memory     : 15 GB
os         : Ubuntu 26.04 LTS, kernel 7.0.0-1006-aws
lua        : 5.4.8
postgres   : 16-alpine in Docker, same box, stock settings
redis      : 7-alpine in Docker, same box
generator  : wrk 4.1.0, same box, pinned to one whole physical core
affinity   : servers on 3 physical cores (vcpu 1,5,2,6,3,7)
             generator on 1 physical core (vcpu 0,4)
ulimit -n  : 65535
```

One box, so the generator is co-located. It is pinned to a **whole physical
core** and the servers to the other three, which is what makes the numbers
below the server's rather than the generator's. Verified during a run: server
cores at 100% while generator cores sat at 66% and 23%.

The full suite — 139 tests — passes on this machine.

### Noise floor

Ten repetitions of one identical configuration:

```
n=10  min 2679  p50 2688  p95 2698  max 2698 req/s
spread = 70 basis points = 0.7%
```

**Any difference below 0.7% is not a result.** Pinning brought this down from
2.6% unpinned, and raised baseline throughput from 2,407 to 2,688 req/s — the
contention was costing both stability and speed.

For contrast, the project this methodology came from measured ±57.6% on its
hardware, which invalidated a comparison it was about to base a decision on.

---

### 1. Scaling with no database — `/ping`

```
processes        req/s        p50        p99   req/s/process   scaling
1              9003.81    10.97ms    14.12ms            9004     1.00x
2             18058.53     5.36ms     8.66ms            9029     1.00x
3             26901.55     3.71ms     5.48ms            8967     1.00x
6             31801.55     3.12ms     4.96ms            5300     0.59x
```

**Perfectly linear across physical cores: 1.00x, 1.00x, 1.00x.** Three
processes on three physical cores deliver three times one process, with
per-process throughput varying by 0.7% — exactly the noise floor.

The drop at six is **hyperthreading, not the framework**. Six processes on the
same three physical cores yield 31,802 against 26,902, which is **1.18x for
twice the processes** — the usual return from a second thread on a busy core.

**This is the answer to CPU-bound work.** One Lua VM is one core; capacity is
processes; processes scale linearly with real cores and give roughly another
fifth from hyperthreads.

### 2. The realistic path — `/users/:id`, one indexed query

```
processes        req/s        p50        p99   req/s/process   scaling
1              2393.14    40.62ms   190.88ms            2393     1.00x
2              2691.92    36.92ms   119.12ms            1346     0.56x
3              2705.63    36.03ms    99.96ms             902     0.38x
6              2651.42    34.98ms   107.72ms             442     0.18x
```

Throughput gains 12% from one process to two — above the 0.7% floor, so real —
then flattens at about 2,700 req/s. p99 nearly halves, 191 ms to 100 ms.

> **This section drew the wrong conclusion, and `bench/compare/RESULTS.md`
> corrects it.** It read the gap between `/ping` at 31.8k and `/users/:id` at
> 2.7k as "Postgres is the limit". Gin later reached 26,212 req/s and FastAPI
> 9,316 against that same Postgres, on this same box, with the same pool and
> the same query — so Postgres was never the limit at 2.7k. The limit is
> **pgmoon**, which parses the wire protocol in pure Lua. Left here rather than
> rewritten, because the reasoning is instructive: measuring one system alone
> cannot tell you which of its parts is saturated.

`/ping` reaches 31,802 req/s where `/users/:id` reaches 2,705. Within akkar the
database path is twelve times more expensive than the framework path — but that
cost is the driver's, not the database's.

### 3. What one blocking handler costs the neighbours

`/ping` under load while `/expensive` burns ~200 ms of CPU per call:

| arrangement | processes | /ping req/s | p50 | **p99** |
|---|---:|---:|---:|---:|
| nothing blocking | 1 | 9,444 | 5.24 ms | **7.69 ms** |
| blocking | 1 | 8,891 | 5.26 ms | **74.67 ms** |
| blocking | 8 | 34,964 | 1.26 ms | **38.07 ms** |
| `work.yielding` | 1 | 8,625 | 5.74 ms | **8.15 ms** |
| `work.yielding` | 8 | 34,429 | 1.23 ms | **4.28 ms** |

1. **One blocking handler multiplies neighbour p99 by ten** — 7.69 to 74.67 ms
   — while barely moving p50 or throughput. A tail problem, which is why this
   project reports p99 and never a mean.

2. **`work.yielding` all but erases it**: back to 8.15 ms against a 7.69 ms
   baseline. For a Lua loop, a ninefold improvement in what everyone else feels.

3. **Yielding beats adding processes here.** One process yielding (8.15 ms) is
   better than eight not yielding (38.07 ms). Processes divide the damage;
   yielding removes it.

**The limit that survives all of it:** `work.yielding` needs a Lua loop. A C
function that runs 250 ms without returning — `bcrypt` at cost 12 — gives Lua
no point at which to regain control, so only the middle row applies to it.

---

## Two runs of this benchmark were wrong

Recorded because the failures are more instructive than the numbers.

### The configuration was not the configuration

The first scaling run reported a flat line: 2,433 req/s at one process, 2,424
at eight. Flat, inside the noise floor, entirely believable — the obvious
reading was "Postgres is saturated".

Seven of the eight processes had died instantly with `EADDRINUSE`, because
akkar never passed `reuseport` through to lua-http. The survivor answered every
request correctly, so the run passed its own *verify every response* gate and
produced a plausible number labelled **8 processes**.

That found a hole in the framework, not just the harness: without
`SO_REUSEPORT` multi-process deployment is impossible, and multi-process is
akkar's answer to CPU-bound work. The harness now verifies the configuration
too, and refuses to run when fewer processes are alive than were asked for.

### The pinning shared physical cores

The second run pinned the generator to vCPU 0–1 and the servers to 2–7, and
read per-process throughput falling to 0.67x — which looked like the framework
scaling poorly.

On this machine vCPU 4 and 5 are the sibling threads of vCPU 0 and 1. The
servers had been handed the siblings of the generator's cores, so the
contention survived the pinning and wore the framework's name.

With whole physical cores assigned, the same measurement reads **1.00x, 1.00x,
1.00x**. `bench/run.sh` now reads the sibling map from `/sys` and hands out
whole physical cores.

The borrowed methodology said a rejected load generator still reports a number.
These two runs added the rest of that thought: **a configuration that is not
the configuration reports a number too, and so does an affinity mask that only
looks like isolation.**

---

## What this box cannot answer

- **Scaling past three processes as measured.** Not a framework limit — the
  box has four physical cores and one is holding the generator. A second
  machine would free it, but the linear result to three is already the answer.
- **Postgres tuned.** Stock settings, in Docker, competing with the thing
  benchmarking it.
- **Sustained load.** Everything here is twelve to fifteen seconds. Connection
  churn, memory growth and GC behaviour over hours are unmeasured.
