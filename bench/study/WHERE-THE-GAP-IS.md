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

## 3. A real HTTP server in Lua is faster than Gin

The `cqueues` row above answers without reading anything, so it bounds the
event loop and nothing else. The obvious objection is that parsing is the
expensive part and the floor is therefore meaningless.

`floors.lua minimal` answers that objection. It is a real HTTP/1.1 server: it
parses the request line into a method and a path, walks the headers looking
for `content-length`, consumes a declared body, routes on the path and writes
a response. Same pinning, same generator, same bytes.

```
layer                            req/s        p50        p99   spread   cores us/req/core
cqueues, no parsing          169960.30   186.00us     3.31ms     1.7%    1.96        11.5
minimal real HTTP server     171329.79   255.00us     3.32ms     0.6%    2.00        11.7
lua-http, no akkar            34173.28     2.85ms     4.68ms     0.4%    2.00        58.5
akkar /ping                   19408.18     5.08ms     6.13ms     2.0%    2.00       103.0
gin, GOMAXPROCS=1            101584.35     0.98ms     2.32ms     1.2%    2.00        19.7
```

**Parsing and routing are free.** 11.5 µs without them, 11.7 µs with them. And
the minimal server runs at **171,330 req/s — 1.69x Gin on the same two cores.**

That settles the language question in the other direction from where it is
usually assumed. The 47 µs lua-http spends is not what HTTP costs in Lua. It
is what lua-http's design costs: stream objects, header objects carrying a
list and an index, an abstraction layer that also has to serve HTTP/2, and a
connection state machine.

## 4. And the collector is not the answer either

Before proposing that anyone rewrite akkar's 44.6 µs, it is worth knowing how
much of it is code rather than Lua reclaiming what the code produced. akkar
allocates about 2,166 bytes per request; the minimal server allocates a small
fraction of that.

`bench/study/gc-cost.sh`, same route, same everything:

```
collector                    req/s        p50        p99   spread   cores     us/req peak rss
default (shipped)         19135.49     4.33ms     7.50ms     0.7%    2.00      104.5     31MB
generational              19622.27     5.02ms     5.66ms     1.9%    2.00      101.9     29MB
incremental, lazy         19495.29     4.51ms    12.79ms     1.8%    2.00      102.6     42MB
STOPPED (probe)           19814.92     5.17ms     5.51ms     0.5%    2.00      100.9  10874MB
```

**With the collector stopped entirely — ten point nine gigabytes of resident
memory — akkar gains 3.5%.** That is the upper bound on what any collector
tuning could ever be worth, and it means the 44.6 µs is overwhelmingly work,
not reclamation.

One free thing did fall out: the **generational** collector is 2.5% faster and
cuts p99 from 7.50 ms to 5.66 ms on 2 MB less memory. Line of investigation 9
asked whether generational was better here. It is, mildly, and mostly in the
tail.

## 5. So what can actually be done

Stated with ceilings, because a direction without a ceiling is a wish. The
budget is fixed and small: **Gin costs 19.7 µs, and a real Lua HTTP server
costs 11.7 of them.** Everything a framework does has to fit in the remaining
**8 µs** for parity.

| change | akkar's µs/req | req/s | against Gin |
|---|---:|---:|---:|
| today | 103.0 | 19,400 | 0.19x |
| replace lua-http's hot path only | ~56 | ~35,700 | **0.35x** |
| that, and halve akkar's own cost | ~34 | ~59,000 | **0.58x** |
| parity with Gin | 19.7 | ~102,000 | 1.00x |

The last row is what the question really asks, so it is worth being exact
about what it demands: akkar's own code would have to go from **44.6 µs to
8 µs**, a 5.6x reduction, on top of a substrate that does not exist yet. The
collector cannot supply it — section 4 puts the whole collector at 3.5%. It
would have to come out of the router, the middleware chain, the request table,
the capability lookups, the deadline and the JSON encoder, which is to say out
of the things akkar exists to provide.

**So: parity on `/ping` is not a realistic target, and 0.35x to 0.6x is.**
Saying that plainly is more useful than implying otherwise, and the second
number is a 2x to 3x improvement on what ships today.

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

### But first: the direction of travel had reversed

While measuring all of the above, akkar's `/ping` came back at 19,135–19,622
across six independent runs. §2 of `RESULTS.md` published **20,648** the day
before, on this box, with this harness. On the same runs Gin reproduced within
**0.2%** and FastAPI within **0.1%** — the machine had not changed, akkar had.

`bench/study/regression.sh` alternates two trees per repetition and bisects it.
The 6.7% was two costs, not one, and both arrived with correctness fixes:

| commit | what it fixed | cost on `/ping` |
|---|---|---:|
| `d1e5d45` | seven resource leaks: capabilities, sockets, pool slots | −3.3% |
| `0ff3c80` | the two lua-http denial-of-service defects | −4.1% |
| everything else, ~50 commits | — | ~0 |

The first is a price worth paying and there is no obvious way around it: a
leaked pool slot per dropped connection is not a trade.

**The second was mostly accident.** The repair wraps `h1_stream:shutdown`, and
in HTTP/1.1 keep-alive a stream *is* a request, so every request built a
closure with two upvalues, inserted it into the instance table, and packed the
results of a `pcall` into a fresh table — to arm a guard that only matters when
there is something left to drain. Rebuilt with the guard function created once
at patch time, its state on the stream, and no `table.pack`: **HEAD is now
within 0.3% of the tree before the repair**, and the substrate specs and the
framing fuzz still pass. Net against the published number: −6.7% became −4.6%.

Which is the useful lesson here, and it is not about Gin. **Nothing was
watching.** A framework can lose 4% to an allocation in a patch nobody thought
of as hot, and the only reason this was caught is that a peer framework
happened to reproduce to 0.2% in the same table. That belongs in CI, not in
somebody's curiosity.

---

## 6. And the framing that matters more than any of it

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

## 7. What these measurements do not say

- **Three repetitions, not five.** Enough to see a 5x difference; not enough
  to claim a 5% one. The spreads are printed so nobody has to guess.
- **The cqueues floor is not a web server.** It reads until the blank line and
  throws it away. It bounds the event loop; it does not prove a real server
  could be built at 11.6 µs.
- **One route, no TLS, loopback.** A real network, a real payload and a real
  TLS handshake all move these numbers, and none of them was measured here.
- **The ceilings in section 3 are arithmetic, not results.** They say what the
  measured costs permit, not what anyone has achieved.
