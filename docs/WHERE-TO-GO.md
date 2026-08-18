# Where akkar can go from here — five options, priced

Written to answer one question with numbers rather than taste: **akkar is
8.4× slower than OpenResty. What, concretely, could change that, and what
would each cost?**

Every figure here was measured. Where something is an estimate it says so.

---

## What is known

### The gap

| | req/s | p99 |
|---|---:|---:|
| OpenResty (nginx + LuaJIT) | ~101,000 | 1.0 ms |
| Luvit (libuv + LuaJIT) | ~12,500 | 28–39 ms |
| **akkar** (Lua 5.4 + cqueues + lua-http) | ~11,800 | 10–13 ms |
| Lapis (same cqueues, same lua-http) | ~8,400 | 14 ms |

### Where a request's CPU goes

Measured by ablation — three servers answering the same wire bytes, driven by
the same client in the same process, so the absolutes carry the client and the
**differences are exact**:

| | µs/request | above the socket floor |
|---|---:|---:|
| bare cqueues socket server | 69.8 | — |
| + the vendored HTTP | 348 | **278 (66%)** |
| + akkar | 491 | 143 (34%) |

**Two thirds of the CPU above the socket is HTTP written in Lua.** akkar's own
chain — routing, validation, the request table, capabilities, the deadline —
is the other third.

That mirrors the allocation split measured separately (HTTP 54%, akkar 44%)
and is more lopsided still.

### What LuaJIT actually gives this code

The port is **done**: all 60 akkar files parse under LuaJIT 2.1, every rock
builds (cqueues, luaossl, lpeg, lua-cjson, lpeg_patterns, basexx, binaryheap,
fifo), and akkar loads and answers `{"pong":true}`.

**Measured on the study box**, same tree, same service file, same rock
versions and the same pinned cqueues commit in both arms, alternating
repetitions, servers restarted between each, zero non-2xx anywhere:

| | req/s | spread | p50 | p99 | µs/req at fixed cores |
|---|---:|---:|---:|---:|---:|
| Lua 5.4, one process | 12,083 | 1.9% | 8.09 ms | 9.75 ms | 82.8 |
| **LuaJIT, one process** | **19,603** | 2.1% | 4.57 ms | 6.65 ms | **51.0** |
| Lua 5.4, two processes | 24,122 | 3.5% | 4.07 ms | 4.60 ms | 82.9 |
| **LuaJIT, two processes** | **39,736** | 4.1% | 2.32 ms | 3.98 ms | **50.3** |

**1.62× to 1.65×**, against a largest spread of 4.1%, and the tail moves with
it — p99 9.75 → 6.65 ms — so it is not a mean-only win. The cleanest way to
state it is **82.8 → 51.0 µs per request at fixed cores, −38%**, which
reproduced within 0.7% across two independent topologies.

Where the gain is, by shape:

| workload | Lua 5.4 | LuaJIT | gain |
|---|---:|---:|---:|
| numeric loop | 0.252 s | 0.033 s | **7.6×** |
| work across a coroutine yield | 0.123 s | 0.037 s | 3.3× |
| `string.format` | 0.180 s | 0.091 s | 2.0× |
| table constructor, 4 keys | 0.143 s | 0.077 s | 1.9× |
| `string.match` on a header line | 0.400 s | 0.297 s | **1.35×** |
| akkar's own chain through `app:test` | 20.6 µs | 17.8 µs | 1.15× |

**AN EARLIER VERSION OF THIS PAGE REPORTED 1.15× AND IT WAS WRONG.** That
figure came from `app:test`, which skips the HTTP layer entirely — and the
HTTP layer is two thirds of the CPU. Measuring the least JIT-friendly third
and calling it the answer understated the gain by 40%. The in-process
instrument is fine for allocation, where it agrees with the socket, and it is
not fine for CPU.

`docs/PLAN.md` F3 fixed the rule in advance: **under 2× on `/ping`, LuaJIT is
refused with a number.** 1.62× is the number.

---

## The five options

### A — Stay on Lua 5.4/5.5 and keep cutting

**What it buys.** This session cut allocation 21.6% and gained 16.0% of
throughput, so the coupling is about 0.75. What is left, all measured:

| | bytes/request | notes |
|---|---:|---|
| the two per-request coroutines | 6,283 (55%) | **removable, not just reducible** — a long-lived worker measured ZERO per unit of work against 1,664 for a fresh coroutine |
| the two `headers` objects | 1,312 (11%) | |
| the `h1_stream` object | 737 (6%) | pooling it is the shape `SEGFAULT.md` distrusts |
| all request parsing | 152 (1.3%) | |

At 0.75 coupling, removing the coroutines would be worth roughly **+40%**.

**What it costs.** Weeks. And one design problem gates it: a worker pool and a
deadline-without-a-controller both need a safe way to abandon work, which is
what `spec/abandoned_defence_spec.lua` and `spec/pool_abandoned_wait_spec.lua`
are about. That problem has already produced one outage on the study box.

**Ceiling.** akkar's own chain is 34% of the CPU. Even perfect, this cannot
approach OpenResty — it gets akkar from ~11,800 to maybe 16,000–18,000 rps.

**Risk.** Low. Every step is measurable with an instrument that needs no quiet
machine.

---

### B — LuaJIT

**Refused, with the number: 1.62× against a rule that asked for 2×.**

38% of the CPU is real and it is not nothing. What it costs:

- **LuaJIT has no integer subtype.** `db.lua:57` chooses `int8` over `float8`
  from `math.type` — what `DECISIONS.md` calls the 3.91× fix. The measurement
  above exists **only because a shim was installed that lies**, returning
  `"integer"` for whole doubles, exactly as this project predicted it would
  have to. Without it `/users/42` does not answer at all; with it the 3.91×
  fix is silently advisory and `v.integer` becomes a comment.
- **The port is less done than "all 60 files parse" suggested.** A parse
  census cannot see a missing function. Running it found five more modules
  broken at load and run time: `math.type` (9 sites), `table.unpack` (14),
  `table.pack` (10), `utf8.len`/`utf8.offset` (4, in `safe_text`, on the
  per-header path) and `rawlen` (1). The remaining work is roughly the same
  shape and size as the work already done.
- LuaJIT 2.1 has been nominally beta since 2015.

**What the port bought anyway, and it should be kept:** `akkar/bitwise.lua`
and the `using(handle, fn)` helper are portable spellings that cost the
primary target 0.04% of a request, measured. They make akkar 5.1-compatible at
the syntax level for free, whether or not LuaJIT is ever adopted.

**Time spent: two days, and it is finished.** The answer is a number and the
rule was applied to it.

---

### C — OpenResty: akkar becomes a library

**What it buys, and now the split is measured.** The gap to OpenResty is 9.4×.
LuaJIT is **1.62×** of it, so nginx's C event loop and C HTTP parsing are
**5.8×** — and in absolute throughput it is more lopsided still: of the
~92,000 req/s difference, the language recovers ~7,500 (**8%**) and the C
server accounts for ~84,700 (**92%**).

An akkar that were entirely LuaJIT would land near 19,600 req/s and OpenResty
would still be **5.3× ahead**. **The gap is nginx, not PUC Lua.**

**What it costs, and this is the real number.** It is not a port, it is a
change of product:

- The process, the event loop, the connection lifecycle, the worker model and
  the timeouts become nginx's. `app:run` becomes `nginx.conf`.
- **The four invariants lose their substrate.** "All I/O goes through adapters
  the framework owns" is enforceable because akkar owns the loop. Under
  OpenResty the loop is nginx's and the sockets are cosockets.
- Every adapter is rewritten against `ngx.socket.tcp`.
- LuaJIT comes with it, so the integer-subtype problem in B arrives too.

**Estimate: months, and a different thing at the end.** "akkar, a Lua library
for OpenResty" is a legitimate product. It is not this one.

---

### D — A C HTTP layer under akkar's Lua

The measured version of "have our own nginx", and the only option here whose
value can be bounded from data already in hand.

**What it buys, bounded.** The vendored HTTP is 66% of the CPU above the
socket. If a C layer made it free — it would not — the ablation numbers give
491 µs → 213 µs, about **2.3×**. Realistically, with a C tokeniser, C framing
and C header representation, call it **1.6–2×**.

**Not 8.4×**, because akkar's own Lua chain is the other third and stays Lua.

**What it costs.**

- `akkar/vendor/http/` is 5,523 lines of Lua. Its C replacement is smaller for
  parsing and larger for everything else — connection state, framing, chunked
  encoding, the writer.
- **Framing is where request smuggling lives.** llhttp owns that logic and has
  the CVEs (2022-32213/32214/32215) to show for it. `docs/PLAN.md` F5a already
  concluded: C for tokenising, Lua for framing.
- 656 lines of existing framing, fuzz and encoding tests inherit on day one,
  which is the single strongest argument that this is even attemptable.
- It becomes a separate optional rock, like `akkar-pq`, so a C compiler never
  becomes a hard dependency.

**Estimate: 3–6 months to something trustworthy, then permanent maintenance
of a security-relevant C parser.**

**And one measured caution.** The allocation study found *all request parsing*
is 152 bytes of 11,450. Parsing is cheap in bytes and expensive in CPU, so a C
parser buys CPU only — which is exactly why this option is priced from the CPU
ablation and not from the allocation one.

---

### E — Our own runtime, end to end

**What it buys.** In principle, OpenResty's numbers. In practice this is
writing nginx and a Lua runtime and maintaining both.

**What it costs.** Years, and it changes what the project is. The gap to
OpenResty is not one thing to fix; it is a C server that has had twenty years
of people making it fast.

**Recorded so it is refused explicitly rather than drifted past.**

---

## What the numbers say, put plainly

1. **LuaJIT is refused.** 1.62×, measured on the study box, against a rule
   that asked for 2× — and it costs the integer subtype, with the lying shim
   in place for the measurement to happen at all.
   **22% of the OpenResty gap is the language; 78% is C.**
2. **Two thirds of the CPU is HTTP in Lua.** Anything that does not address
   that cannot be worth more than about 1.5×.
3. **akkar's own chain is one third**, and its largest single item — 55% of a
   request's allocation in two coroutines — is removable rather than merely
   reducible.
4. **The ceiling on staying pure Lua is roughly 1.5×**; on a C HTTP layer,
   roughly 2–2.3×; on becoming OpenResty, the full 8.4× at the cost of being a
   different product.

## The decision, taken 18 August 2026

**A now. D as a deliberate later decision. B refused with a number. C and E
not this project.**

`docs/LUARESTY.md` works through the four ways to take nginx's 5.8× -- akkar
as an OpenResty library, forking OpenResty, a C core inside akkar, and staying
pure Lua -- with what each keeps and loses of akkar's identity. The short
version of why C and E are refused: 78% of the gap is nginx being a
twenty-year-old C server, so competing with it means becoming one, and the
first invariant -- all I/O through adapters akkar owns -- stops being a
structural fact and becomes a rule people can break.

WHAT COMES FIRST, and it is not performance: F2 left an unexplained 16x p99
regression on `/users/42`. Correctness before speed.

A is weeks, measurable at every step, and worth perhaps +40% on its own — most
of what pure Lua has left. It also happens to be the work that makes D
cheaper, because a C layer under a leaner Lua chain is a smaller C layer.

The one thing to decide before starting D is not technical: **is 2× worth a
permanent C security surface?** That is a product question, and the honest
input to it is that akkar's competitive number is not OpenResty's — it is
Lapis's, on the identical substrate, where akkar is already **31% ahead**.
