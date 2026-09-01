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

Two routes, eight dimensions. `/ping` is the runtime path with no database in it.
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

Eight dimensions, each with a reason to exist:

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

**D8 · Per-request HTTP/2 cost, against HTTP/1.1 on the same routes.** Not a
fifth candidate and not a faster number: the same akkar, the same two routes,
one protocol changed. What h2 *does* is established — h2spec 2.6.0 passes 146
of 146 and `spec/http2_admission_spec.lua` puts six requests down one
connection — but what a request *costs* on that path, with HPACK encode, frame
assembly and a coroutine per stream instead of one per connection, has never
been measured. `docs/HANDOFF.md:178-182` carries it in exactly those words:
*"Per-request h2 cost under load, including HPACK, framing, and stream
coroutines, is still unknown relative to HTTP/1.1."* This is the dimension
where a shipped subsystem is priced rather than announced. Its method is the
amendment at the end of this file, written — like everything above it — before
the generator was installed and therefore before any number could shape it.

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

---

# Amendment — D8, HTTP/2 against HTTP/1.1

**Written before the generator exists, and before any h2 number exists.** The
opening rule of this file is not a preface, it is the rule: a threshold picked
after seeing the result is a rationalisation, and a benchmark designed after
seeing the result is worse. `h2load` is not installed on this box. That is the
right moment to write this section and the only moment at which it can be
written honestly — once a generator is on the machine, every choice below is
available for retrofitting.

Nothing here is a measurement, a script, or a number taken from anything. The
one number-shaped statement in it is a prediction, and it is labelled as one.

## What D8 asks

> **On identical routes, with everything but the protocol held still, what
> does a request cost over HTTP/2 relative to HTTP/1.1 — and where does that
> cost sit: HPACK, framing, or the per-stream coroutine?**

The three named suspects are not decoration. h1 on this server hands a
connection to one coroutine that reads a request line and writes a status
line. h2 adds a header compressor with a dynamic table whose payoff depends on
how many exchanges share a connection, a frame layer that must assemble and
account for every write, and a coroutine per *stream* rather than per
connection. Those three amortise differently, so a single ratio would answer
the question badly even if it were true. The run has to separate them or say
that it could not.

## D8 is governed by Rule 7, and is not a comparison row

Rule 7 says: where a candidate cannot be equalised, measure both and label,
and *"a caveat in prose under a table nobody reads is not labelling."* D8 is
the second case of that rule, and it is a stronger case than Tarantool's,
because there is no version of it that produces a comparison row at all:

- **Luvit** is hand-rolled HTTP/1.1. `bench/runtime/luvit/serve.lua:23` takes
  Luvit's own `http` module and `:64` listens on it; there is no h2 in that
  path to ask for.
- **Lapis** has no HTTP/2 server of its own. On the cqueues backend this
  comparison requires (see prerequisite 1), what would be measured is
  lua-http's h2 — the same stack akkar vendors — which is not a second data
  point, it is the same one wearing a different name.
- **OpenResty** could speak h2, and does not here:
  `bench/runtime/openresty/nginx.conf:52` is `listen 8412 reuseport;` with no
  `http2`.

So D8 is realistically **akkar h1 against akkar h2**, and it is labelled that
way wherever it appears: its own block, its own heading, never a row beside
Luvit, Lapis or OpenResty. A protocol delta measured on one server is not a
ranking, and printing it in a ranking would make it read as one.

**The one promotion available, recorded so it is a decision and not a
discovery.** Adding `http2` to `nginx.conf:52` would make OpenResty a genuine
h2 comparison row. It is a configuration change, not a code change, which is
exactly why it must not be made quietly: it changes the candidate away from
the configuration that produced every published number in `RESULTS.md`. If it
is ever done, it is a separate, separately labelled run with its own noise
floor, and the h1 OpenResty numbers already on file are not reused beside it.

## The generator, and why it cannot be lua-http

**lua-http's client is disqualified by a bug that is documented in this
repository, with evidence.** `spec/http2_admission_spec.lua:32-37`:

> the h2 cases use a ceiling of ONE, so only one 200 is ever in flight. Two
> responses coming back together on one h2 connection make this client raise
> COMPRESSION_ERROR, and that is its bug, not the server's: the same three
> requests against a plain handler returning 503 reproduce it with no
> admission control anywhere, and a trace of the server shows its HPACK encode
> order and its wire order agreeing frame for frame.

Read as a benchmarking constraint, that is fatal and not merely awkward. The
spec's workaround is to keep exactly one response in flight — which is the
definition of not measuring throughput. A generator that must serialise
responses to avoid crashing itself cannot load an h2 server, and a generator
that crashes under load reports a number on the way down. Rule 1 exists
because *"a load generator being rejected still reports a number, and the
number looks like a number."*

**The generator is therefore external, and it is `h2load` from nghttp2.** The
deciding property is not that it is fast, it is `--h1`:

> **The same binary drives both legs, and only the protocol differs.**

Two clients would make D8 a comparison of two clients — their syscall
patterns, their buffering, their timing code — with the protocol as a
confound. One client with a protocol switch is what makes the delta
attributable. If `--h1` is absent or behaves differently from its
documentation on the installed build, that is a finding to record before the
run, not a detail to work around during it.

Two mechanical requirements, both already established practice here:

1. **Fetched and cached like h2spec, and pinned.** `bench/h2spec.sh:58-75` is
   the pattern: a cache directory, an exact version, a clear failure when no
   build exists for the platform. h2spec is pinned at `v2.6.0` and h2load gets
   the same treatment. On Ubuntu it is the `nghttp2-client` package, which is
   not installed on this box; whichever way it arrives, the resolved version
   goes in `RESULTS.md` beside the others, because an unpinned instrument
   makes two runs incomparable and nobody notices until they disagree.
2. **Pinned to its own physical core.** Rule 5: the generator gets one whole
   physical core, the services get the others, and splitting sibling threads
   leaves contention in place while looking like isolation.
   `bench/runtime/run.sh:273` already runs the generator under
   `taskset -c "$GEN_CPUS"`; h2load is threaded, so its thread count must fit
   inside that reservation rather than inheriting a default that walks off it.

## What the benched service needs, and what turning it on costs

**Today the benched akkar speaks HTTP/1.1 only.** `bench/runtime/akkar/serve.lua:44-60`
passes no `tls` and no `h2c`, so there is no ALPN negotiation to reach h2
through and no cleartext h2 either. Cleartext h2 is `h2c = true`.

**And it is opt-in for a reason that lands directly on this measurement.**
`akkar/init.lua`, in the `server.listen` options — quoted rather than cited by
line, because the line moves and a wrong citation is worse than a coarse one:

> CLEARTEXT h2 is `h2c = true` because the preface sniff it needs is a read on
> every connection, h1 ones included.

That single sentence forces the shape of the run, because it means an h1 leg
measured against an `h2c = true` process is *not* the same h1 as the one
already published. Three legs, and the arithmetic between them is the point:

| leg | service configuration | client | what it is for |
|---|---|---|---|
| **L1** | as shipped today, `h2c` absent | `h2load --h1` | connects D8 to the D4 numbers already in `RESULTS.md` |
| **L2** | `h2c = true` | `h2load --h1` | the h1 baseline the h2 leg is compared against |
| **L3** | `h2c = true`, same process configuration as L2 | `h2load` (cleartext h2, prior knowledge) | the h2 number |

- **L3 − L2 is D8's headline**, and it is the only pair in which nothing but
  the protocol differs.
- **L2 − L1 is the price of the flag** — the preface sniff, amortised over
  whatever a connection carries. It is reported separately and never folded
  into the protocol delta.
- **L3 must never be compared to L1**, and this is the trap the table exists to
  prevent: it would charge h2 with the sniff that h1 also pays under that
  configuration, and it would silently compare two different server
  configurations while looking like one clean number.

TLS is deliberately out. Everything above is cleartext, so nothing here prices
ALPN, handshakes or record framing — see *what D8 cannot answer* below.

## The load shape, which is where this measurement is easiest to get wrong

**h2 multiplexes and h1 does not, so "the same load" has two meanings and only
one of them answers D8.** At a fixed connection count `-c`, an h2 run with `-m`
streams per connection offers up to `c × m` requests in flight while the h1 run
offers `c`. Comparing those two directly measures what multiplexing buys and
calls it what a request costs.

- **D8's headline runs at equal requests in flight**, which means the h2 leg
  runs with one stream per connection. Multiplexing off, protocol on. That is
  the only configuration in which the delta is per-request cost.
- **Equal connections with `m > 1`** is run too, and reported in a separate
  block labelled *not a comparison* — same treatment Rule 7 gives Tarantool's
  own-storage numbers. It is context for what the multiplexing buys, and it
  must never appear in a row beside the equal-in-flight numbers.
- **What `-m` does under `--h1` is verified, not assumed.** h2load does not
  pipeline HTTP/1.1; if the flag is ignored rather than refused there, an
  operator can believe they equalised something they did not.

**Requests per connection is a parameter of this dimension, not an incidental
of the harness.** HPACK's dynamic table pays nothing on a connection's first
exchange and progressively more on every one after it, so a run of one request
per connection measures h2's worst case and a long-lived keep-alive run
measures its best. A single ratio taken at an unrecorded `n/c` is an artefact
of that ratio. At minimum two points, both recorded.

**Two ceilings bound the offered load, and crossing either measures the
refusal path instead of the serving path:**

- `h2_max_concurrent_streams` defaults to **100** per connection
  (`akkar/init.lua:3477`). It is enforced by the h2 layer with
  RST_STREAM(REFUSED_STREAM), which arrives before akkar answers anything.
- `max_concurrent` defaults to `descriptor_ceiling()` — **66% of the soft
  `RLIMIT_NOFILE`** (`akkar/init.lua:3185`, `:3190`) — and akkar's admission
  gate answers past it with a 503 and a `Retry-After`. h2 streams count as
  in-flight requests there, so `c × m` is what is measured against it, not
  `c`.

Both are recorded for every run, together with `-c`, `-m`, the request total
or duration, the resulting requests per connection, and the box's soft and
hard `RLIMIT_NOFILE`. **A run that does not record all of these is not
reproducible**, and a 503 or a REFUSED_STREAM under load is a Rule 1 failure —
non-2xx fails the run — not a lower number to publish.

## The output rules that already apply, cited rather than restated

Nothing new is invented for D8; the existing rules bind it, and two of them
bind it harder than they bind D4.

- **Rule 4.** n, min, p50, p95, p99, max, nearest-rank, **no mean**. h2load's
  summary line reports a mean and a standard deviation prominently; those are
  not reported here. Percentiles come from per-request records, taken
  nearest-rank so every published value is one the machine observed. A
  protocol difference that lives in the tail — head-of-line behaviour, a
  compressor's dynamic table warming up — is invisible in a mean, and the tail
  is the whole question.
- **Rule 3.** Every leg gets its own noise floor: ten repetitions of one
  identical configuration, spread in basis points. **A difference smaller than
  the larger of the two floors involved is not a result.** akkar's 0.7% floor
  was measured with `wrk`, on the h1 path, on the study box; it is not
  inherited by a different generator or a different protocol, and assuming it
  would be the mistake Rule 3 exists to prevent. L1, L2 and L3 each get a
  floor of their own.
- **Rule 5.** Generator on one whole physical core, services on the others,
  no split sibling threads, and each side's actual parallelism verified at
  runtime rather than read off its configuration.
- **Rule 4's alternating order.** Outer loop the repetition, inner loop the
  leg. Running L2 to completion and then L3 hands one of them a warm cache for
  its whole block, and the measured difference would be the order.
- **Rules 1 and 2.** Byte-identical responses on both protocols before the
  clock starts, and the same routes, the same validation, the same three
  fields, logging off. h2 returning a different body, a different status
  shape, or omitting a header h1 sends is doing different work, and doing less
  is not being faster.

## What is predicted, in advance

Continuing the numbered list above, and in the form `bench/study/saturation.sh:9-21`
uses — falsifiable, stated before the instrument exists, and scored afterwards
the way `bench/study/RESULTS.md:424-430` scored that run's four and found two
of them wrong. **Being wrong here is the finding, not an embarrassment.** The
magnitudes below come from mechanism, not from data; there is no h2 data.

7. **h2 costs more per request than h1 on `/ping`**, at equal requests in
   flight, and the gap clears the larger of the two noise floors. Predicted
   band: **5% to 25%** on that route. Mechanism: HPACK encode plus frame
   assembly plus a coroutine per stream, against a path that has one coroutine
   per connection. If h2 ties or wins, the per-stream machinery is not the
   overhead it has been assumed to be, and the deferral argument in
   `docs/HANDOFF.md:154-160` — which treats `h2_connection`, `h2_stream` and
   `hpack` as weight worth loading late — loses part of its footing.
8. **The gap collapses on `/users/:id`, to below the noise floor.** The same
   Postgres round trip sits on both sides and dominates; this is prediction 6
   applied to a protocol instead of to a candidate. If a protocol difference
   is still visible through a database round trip, the cost is larger than
   anything the framing layer alone should explain, and that is a defect to
   go and find rather than a number to publish.
9. **Per-request h2 cost falls as requests per connection rises**, because
   HPACK's dynamic table only earns anything after the first exchange. The
   one-request-per-connection point is h2's worst case. If the two points are
   indistinguishable, HPACK is not where the cost is, and the per-stream
   coroutine is — which would redirect any optimisation work away from the
   compressor entirely.
10. **The preface sniff is below the noise floor (L2 − L1)** at a keep-alive
    shape: it is one read at connection setup, amortised over every request
    the connection carries. If it is visible above the floor there, `h2c`
    costs more than that comment in `akkar/init.lua` implies, and that
    comment — which is the documented justification for the flag being opt-in
    — is wrong and gets rewritten to what was measured.

## The decision rule, written before the run

Specific, so it can fire against us.

| if | then |
|---|---|
| h2 is within the noise floor of h1 on `/ping` | The h2 path is cheap, and the lazy-loading argument for `h2_connection`/`hpack` is about boot time only. Say so, and stop implying a per-request price. |
| h2 costs **≥ 25%** on `/ping` | h2 is a feature with a bill attached. It gets documented as one, `h2c` stays opt-in with a measured reason rather than an argued one, and finding where the 25% sits becomes a work item **with a number**. |
| h2 costs more *and* the cost does not fall with requests per connection | HPACK is exonerated and the per-stream coroutine is the suspect. That is a substrate question, and it belongs beside the `akkar-substrate-luv` decision rather than in the h2 layer. |
| the equal-connections block shows h2 delivering materially more work than h1 | Real, worth saying, and **still not this dimension's number.** It goes in the labelled block under Rule 7 and never in the per-request row. |

## What D8 cannot answer

Named rather than implied, in keeping with the section above it:

- **Anything about h2 over TLS.** These legs are cleartext. Production h2 is
  almost always ALPN over TLS, and the handshake and record layer are not the
  protocol's cost — they would be measured together and reported as one number
  if this were run over TLS, which is why it is not.
- **Behaviour against a hostile or merely unusual peer.** `docs/UNKNOWNS.md`
  §8b records that hostile flow control and long-lived sockets are unmeasured;
  a well-behaved load generator will not surface any of it.
- **What a browser does.** h2load opens the connections it is told to open. A
  browser coalesces, prioritises, and cancels streams, and none of that is
  modelled here.
- **Whether h2 is worth enabling for a given service.** That depends on the
  client population and the route mix, and neither is a property of this
  server.
