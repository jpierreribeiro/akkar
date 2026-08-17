# Comparing akkar against the neighbours it actually has

Written before the services exist and before any number exists. A threshold
picked after seeing the result is a rationalisation, and a benchmark designed
after seeing the result is worse. Same rule as `bench/compare/METHOD.md`,
which this borrows most of its discipline from.

## The failure this corrects

`bench/compare/` measures akkar against **Gin and FastAPI**, and it says why
in its own words:

> Those three because they are what the owner actually writes, not because
> they are a representative sample of anything.

That was honest and it was sufficient, because the question at the time was
*"how much of a request is the framework?"* — a question Gin and FastAPI
answer well. `bench/study/WHERE-THE-GAP-IS.md` then used Gin as an external
ruler to split akkar's 103 µs into substrate and framework, and that
measurement still stands: it needed a compiled runtime on the other side, and
none of the candidates below could have replaced it.

**The positioning changed and the instrumentation did not.** akkar now calls
itself an application runtime for services — `README.md`, the rockspec and
`docs/RUNTIME-1.0.md` all say so. Against that claim, Gin and FastAPI are the
wrong neighbours, and the right ones have never been measured:

```
$ grep -rn "Lapis\|OpenResty\|Luvit\|Tarantool" bench/
$
```

Nothing. Not one line.

And it is worse than a missing benchmark. `docs/PLAN.md` and the Execution
Scope plan both assert:

> There is no cohesive server-side platform in Lua with these invariants.

That is a claim **about the neighbours**, published beside measured numbers,
with no instrument ever pointed at them. In this project that is the class of
thing treated as a defect: assertion standing where measurement belongs. This
document is the instrument, and it is written so it can refute the claim.

## The question

Not "is akkar fast". `bench/compare/` already answers throughput against
compiled runtimes, and the database dominates a real request twelve to one.

The question is what a **runtime** claim is actually made of:

> **Against the server-side Lua that already exists, what does akkar cost, what
> does it give back, and does the difference show up anywhere other than
> requests per second?**

Two routes, six dimensions. `/ping` is the runtime path with no database in it.
`/users/:id` is the realistic shape. The dimensions are where this differs from
every measurement in this repository so far.

## The candidates, and what each one answers

Chosen because each answers a **different** question. A candidate that answers
nothing the others do not is cost without information.

| candidate | what it is | the question only it answers |
|---|---|---|
| **Luvit** | Node-like on **libuv** | *"Lua already has a runtime"* — the incumbent. If akkar's claim is wrong, this is where it breaks. And it prices `akkar-substrate-luv`, parked in the Execution Scope plan, with evidence instead of taste. |
| **Lapis** | web framework on the **same substrate** akkar uses | With the base controlled, the delta *is* akkar. Isolates the price of the four invariants better than any other measurement available. |
| **OpenResty** | Lua inside **Nginx** | *"How much does it cost not to have Nginx in front?"* It is the de-facto standard for server-side Lua, so it is the number a sceptic asks for first. |
| **Tarantool** | app server **integrated with a database**, fibers | Included at the owner's decision, over a stated objection — see Rule 7. It is the only candidate that answers *"what if the datastore is not across a socket?"* |

**Gin stays.** Not as a competitor: as the fixed external ruler that already
produced `WHERE-THE-GAP-IS.md`. Removing it would make the new numbers
incomparable with every number already published.

---

## Rule 1 — semantic equivalence is a gate

Inherited unchanged, because it was learned the expensive way: a load
generator being rejected still reports a number, and the number looks like a
number.

Before any timing is recorded:

- every candidate answers both routes with **byte-identical JSON** for the
  same input, checked by diffing actual responses, not sampled;
- every candidate returns 404 with the same shape for a missing id and 422 for
  a bad one, so nobody is fast by skipping error paths;
- `wrk` output is inspected for `Non-2xx or 3xx responses` and any socket
  error, and either fails the run;
- process count, listening sockets and one successful request are verified
  **before the clock starts**.

## Rule 2 — the same work means the same work

| | |
|---|---|
| Validation | Every candidate validates `id` as a positive integer and rejects otherwise. A runtime that skips validation is not faster, it is doing less. |
| Serialisation | The same three fields. Nobody returns a smaller object. |
| Database | Same query, same pool size, pooled and async where the runtime is async. |
| Logging | Off everywhere. A line per request measures the terminal. |
| Concurrency model | Whatever each one's native model is — that IS the subject — but the **process count and the cores are identical**. |

Anything that cannot be equalised is reported as a caveat, never absorbed
silently into a number.

## Rule 3 — the machine decides the tolerance

Each candidate gets its own noise floor: ten repetitions of one identical
configuration, spread in basis points. **A difference smaller than the larger
of the two floors involved is not a result.**

akkar's floor on the study box is 0.7% with cores pinned. Every other floor is
unknown and will not be assumed.

## Rule 4 — distributions, alternating order, discarded warm-up

n, min, p50, p95, p99, max. Nearest-rank, so every reported value is one the
machine observed. No mean — a mean hides the tail, and the tail is the whole
question.

Outer loop is the repetition, inner loop is the candidate. Running all of one
candidate's repetitions in a block hands it a warm cache for the block, and
the measured difference would be the order.

## Rule 5 — topology-aware pinning

The study box is 4 physical cores × 2 threads. The generator gets one whole
physical core; the services get the other three. Splitting sibling threads
leaves contention in place while looking like isolation — this project read
0.67× per-process scaling from exactly that mistake, and 1.00× after fixing
it.

**And the mirror of it, which also already bit:** `WHERE-THE-GAP-IS.md`
published a table where Gin had twice the hardware threads, because Go reads
the affinity mask and akkar counted physical cores. Every candidate's actual
parallelism is verified at runtime, not assumed from its config.

## Rule 6 — the dimensions are runtime dimensions

**This is the rule that makes the document new.** Every comparison in this
repository so far reduces to requests per second. For a framework that is the
right reduction. For a runtime it is not, and reporting only throughput would
reproduce the original mistake in a new directory.

Six dimensions, each with a reason to exist:

**D1 · Time to first response.** From `exec` to the first 200, polled tightly.
A runtime that takes two seconds to boot changes deployment, autoscaling and
how tests are written. Nobody has measured akkar's.

**D2 · Resident memory, idle and loaded.** Idle decides density — how many
processes fit on a box. Loaded decides the ceiling. `bench/study/` has akkar's
in isolation; it has never been comparative.

**D3 · Cost per idle connection.** Descriptors and bytes per open, parked
keep-alive connection. **This is the dimension that separates a runtime from a
framework**, and it is where akkar's own numbers already have consequences: a
controller costs 2 descriptors on epoll and 3 on kqueue, which puts a hard
wall around 500 concurrent requests against `ulimit -n 1024`. No other
candidate has been asked this question at all.

**D4 · Throughput and p99 on `/ping` and `/users/:id`.** The old ruler, kept
so the new numbers connect to the published ones.

**D5 · Behaviour at saturation.** Not the mean: the p99, and whether it
degrades or collapses. akkar makes an explicit claim here — *"slow is a state
a server can be in; out of descriptors is not"* — and that claim is
comparative or it is decoration.

**D6 · The shape of the artefact you deploy.** What you copy to a server, in
megabytes and in steps. akkar builds 369 Lua modules and 46 native ones into a
5.08 MB executable with no Lua and no LuaRocks at runtime. This is the
dimension where akkar's distribution thesis lives, and it has never been put
beside anyone else's.

**D7 · What happens when a dependency is down.** Semi-qualitative and recorded
anyway: with Postgres stopped, does the server boot and answer a liveness
probe? akkar has `check_capabilities = false` for exactly this and treats it
as a feature. Whether the neighbours do is unknown.

## Rule 7 — where a candidate cannot be equalised, measure both and label

**Tarantool is the case.** It integrates the datastore, so running
`/users/:id` against an external Postgres removes the only reason to use it,
while running it against its own storage compares two different programs. My
recommendation was to leave it out. The owner decided to include it, and the
methodological answer is not to force a false equivalence:

- **`/ping` is comparable for all five.** No database is involved; it is the
  runtime path. Tarantool is in the ranking here without qualification.
- **`/users/:id` against external Postgres** is the semantically equivalent
  comparison, and Tarantool runs it. **This is the number that goes in the
  comparison table.**
- **`/users/:id` against Tarantool's own storage** is run too, and is reported
  in a separate block labelled *not a comparison*. It is context for what the
  integrated model buys, and it must never appear in a row beside the others.

The same treatment applies to any other candidate that cannot be equalised.
A caveat in prose under a table nobody reads is not labelling.

## Setup prerequisites, verified before any number

Each of these can invalidate the whole run, so each is checked and written
into `RESULTS.md` as part of the record:

1. **Which substrate Lapis is actually on.** Lapis can run under OpenResty or
   under lua-http/cqueues. **The comparison in this document requires the
   cqueues variant** — that is the entire reason Lapis is a candidate, because
   it holds the substrate constant. If the natural configuration turns out to
   be OpenResty-backed, Lapis stops answering its question and becomes a
   second OpenResty data point; that is a finding to record, not a detail to
   paper over.
2. **Whether each candidate is single-process by default.** Luvit and
   OpenResty both have worker models. akkar is one process per core by design.
   Equalising this is Rule 2; discovering it is a prerequisite.
3. **Lua version and JIT per candidate.** OpenResty is LuaJIT; akkar is PUC
   5.4. This difference cannot be removed and must be stated on every table —
   it is also, separately, the thing the parked LuaJIT spike would price.
4. **The idle gate.** `/proc/loadavg` on the study box does not decay and is
   not an instrument here. `vmstat` decides whether the machine is quiet. This
   already cost one discarded run.

## What is predicted, in advance

Recorded so no result can be retrofitted into a story.

1. **OpenResty wins `/ping` clearly.** LuaJIT plus a C server front-end
   against an interpreter plus a Lua HTTP stack.
2. **Luvit beats akkar on `/ping`**, by less than OpenResty does.
3. **Lapis beats akkar on `/ping` by a modest margin** — same substrate, fewer
   invariants, so the delta should be small and it is the price of the
   invariants.
4. **akkar is competitive on D3** and possibly wins it, because the descriptor
   cost per request is the one thing here that has been measured and defended.
5. **akkar wins D6 outright.** No other candidate ships a single self-contained
   executable of its whole stack.
6. **The gaps narrow sharply on `/users/:id`** for everyone except Tarantool
   in its own-storage block, because everyone else waits on the same Postgres.

If the results contradict these, the results win and the prediction is
recorded as wrong — as it was for the checkpoint hypothesis, where the
refutation was sitting in the next column.

## The decision rule, written before the run

Specific, so it can fire against us.

| if | then |
|---|---|
| Lapis is **≥ 15 %** faster on `/ping`, same substrate | The invariants cost more than the thesis claims. It becomes a work item **with a number**, not a footnote. |
| Lapis is within **5 %** | The invariants are close to free on the same base, and that is the strongest single sentence akkar can say about itself. |
| Luvit is **≥ 2×** on `/ping` **and** **≥ 2×** on D3 | `akkar-substrate-luv` moves from parked to scheduled. libuv would then be beating cqueues on both throughput and the descriptor question, and taste stops being a reason to stay. |
| Luvit wins throughput but akkar wins D3 | The substrates trade off, and the parked experiment stays parked with a reason on file. |
| akkar loses D4 but wins D3 and D6 | **The runtime thesis survives and the messaging changes.** Stop quoting req/s as an argument; quote density and the artefact. |
| akkar loses D3 and D6 too | **The thesis is wrong as stated.** `docs/RUNTIME-1.0.md` and the README get rewritten to whatever is true, and the claim about no cohesive Lua platform comes out. |

That last row is the point. A comparison that cannot lose is an advertisement.

## What this cannot answer

Named rather than implied:

- **Whether any of them is fast enough.** That depends on a service, and
  `docs/UNKNOWNS.md` §10 is still the largest gap.
- **Ecosystem, hiring, documentation, tooling, or how it feels to use.** These
  decide adoption far more often than throughput, and this measures none of
  them. Luvit's decade of libuv is not on any of these tables.
- **Maturity or maintenance risk.** lua-http has had no release since
  September 2024 and carries two denial-of-service repairs in
  `akkar/substrate.lua`. That is a real fact about akkar's stack and no
  benchmark will surface it.
- **Anything about Lua as a language.** `WHERE-THE-GAP-IS.md` already
  answered that question and the answer was: not the language.
- **Correctness.** Every candidate here is assumed to answer correctly because
  Rule 1 checks the two routes it is asked about, and nothing else.
