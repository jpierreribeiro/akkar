# Where the gap against Gin actually is

Asked a fair question after reading the comparison: *what justifies Gin's
result, and is there anything we can do about it, or is it a limit of the
language?*

`docs/PERFORMANCE-STUDY.md` listed the answer as line of investigation 7 —
*"How much of the overhead is lua-http and cqueues rather than akkar?"* — and
never ran it. Without it, "akkar is 5x behind Gin" cannot be split into the
part akkar could fix and the part it is standing on.

Two measurements, both on the study `c5.2xlarge`, both on `/ping`, which is
the framework path with no database in it.

```
machine   : AWS c5.2xlarge, Xeon 8124M, load 0.04-0.9 at start
cores     : servers 2,6,3,7 (2 physical, 4 threads), generator 1,5
processes : 2 each unless stated, count VERIFIED after every start
load      : wrk -t4 -c100, 3 repetitions of 10s, nearest-rank median
body      : every server answers the same 13 bytes, {"pong":true}
date      : 2026-08-16
```

---

## 1. First, the part that was the harness, not the framework

`SERVERS` is every hyperthread of the server cores — four vCPUs. `PROCS`
defaults to `SERVER_CORES`, which counts **physical** cores, so akkar ran two
single-threaded processes: two hardware threads out of four.

Go never agreed to that. `main.go` does not set `GOMAXPROCS`, so the runtime
takes it from `runtime.NumCPU()`, which reads the affinity mask and sees four.

So the published table had Gin on twice the hardware threads. That is the same
shape of asymmetry that got `bench/compare/RESULTS.md` retracted — *"a 2:1 CPU
handicap manufactures exactly that kind of outcome"* — and nothing in the
harness was checking for it.

`bench/study/cpu-parity.sh` measures CPU **consumed**, not CPU allowed:

```
configuration                        req/s        p50        p99   spread    cores
akkar x2 (as published)           19224.76     5.18ms     5.99ms     1.1%     2.00
akkar x4 (one per vCPU)           22121.34     4.42ms     5.85ms     1.7%     3.99
gin x2 (as published)            116822.31   639.00us     8.76ms     0.9%     3.94
gin x2, GOMAXPROCS=1             102884.93     0.97ms     2.20ms     2.1%     2.00
```

**The asymmetry was real and it explains almost none of the gap.** Held to the
same two cores Gin drops from 116,822 to 102,885, and the ratio goes from
6.08x to **5.35x**. About 12% of the discrepancy was the harness. The rest is
not.

Two things worth keeping from that table:

- **akkar x4 buys 15% for twice the CPU.** The second pair of processes lands
  on hyperthread siblings, not on idle cores, and siblings are not cores.
  Per-core throughput *falls* from 9,612 to 5,544. Section 3's "linear
  scaling" holds across physical cores and does not extend to threads.
- **Gin at `GOMAXPROCS=1` is 88% as fast on half the CPU, and its tail is four
  times better** — p99 8.76 ms to 2.20 ms. Its scheduler was costing it more
  than it was buying at this concurrency.

---

## 2. The decomposition, which is the answer

`bench/study/floors.sh` runs four servers that answer the same bytes, pinned
identically, at two cores each:

```
layer                            req/s        p50        p99   spread   cores us/req/core
cqueues, no parsing          169814.61   147.00us     3.30ms     0.4%    1.97        11.6
lua-http, no akkar            34097.77     2.93ms     4.62ms     1.5%    2.00        58.7
akkar /ping                   19352.57     5.20ms     6.02ms     2.0%    2.00       103.3
gin, GOMAXPROCS=1            102096.43     0.98ms     2.22ms     1.5%    2.00        19.6
```

- **cqueues** is a raw TCP socket, a hand-written 63-byte response and no
  parsing at all. It is not a web server; it is the ceiling of the event loop.
- **lua-http** is the substrate akkar is built on, with akkar removed: real
  parsing, real header objects, real write path.
- **akkar** is `app:get("/ping", ...)`, the published number.

### It is not the language

**The Lua event loop costs 11.6 µs per request. Gin costs 19.6 µs.** Raw
cqueues is **1.7x faster per request than Gin** on this box.

Whatever is making akkar slow, it is not that Lua cannot move packets. The
substrate is faster than the thing it is losing to.

### Where akkar's 103.3 µs goes

| | µs/req | share |
|---|---:|---:|
| cqueues — the event loop | 11.6 | 11% |
| **lua-http — parsing and writing** | **47.1** | **46%** |
| akkar — router, chain, request table, deadline, capabilities, JSON | 44.6 | 43% |

**The single largest item is lua-http**, and it is larger than everything
akkar itself does. Forty-seven microseconds to parse roughly eighty bytes of
request and write thirteen bytes of response.

---

## 3. So what can actually be done

Stated with the ceilings, because a direction without a ceiling is a wish.

**If every line of akkar were free**, akkar would be the lua-http floor:
34,098 req/s, or 0.33x of Gin. That is the hard bound on optimising akkar
alone, and akkar is currently at 19,353, so its own code is worth at most
**1.76x** — real, and not enough on its own.

**If lua-http's hot path were replaced** with something at, say, 15 µs, and
akkar's own cost were untouched, the stack would be 11.6 + 15 + 44.6 = 71 µs →
about 28,000 req/s. Both together, at the same optimism, land somewhere near
40,000 — roughly **0.4x of Gin instead of 0.19x**.

**Beating Gin on `/ping` would need the whole stack under 19.6 µs**, which is
below what lua-http costs today for parsing alone. That is not a realistic
target for a general framework, and saying so is more useful than implying it.

Three concrete directions, in the order their measurements justify:

1. **lua-http's request path is the biggest single line and the least
   defended.** It is pure Lua, has had no release since September 2024, and
   akkar already patches two denial-of-service defects in it at runtime
   (`akkar/substrate.lua`). A fast path that parses the common request shape
   directly on cqueues, falling back to lua-http for everything else, is the
   one change with 47 µs behind it. It is also the largest and riskiest, and
   `docs/substrate/RESULT.md` plus the executable substrate contract exist
   precisely to make that kind of move a measured step rather than a leap.
2. **akkar's own 44.6 µs has never been decomposed.** The performance study
   attacked the database path and found real things there. Nobody has profiled
   the framework path since. One data point already exists and is worth
   noting: `akkar-lean`, which turns the per-request deadline off, is 9%
   faster on `/ping` (21,415 against 19,454) — so one feature is a tenth of the
   framework's own cost, and there are others nobody has priced.
3. **Stop shipping the hyperthread deficit.** `PROCS` defaulting to physical
   cores costs about 15% of available throughput on any box with SMT. That is
   a sizing recommendation in `docs/RUNTIME.md`, not a code change, and it is
   the cheapest item here.

---

## 4. And the framing that matters more than any of it

`/ping` is akkar's **worst** case. It is pure framework overhead with no work
underneath it to amortise, and it is the only route where the comparison is
purely interpreter against compiled code.

On a route that does what applications actually do — `/rows/200`, two hundred
rows out of Postgres — akkar with the C driver is at **0.48x of Gin and 3.95x
of FastAPI**, with a p99 *below Gin's own*. See §2.1 of `RESULTS.md`.

The gap is widest exactly where the work is smallest. That is a real property
and it is the honest way to describe this framework's position: the more a
request actually does, the less the framework costs relative to it.

---

## 5. What these measurements do not say

- **Three repetitions, not five.** Enough to see a 5x difference; not enough
  to claim a 5% one. The spreads are printed so nobody has to guess.
- **The cqueues floor is not a web server.** It reads until the blank line and
  throws it away. It bounds the event loop; it does not prove a real server
  could be built at 11.6 µs.
- **One route, no TLS, loopback.** A real network, a real payload and a real
  TLS handshake all move these numbers, and none of them was measured here.
- **The ceilings in section 3 are arithmetic, not results.** They say what the
  measured costs permit, not what anyone has achieved.
