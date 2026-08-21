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
| 1 | fail/hang/drop parity on the cache adapter | **TODO** | the DB memory adapter has `:fail()/:hang()/:drop()`; the cache adapter does not. Copy the pattern from `akkar/db/memory.lua` |
| 2 | capacity params on memory adapters (`max_qps`, `latency_ms`) | **TODO** | neither adapter takes them. **This is the one that closes the loop** — see below |
| 3 | a load generator inside `app:test()` | **TODO** | none. `bench/study/low-load-latency.lua` (written 2026-08-20) is the seed: it drives `app:test` in a tight loop and reports percentiles. Generalise it to `app:test():load { rps, duration, routes }` |

Two done, one partial, three to build. **None blocks Phase 1, 2, or 3.** Items
1 and 2 are what Phase 4 needs first; item 3 is what makes "IMPLEMENT → MEASURE"
run inside the jail instead of needing an external load tool.

### Why item 2 is the keystone

Today the diagram says "capacity 1,500/s, service 8 ms" and the test adapter
does not know it. If `akkar.db.memory { max_qps = 1500, latency_ms = 8 }`
existed, **the same numbers would configure the simulation AND the real run** —
the loop closes on itself. And item 3 then produces the best lesson in the
product: the simulator predicted p95 33 ms, the real run gave 41 ms, and the
student sees *where the model is wrong*. A simulator that admits it is
approximate teaches more than one that presents itself as truth (the plan's D1).

The shape to copy is already in the tree: `akkar/db/memory.lua`'s `:on()`,
`:fail()`, `:hang()`, `:drop()` are per-adapter behaviour toggles. `max_qps`
and `latency_ms` are the same kind of thing — construction-time knobs on the
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
matter are **12.8 MB resident** and **29 ms boot**: a hundred idle exercises fit
in ~1.2 GB, five hundred in ~6 GB. That is the density the teaching platform was
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

## Open questions for the product owner

These are decisions the code cannot make. Answers change what gets built.

1. **Is Lab #001 (URL shortener) live-collaborative, or single-player?** The
   plan's §8 last row is conditional: `LiveRoomDO` is ready, but the Lab alone
   does not need a live room. If single-player, the diagram-ops protocol work
   drops entirely for now.

2. **Does Phase 4 want the generated project to run under `akkar build` (single
   binary) or under a system-path akkar in the image?** Both work; the binary is
   cleaner for the `-E` reason above, but is one more build step in the runner
   image. Item 6 assumes the binary — confirm.

3. **For item 2, should `max_qps`/`latency_ms` be honoured by advancing the
   injectable clock (deterministic, fast, my recommendation) or by real time
   (simpler, but non-deterministic and slow)?** Determinism is the plan's own
   D1/D4 principle, so I would advance the clock — but that means the load
   generator (item 3) drives the clock too, which is a small design constraint
   worth stating now.

4. **Priority order for the three TODO items.** My read: 2 (capacity params)
   unlocks the loop and is the keystone; 3 (load generator) is what makes the
   loop visible; 1 (cache fail/hang/drop) is the Lab #001 lesson itself. So
   **2 → 3 → 1**, but 1 is what the *first* Lab needs to teach its climax
   (cache stampede), so it could lead. Your call on whether the first Lab's
   lesson or the general loop comes first.

5. **Does the akkar-side work live in the akkar repo or as a dalivim fork of
   it?** akkar is a separate project with its own test suite and CI. Items 1-3
   are general akkar features (not dalivim-specific, as the plan itself notes),
   so they belong upstream in akkar. Confirm that is the intent and not a
   vendored copy.
