# Handoff — 16 August 2026

For whoever picks this up next, including you in a week. It says what is
waiting, what changed, what was learned, and what to do — in that order,
because the first one has a deadline and the rest do not.

Rewritten rather than appended to. The previous version had grown four layers
of correction blocks over sections that were no longer true, which is
archaeology and not a handoff. The corrections live in the documents that carry
the measurements, where somebody reading a number will meet them.

---

## Waiting on you

**1. Merge PR #3** — https://github.com/jpierreribeiro/akkar/pull/3 — twelve
commits, MERGEABLE, 1,696 tests passing. This session does not merge to `main`.

**2. Sync your checkout.** It is on `main` at `d1e5d45`; `origin/main` is at
`f15d6fa`.

```sh
cd ~/Desktop/akkar && git pull --ff-only origin main
```

**3. akkar has never been published.** It is not on luarocks.org, so the README
tells people to install from a rockspec URL — which works, and was tested, but
is not what anyone expects to type. `luarocks upload` is a release step nobody
has taken; there is no technical obstacle and no CI job for it either.

**4. Two things are billing.** The `c5.2xlarge` at `100.48.219.220` has been up
27 hours and is idle. The Railway service `akkar-deploy-test` is still live from
an earlier session. Neither is in use.

---

## Where the project stands

**1,696 tests, 0 failures, 0 pending**, verified on a shell with `LUA_PATH` and
`LUA_CPATH` unset — the shape that catches path assumptions.

`main` is `0.1.0`. The framework works; what the last two days changed is how
much of it is *known* rather than believed.

### The runtime has a first minute

```sh
akkar new my-api
cd my-api
akkar run
curl localhost:8080/health     # {"ok":true}
```

`new`, `run` and `test` joined `doctor`, `watch`, `build`, `archive` and
`version`. All of them read one shape: a file that **returns** the app,
optionally with its config. `spec/cli_spec.lua` spawns the real CLI, because
the value of a scaffold is entirely in whether the thing it emits runs.

### The C driver has no objection left against it

`akkar.pq` is **1.27x on a single row, 2.79x on a thousand**, with p99 under
saturation falling from 1.3 s to 475 ms. It returns byte-identical rows.

The consistency objection that kept it off has been **withdrawn** — see
"What was wrong" below. The default is still pgmoon, for a packaging reason
nobody had stated: the C half is a separate rock, so a default of `pq` would
fail at the first query for anyone who installed only `akkar`.

```sh
luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir)
```

Install it, pass `driver = "pq"`, and use it.

### The gap against Gin is attributed, not quoted

All at two cores, same 13 bytes:

| layer | req/s | µs of CPU per request |
|---|---:|---:|
| cqueues, no parsing | 169,960 | 11.5 |
| **a real HTTP server in pure Lua** | **171,330** | **11.7** |
| lua-http | 34,173 | 58.5 |
| akkar `/ping` | 19,408 | 103.0 |
| Gin, same CPU | 101,584 | 19.7 |

**It is not the language.** A hand-written HTTP server in PUC Lua 5.4 runs at
1.69x Gin. akkar's 103 µs is cqueues 11%, **lua-http 46%**, akkar's own code
43% — and the collector is at most 3.5% of it.

`bench/study/WHERE-THE-GAP-IS.md`.

---

## What was wrong, and is not any more

Nine defects, and the ones that matter were not found by reading.

| what | how it was found |
|---|---|
| **`app:mount` discarded the mounted app's middleware** — a protected route answered 200 with no credential | porting a real service |
| **Webhook signatures were impossible** — the raw body was decoded and thrown away | porting a real service |
| `timeout = 0` answered **408 to every request**, including a GET with no body | a benchmark gate refusing to publish a number |
| A misspelled schema constraint validated **nothing**, silently | porting a real service |
| `v.integer` returned a float from JSON and an integer from a query string | porting a real service |
| The retry schedule every webhook system uses could not be expressed | porting a real service |
| Sub-second retry delays did not exist, quantising the jitter that prevents a thundering herd | a probe misbehaving |
| A 4% throughput regression, from three allocations added to a hot path | a peer framework reproducing to 0.2% in the same table |
| Invalid UTF-8 echoed into JSON responses | pointing hostile bytes at it |

Two of those are security defects and both were sitting in the open-items list
wearing the label "ergonomic".

### And two things this session believed and had to withdraw

**The C driver is less consistent than pgmoon.** It is not. Re-measured at the
configuration the claim came from, it is 1.8% spread with zero anomalous
windows against a published 21.4% and two. The raggedness that does reproduce
is `SO_REUSEPORT` splitting few connections across processes, and it hits
**pgmoon harder**. `bench/driver/ANOMALY.md` carries all four experiments,
including the checkpoint hypothesis that looked decisive at n=1 and died when
it was forced.

**A run was discarded for being taken on a busy machine.** It was not busy.
`/proc/loadavg` on that box reads 2.3 while `vmstat` reports the CPU 100% idle;
the load average does not decay there. The gate now asks `vmstat`.

---

## What to do next

The direction is `docs/RUNTIME-1.0.md`: a small, predictable backend runtime
whose application language is Lua, not a framework chasing Gin. Ordered by risk
removed rather than by architectural appeal.

**1. The platform, which is the next piece of work.** `akkar new/run/test` is
the first mile. What is missing between that and a distribution: automatic
recipes for native dependencies, cross-compilation and a platform matrix, and
an `akkar version` that prints the whole lock — Lua, cqueues commit, OpenSSL,
cjson, driver, target. The product is "Akkar Runtime 1.3 is the supported
platform", which moves an entire class of issue from the user to release
engineering.

**2. The LuaJIT spike — one week, decision rule already written.** 91.6 of
akkar's 103 µs per request is interpreted Lua, and a JIT is the only single
change that touches all of it while requiring nobody to own anything. The
port cost is audited: `<close>` in four places, `//` in twelve, `math.type` in
nine, `table.pack` in ten, `utf8` in three. It comes **before** writing an HTTP
parser, because its answer decides whether that parser is worth owning.

**3. Keep porting.** Three slices done — invoice API, inbound webhook, outbound
dispatcher — and they produced six of the nine defects above. Untouched: the
reconciliation cron, disputes, KYC, the IP-allowlisted admin surface. And the
dispatcher ran against a **fake** HTTP client, so the queue and the retry
schedule are proved and the transport is not.

**4. Do not rewrite lua-http for speed.** It is 46% of `/ping` and replacing it
would take akkar from 0.19x of Gin to about 0.35x — but on a route that touches
a database a request already costs ~570 µs, so the whole substrate saving is
worth at most 8%. Rewrite it when the reason is maintenance and
denial-of-service surface: no release since September 2024, and akkar already
carries two repairs for it. Speed is the bonus, not the case.

---

## Instruments nobody has pointed yet

From `docs/UNKNOWNS.md`, and the list is shorter than it was:

- **Platform.** CI is `ubuntu-24.04` and nothing else. This matters more now
  that the project calls itself a runtime: the promise of a runtime *is* the
  combination that works, and akkar cannot yet say where it works.
- **Adversarial security review.** Of the nine defects, two were security
  failures found by accident. Somebody trying would find more.
- Infrastructure failure injection, resource exhaustion at the ceiling, scale
  of *shape* (ten thousand routes, a one-megabyte header), dependency movement,
  and observability during an incident.

Closed since it was written: correctness over time, hostile encodings, the
clock, and — started — porting a real application.

---

## Reproducing anything here

The `c5.2xlarge` has everything: rocks for Lua 5.4, the compiled
`pq_native.so`, `wrk`, Postgres seeded with 10,000 users and 2,000 bench rows,
Gin built and a FastAPI venv.

```sh
ssh -i ~/Downloads/colossus.pem ubuntu@100.48.219.220
eval "$(luarocks --local --lua-version 5.4 path)"
cd ~/akkar

bash bench/study/floors.sh          # where the Gin gap is
bash bench/study/run.sh compare     # akkar, Gin, FastAPI, both drivers
bash bench/driver/end-to-end.sh     # pgmoon against akkar.pq
bash bench/driver/distribution.sh   # why the "inconsistency" was the harness
bash bench/study/regression.sh <ref> HEAD   # did akkar get slower?
```

Three ways to waste a run, each of which cost one:

- **`luarocks` on Ubuntu defaults to Lua 5.1.** Rocks installed without
  `--lua-version 5.4` build against 5.1 and die on `luaL_register`.
- **Never measure on the laptop.** It runs at load 4 from an ordinary browser
  session, and a contaminated benchmark does not fail — it produces a clean
  curve of wrong numbers.
- **`/proc/loadavg` is not an instrument on the study box.** Ask `vmstat`.

---

## Teaching akkar, and why it is also an instrument

`~/Desktop/akkar-exercise-spike/` — a spike answering one question: can a
backend exercise in akkar be graded inside the constraints `dalivim-runner`
imposes on Lua? Isolated mode, one entry file, no network, a hard `RLIMIT_AS`.

**Yes, comfortably.** Two exercises, twelve submissions, **12.8 MB peak RSS
against a 256 MB address-space cap, 40–100 ms per grading, no network at all.**

`app:test()` is what makes it possible: a request goes through routing,
validation, middleware and the handler **without opening a socket**, so a
backend exercise becomes a deterministic function call — the only shape an
isolated jail runs.

The runner's `-E` decides the design. It ignores `LUA_INIT`, `LUA_PATH` and
`LUA_CPATH`, so akkar cannot arrive through the environment. Either it lives in
the image's system path, or the interpreter is not `lua5.4` at all: it is the
single binary `akkar build` produces, which carries akkar and 46 native modules
and hosts code it never embedded.

### And it is an instrument for akkar

Writing **one** exercise against `akkar.db.memory` surfaced five API surprises,
none of which any test in this repository would have caught:

| | |
|---|---|
| `check_capabilities` is not an `app:test{}` option | akkar refused it by name, which is right |
| the query log records values as `args`, not `params` | documented, and easy to assume wrong |
| `:on(pattern, {})` is **one empty row**, not zero | zero rows needs a function returning nil |
| `Memory:reset()` does **not** clear programmed responses | and `find` returns the first match, so re-programming never wins |
| an unprogrammed query **raises** | which is the right default, and not obvious |

Only the third is arguably a defect: an empty table is what anyone reaches for
to mean "no rows", and a row with no columns has no use. It was **not changed**
— five specs depend on the current behaviour, and changing an API on a
preference in the middle of other work is how a framework acquires surprises
rather than loses them. It is documented instead.

That is the argument for the teaching idea as engineering rather than as a
product: exercises are miniature ports, a grader running learner code is a
fuzzer for the API surface and the error messages, and a hundred learners would
be the largest source of *found by use* this project could have.

### The lesson that cost two distractors

A distractor only teaches if it is genuinely wrong, and the only way to know is
to run it. Two were written as traps and passed, correctly — a float path that
`math.ceil` makes integral, and a "returns the whole row" that a fixture with
exactly the right columns cannot catch. **Failing somebody for being right is
the worst defect an exercise platform can have.**

## The port lives outside this repository

`~/Desktop/escrow-akkar/` — three slices of a private escrow service, ported to
akkar. It stays out of the public repo because the business logic is somebody's
and akkar is public. What comes back here is the defects, in
`docs/PORT-FINDINGS.md` and `spec/port_findings_spec.lua`.
