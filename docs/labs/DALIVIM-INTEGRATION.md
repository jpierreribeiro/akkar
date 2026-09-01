# akkar as the dalivim Labs runtime

This is the akkar side of `dalivim-backend#171` (the Labs plan). That PR is the
authority on the product; this file is the authority on **what the akkar runtime
already provides, what it does not, and what each gap costs** — so whoever
picks up Phase 4 or Phase 5 does not re-derive it from the code.

Read `dalivim-backend#171` first. This assumes it.

## Where the two products meet

The Labs cycle is `UNDERSTAND → DRAW → SIMULATE → BREAK → FIX → EXPLAIN`. akkar
enters at **FIX**: the "Implement" button turns the diagram into a running akkar
project, the student writes the real handler, and correction is `app:test()`
inside the runner's jail. Everything before FIX is the frontend's deterministic
simulator; akkar never runs the simulation and never produces a grade.

The mapping the plan lists (§7, Phase 4) is 1:1 with what akkar already exposes,
and that is the whole reason this is template expansion and not code generation:

| diagram node | akkar, and does it exist today |
|---|---|
| API | `akkar.new()` + routes — **yes** |
| PostgreSQL | `app:run { db }`, `req.db:one/transaction` — **yes** |
| Redis | `app:run { cache }`, `req.cache` — **yes** |
| Queue | `jobs.new(store, name, { retries, backoff })` + `queue:push` — **yes** |
| Worker | the handler registered on the queue — **yes** |
| Load balancer | N processes with `SO_REUSEPORT` (`reuseport = true`) — **yes** |
| concurrency limit | `akkar.limit.concurrent` / `akkar.limit.rate` — **yes** |

Every node maps to something that exists. The generated project is the WIRING;
the handler stays the student's work. And `app:test { db = ..., cache = ... }`
with in-memory adapters needs no Postgres or Redis installed, so the project
clones, runs, and passes — the same project the runner's jail executes.

## The six suggestions, scored against the actual code

`dalivim-backend#171` §7 (Phase 4) lists six asks. Here is the real state of
each in the akkar tree, so none is estimated twice.

| # | ask | state | work |
|---|---|---|---|
| 4 | deterministic clock in test | **DONE** | `akkar.time.manual` + `akkar.time.set`; the L1 sim already depends on it |
| 6 | `akkar build` single binary on the runner path | **DONE** | builds and serves; 6.4 MB scratch image (`docs/RUNTIME.md`, `docs/DEPLOY.md`) |
| 5 | in-process metrics readable from `app:test()` | **PARTIAL** | `akkar.metrics` collects via `Registry:observe`; not surfaced to the test client. Small: expose a snapshot on the test handle |
| 1 | fail/hang/drop parity on the cache adapter | **DONE** 2026-09-01 | `akkar/cache/memory.lua` has `:on()/:fail()/:hang()/:drop()`, anchored in what `akkar/redis.lua` actually produces rather than copied: an error reply leaves a HEALTHY connection, a timeout leaves `broken`, a failed write leaves `broken` and `in_flight`. `spec/cache_fault_parity_spec.lua`, 20 cases |
| 2 | capacity params on memory adapters (`max_qps`, `latency_ms`) | **DONE** 2026-09-01 | both adapters take them, honoured by advancing `akkar.time` rather than sleeping, so a manual clock collapses the wait and the real clock charges it. They are ONE queue, not two delays added. `spec/capacity_spec.lua`, 19 cases over both adapters from one options table |
| 3 | a load generator inside `app:test()` | **TODO** | none. `bench/study/low-load-latency.lua` (written 2026-08-20) is the seed: it drives `app:test` in a tight loop and reports percentiles. Generalise it to `app:test():load { rps, duration, routes }` |

Four done, one partial, one to build. **None blocks Phase 1, 2, or 3.** Items
1 and 2 are what Phase 4 needs first; item 3 is what makes "IMPLEMENT → MEASURE"
run inside the jail instead of needing an external load tool.

### Why item 2 is the keystone

The diagram said "capacity 1,500/s, service 8 ms" and the test adapter did not
know it. `memory.new { max_qps = 1500, latency_ms = 8 }` exists now, on both
adapters, so **the same numbers configure the simulation AND the real run** —
the loop closes on itself. Item 3 is what turns that into the best lesson in the
product: the simulator predicts p95 33 ms, the real run gives 41 ms, and the
student sees *where the model is wrong*. A simulator that admits it is
approximate teaches more than one that presents itself as truth (the plan's D1).

That is why item 3 is now the only one left. Items 1 and 2 both landed on
2026-09-01, and the shape they copied was already in the tree:
`akkar/db/memory.lua`'s `:on()`, `:fail()`, `:hang()`, `:drop()` are per-adapter
behaviour toggles. `max_qps` and `latency_ms` are the same kind of thing —
construction-time knobs on the
memory adapter, honoured by advancing the injectable clock (`akkar.time`, which
already exists) rather than by real sleeping, so a test stays deterministic and
fast.

## The cost question, answered with numbers

The plan says "o melhor é o menor custo". akkar is close to the floor for this
workload, and here is why, measured:

| | |
|---|---:|
| boot, full app (db + redis + jobs + auth + metrics) | **29 ms** |
| idle resident memory, one process | 12.8 MB (the spike measured this in the jail) |
| container image (`scratch`, single binary) | **6.4 MB** |
| correction in the jail | 40–100 ms, 12.8 MB peak against a 256 MB cap, zero network |
| service time per request at low load | 14.5 µs (`GET /ping`), 21 µs (validated POST) |

For a per-tenant, per-exercise model billed by GB-second, the two numbers that
matter are **11.4 to 14.1 MB resident** and **29 ms boot**: a hundred idle
exercises fit in ~1.1 to 1.4 GB, five hundred in ~5.7 to 7.1 GB. (The 12.8 MB
this page used to give was the spike's PEAK under grading, which the row two
above still reports correctly as a peak. Idle RSS is the D2 measurement, and it
is a range.) That is the density the teaching platform was
always designed around, and it is why a process-per-student model is affordable
where a container-per-student one is not. The runner already imposes CPU,
memory, output and deadline caps per tenant, so the cost ceiling is enforced
where it should be.

**The cheapest server is the one that runs the most exercises per gigabyte**, and
6.4 MB of image plus 12.8 MB resident is as low as this gets without giving up a
real HTTP runtime. A bare Lua interpreter would be smaller and could not answer
a request; a container-per-student would isolate as well and cost 10× the RAM.

## Two things the runner forced, already learned by the spike

1. **`lua5.4 -E` ignores `LUA_INIT`/`LUA_PATH`/`LUA_CPATH`.** So akkar cannot be
   delivered through the environment. Either it lives on the image's system path,
   or — better, and this is why item 6 matters — the interpreter IS the single
   binary `akkar build` produces. The runner image should carry that binary.

2. **`app:test()` is the correction primitive**, not a real socket. It takes a
   request through routing, validation, middleware and the handler with no
   socket opened, so an API exercise becomes a deterministic function call —
   the only thing a locked jail can run. This is why the whole integration is
   possible without a network inside the sandbox.

## What is NOT akkar's to solve

- The deterministic simulator (Phase 1) is a pure TypeScript module in the
  frontend. akkar has no part in it, by decision D2: one implementation of the
  physics, in TS, or the screen and the verdict diverge.
- Grading authority (Phase 3) is `dalivim-engine`'s `SpecKind = "scenario"`.
  akkar's `app:test()` is only invoked in Phase 4, for the code exercise.
- Isolation of student code (D5) is the runner's job — separate process, CPU /
  memory / fs / network / deadline caps. `akkar.vm` says in its own header it is
  a sandbox and not a boundary; the runner is the boundary. **This is the same
  process-isolation P0 the akkar handoff is tracking**, and the subprocess spike
  (`bench/spike/subprocess-spawn.lua`) plus Landlock is akkar's own path to it —
  but for dalivim, the runner already provides it and akkar does not need to.

## Decisions, resolved

The product owner answered one and delegated the rest. The delegated ones are
resolved here with a reason, because they are engineering calls the code can
make, not product calls that need a person.

1. **Single-player.** DECIDED by the owner. So the diagram-ops protocol on
   `LiveRoomDO` (`node_add`/`node_move`/`edge_add`) drops entirely for Lab #001,
   and the last row of the plan's §8 table stays out. The live room is a later
   product (interview/whiteboard), and it is already built underneath when that
   day comes. This removes the largest conditional piece of work from the Labs
   scope right now.

2. **The generated project runs under the single binary (`akkar build`), not a
   system-path akkar.** Resolved toward the binary for the reason the spike
   already proved: the runner runs `lua5.4 -E`, which ignores `LUA_PATH`, so a
   system-path install is fragile exactly where the jail is strictest. The
   binary carries its own modules and is one file to place in the image. The
   cost is one build step in the runner image, which is cheap and cacheable.
   (Item 6 already assumed this; it is now confirmed by the constraint, not by
   preference.)

3. **Capacity params advance the injectable clock, not real time.** Resolved
   toward the clock because it is the plan's own D1/D4 principle: a measurement
   that changes between runs cannot be a verdict. `akkar.time` is already
   injectable and the L1 simulation already depends on it, so a
   `latency_ms = 8` is eight milliseconds of *simulated* time, deterministic and
   instant. The design constraint this creates, stated so it is not a surprise:
   the load generator (item 3) must drive that same clock, or a real-timed
   generator and a clock-timed adapter disagree. One clock, both tools.

4. **Build order: 1 → 2 → 3.** Resolved toward the first Lab's lesson leading,
   over the general loop, and here is the trade. Item 2 (capacity params) is the
   keystone that closes the sim-and-run loop, and in the abstract it comes first.
   But Lab #001's entire climax is the cache stampede, and that needs item 1
   (cache `fail/hang/drop` parity) to exist at all. A keystone with no first Lab
   to demonstrate it is a feature with no user. So build the thing the first Lab
   teaches (1), then the keystone that generalises it (2), then the load
   generator that makes it visible (3). Item 1 is also the smallest — it copies
   an existing pattern from `akkar/db/memory.lua` — so it is the cheapest thing
   to lead with.

5. **The akkar work lands upstream in the akkar repo, not as a dalivim fork.**
   Items 1-3 are general akkar features, not dalivim-specific, as the plan
   itself notes: a fault-injectable cache, capacity-limited memory adapters and
   an in-process load generator are useful to any akkar user testing a service.
   akkar has its own test suite and CI (1,863 tests, three platforms), so a
   vendored copy would fork that maintenance for no gain. They belong upstream,
   and dalivim consumes them the same way it consumes the rest of akkar.

## Status

Nothing here is being built yet. This is the plan of record for when the Labs
Phase 4/5 work starts: the six asks scored against the code, the three TODO
items ordered 1 → 2 → 3, and the five decisions resolved. The seed for item 3
(`bench/study/low-load-latency.lua`) already exists. Whoever picks this up
starts from here, not from the code.
