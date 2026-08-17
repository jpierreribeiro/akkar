# akkar against the neighbours it actually has — first numbers

Run against `bench/runtime/METHOD.md`, which was written before any service
existed. The predictions and the decision rule in that file were fixed in
advance, and two of the predictions turned out wrong. Both are recorded below
rather than quietly dropped.

```
machine   : AWS c5.2xlarge, 8 vCPU, 4 physical cores x 2 threads
idle gate : vmstat 100% idle before the run  (/proc/loadavg on this box does
            not decay and is not an instrument)
cores     : generator 0,4 -- services 1,2,3,5,6,7
processes : ONE per candidate. Not two. See "what these numbers are not".
load      : wrk -t4 -c100, 5 repetitions of 10s, outer loop = repetition
body      : every candidate answers the same 13 bytes, {"pong":true}
akkar     : 9f00705 (main, with the platform matrix)
date      : 2026-08-17
```

Versions, resolved rather than assumed:

| | |
|---|---|
| akkar | Lua 5.4.6, cqueues + lua-http from `~/.luarocks` |
| Lapis | 1.19.0, **on `lapis.cqueues`** — the same cqueues and lua-http rocks akkar reads |
| Luvit | 2.18.1 (luvi 2.14.0, LuaJIT) |
| OpenResty | 1.31.1.1 (nginx + LuaJIT) |
| Tarantool | 3.8.0 — installed, **not yet measured**, see below |

## D4 — throughput and tail on `/ping`

| candidate | mean req/s | spread | p50 | p99 | vs akkar |
|---|---:|---:|---:|---:|---:|
| **OpenResty** | **107,478** | 2.22% | 0.92 ms | 1.02 ms | **11.2×** |
| Luvit | 11,831 | **25.60%** | ~6.2 ms | 27–51 ms | 1.23× |
| **akkar** | **9,627** | 1.16% | 10.1 ms | ~13.1 ms | — |
| Lapis | 8,244 | 1.58% | 11.8 ms | ~15.2 ms | 0.86× |

Zero non-2xx responses anywhere. Rule 1's equivalence gate passed for all four
before the clock started.

### The result that matters most, and it contradicts the prediction

**akkar is 16.8% faster than Lapis, on the same substrate.**

Prediction 3 said Lapis would beat akkar by a modest margin, because it stands
on the same base and carries fewer invariants. It does not. The floors are
1.16% and 1.58%, so 16.8% is an order of magnitude above the noise: by Rule 3
this is a result, not a difference.

What it does **not** license is "the invariants are free". Lapis and akkar
differ in more than four invariants, and this measures two whole frameworks,
not one feature. What it does license is narrower and still worth having: on
identical cqueues and lua-http, the akkar request path is faster than the
nearest comparable Lua framework's, so **the invariants are not being paid for
in throughput.**

**And the decision rule had no row for this.** Its Lapis rows covered "≥15%
faster" and "within 5%" — both written assuming akkar would lose or draw. A
rule that only enumerates the ways you might be disappointed is a rule with a
blind spot, and this one had it.

### Luvit is faster in the middle and much worse in the tail

1.23× akkar's throughput and a better p50 (6.2 ms vs 10.1 ms) — and a p99 of
27 to 51 ms against akkar's 13.1 ms, with a **25.6% spread** across
repetitions where every other candidate sat between 1.16% and 2.22%.

The p99 also climbed monotonically across the five repetitions — 27.4, 35.6,
47.4, 47.3, 51.4 ms — which is the shape of something accumulating rather than
of noise. Not chased down here; recorded because it is exactly what D5
(saturation) exists to examine, and because a runtime whose tail grows over a
50-second run is making a different promise than its median suggests.

For a service runtime the tail is the number that matters. A p50 that is 40%
better and a p99 that is 2–4× worse is not a win.

### The 40 millisecond mistake, and why the first Luvit number was thrown away

The first run reported Luvit at **2,435 req/s across three repetitions with
0.06% spread**. A constant is the shape of a limit, not of performance, so it
was diagnosed rather than published: the first request on a connection took
0.45 ms and every one after it took **40.9 ms**. Nagle meeting delayed ACK —
the response leaves as two segments and the kernel waits for an ACK the peer
is holding.

Setting `TCP_NODELAY` per connection took Luvit from 24 req/s to 9,582 req/s
on a single connection, and latency from 40.67 ms to 111 µs.

Two things follow, and they point in opposite directions, so both are stated:

- The number 2,435 was about a socket option, and publishing it would have put
  Luvit at a quarter of akkar's throughput while measuring neither. A number
  that wrong in our own favour is worse than no number.
- Luvit does not set it for you. That is a real fact about the runtime's
  defaults — but it is a fact about a default, not about how fast libuv can go,
  and the table above uses the corrected figure.

## D1 — time to first response

| candidate | boot to first 200 |
|---|---:|
| OpenResty | 113 ms |
| Luvit | 113 ms |
| akkar | 114 ms |
| Lapis | 221–327 ms |

Nobody had ever measured akkar's. It is unremarkable, which is the useful
answer: boot time is not a cost akkar is paying.

## D2 — resident memory, idle

| candidate | idle RSS |
|---|---:|
| Luvit | 7.2 MB |
| Lapis | 12.9 MB |
| akkar | 13.3 MB |
| OpenResty | 17.8 MB |

## D3 — cost per idle keep-alive connection

200 connections opened, one request each, then parked.

| candidate | fds/conn | KB/conn |
|---|---:|---:|
| OpenResty | 1.000 | **0.42** |
| Lapis | 1.000 | 15.30 |
| Luvit | 1.000 | 15.48 |
| **akkar** | 1.000 | **19.50** |

**akkar is the most expensive of the four, and OpenResty is 46× cheaper.** For
a runtime that argues about density this is the unfavourable number in the set,
and prediction 4 — that akkar would be competitive here and might win — was
wrong.

**What this dimension did NOT measure**, stated because the descriptor column
invites the wrong reading: every candidate shows exactly 1.000 descriptors per
connection, which is the socket itself. akkar's two-descriptors-per-controller
cost applies to a request **in flight**, and a parked connection has none. The
concurrency wall near 500 concurrent requests is therefore untouched by this
table. Measuring it needs requests held open, not connections, and that is a
second pass.

## The decision rule, applied

| rule | fires? |
|---|---|
| Lapis ≥15% faster → invariants cost more than claimed | **No** — akkar is 16.8% faster |
| Lapis within 5% → invariants close to free | No — the gap is larger, in akkar's favour |
| Luvit ≥2× on `/ping` **and** ≥2× on D3 → schedule `akkar-substrate-luv` | **No.** 1.23× on throughput, 1.26× on D3. Neither reaches 2×, and Luvit's tail is 2–4× worse. |
| Luvit wins throughput, akkar wins D3 → substrates trade off, stays parked | Partially: Luvit wins throughput **and** D3, but by well under the threshold, and loses the tail |
| akkar loses D4 but wins D3 and D6 → thesis survives, messaging changes | Does not apply as written — akkar lost D3 |
| akkar loses D3 and D6 too → thesis wrong as stated | D6 not yet measured comparatively |

**`akkar-substrate-luv` stays parked, and now with evidence rather than
taste.** That is the clearest decision this run produced.

## What these numbers are not

- **Not two processes.** `bench/study/WHERE-THE-GAP-IS.md` measured akkar at
  19,408 req/s with two processes; this measures 9,627 with one, and 9,627 × 2
  ≈ 19,254 is close enough to be reassuring about consistency rather than a
  contradiction. Every candidate here got one process, which is what makes them
  comparable to each other, not to that table.
- **Not the same Lua.** OpenResty and Luvit are LuaJIT; akkar and Lapis are PUC
  5.4. That cannot be removed, and it is separately the thing the parked LuaJIT
  spike would price. A meaningful share of OpenResty's 11.2× is JIT, and this
  run cannot say how much.
- **Not nginx-free.** OpenResty is a C server with a Lua handler inside it.
  Comparing it to akkar is the point — akkar's README sells "no nginx in front"
  — but it is not a comparison of Lua code.
- **Not `/users/:id`.** Only `/ping` cleared the equivalence gate for all four.
  Lapis and OpenResty both 500 on the database route as configured; OpenResty's
  cause is known (its LuaJIT cannot load a Lua 5.4 `cjson.so`). Until they pass
  the gate there is no row, because a candidate that errors is not fast.
- **Not Tarantool.** Installed at 3.8.0 and not yet written against. Rule 7
  governs how it will be reported when it is.
- **Not D5 or D7.** Saturation and dependency-down are a second pass, and
  Luvit's climbing p99 is the first thing D5 should look at.

## Corrections this run made to itself

Kept because the method says a benchmark designed after seeing the result is
worse than a threshold picked after seeing it.

1. **Luvit's first number was Nagle**, not Luvit. Thrown out, diagnosed, re-run.
2. **Every percentile read `-`** in the first run. The parser matched wrk's
   `50.000%` form; wrk 4.2 prints `50%`. The tail — the whole question — was
   being silently discarded.
3. **`lapis.cqueues` was reported ABSENT** during provisioning by a bare
   `pcall` that hid `module 'http.headers' not found`. The backend was present
   all along. Concluding otherwise would have removed the one candidate that
   makes this comparison mean anything.
4. **The akkar checkout on the box was at `063677e`** — before the platform
   matrix, before the substrate regression repair, before the 408 fix. Reset to
   `origin/main` before anything was measured.
