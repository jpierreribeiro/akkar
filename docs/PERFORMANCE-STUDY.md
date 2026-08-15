# Performance study

## Why this is a study and not a patch

An earlier framework of the owner's proved, twice and with numbers, that
**a symbol's share of a profile is not the gain from removing it**:

- buffer pre-sizing held 10.7% of the encode profile and measured **−2.6%
  ceiling** when done. The note left behind reads *"do not revive builder
  pre-sizing unchanged"*.
- a request-local RTTI cache held 6.86% and regressed **p99 by 17.8%**.

So every fix here has to be certified end-to-end against a noise floor derived
from the machine, not argued from a profile. That is what `bench/certify/`
exists for.

## What is being measured, and where

| | |
|---|---|
| Machine | AWS c5.2xlarge, 4 physical cores × 2 threads, whole cores pinned |
| Noise floor | 0.7% with pinning, derived per run |
| Baseline | `/ping` 28,850 req/s (34.7 µs/req); `/users/:id` 2,744 req/s |
| Peers | Gin 163,014 / 26,212 · FastAPI+uvloop 40,245 / 9,316 |

## The shape of the problem

Payload sweep, three frameworks, byte-equivalent responses:

```
rows    gin r/s   fastapi r/s   akkar r/s   akkar/gin   bytes
1        22,563       8,729      10,808       0.48         60
10       21,373       8,250       7,942       0.37        504
100      13,194       5,798       3,853       0.29      5,187
1000      2,912       1,489         555       0.19     54,690
2500      1,254         663         228       0.18    141,690
```

At one row akkar **beats** FastAPI. From ten rows on it loses, and the ratio
against Gin degrades continuously. **This is the "medium JSON" shape** the
owner reported hitting in the previous framework, reproduced here.

## Lines of investigation

Seven, run in parallel, because a single line of enquiry tends to find what it
went looking for.

| | Question |
|---|---|
| 1 | Where does the request path waste time, outside the database? |
| 2 | Why does one query cost 330 µs here against 32 µs through pgx? |
| 3 | What did the previous framework learn, especially about medium JSON? |
| 4 | What does published research say about optimising pure Lua 5.4? |
| 5 | How do we certify a fix end-to-end rather than trusting a profile? |
| 6 | Decomposed by stage, where does the payload degradation come from? |
| 7 | How much of the overhead is `lua-http` and `cqueues` rather than akkar? |
| 8 | What do the fast frameworks do that transfers to Lua? |
| 9 | Is the garbage collector part of the tail, and is generational better here? |

## Rules for this study

Taken from the previous framework's methodology, each earned by a mistake:

1. **Certify end-to-end.** Profile share predicts nothing. A/B the whole
   request against the noise floor.
2. **Read goodput and p50 together.** Two of their campaigns were discarded
   because a change moved the knee and the "ceiling" column started reporting
   the generator's rate rather than the server's capacity. A p50 in the
   hundreds of microseconds with ~100% of offered load served is service time;
   anything else may be queue depth wearing a latency label.
3. **Verify byte identity before comparing.** Their float rendering put 960
   extra bytes on the wire and invalidated an entire comparison row.
4. **Allocation is where a regression assertion can live.** It is exact and
   machine-independent; timing is not. Assert on bytes per request, record
   timing as a baseline.
5. **Look for the redundant pass first.** Their single largest cost was work
   the framework chose to do twice — revalidating what it had just serialised,
   re-tokenising what it had just parsed. That is a class of bug, not an
   instance.

## Findings

Recorded as they land, with the fix and its certification.

*(in progress)*
