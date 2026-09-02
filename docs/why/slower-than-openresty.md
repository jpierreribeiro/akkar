# Why akkar is slower than OpenResty, and what can be done about it

The honest position, in one page, because it was previously spread across seven
files that disagreed with each other.

akkar is **8.75x slower than OpenResty on `/ping`** (`bench/runtime/RESULTS.md`,
third run, 2026-08-19). That is the current number and the rest of this page is
about what is inside it.

Three claims up front, because each of them is the opposite of what people
assume when they hear "Lua framework":

1. **The language is not the ceiling.** A real HTTP/1.1 server written in PUC
   Lua 5.4 runs at **1.69x Gin** on the same two cores.
2. **Parsing is not the cost.** Parsing and routing measure 0.2 µs of a 103 µs
   request. Every C-parser proposal in this repository has been refused on that.
3. **The gap is widest exactly where the work is smallest.** On `/ping` akkar is
   0.17x of Gin; on a two-hundred-row database route it is 0.48x with a p99
   *below Gin's own*.

---

## 1. OpenResty's speed is nginx, not LuaJIT

This is the first thing to get right, because it decides whether the answer is
"change the VM" or "change the server".

The OpenResty candidate's whole `/ping` handler is in
`bench/runtime/openresty/nginx.conf:57-61`:

```nginx
location = /ping {
    content_by_lua_block {
        ngx.print('{"pong":true}')
    }
}
```

One interpreted Lua call, into a C function. Everything before and after it —
accept, read, parse, header table, write, keep-alive — is nginx, in C. Swapping
the VM underneath a handler that shape would not be expected to move it, and it
is reported elsewhere that swapping Lua 5.1, Lua 5.4 and LuaJIT under nginx does
not; **that control has not been run in this repository**, so it is named as
corroboration and not as one of this page's numbers. The measurement that *is*
here settles the same question from the other side.

`bench/study/COST-OF-A-REQUEST.md` splits the gap:

| | |
|---|---:|
| whole gap to OpenResty | **9.4x** |
| the language (LuaJIT, measured) | 1.62x |
| the remainder — nginx's C event loop and C parsing | **5.8x** |

In absolute throughput it is more lopsided still: of the ~92,000 req/s
difference, the language recovers ~7,500 (**8%**) and the C server accounts for
~84,700 (**92%**). An entirely-LuaJIT akkar lands near 19,600 req/s with
OpenResty still 5.3x ahead.

So "make akkar as fast as OpenResty" is not a Lua problem. It is a proposal to
write nginx.

---

## 2. Where the time actually goes

`bench/study/WHERE-THE-GAP-IS.md` is the central measurement in this repository
and the one everything else should be read against. Four servers plus a fifth,
all answering the same thirteen bytes, all pinned to the same two cores, same
generator, same run:

| layer | req/s | µs/req/core |
|---|---:|---:|
| cqueues, no parsing | 169,960 | 11.5 |
| **a minimal real HTTP server in pure Lua** | **171,330** | **11.7** |
| lua-http, no akkar | 34,173 | 58.5 |
| akkar `/ping` | 19,408 | 103.0 |
| Gin, held to the same two cores | 101,584 | 19.7 |

The `minimal` row is the one that reframes the argument. It is not a socket
echo: it parses the request line into a method and a path, walks the headers
looking for `content-length`, consumes a declared body, routes on the path and
writes a response. **11.5 µs without parsing and routing, 11.7 µs with them.**
Parsing and routing are free, and a real HTTP server in interpreted Lua beats
Gin by 1.69x on identical hardware.

Which means the 47 µs between the `minimal` row and the `lua-http` row is not
what HTTP costs in Lua. It is what **lua-http's design** costs: a stream object
per request, header objects carrying both a list and an index, an abstraction
layer that also has to serve HTTP/2, and a connection state machine.

Decomposed, akkar's 103 µs:

| | µs/req | share |
|---|---:|---:|
| cqueues — the event loop | 11.6 | 11% |
| **lua-http — parsing and writing** | **47.1** | **46%** |
| akkar — router, chain, request table, deadline, capabilities, JSON | 44.6 | 43% |

**This table is from 2026-08-16 and is the most-cited stale number in the
tree.** The vendored-HTTP allocation work that followed it removed 12.3–12.8%
of `/ping` and took CPU from 99.0 to 87.8 µs per request at a fixed 2.00 cores
(`bench/study/HTTP-OPTIMISATION.md`), and almost all of that came out of the
lua-http row. So the *shares* have moved in akkar's favour and nobody has
re-run the decomposition. Read 46/43 as the ranking, not as today's arithmetic.

### And it is not the collector

Before anyone proposes rewriting the 44.6 µs, `bench/study/WHERE-THE-GAP-IS.md`
section 4 priced the alternative. With garbage collection **stopped entirely** — 10.9
GB of resident memory — akkar gains **3.5%**. That is the upper bound on what
any collector tuning could ever be worth, and it says the 44.6 µs is work, not
reclamation. One free thing did fall out: the generational collector is 2.5%
faster and cuts p99 from 7.50 ms to 5.66 ms on 2 MB less memory.

### And it is not the harness, though some of it was

`bench/study/cpu-parity.sh` found Gin running on twice the hardware threads —
the same asymmetry that got `bench/compare/RESULTS.md` retracted. Held to the
same two cores Gin drops from 116,822 to 102,885 and the ratio goes from 6.08x
to 5.35x. **About 12% of the discrepancy was the harness. The rest is not.**

---

## 3. Is being slower a problem?

Not where the answer is usually looked for.

**`/ping` is akkar's worst case.** It is pure framework overhead with nothing
underneath it to amortise, and it is the only route where the comparison is
purely interpreter against compiled code. On a route that does what applications
actually do — `/rows/200`, two hundred rows out of Postgres, with the C driver
(`bench/study/RESULTS.md` section 2.1):

```
gin              7206.08     1.99ms     7.04ms     1.1%      1.00x
akkar-pq         3482.56     4.57ms     6.53ms     2.0%      0.48x
fastapi           880.59    17.92ms    23.94ms     1.9%      0.12x
```

**0.48x of Gin, 3.95x of FastAPI, and a p99 of 6.53 ms against Gin's own
7.04 ms** — the first row in that study where akkar's tail is not the worse one.
The gap is widest exactly where the work is smallest, and that is a real
property of the shape rather than a way of changing the subject: the more a
request actually does, the less the framework costs relative to it.

The second reason not to over-read the throughput number is that **the latency
gap is the throughput gap in other units.** `bench/runtime/RESULTS.md` measures
akkar's own service time at **117 µs** at one connection; throughput saturates
by sixteen connections and everything above that is queue. At a hundred
connections the p50 is 81x the service time, and three of the four candidates
sit exactly on Little's law. 91,829/10,038 is 9.15x and 9.78/1.08 is 9.06x —
the same number twice. A plan that treats "close the latency gap" as a separate
project from "close the throughput gap" is counting one thing twice.

That is not a claim that tail defects do not exist. One was found and fixed the
same week: a pool that woke every waiter produced a p99 of 5.42 s against a p50
of 5.9 ms, a ratio of 900. The healthy ratios above are 1.2 to 2.7.

---

## 4. Which gap number is current, and why the movement is not progress

`bench/runtime/RESULTS.md` contains **three different headline figures** for the
OpenResty gap. They are not a trend.

| run | date | figure | box | fixture |
|---|---|---:|---|---|
| first | 2026-08-17 | 11.2x | c5.2xlarge, **gone** | `bare`, two headers — retired |
| first, re-measured | 2026-08-18 | 9.15x | same box, **gone** | `browser`, six headers |
| second | 2026-08-18 | (9.39x, not published as a headline) | fresh c5.2xlarge, **gone** | `browser` |
| **third** | **2026-08-19** | **8.75x** | rebuilt box, CI recipe | `browser` |

**8.75x is current.** The file says the reason for the movement plainly and it
is worth repeating: all three came off different machines and two came off a
fixture that has since been retired. Nothing in akkar closed 11.2x to 8.75x.

The retired fixture is the larger of the two effects. Every measurement in this
repository used three short identical headers until 2026-08-18, and
`bench/study/COST-OF-A-REQUEST.md` measured what that hides: browser headers
cost +17%, a validated route +10%, and the two **together** cost 1.64x where
independent effects would predict 1.29x. `bench/study/lib.sh` and
`bench/runtime/run.sh` now default to `SHAPE=browser` and **print the shape with
every run**, because a run under one shape is not comparable with a run under
another and the only defence against comparing them by accident is that both say
which they were. `SHAPE=bare` restores the old form for comparison with anything
published before 2026-08-18.

The floors table in section 2 above is `bare`, on the first box, from
2026-08-16. Its internal comparisons are like-for-like and stand; its absolute
figures are not comparable with 8.75x.

---

## 5. What was tried, and what was refused

Every refusal here carries the measurement that refused it and the bar it was
measured against. Where two documents disagree about a refusal, both are named.

### LuaJIT — 1.62x, and two documents disagree about what that means

`docs/substrate/LUAJIT.md` is the sole authority for this number and it is
published in `README.md`. Same tree, same service file, same rock versions, same
pinned cqueues commit, alternating repetitions, zero non-2xx:

| | req/s | spread | p99 | µs/req |
|---|---:|---:|---:|---:|
| Lua 5.4, one process | 12,083 | 1.9% | 9.75 ms | 82.8 |
| **LuaJIT, one process** | **19,603** | 2.1% | 6.65 ms | **51.0** |
| Lua 5.4, two processes | 24,122 | 3.5% | 4.60 ms | 82.9 |
| **LuaJIT, two processes** | **39,736** | 4.1% | 3.98 ms | **50.3** |

**1.62x to 1.65x**, largest spread 4.1%, reproduced within 0.7% across two
topologies. `docs/PLAN.md` F3 set the bar at 2x in advance, so LuaJIT is refused
with a number.

Three things a reader should know before treating that as settled:

- **The page contradicts itself.** Its opening says *"the throughput half is
  still unmeasured and the decision is still open"* and its closing lists
  *"still to do, and it needs the study box: … then run `/ping`"*, while its
  middle section is headed **"THE ANSWER: 1.62x, REFUSED"** with the table
  above. The measurement is the current part; the framing around it was never
  updated. `docs/RUNTIME-1.0.md` sections 2 and 6 also still describe the spike as
  unrun.
- **The two decision rules disagree.** `docs/PLAN.md` F3 says under 2x is a
  refusal. `docs/RUNTIME-1.0.md` section 2 says under 1.5x closes the experiment
  permanently, 2x adopts it, and **anything between keeps it as
  `experiments/luajit`, unsupported**. 1.62x is "anything between". So the
  measurement refuses LuaJIT as a *supported target* and does not, under the
  later rule, close it.
- **The number was bought with a lie.** The LuaJIT arm needed a 31-line compat
  shim whose `math.type` returns `"integer"` for whole doubles, because
  `db.lua:57` needs that to keep binding `int8` — the "3.91x fix". LuaJIT has no
  integer subtype at all; every number is a double. So `v.integer` becomes
  advisory under LuaJIT, and that is a property of the runtime, not of the shim.
  The measurement is real; the configuration it was taken under is not one that
  could ship as-is.

### A C HTTP tokeniser — refused on 152 bytes, and the bar it failed

`docs/PERFORMANCE-PLAN.md` A4 is the proposal: picohttpparser for the request
line and header block, framing kept in Lua, shipped as a separate optional rock
the way `akkar.pq` is. It is **refused on evidence**:

> **all request parsing** — request line, headers, framing — **152 bytes**,
> **1.3%** of a request.

**That refusal is on allocation, and the bar it is measured against is stated in
CPU.** `docs/RUNTIME-1.0.md` section 3 wrote the bar in advance — *a component
earns C only when a measurement shows it is at least 30% of a route's CPU, and
the C version is proved to return byte-identical results before it is timed* —
and `akkar.pq` cleared it, row materialisation being 55% of a thousand-row
query. A4 then refused a tokeniser on **bytes**, and nowhere in this repository
does anyone reconcile the two axes. So here is the CPU side, written out as
arithmetic rather than as a result, because until now it did not exist:

Parsing measures 6.5–6.7 µs of an 83 µs request on this repository's own fixture
(**8%**), and 37–41 µs on a production-shaped one (**45–49%**) — but that second
figure was taken **before** the one-line fix below, which removed most of it.
What is left is on the order of **13–15% of `/ping`**. A tokeniser that
eliminated all of it is therefore worth roughly **1.15x** on akkar's worst
route, and against the README's own framing — an endpoint that spends four
milliseconds in Postgres — about **half a percent** of a real response. **It
fails the 30% bar on CPU as well as on bytes**, which is the reconciliation, and
it should be re-measured on the browser fixture before anyone leans on it.

Two further things a reader should know about that bar:

- **Nothing else in the repository cites it.** `docs/RUNTIME-1.0.md` section 3
  is the only place the 30% rule appears; it was proposed there and never
  adopted, restated, or applied by any other page. It is a good rule with no
  inbound references, which is how it came to be quietly bypassed.
- **`docs/RUNTIME-1.0.md`'s own table appears to say the opposite, and this is
  the one place these documents genuinely conflict.** Its section 3 candidate
  list reads *"HTTP request parsing + writing | 46% of `/ping` | yes, and it is
  the largest open one"*. That 46% is the whole lua-http **layer** — stream
  objects, header objects, the state machine, the write path — not the
  tokeniser. The layer clears the bar; the parser inside it does not. Reading
  that row as a case for a C parser is the same mistake the JSON row on the same
  page exists to prevent — and section 6 below says what the layer clearing the
  bar actually licenses now that akkar owns it.

The cost side is the other half of the refusal. Framing is where request
smuggling lives — a defect class first published in 2005 and still producing
CVEs in llhttp in 2022 (`CVE-2022-32213/32214/32215`) — so a C tokeniser buys
~1.15x on the cheapest possible route in exchange for owning a
security-relevant boundary in a memory-unsafe language.

One contained idea survives A4: `read_headers` runs an lpeg `Connection:match`
on every request, worth **72 bytes**. A two-string fast path for `keep-alive`
and `close` with lpeg as the fallback is an hour's work at low risk.

### Generated validators — refused on zero bytes

`bench/study/HTTP-OPTIMISATION.md`, 20,000 iterations, collector stopped:

```
validate, 4 fields, all present    152.0 bytes
just the cleaned output table      152.0 bytes
```

Identical. Pre-expanding schemas at route registration had already removed every
allocation validation used to make, and what remains is the table the caller
asked for. **Codegen would save zero bytes.** Its remaining case is CPU —
removing the `pairs(schema)` walk and the per-field dispatch — and that is a real
cost which this instrument cannot see, so it needs a CPU measurement before it is
worth building.

Two smaller ones measured zero for the same reason and are recorded so nobody
repeats them: `string.match` → `string.find` for header validation, and
`v:sub(-1,-1)` → `v:byte(-1)`. **Lua interns strings of 40 bytes or less**, so in
a header parser "this allocates a copy" is usually false. A lazy header index
measured **7 bytes** and was reverted, because it added an indirection to six
readers.

### The largest parsing win in this repository was one line of Lua

`bench/study/COST-OF-A-REQUEST.md`. The header-line pattern was
`^([^%s:]+):[ \t]*(.-)[ \t]*$`, and the lazy `(.-)` against an anchored trailing
`[ \t]*$` makes Lua's matcher advance one character at a time and re-try the
tail from every position — so the cost grew with the **value**, not with finding
the colon:

| line | old | new | |
|---|---:|---:|---:|
| 17 bytes | 1,186 ns | 717 ns | 1.65x |
| 68 bytes, padded | 3,636 ns | 1,606 ns | 2.3x |
| **113 bytes** | **6,693 ns** | **1,436 ns** | **4.7x** |

A greedy `(.*)` with the trailing whitespace removed by byte. On a
production-shaped request that is about **23 µs of 83, or 27% of the CPU**; on
this project's own benchmark it is worth 1.7%, which is why nobody had found it.

It was found by accident, and the accident is the argument: the fixture that hid
it was the thing under suspicion, not the parser. Equivalence was the whole
claim and is pinned by `spec/vendor_header_parse_spec.lua` — the old pattern
kept as the reference, compared on 36 hand-written shapes and 200,000 random
byte strings, because a faster header parse that disagrees is a parser
differential, and differentials between two implementations of one protocol are
how request smuggling works.

### What was taken, not refused: the C driver

The one C module worth having is `akkar.pq`, and it exists. `bench/driver/RESULTS.md`:

| | pgmoon | akkar.pq | |
|---|---:|---:|---|
| `/ping` @100 | 19,241 | 19,392 | **OVERLAPPING** — the control |
| `/users/42` @16 | 7,040 | **8,969** | 1.27x |
| `/rows/100` @16 | 2,392 | **5,031** | 2.10x |
| `/rows/1000` @16 | 333 | **928** | 2.79x |
| p99, `/rows/1000` @100 | 1300 ms | **475 ms** | −63% |

`/ping` is listed first on purpose: it touches no database, and the two variants
being identical there is what says the driver variable is not leaking into every
other row. **That row is also the model in one line — C where the mechanical
work is, Lua everywhere else, and no cost where there is nothing to accelerate.**

Two corrections on that page are load-bearing and both are on it. Its first run
was taken on a machine with twenty-two wedged servers spinning on it, and the
contamination **inflated** the result being sold, 3.01x reported as 3.91x. And
its section 5.4 objection — *"the C driver is faster and less consistent"* — was
investigated and **retracted**: measured at the same configuration, pq comes back
at 1.8% spread with zero anomalous windows, and the raggedness belongs to the
harness, where `SO_REUSEPORT` splitting six connections over two processes hits
**pgmoon harder** (37.3% spread against 30.5%).

pgmoon nevertheless remains the default, for a reason that has nothing to do
with speed: `akkar.pq_native` is a separate rock, so a default of `pq` would fail
at the first query for anyone who installed only `akkar`.

---

## 6. akkar owns the 47 µs. It has never redesigned it.

This is the most important open item and the one the older documents get wrong,
because they were written when the framing was different.

`akkar/vendor/http/` is not a dependency akkar routes around. **akkar has
assumed the fork.** `akkar/vendor/http/README.md` states the position without
hedging: *"Upstream's last release is v0.4 (2021) and its last commit is
2024-09-08, so there is no version to wait for."* akkar vendored ~10,100 lines
of it, diverged from it in the hot path, backported two post-release upstream
fixes by hand, and carries its own denial-of-service repairs inside it. That is
an orphan adopted, not a dependency pinned.

That changes the conclusion drawn from the same number. When the 47 µs belongs
to a dependency, it is a **fact you route around** — which is how
`docs/RUNTIME-1.0.md` section 6 reads it, ranking "write an HTTP fast path" fourth and
framing it as writing and then owning a parser. When it belongs to your own
fork, it is a **design you can change**. The honest statement of the open
question is therefore not *"should akkar write a C parser to get under
lua-http"*. It is:

> **akkar owns the layer that costs 47 µs, and has never redesigned it.**

Restructuring code you already own is cheaper than a C rewrite, carries no new
memory-unsafe boundary, and is aimed at **47.1 µs against the 13–15 µs a
tokeniser would target** — three times as much of the request, for none of the
new boundary. The evidence that the redesign is tractable is already on the
page: the allocation work took a request from 14,610 bytes to **5,376**, and the
two per-request coroutines that were 55% of it are 5.7% between them — all of it
by changing shapes in code akkar owns.

### The counterweight, which is real

Owning the fork means owning every future defect in **~10,100 lines** of vendored
Lua, with no upstream to inherit fixes from. That is not hypothetical, and the
cost has already been realised in the smallest possible way: **the provenance
ledger rotted, and it rotted within a day.** The old
`akkar/vendor/http/README.md` carried the divergence table in prose and
certified the two files holding akkar's HTTP/2 and WebSocket denial-of-service
repairs as untouched — while `akkar/vendor/http/h2_connection.lua` carries
twenty commented lines of the fix for the three-byte frame header that killed
the accept loop, at `read_http2_frame`. A re-vendor on the strength of that
table would have reverted every repair silently, with the whole suite still
green.

The repair is the right one and it is worth naming, because it is the same
method the rest of this page argues for: the ledger moved to
`akkar/vendor/http/PROVENANCE.md` and `spec/vendor_provenance_spec.lua` now
fails CI, naming the commit, if a patch is gone from the file the ledger claims
it is in. **Prose that nothing executes is how it went wrong once already.**
That is what the fork costs: not the rot, which was fixed, but the standing
obligation to build an instrument for every promise the fork makes.

Both halves belong in the decision. The fork makes the 47 µs addressable; it
also makes akkar the only maintainer of the code that produces it.

---

## 7. What is still open

**The HTTP fast-path spike — running now, no number yet.** A prototype that
parses the common request shape directly on cqueues, with lua-http as the
fallback for everything else. The question it answers is narrow and worth
stating so the result cannot be over-read: *how much of the 47 µs between the
`minimal` row and the `lua-http` row is recoverable by a fast path that a real
framework can actually stand on?* The `minimal` server is a floor, not a
proposal — it has no TLS, no HTTP/2, no chunked encoding, no trailers and no
connection state machine. The spike's number will say how much of the distance
between 11.7 µs and 58.5 µs survives contact with those. **It is not in yet, and
this section will carry it when it is.** `bench/study/WHERE-THE-GAP-IS.md` section 5
puts the arithmetic ceiling at ~56 µs/req, ~35,700 req/s, **0.35x of Gin** — and
labels it arithmetic rather than a result, which is the correct label.

**akkar's own 44.6 µs has never been decomposed.** The performance study
attacked the database path and found real things there; nobody has profiled the
framework path since. One data point exists: `akkar-lean`, which turns the
per-request deadline off, is 9% faster on `/ping` (21,415 against 19,454). One
feature is a tenth of the framework's own cost and the others have never been
priced.

**Validation has never been decomposed either.** `docs/RUNTIME-1.0.md` section 3 lists
it as *"unknown — measure before deciding"* and it still is. It is the one
candidate on that page where the bar cannot yet be applied, and
`bench/study/COST-OF-A-REQUEST.md` found that validation and browser headers
interact **superlinearly** (1.64x together against 1.29x predicted), so it is
not a small unknown.

**Three request shapes have never appeared in any number here.** Reading a
request body costs **2.47x**, opening a connection costs **1.88x**, and a 64 KB
JSON response costs **5.26x** and allocates 105 KB. Every benchmark on this page
is a keep-alive GET with a 13-byte response. The write path and the JSON encoder
scale worse than linearly in a way nothing is watching.

**The hyperthread deficit still ships.** `PROCS` defaults to physical cores, so
akkar leaves about 15% of available throughput on any box with SMT. That is a
sizing recommendation in `docs/RUNTIME.md`, not a code change, and it is the
cheapest item on this page. It is also not free: the fourth process lands on a
hyperthread sibling, and per-core throughput *falls* from 9,612 to 5,544.

**CI has never compiled `src/akkar_pq.c`.** The one C module this project
decided was worth having is the one its continuous integration does not build.
`src/build.sh` is invoked by no workflow, `akkar-pq-0.1.0-1.rockspec` is
referenced by none, and `.github/workflows/ci.yml:437` says so itself — *"Neither
job builds `pq_native.so`, so the C driver skips in both"* — including the
`integration` job that has a real Postgres beside it. The keeping-C-honest gate
in `src/build.sh` is `-Wall -Wextra`, and it only ever runs on somebody's laptop.
So the module that carries the strongest argument on this page for spending C is
the module with no automated coverage on any platform, and every driver number
here comes from a rock somebody installed by hand.

**Nothing is watching for regressions.** akkar lost 6.7% of `/ping` to two
correctness fixes and it was caught only because Gin happened to reproduce to
0.2% in the same table. Half of it was recoverable — a closure with two upvalues
and a `table.pack` per request, in a guard that only matters when there is
something left to drain — and the recovery brought HEAD to within 0.3% of the
tree before the repair. The other half is a leaked pool slot per dropped
connection, which is not a trade. **The useful lesson is not about Gin: a
framework can lose 4% to an allocation in a patch nobody thought of as hot.**
That belongs in CI, not in somebody's curiosity.

---

## 8. What this page does not say

- **Three repetitions, not five**, on the floors measurements. Enough to see a
  5x difference; not enough to claim a 5% one. The spreads are printed on the
  source pages so nobody has to guess.
- **Two of the three boxes no longer exist.** The absolutes in sections 2 and 5
  were taken on machines that were lost. Their internal comparisons are
  like-for-like and stand; comparing an absolute from one against an absolute
  from another does not.
- **The cqueues floor is not a web server.** It reads until the blank line and
  throws it away. It bounds the event loop. It does not prove a real server could
  be built at 11.5 µs — that is what the `minimal` row is for, and the `minimal`
  row is not a framework.
- **The ceilings are arithmetic, not results.** ~56 µs, 0.35x of Gin, ~1.15x for
  a tokeniser: all of them say what the measured costs permit, not what anyone
  has achieved.
- **One route, no TLS, loopback, one keep-alive connection.** A real network, a
  real payload and a real TLS handshake all move these numbers and none of them
  was measured.
- **The 46/43 split is from 2026-08-16 and predates a 12.5% cut**, most of which
  came out of the lua-http side. It has not been re-run.
- **`bench/study/RESULTS.md` section 8 retracted its own saturation sweep** — a table
  labelled median that was a best-of-three. Its retraction works out which
  conclusions survive; this page cites nothing from it.
- **Nobody has built an application on akkar.** Every defect named on this page
  was found by engineering an exposure. That is the largest gap in the evidence
  and no benchmark closes it.

## What to read next, and what has expired in it

- `bench/study/WHERE-THE-GAP-IS.md` — the floors, the decomposition, and the
  collector bound. The central measurement.
- `bench/study/COST-OF-A-REQUEST.md` — the per-request CPU and byte split, the
  parse-cost census, and the fixture audit that found 1.6x to 5x hiding in the
  request shape.
- `bench/study/HTTP-OPTIMISATION.md` — what was tried on the vendored HTTP path,
  including the three things that measured exactly zero.
- `bench/runtime/RESULTS.md` — the four-way comparison, its three headline
  figures, and its own account of which are withdrawn.
- `bench/driver/RESULTS.md` — the C driver, and two retractions worth reading
  for the method.
- `docs/substrate/LUAJIT.md` — the LuaJIT measurement and the syntactic
  inventory behind it. **Its opening and its closing paragraph still say the
  throughput half is unmeasured**; the section between them is the answer.
- `docs/PERFORMANCE-PLAN.md` — the refusals, item by item, with what each is
  worth. Note its own warning: every allocation figure in it is a **lower
  bound** on production, because the fixture interned every header value.
- `docs/RUNTIME-1.0.md` — the 30% bar, the layer model, and the ordering.
  **Written 2026-08-16 and not edited since, and four of its premises have
  expired.** It is still worth reading for the bar and the layer model; it is
  not a current statement of where the project is:

| premise | state |
|---|---|
| section 2 and section 6 item 3 — the LuaJIT spike is unrun, and its expected value has gone up | **expired.** Run and refused at 1.62x, `docs/substrate/LUAJIT.md` |
| section 6 item 1 — `akkar.pq`'s inconsistency is unexplained and is "the only thing between the project and a 2.79x" | **expired on both clauses.** Explained in `bench/driver/ANOMALY.md` as `SO_REUSEPORT` splitting connections in the harness, and it hits pgmoon harder. What keeps pgmoon the default is packaging: `akkar-pq` is a separate rock |
| section 2 — the LuaJIT shim inventory, and "roughly a week" | **expired.** The syntactic work is done, behind `akkar/bitwise.lua`; the counts in the table were never right, and the blockers that remain are semantic rather than syntactic |
| section 4 item 3 — "CI is `ubuntu-24.04` and nothing else, and ARM64 has been measured exactly once by hand" | **expired.** `.github/workflows/ci.yml` has a platform matrix — `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-14`. Cross-compilation is still not in CI |
| section 4 item 1 — `akkar run` is missing | **half expired, and now ambiguous.** The CLI subcommand shipped on 2026-08-16. The thing section 4 actually asks for — the built binary hosting a source file it reads at startup — is still listed as next in `docs/RUNTIME.md` |
