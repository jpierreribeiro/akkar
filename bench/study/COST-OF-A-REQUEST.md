# What a request costs, and where the gap to OpenResty is

A measurement report. No recommendations — the numbers, how they were taken,
and what they bound.

---

## The candidates

`bench/runtime/`, one process each, `/ping`:

| | req/s | p99 |
|---|---:|---:|
| OpenResty (nginx + LuaJIT) | ~101,000 | 1.0 ms |
| Luvit (libuv + LuaJIT) | ~12,500 | 28–39 ms |
| **akkar** (Lua 5.4 + cqueues + lua-http) | ~11,800 | 10–13 ms |
| Lapis (same cqueues, same lua-http) | ~8,400 | 14 ms |

---

## Where a request's CPU goes

Ablation: three servers answering the same wire bytes, driven by the same
client in the same process. The absolutes carry the client, so they are not
comparable to anything else; the **differences are exact**.

| | µs/request | above the socket floor |
|---|---:|---:|
| bare cqueues socket server | 69.8 | — |
| + the vendored HTTP | 348 | **278 (66%)** |
| + akkar | 491 | 143 (34%) |

**Two thirds of the CPU above the socket is HTTP written in Lua.** akkar's own
chain — routing, validation, the request table, capabilities, the deadline —
is the other third.

That is more lopsided than the allocation split measured separately (HTTP 54%,
akkar 44%), which is expected: parsing is cheap in bytes and expensive in CPU.

**Reproduce:** `WHAT=bare|http|akkar lua5.4 cpuphase.lua`, twice per arm.

---

## Where a request's bytes go

`bench/study/HTTP-OPTIMISATION.md` has the full account. The summary, after
this session's cuts took a request from 14,610 to 11,450 bytes:

| | bytes/request | share |
|---|---:|---:|
| the two per-request coroutines | 6,283 | **55%** |
| the two `headers` objects | 1,312 | 11% |
| the `h1_stream` object | 737 | 6% |
| all request parsing | 152 | 1.3% |
| the whole write path, four short headers | 136 | 1.2% |
| the entire connection and accept plumbing | 3 | 0.03% |

A coroutine's cost is ~1,216 bytes plus 64 bytes per frame of the depth **it
itself** reaches — not the caller's depth, which costs 15 bytes at 200 levels.
A long-lived worker parked on a condition measured **zero** bytes per unit of
work against 1,664 for a fresh coroutine.

**The coupling between the two instruments:** a 21.6% cut in allocation
produced 16.0% more throughput, on two independent invocations. About 0.75,
and not to be trusted past one significant figure — but it is the only thing
that turns an allocation figure, which is exact and free to measure, into a
throughput prediction, which is neither.

---

## What LuaJIT gives, and the split of the OpenResty gap

Both arms the same tree, the same service file, the same rock versions and the
same pinned cqueues commit; alternating repetitions, servers restarted between
each, zero non-2xx anywhere.

| | req/s | spread | p50 | p99 | µs/req at fixed cores |
|---|---:|---:|---:|---:|---:|
| Lua 5.4, one process | 12,083 | 1.9% | 8.09 ms | 9.75 ms | 82.8 |
| **LuaJIT, one process** | **19,603** | 2.1% | 4.57 ms | 6.65 ms | **51.0** |
| Lua 5.4, two processes | 24,122 | 3.5% | 4.07 ms | 4.60 ms | 82.9 |
| **LuaJIT, two processes** | **39,736** | 4.1% | 2.32 ms | 3.98 ms | **50.3** |

**1.62× to 1.65×**, against a largest spread of 4.1%, with the tail moving too
— p99 9.75 → 6.65 ms. Stated portably: **82.8 → 51.0 µs per request at fixed
cores, −38%**, reproduced within 0.7% across two topologies.

Where the gain is, by workload shape:

| | Lua 5.4 | LuaJIT | gain |
|---|---:|---:|---:|
| numeric loop | 0.252 s | 0.033 s | **7.6×** |
| work across a coroutine yield | 0.123 s | 0.037 s | 3.3× |
| `string.format` | 0.180 s | 0.091 s | 2.0× |
| table constructor, 4 keys | 0.143 s | 0.077 s | 1.9× |
| `string.match` on a header line | 0.400 s | 0.297 s | **1.35×** |
| akkar's own chain through `app:test` | 20.6 µs | 17.8 µs | 1.15× |

### The split

| | |
|---|---:|
| whole gap to OpenResty | **9.4×** |
| the language (LuaJIT) | 1.62× |
| the remainder — nginx's C event loop and C parsing | **5.8×** |

In absolute throughput it is more lopsided: of the ~92,000 req/s difference,
the language recovers ~7,500 (**8%**) and the C server accounts for ~84,700
(**92%**). An entirely-LuaJIT akkar lands near 19,600 req/s, with OpenResty
still 5.3× ahead.

---

## Two instrument warnings, both earned

**`app:test` is exact for allocation and unusable for CPU.** It skips the HTTP
layer, which is two thirds of the CPU, so it reported LuaJIT at 1.15× where
the socket measured 1.62% — understating by 40%. It also runs outside a
cqueues controller, so `with_deadline` takes its no-controller branch and the
per-request coroutine production creates never exists.

**A parse census is not a load test.** Nine akkar files were fixed for LuaJIT
syntax and the sweep went clean; running it found five more modules broken at
load and run time — `math.type` (9 sites), `table.unpack` (14), `table.pack`
(10), `utf8` (4), `rawlen` (1). And the failure mode was a fast, well-formed,
empty-bodied 503 with no log line, which a load generator reports as forty
thousand requests a second.

---

## What parsing costs, and why the benchmark was hiding it

Measured in isolation, the actual patterns from `h1_connection.lua` against
the actual lines a request carries, 2,000,000 iterations, twice:

| | ns/call |
|---|---:|
| request line, `^(%w+) (%S+) HTTP/(1%.[01])\r\n$` | 921 |
| header line, short (17 bytes) | 1,087 |
| **header line, long (118 bytes)** | **6,401–7,151** |
| `name:lower()` | 196–219 |
| `headers:append` | 566–626 |

**A header line six times longer cost six times more to parse.** The pattern
was `^([^%s:]+):[ \t]*(.-)[ \t]*$`, and the lazy `(.-)` with an anchored
trailing `[ \t]*$` makes Lua's matcher advance one character at a time and
re-try the tail from every position — so the cost grew with the VALUE, not
with finding the colon.

Multiplied out against 83 µs of CPU per request:

| request shape | parsing | share of CPU |
|---|---:|---:|
| this project's benchmark: 1 line + 3 short headers | 6.5–6.7 µs | **8%** |
| production: 1 line + 8 headers, half of them long | 37–41 µs | **45–49%** |

**Every measurement in this repository used three short identical headers.**
A real browser request — `User-Agent`, `Cookie`, `Accept`, `Accept-Encoding` —
costs five to six times more to parse than the benchmark suggests. The same
warning already applied to allocation, because Lua interns strings of ≤40
bytes and the benchmark repeats them; here it applies to CPU, and by more.

**The fix was one line and needed no C.** A greedy `(.*)` with the trailing
whitespace removed by byte:

| line | old | new | |
|---|---:|---:|---:|
| 17 bytes | 1,186 ns | 717 ns | 1.65× |
| 68 bytes, padded | 3,636 ns | 1,606 ns | 2.3× |
| 113 bytes | 6,693 ns | 1,436 ns | **4.7×** |

On a production-shaped request that is about **23 µs of 83, or 27% of the
CPU**. On this project's benchmark it is worth about 1.7%, which is why nobody
had found it.

Equivalence was the whole claim and is pinned by
`spec/vendor_header_parse_spec.lua`: the old pattern is kept there as the
reference and the two are compared on 36 hand-written shapes and 200,000
random byte strings, because a faster header parse that disagrees is a parser
differential, and differentials between two implementations of one protocol
are how request smuggling works.

**Reproduce:** `lua5.4 bench/study/parse-cost.lua`.
