# Handoff — 16 August 2026

Written at the end of the session that measured the C driver end to end. It
covers what changed, what is waiting for you, and what the next person should
point an instrument at.

---

## Do these three things first

1. **Sync your local checkout.** It sits on `main` at `d1e5d45`, one position
   behind `origin/main` (`48772cc`, your merge of PR #1). Clean fast-forward:

   ```sh
   cd ~/Desktop/akkar && git pull --ff-only origin main
   ```

2. **Merge PR #2** — https://github.com/jpierreribeiro/akkar/pull/2 —
   three commits, MERGEABLE, 1,661 tests passing. It carries the driver
   measurement, a real 408 defect it uncovered, and the framework comparison
   redone. Merging is yours to do; this session does not merge to `main`.

3. **The EC2 is running and billing.** `100.48.219.220`, quiet, fully
   provisioned. Stop it if you are done, or leave it up — the memory says you
   want it up, so it was left up.

Also still live: the Railway service `akkar-deploy-test`, from an earlier
session, still costing money.

---

## What this session established

### The question that started it

*"Our performance, comparison and benchmark tests never measured with the new
driver, right?"* — correct, and wider than the question. `driver = "pq"` is
opt-in, and **no benchmark server in this repository ever passed it.** The
comparison against Gin and FastAPI, the saturation sweep and the eight-hour
soak all ran pgmoon. The one measurement that used the C driver ran it in
isolation — one connection, one query at a time — and on a laptop rather than
the study machine, so it was not comparable with anything else either.

Both gaps were already written down, in `bench/driver/RESULTS.md` §4 and in the
study's "What this does NOT prove". Writing a gap down is not closing it.

### The driver, measured end to end

`bench/driver/RESULTS.md` §5, on the study `c5.2xlarge`:

| route | pgmoon | akkar.pq | ratio |
|---|---:|---:|---:|
| `/ping` @100 | 19,241 | 19,392 | 1.01x — the control |
| `/users/42` @16 | 7,040 | 8,969 | 1.27x |
| `/rows/100` @16 | 2,392 | 5,031 | 2.10x |
| `/rows/1000` @16 | 333 | 928 | 2.79x |
| `/rows/1000` @100 | 322 | 861 | 2.68x |

p99 under saturation: **1.3 s → 475 ms**.

A published prediction failed. §3 of that page said the driver would not move
`/users/:id`, because one row was OVERLAPPING in isolation. It moves 1.27x and
separates. §3 is kept as written, with a pointer to the score.

The direction is the interesting part: the advantage is **larger** through a
whole request (1.27x) than over a bare query (1.09x), which is backwards from
dilution. The hypothesis on offer — labelled as one, because nothing here
isolates it — is that one thread per process means driver CPU is not paid by
the request that spends it. Concurrency multiplies driver cost instead of
diluting it.

### The comparison, with the driver in the table

`bench/study/RESULTS.md` §2.1. `/rows/200` at 16 connections:

```
gin              7206.08     1.99ms     7.04ms     1.00x
fastapi           880.59    17.92ms    23.94ms     0.12x
akkar            1425.37    10.72ms    18.56ms     0.20x
akkar-pq         3482.56     4.57ms     6.53ms     0.48x
```

A fifth of Gin becomes about half of it; 1.6x FastAPI becomes 3.95x. The p99
lands under Gin's own — the first row in the study where akkar's tail is not
the worse one. `/ping` does not move, which is what says the driver variable is
not leaking into the framework path.

The pgmoon rows also **reproduced section 2 a day later** on the same box: Gin
7,194 → 7,206, FastAPI 880 → 881, akkar 1,450 → 1,425. That agreement is worth
as much as the new row.

### Defects found, all with running proofs

| what | how it was found |
|---|---|
| `timeout = 0` answered **408 to every request**, including a GET with no body | the comparison harness refusing to publish a number for a server answering errors |
| Two specs spawned a child `lua5.4` and trusted `LUA_PATH`, producing ten false failures that blamed the code under test | running the suite on a shell where luarocks is per-user |
| `bench/study/apps/serve.lua` could not select a driver, and did not set `package.cpath` for the C module | building the measurement |
| The `timeout` reference never documented that `0` disables the deadline | checking a claim before publishing it |

The 408 is the one to remember. `spec/slow_body_spec.lua` is the file that
introduced the body-read budget and tests it carefully — with `0.5` and with
`2`. **The value that turns the feature off was never sent through the
feature.** In Lua `0` is true, so `budget and (...)` turned "no deadline" into
"a deadline of right now".

---

## The state of things

- **1,661 tests passing**, 0 failures, 0 pending, verified on a shell with
  `LUA_PATH`/`LUA_CPATH` unset.
- `main` is `0.1.0`. PR #2 is the next merge.
- The default driver is **still pgmoon**, deliberately — see below.

### Why the default did not move

The C driver is faster **and less consistent**. Across thirty ten-second
windows, pgmoon held 0.9%–3.5% spread on every route and produced zero
anomalous windows. `akkar.pq` produced two, on routes whose spread was 21.4%
and 14.2%. In a slow window p50 rose along with p99, so the whole window was
slower rather than one request hanging in it.

No explanation has been measured. It is not row-count dependent — `/rows/10`
sits between the two affected routes and is clean. It never happened to pgmoon
on the same box in the same alternating runs.

A driver becomes the default by proving itself, and an unexplained
intermittent loss of its entire advantage is not proof.

---

## What to do next, and what not to

> **Superseded in part by `docs/RUNTIME-1.0.md`**, which reframes the project
> as a backend runtime rather than a framework chasing Gin, prices a LuaJIT
> spike at about a week, and sets the bar a component must clear to earn a C
> implementation. The ordering below survives with one change: the LuaJIT
> experiment moves up, because 91.6 of akkar's 103 µs per request is
> interpreted Lua and a JIT is the only single change that touches all of it.


Asked directly what we should do, after measuring the gap against Gin. The
answer the measurements support is **not** "chase Gin".

### Do not rewrite lua-http for speed

It is the largest single line in the `/ping` budget — 47 µs of 103 — and
replacing it would take akkar from 0.19x of Gin to about 0.35x. That is real,
and it is the wrong reason to do it, because **`/ping` is the route where
applications spend the least time.**

On `/rows/200` a request occupies roughly 570 µs of server time. Removing 47 µs
of substrate is worth at most 8% there. The 2.79x that actually moved
application performance came from the C driver, not from the framework path.

Rewrite the substrate when there is a reason other than a benchmark: lua-http
has had no release since September 2024, akkar already carries two
denial-of-service repairs for it, and `docs/substrate/RESULT.md` plus the
executable contract exist to make that move a measured step. Speed is the
bonus, not the case.

### 1. Explain the pq inconsistency, then make it the default

This is the highest return available and most of the work is done. `akkar.pq`
is **2.79x on a thousand rows** with p99 under saturation falling from 1.3 s to
475 ms, and it is switched off by default for one unexplained reason: two
anomalous windows in thirty, where a whole ten-second window ran at pgmoon's
speed. pgmoon produced zero such windows in the same alternating runs.

Per-request timing over a long run, not per-window throughput — that is the
only instrument that says whether the window holds one long stall or a hundred
thousand slightly slower requests. Everything needed is provisioned on the box.

### 2. ~~Put a gate on the hot path~~ — DONE

The allocation ceiling existed and was watching `app:test()`, which never calls
`app:run` and therefore never touches lua-http, the socket, or the substrate
repair. It is now also measured over a real socket against a real server, and
calibrated by proving it fails on the commit it exists for: the old repair
costs 511 bytes per request, the rewritten one costs zero, and the measurement
repeats to within two bytes.

### 3. Port a real application

Unchanged as the largest gap, and `docs/UNKNOWNS.md` §10 still says so. Every
defect this week was found by engineering an exposure — including the 408,
which a benchmark gate caught, and the 4% regression, which surfaced only
because a peer framework reproduced to 0.2% in the same table. **None was found
by anybody using akkar to build something.**

### Cheap things sitting on the table

- **Generational collector**: 2.5% faster, p99 from 7.50 ms to 5.66 ms, 2 MB
  less memory. Do not flip the default on ten seconds of evidence — the soak
  that justifies it is the same soak the C driver needs, so run them together.
- **`PROCS` sizing**: defaulting to physical cores leaves about 15% on the
  table on any box with SMT. A paragraph in `docs/RUNTIME.md`, not a code
  change.

---

## Instruments still unpointed

Ranked by what they would actually tell you.

1. **Explain the pq inconsistency.** This is the blocker on the default and the
   only open question with a clear shape. Per-request timing over a long run,
   not per-window throughput — that is the only thing that can say whether the
   window contains one long stall or a hundred thousand slightly slower
   requests. Everything needed is provisioned on the box.

2. **Soak the C driver.** Section 9 of the study is eight hours of pgmoon. The
   C driver has never run for more than ten seconds at a stretch, and it is the
   one that allocates less per row — the interesting comparison. `soak.sh` now
   checks correctness byte-for-byte every sample, so it would catch drift as
   well as leaks.

3. **Port a real application.** Still the largest gap, and `docs/UNKNOWNS.md`
   §10 still says so. Every defect this session found was found by engineering
   an exposure. None was found by use — including the 408, which was found by a
   benchmark gate, not by anyone running an app.

The remaining lenses in `docs/UNKNOWNS.md` — infrastructure failure injection,
resource exhaustion at the ceiling, scale of shape, dependency movement,
observability during an incident, adversarial security review — are unchanged.
Items 2 and 5 closed this week, along with the clock exposure under item 3.

Open items also live in `docs/BACKLOG.md` §11: a job store that fails at first
push rather than at construction, `app:mount` not running sub-app middleware,
`docs/DEPLOY.md` not re-run by anything, no `env` marker for the docs runner,
and webhook signature verification being impossible because the raw body is
discarded.

---

## Reproducing the measurements

The box has everything: rocks for Lua 5.4, the compiled `pq_native.so`, `wrk`,
Postgres seeded with 10,000 users and 2,000 bench rows, Gin built and a FastAPI
venv.

```sh
ssh -i ~/Downloads/colossus.pem ubuntu@100.48.219.220
eval "$(luarocks --local --lua-version 5.4 path)"
cd ~/akkar

bash bench/driver/end-to-end.sh                       # driver, both, six targets
TARGETS="/users/42:16:4" REPS=8 bash bench/driver/end-to-end.sh   # one route, deeper
bash bench/study/run.sh compare                       # five-way, three targets
```

Two things that are easy to get wrong and cost a run each:

- **`luarocks` on Ubuntu defaults to Lua 5.1.** Rocks installed without
  `--lua-version 5.4` build against 5.1 and die on `luaL_register`.
- **Never measure on the laptop.** It ran at load 4 from an ordinary browser
  session. A contaminated benchmark does not fail, it produces a clean curve of
  wrong numbers — which is what the CORRECTION block at the top of
  `bench/driver/RESULTS.md` is about.
