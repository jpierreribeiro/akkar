# Why one process per core, and not threads

akkar's answer to "the machine has eight cores" is to run several copies of the
process and let the kernel share the port between them.

```lua no-run
app:run { port = 8080, reuseport = true }
```

There is no thread pool, no worker option, and no number to tune that makes one
process use two cores. This page says why that is the only honest answer for
Lua, what it measures, and what it costs.

## The constraint you cannot design around

**One Lua VM is one core.** A Lua state is not thread safe, Lua 5.4 has no
threads of its own (`coroutine` is cooperative, not parallel), and
`akkar/vm.lua` records that Lua 5.4 cannot even create a second isolated state
from Lua: that needs C or a subprocess.

So the choice is not "processes or threads". It is:

1. several OS processes, each with one VM, or
2. one process with several OS threads sharing one VM behind a lock.

Option 2 is not hypothetical, and akkar has looked closely at a project that
took it. `docs/BACKLOG.md` section 8 records three claims about Astra
(Rust + Tokio + Axum + SQLx, hosting Lua through mlua) verified against the
source at commit `885586c`, v0.51.2. The relevant one:

> **One global Lua VM serialises CPU work.** mlua's `ReentrantMutex` is taken
> at the start of `poll` and held across `resume_inner`, so a handler that
> never yields holds it for the whole request and other Tokio workers block on
> it. `thread_pool_size` is a coroutine object pool, not parallelism.

The backlog is careful about what that licenses: all three findings are
implementation defects fixable in a patch, not consequences of choosing Rust,
and "positioning against them as permanent failings ages badly". The point here
is narrower and it survives a patch: a knob named `thread_pool_size` that is
not parallelism is the failure mode akkar is trying to avoid by not having the
knob at all. The backlog's own follow-up item is to audit every concurrency
knob akkar exposes for the same trap.

Choosing processes means the parallelism is the operating system's, which is
the only place it has ever been true for a Lua application.

## `SO_REUSEPORT` is what makes it work without a proxy

Without it, the second process dies with `EADDRINUSE` and you need nginx or
HAProxy in front to fan out. With it, several processes bind the same port and
the kernel load balances accepted connections between them.
`akkar/init.lua` states the reasoning next to the flag:

> SO_REUSEPORT is how several processes share one port, which is how akkar uses
> a machine: one Lua VM is one core, so capacity is processes. The kernel
> load-balances accepted connections between them, and no proxy is needed in
> front.

### It was missing, and a benchmark found it by lying

This is the part worth keeping. The first scaling run on a c5.2xlarge reported
a flat line: **2,433 req/s at one process, 2,424 at eight**. Flat, inside the
0.7% noise floor, entirely believable. The obvious reading was "Postgres is
saturated".

Seven of the eight processes had died instantly with `EADDRINUSE`, because
akkar never passed `reuseport` through to lua-http. The survivor answered every
request correctly, so the run passed its own *verify every response* gate and
produced a plausible number labelled **8 processes**.

`bench/RESULTS.md` draws the lesson twice over:

> a configuration that is not the configuration reports a number too, and so
> does an affinity mask that only looks like isolation.

The harness now refuses to run when fewer processes are alive than were asked
for. The same defect later turned up on the other side of a comparison: in
`bench/compare/RESULTS.md`, Gin was started as three processes on one port, Go's
`net.Listen` does not set `SO_REUSEPORT`, two panicked instantly, and the
survivor used **6 vCPUs through goroutines while akkar and FastAPI used 3**.
That is one of the four asymmetries that got the whole page retracted.

## Does capacity actually follow cores? Yes, on the CPU path

`bench/RESULTS.md`, `/ping`, no database, on a c5.2xlarge with servers pinned
to whole physical cores and the load generator on a core of its own:

```
processes        req/s        p50        p99   req/s/process   scaling
1              9003.81    10.97ms    14.12ms            9004     1.00x
2             18058.53     5.36ms     8.66ms            9029     1.00x
3             26901.55     3.71ms     5.48ms            8967     1.00x
6             31801.55     3.12ms     4.96ms            5300     0.59x
```

Per-process throughput varies by 0.7%, which is exactly the measured noise
floor for that machine (ten repetitions of one identical configuration:
min 2679, p50 2688, max 2698 req/s, spread 0.7%). **Any difference below 0.7%
is not a result**, and 1.00x three times is the strongest form of "linear" this
harness can report.

The drop at six processes is hyperthreading, not the framework. Six processes
on the same three physical cores give 31,802 against 26,902, which is 1.18x for
twice the processes: the usual return from a second thread on a busy core.

The later positioning study reproduces it independently
(`bench/study/RESULTS.md` section 3):

```
framework procs         req/s        p50        p99   per-proc
akkar    1          10024.38     9.72ms    12.80ms      10024
akkar    2          20534.50     4.84ms     5.81ms      10267
```

Slightly superlinear there, as the second process picks up hyperthread siblings
that were idle.

This is also the framing to use when comparing against Gin. One Gin process
spreads goroutines across every core; one Lua VM is one core. Per process,
`bench/study/RESULTS.md` puts it at **10,267 against about 58,600, which is
5.7x**, and calls that "the number that means something".

## Where it stops being linear, stated plainly

The database route does not scale the way `/ping` does, and pretending
otherwise would be the easy lie of this page. Same machine, same run
(`bench/RESULTS.md` section 2), `/users/:id`:

```
processes        req/s        p50        p99   req/s/process   scaling
1              2393.14    40.62ms   190.88ms            2393     1.00x
2              2691.92    36.92ms   119.12ms            1346     0.56x
3              2705.63    36.03ms    99.96ms             902     0.38x
6              2651.42    34.98ms   107.72ms             442     0.18x
```

Throughput gains 12% from one process to two, which is above the noise floor
and therefore real, and then flattens at about 2,700 req/s. p99 nearly halves.

That section originally read the gap as "Postgres is the limit", and
`bench/RESULTS.md` now carries the correction inline rather than editing it
away: Gin later reached 26,212 req/s and FastAPI 9,316 against **that same
Postgres, on that same box, with the same pool and the same query**. Postgres
was never the limit at 2,700. The limit was pgmoon parsing the wire protocol in
the interpreter. The reasoning is left in place because it is instructive:
measuring one system alone cannot tell you which of its parts is saturated.

So: processes buy CPU. They do not buy a faster driver, and they do not buy a
bigger database.

## The other thing processes buy: blast radius

`bench/RESULTS.md` section 3 measures `/ping` while a neighbouring route burns
about 200 ms of CPU per call:

| arrangement | processes | /ping req/s | p50 | p99 |
|---|---:|---:|---:|---:|
| nothing blocking | 1 | 9,444 | 5.24 ms | 7.69 ms |
| blocking | 1 | 8,891 | 5.26 ms | **74.67 ms** |
| blocking | 8 | 34,964 | 1.26 ms | **38.07 ms** |
| `work.yielding` | 1 | 8,625 | 5.74 ms | **8.15 ms** |
| `work.yielding` | 8 | 34,429 | 1.23 ms | **4.28 ms** |

One blocking handler multiplies neighbour p99 by ten while barely moving p50 or
throughput. Eight processes cut that tail roughly in half, because the damage
is divided among them.

But note row four. **One process that yields beats eight that do not**, 8.15 ms
against 38.07 ms. Processes divide the damage; yielding removes it. Adding
processes is not a substitute for not blocking the loop, and the limit that
survives all of it is that `work.yielding` needs a Lua loop: a C function that
runs for 250 ms gives Lua no point at which to regain control.

## What it costs

### Nothing is shared, and that is not always convenient

Two processes have two of everything in memory.

- `akkar.cache.memory` is per process. With six processes,
  `akkar.limit.rate { per_second = 10 }` enforces sixty per second across the
  fleet. The README says so without softening: "That is a development default,
  not rate limiting."
- Idempotency keys held in the memory cache are per process, "which is not
  deduplication at all".
- Sessions in the memory cache only work on the process that created them.
- Metrics are per process, so something has to aggregate them.

The general shape: **anything that must be true for the deployment rather than
for the process has to live in Redis or Postgres.** That is a real cost of the
model, and it is the cost that a threaded server with a shared heap would not
pay.

### Memory multiplies

Each process carries its own VM, its own compiled Lua and its own pool. The
eight hour soak in `bench/study/RESULTS.md` section 9 measures two processes at
**28 MB resident, unchanged at every one of 96 samples over 480 minutes**, and
`docs/DEPLOY.md` measures a single idle built binary at 6.7 MiB. Small numbers,
but they are per process, and the pool multiplies with them: two processes with
`pool_size = 10` is a capacity of 20 Postgres connections, which is what
Postgres sees.

### Descriptors are the real ceiling, and akkar has to compute it

Every in-flight request holds a `cqueues` controller for its deadline, and a
controller costs exactly two file descriptors. Measured in `akkar/init.lua`:

```
concurrent      fds     per request
64              134            2.09
256             518            2.02
512            1030            2.01
```

Against the common default of `ulimit -n 1024` that is a wall at about 500
concurrent requests **per process**, and hitting it is not a clean failure:
`accept` starts failing, every socket operation starts failing, and the process
flails. A machine was lost that way during a 512-connection sweep. akkar reads
the limit at boot and tells lua-http to stop accepting before it, turning
collapse into backpressure.

### More processes does not mean more capacity to accept

The saturation sweep in `bench/study/RESULTS.md` section 8 holds two processes
with `pool_size = 10` each, a capacity of 20 connections, and sweeps offered
concurrency from half capacity to four times it:

```
mult   conns         req/s       p50       p99   errors
1x     20          7315.41    2.71ms    3.74ms        0
2x     40          7768.32    5.18ms    6.22ms        0
3x     60          7181.37    6.65ms   37.70ms        0
4x     80          6941.36    9.28ms   82.38ms        0
```

The rule it produced: **offered concurrency up to twice the pool is free; past
that it is paid for in the tail and it buys nothing.** Size the pool at about
half the peak concurrency you intend to accept, and use
`akkar.limit.concurrent` to refuse the rest rather than queue it.

That table carries its own retraction and it is worth reading before quoting
it. The script said "three repetitions, nearest-rank median" and actually kept
the run with the **highest** throughput, so every figure is a best of three.
The retraction works through what that does: the knee between 2x and 3x
survives, because taking a maximum cannot manufacture a five-fold break; the
2x peak does not survive, because +6% is the same order as the difference
between a maximum and a median; and the tail figures past the knee are
optimistic, so the real p99 at 3x and 4x is worse than 37.70 ms and 82.38 ms.
The table has not been re-measured, because the machine it needs is not up.

### You need a supervisor

Nothing in akkar starts the other processes. That is systemd, Docker, or a
shell loop, and `docs/DEPLOY.md` shows the systemd form. The framework's
contribution is that the port does not need a proxy in front of it.

## What to read next

- `bench/RESULTS.md`, including the two runs that were wrong.
- `bench/study/RESULTS.md` sections 3, 8 and 9.
- `docs/DEPLOY.md`, for running more than one of them on a real host.
