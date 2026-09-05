# Akkar Runtime 1.0 — what goes in Lua, what earns C, what ships together

> Historical proposal and measurements, not the active implementation checklist.
> See [CONSOLIDATION.md](CONSOLIDATION.md) for current work and evidence. Existing
> CLI/build/JSON facilities must not be reimplemented from this proposal.

Written after a reframing proposal: stop aiming at *"the fastest Lua framework
because it uses a special VM"* and aim at **a small, predictable, safe backend
runtime whose application language is Lua**.

This document agrees with that, says which parts of it the measurements now
settle, and disagrees with one item — because a number taken the same day the
proposal was written points the other way.

---

## 1. What the measurements settle

### The interpreter is not the problem

The strongest evidence for the reframing is the newest and was not in the
repository when the proposal was written. `bench/study/WHERE-THE-GAP-IS.md`,
on the study machine, two cores each, every server answering the same 13 bytes:

| layer | req/s | µs of CPU per request |
|---|---:|---:|
| cqueues, no parsing | 169,960 | 11.5 |
| **a real HTTP/1.1 server in pure Lua** | **171,330** | **11.7** |
| lua-http | 34,173 | 58.5 |
| akkar `/ping` | 19,408 | 103.0 |
| Gin, held to the same CPU | 101,584 | 19.7 |

A hand-written HTTP server in PUC Lua 5.4 — parsing the request line, walking
headers, consuming a declared body, routing, writing a response — runs at
**1.69x Gin**. Parsing and routing are free: 11.5 µs without them, 11.7 with.

So the question *"how far can PUC Lua go as a backend runtime if only the hot
paths move to C?"* already has a first answer, and it is **further than
anyone assumed**. The ceiling is not the language.

### Where akkar's cost actually is

| | µs/req | share |
|---|---:|---:|
| cqueues — the event loop | 11.6 | 11% |
| lua-http — parsing and writing | 47.1 | 46% |
| akkar — router, chain, request table, deadline, capabilities, JSON | 44.6 | 43% |

And it is **work, not the collector**: with garbage collection stopped
entirely — 10.9 GB resident — akkar gains 3.5%.

### The driver was the right kind of move, and it is measured

| | pgmoon | akkar.pq |
|---|---:|---:|
| `/users/42` | 7,040 req/s | **8,969** |
| a thousand rows | 333 | **928** |
| p99, a thousand rows, saturated | 1300 ms | **475 ms** |
| `/ping` (no database) | 19,241 | 19,392 — *identical* |

That last row is the model in one line: **C where the mechanical work is, Lua
everywhere else, and no cost where there is nothing to accelerate.**

---

## 2. The disagreement: LuaJIT is now a *better* bet than it was, not worse

The proposal ranks a LuaJIT spike fifth and frames it as probably not worth
it. Today's decomposition argues the opposite, and it is worth stating clearly
because it is the one place the evidence contradicts the plan.

**91.6 of akkar's 103 µs per request is interpreted Lua** — 47.1 in lua-http
and 44.6 in akkar. Both are pure Lua. A JIT is the only single change that
touches all of it at once. Replacing lua-http's hot path addresses 47 µs and
requires writing and then owning an HTTP parser; a JIT addresses 91.6 µs and
requires owning nothing.

That is not a prediction that LuaJIT would be fast here. Allocation-heavy,
string-heavy, table-churning code is where JITs do worst, and akkar is all
three. It is an argument that **the expected value of the spike went up**, and
it is cheap to settle.

### What the spike actually costs, audited rather than guessed

LuaJIT is Lua 5.1 semantics with extensions. What in akkar does not run there:

| construct | sites | cost to shim |
|---|---:|---|
| `<close>` | 4, all in `static.lua` on file handles | rewrite as explicit close; mechanical |
| `//` integer division | 12 across 4 files | `math.floor(a / b)`; mechanical |
| `math.type` | 9 | trivial shim |
| `table.pack` | 10 | trivial shim |
| `utf8.len` / `utf8.offset` | 3, all in `safe_text` | needs a real UTF-8 validator, ~30 lines |
| `warn` (the 5.4 global) | **0** — every `warn(` is a log method | none |

That is **roughly a week**, not the two days the proposal hopes for and not
the six months it fears. The `<close>` sites are the only ones that touch
resource lifetime, and they are file handles in `static.lua` rather than
anything in the request path the seven-leak audit hardened.

### The decision rule, written before the run

Run `/ping`, `/rows/200`, the router at 200 routes, validation, and both
drivers, under Lua 5.4 and LuaJIT 2.1, JIT on and JIT off.

- **`/ping` improves by less than 1.5x** → close the experiment, write down
  the number, never open it again.
- **`/ping` improves by 2x or more AND `/rows/200` improves at all** →
  LuaJIT becomes a supported target and the shims become permanent.
- **Anything between** → keep it as `experiments/luajit`, unsupported, and
  revisit only if the substrate work stalls.

No fork. No VM port. The rule is written now so the result cannot be
rationalised afterwards.

---

## 3. The layer model, with the boundary made testable

```
┌─────────────────────────────────────────────┐
│                Akkar API                    │
│      routes · schemas · db · jobs · auth    │
├─────────────────────────────────────────────┤
│              Akkar runtime                  │
│    scheduler · pools · deadlines · I/O      │
├─────────────────────────────────────────────┤
│           Native acceleration               │
│   Postgres · crypto · JSON · parsing        │
├─────────────────────────────────────────────┤
│                   Lua                       │
│                5.4 → 5.5                    │
└─────────────────────────────────────────────┘
```

The principle — *Lua keeps policy and composition, C takes mechanical work* —
is right, and it needs a test or it becomes a preference.

**A component earns C only when a measurement shows it is at least 30% of a
route's CPU, and the C version is proved to return byte-identical results
before it is timed.** `akkar.pq` cleared that bar: row materialisation was 55%
of a thousand-row query, and `bench/driver/compare.lua` refuses to time two
drivers that disagree about the data.

Applying the bar to the obvious candidates, from what is already measured:

| candidate | measured share | earns C? |
|---|---|---|
| Postgres row materialisation | 55% of a 1000-row query | **yes — done** |
| HTTP request parsing + writing | 46% of `/ping` | **yes, and it is the largest open one** |
| JSON encoding | finding 3 of the study: *"it is not the JSON encoder"* | **no** |
| Routing | free — 11.5 µs against 11.7 with routing | **no** |
| Validation | never decomposed | **unknown — measure before deciding** |
| Crypto | already C through OpenSSL | n/a |

The row worth noticing is JSON. It looks like an obvious C candidate and the
performance study already measured that it is not. **The bar exists to stop
exactly that kind of plausible mistake.**

---

## 4. What "Runtime 1.0" has to ship

The distribution argument is the strongest part of the proposal, and the
reason is not performance. It is that Lua's real cost of adoption is a graph
of decisions the user has to resolve alone: which Lua, which event loop, which
HTTP library, which TLS, which JSON, which Postgres, and which combination of
versions works together.

`akkar build` already proves the endpoint is reachable: **369 Lua modules and
46 native modules in a 5.08 MB executable**, with no Lua, no LuaRocks and no
shared modules at runtime.

What is missing between that and a distribution:

1. **`akkar run`.** Development on exactly the runtime `akkar build` produces.
   `docs/RUNTIME.md` already names it as the next step.
2. **Automatic native dependency recipes.** Today the C driver needs
   `luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir)`. A
   distribution resolves that itself.
3. **Cross-compilation and a platform matrix.** `docs/UNKNOWNS.md` §1 is still
   open: CI is `ubuntu-24.04` and nothing else, and ARM64 has been measured
   exactly once by hand.
4. **`akkar version` that prints the whole lock.** Lua, cqueues commit,
   OpenSSL, cjson, driver, target. The version of the *platform*, not of one
   library.
5. **A pinned, tested combination per release.** This is the actual product:
   "Akkar Runtime 1.3 is the supported platform" moves an entire class of
   issue from the user to release engineering.

And the part the proposal gets right that is easy to lose: **both doors stay
open.** `akkar run app.lua` uses the distribution; `lua app.lua` with akkar
installed from LuaRocks must keep working. A runtime that can only be used
through its own launcher stops being a Lua library, and being a Lua library is
why `spec/substrate_spec.lua` can exist at all.

---

## 5. The runtime ABI, and the one constraint on it

The proposal suggests an internal interface — `runtime.tcp`, `runtime.crypto`,
`runtime.http` — so the substrate can be swapped without the application
noticing. `spec/substrate_spec.lua` is already the executable half of that
idea, and it was written for exactly this future.

One constraint, and it comes from this project's own history rather than from
taste: **the indirection must be resolved at module load, not per call.**

`spec/allocation_spec.lua` exists because a controller allocated per request
cost 25 µs of a 34.7 µs budget and tied a hard file-descriptor limit to the
pace of the collector. An abstraction that costs a table lookup and a closure
on every `poll` would be the same defect wearing an architecture diagram. The
allocation ceiling — now measured over a real socket as well as through
`app:test` — is the judge, and it should be pointed at the ABI before the ABI
has users.

---

## 6. The order

Merging the proposal's list with what is now measured. Changes from the
original are marked.

1. **Explain `akkar.pq`'s inconsistency, then make it the default.** Two
   anomalous windows in thirty, unexplained, is the only thing between the
   project and a 2.79x it already owns. Needs per-request timing over a long
   run, not per-window throughput.
2. **`akkar run`, then `akkar build` as a product.** The distribution is the
   differentiator and this is its first mile.
3. **The LuaJIT spike — moved up from fifth.** One week, a decision rule
   written in advance, and it prices the one change that touches 91.6 µs of
   103 at once. Do it before committing to write an HTTP parser, because the
   answer changes whether that parser is worth owning.
4. **Then the HTTP fast path**, if the spike does not supply the win. It is
   46% of `/ping` and it is also the least defended dependency in the stack:
   no release since September 2024, two denial-of-service repairs already
   carried in `akkar/vendor/http/h1_stream.lua`.
5. **Lua 5.5 when `luaossl` moves.** Verified: `cqueues` at master builds and
   runs an event loop under 5.5; `luaossl` has no 5.5 target at all. One
   upstream bump, no fork, no heroics.
6. **A real application, ported.** Unchanged from `docs/UNKNOWNS.md` §10 and
   still the largest gap. Every defect found this week — including a 408 that
   answered every request and a 4% regression — was found by engineering an
   exposure. **None was found by anyone building something with akkar.**

---

## 7. What this document does not claim

- **That the reframing is proved.** It is well supported by where the costs
  are, and it is still a bet about adoption, which no benchmark settles.
- **That LuaJIT will be fast here.** The argument is about expected value and
  the cheapness of finding out, not about the outcome.
- **That a native substrate is coming.** The floors number says the ceiling is
  high. It does not say anyone should spend a year reaching it, and on a route
  that touches a database the whole substrate saving is worth at most ~8%.
- **That any of this matters more than item 6.** A runtime nobody has built an
  application on is a runtime whose real defects are all still unfound.
