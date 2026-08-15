# Comparing akkar against Gin and FastAPI

Written before the services, and before any number exists. A threshold picked
after seeing the result is a rationalisation, and a benchmark designed after
seeing the result is worse.

## The question

Not "is Lua fast". The database dominates a real request in akkar by twelve to
one, already measured, so a comparison that is mostly Postgres would say
nothing about any of the three.

The question is narrower and answerable:

> **How much of a request is the framework, in each of the three, and does the
> difference survive contact with a database?**

Two routes answer it. `/ping` is the framework alone. `/users/:id` is the
realistic shape. The gap between them, per framework, is the useful figure —
and the comparison between those gaps is the result.

## What is compared

Go + Gin, Python + FastAPI, Lua + akkar. Those three because they are what the
owner actually writes, not because they are a representative sample of
anything.

## Rule 1 — semantic equivalence, and it is a gate

**Every candidate does the same work, and every response is verified. Not
sampled: every one.**

This is the rule that a reference study learned by throwing away an entire
ApacheBench comparison, because `ab` speaks HTTP/1.0, the strict HTTP/1.1
server rejected every request, and `ab` cheerfully reported 100% non-2xx as
throughput. **A load generator being rejected still reports a number, and the
number looks like a number.**

So, before any timing is recorded:

- each service answers both routes with byte-identical JSON for the same
  input, checked by diffing actual responses;
- each returns 404 with the same shape for a missing id, and 422 for a bad
  one, so nobody is fast by skipping error paths;
- `wrk` output is inspected for `Non-2xx or 3xx responses` and any socket
  error, and either fails the run.

And a rule this project added to that one, after a scaling run reported a
plausible flat line while seven of eight processes were dead:

- **the configuration is verified too.** Process count, listening sockets, and
  a successful request before the clock starts.

## Rule 2 — the same work means the same work

Where the three differ by default, the difference is removed rather than
excused:

| | |
|---|---|
| Validation | All three validate `id` as a positive integer and reject otherwise. akkar has a schema, FastAPI has Pydantic, Gin gets an explicit check. A framework that skips validation is not faster, it is doing less. |
| Serialisation | All three emit the same three fields. No framework gets to return a smaller object. |
| Database | The same query, the same driver style — pooled, async where the runtime is async. Pool size identical. |
| Logging | Off in all three. Writing a line per request measures the terminal. |
| Process count | Identical, and pinned to the same physical cores. |

Anything that cannot be equalised gets reported as a caveat rather than
absorbed silently into a number.

## Rule 3 — the machine decides the tolerance

Each framework gets its own noise floor: ten repetitions of one identical
configuration, spread reported in basis points. A difference smaller than the
larger of the two floors involved is not a result.

akkar's floor on this box is 0.7% with cores pinned. The others are unknown
until measured, and they will not be assumed.

## Rule 4 — distributions, alternating order, discarded warm-up

n, min, p50, p95, p99, max. Nearest-rank, so every reported value is one the
machine observed. No mean: a mean hides the tail, and the tail is the whole
question for a request pipeline.

Outer loop is the repetition, inner loop is the framework. Running all of one
framework's repetitions before touching the next hands the first a warm cache
for its whole block, and the measured difference would be the order.

## Rule 5 — topology-aware pinning

The box is 4 physical cores x 2 threads. The generator gets one whole physical
core; the services get the other three. Splitting sibling threads leaves the
contention in place while looking like isolation — this project already read
0.67x per-process scaling from exactly that mistake, and 1.00x after fixing it.

## What is predicted, in advance

Recorded so the result cannot be retrofitted into a story:

1. **Go wins `/ping` by a large margin**, likely several times. It is compiled,
   has real threads, and does not pay an interpreter per request.
2. **The gap narrows sharply on `/users/:id`**, because both are then waiting
   on the same Postgres.
3. **FastAPI is slowest on `/ping`** and closest to the others on
   `/users/:id`, for the same reason.
4. **akkar sits between them on `/ping`.**

If the results contradict these, the results win and the prediction is
recorded as wrong. If they match, that is worth knowing too, because it means
the ranking was predictable and the interesting number is the *magnitude*, not
the order.

## What this cannot answer

Named rather than implied:

- **Whether any of them is fast enough.** That depends on a service nobody has
  ported yet.
- **Developer velocity, ecosystem, hiring, tooling.** These decide framework
  choice far more often than throughput does, and this measures none of them.
- **Behaviour under a realistic mix.** One route at a time, uniform load.
- **Anything about Go, Python or Lua as languages.** Three implementations on
  one box on one afternoon.
