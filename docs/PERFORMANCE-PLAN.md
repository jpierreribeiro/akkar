# Extracting the maximum from this stack

A plan for the performance work that remains, written after a pass that cut
allocation per request by 21.6% and bought 16.0% of throughput.

**The goal is not OpenResty.** It is 9.4× faster and always will be: it is
nginx in C with LuaJIT on top, and this is pure Lua 5.4 on cqueues. Saying so
in the first paragraph is not modesty, it is the thing that keeps this plan
honest — every item below is judged by what it is worth *within this stack*,
not by how far it closes a gap that this stack cannot close.

What this plan is for: the runtime is near the practical frontier of what it
is, and "near" is not "at". This is the list of what is still on the table,
with what each is worth where that is known, and what it would take to find
out where it is not.

---

## Where things actually stand

Measured on a reserved c5.2xlarge unless stated. `/ping`, one process except
where noted.

| | akkar | Lapis | Luvit | OpenResty |
|---|---:|---:|---:|---:|
| req/s | ~11,800 | ~8,400 | ~12,500 | ~101,000 |
| p99 | 10–13 ms | 14 ms | 28–39 ms | 1.0 ms |
| KB per idle connection | 6.96 | 15.24 | 15.52 | 0.42 |

Lapis is the comparison that means something: identical cqueues, identical
lua-http, identical rock tree. **akkar is 31% faster than it**, so the
framework's own request path is not where the cost is.

And the decomposition, measured this session:

| | bytes/request | share |
|---|---:|---:|
| akkar's own chain (`app:test`, no socket) | 2,118 | 18% |
| the client plus cqueues (bare socket echo) | 1 | ~0% |
| **the vendored HTTP** | **~9,330** | **82%** |

| | syscalls/request |
|---|---:|
| `read` | 3.10 |
| `epoll_ctl` | 2.01 |
| `sendto` | 2.00 |
| `epoll_wait` | 1.10 |
| `write` | 1.05 |
| everything else | ~0.6 |
| **total** | **9.84** |

**The coupling, which is the most useful number in this document:** a 21.6%
cut in allocation produced 16.0% more throughput, measured on two independent
invocations. Call it 0.75. It is one data point and it should not be trusted
past one significant figure, but it is the only thing that turns an allocation
figure — which is exact and free to measure — into a throughput prediction,
which is neither.

---

## The method, which is not negotiable

Every item below is judged the same way, and the rules were each earned by a
mistake this project actually made.

1. **Allocation is the cheap instrument.** Collector stopped, real socket,
   keep-alive, three byte-identical runs. It needs no quiet machine and it
   detects a 40-byte change. It is not throughput.
2. **Throughput comes from the study box or from nowhere.** A local timing
   number is not evidence, and this session produced a 24% "regression" on
   this laptop that was two research agents competing for the CPU.
3. **A difference below the larger of two noise floors is not a result.**
   `/users/42` gained 4.4% against a 6.5% spread this session and is written
   down as *not a result*, beside a `/ping` gain that was.
4. **Measure the condition the problem lives in.** The descriptor wall was
   measured with requests held in a sleeping handler — 3.00 per request, dead
   flat, and completely wrong, because nothing was finishing and so nothing was
   becoming garbage. The real consumer was completed requests awaiting the
   collector.
5. **Record the zeroes.** Three "obviously worth doing" optimisations measured
   exactly zero because Lua interns strings of ≤40 bytes. An unrecorded
   negative result is one somebody re-runs.
6. **A test that re-derives the formula tests nothing.** The descriptor
   ceiling's assertion computed `expected` with the same arithmetic as the
   code and then asserted `expected >= 16`.

---

## Track A — the 9,330 bytes in the vendored HTTP

The largest single target, and the one nobody can currently attribute.

**What is known:** it is 82% of a request's allocation, and the five cuts made
this session came out of it. **What is not known: where inside it.**

An instrument that would have said was built and failed, and the failure is
structural: wrapping each lua-http method to report `collectgarbage "count"`
across itself attributed −944 bytes out of 11,636, because every one of those
methods **yields** inside cqueues coroutines — the measurement window contains
whatever other coroutines ran. There is no fix short of a custom Lua allocator
in C.

**So the method is ablation**: change or stub one thing, measure end to end,
restore, keep the number. Slow, and it is what produced every figure this
project trusts.

### A1 — the phase breakdown  ·  in progress

Split the 9,330 by phase: reading the request line, reading and building the
headers object, writing the status line and headers, writing the body, the
stream object's lifetime, and teardown. Each measured by ablation.

**Until this lands, everything below in Track A is a guess.** That is why it
is first.

### A2 — coalesce the response into one write  ·  sized, not yet measured

`h1_connection` writes the status line and each header with cqueues'
`xwrite(s, "f", …)` — buffered — and then `write_headers_done` uses `"n"`,
which flushes. The body then flushes again. So a response leaves in **two**
system calls where a JSON reply, whose body is fully known before the headers
are written, could leave in one.

Worth roughly 1 of 9.84 syscalls per request. **It cannot be unconditional:**
a streamed response must flush its headers before the body exists, which is
the whole point of `akkar.stream`. So it is a flag on `write_headers`, set by
the caller that knows the body is already in hand.

Cheap to try, contained to two files, and `spec/stream_spec.lua` is the guard
that says whether the streaming path still behaves.

### A3 — the header write path

`write_header` builds `k .. ": " .. v .. "\r\n"` per header. Lua interns
strings of ≤40 bytes, so the benchmark's short headers may be free — and
**production headers are not short**. The allocation harness sends identical
requests, so every value is interned after the first: **every figure in
`HTTP-OPTIMISATION.md` is a lower bound on production.**

Worth measuring with realistic header lengths before deciding it matters.

### A4 — the C tokeniser  ·  F5a, months

picohttpparser tokenises the request line and header block; **framing stays in
Lua**, where `spec/framing_spec.lua` (261 lines), `fuzz_spec.lua` (232) and
`encoding_spec.lua` (163) already are. That split is not squeamishness: framing
is where request smuggling lives, llhttp owns that logic and has the CVEs
(2022-32213/32214/32215) to show for it.

Same shape as `akkar.pq`: a separate, optional rock, so libpq — or here, a C
compiler — never becomes a hard dependency of `luarocks install akkar`.

**Do not start this before A1.** If A1 says header parsing is 1,200 bytes
rather than 5,000, the calculus changes completely.

### A5 — pooling stream objects  ·  962 bytes, measured, and probably refused

The largest single remaining allocation win, and the one this project has the
most reason to distrust: recycling objects that hold sockets is the same shape
as the controller pool that is the leading suspect in
`docs/substrate/SEGFAULT.md`. It needs the same experiment, not the same
enthusiasm — twenty runs an arm, not six.

---

## Track B — the descriptor wall, which is capacity rather than speed

The only place akkar still **fails** rather than slows down.

A request in flight holds three descriptors: the connection socket, and two
for the cqueues controller that carries its deadline. With the usual
`ulimit -n 1024` that is 225 concurrent requests per process.

**And a fix this session was insufficient, which is worth keeping on the
record.** Dividing the descriptor limit by 3 instead of 2 was correct
arithmetic about the wrong consumer: the box still returned errors at `-c100`,
*below* the 225 ceiling, because the descriptors were held by **completed**
requests whose controllers the collector had not reached. 101 sockets, 460
eventpoll descriptors, resident memory flat. `max_concurrent` cannot bound
that, and no divisor can.

Controllers that do not fit the pool are closed deterministically now. **What
that costs is unmeasured** and is on the box.

### B1 — remove the controller from the request path  ·  F2, blocked

The real fix: 3 descriptors per request down to 1, and 225 concurrent becomes
675.

**It is blocked for a stated reason.** `spec/akkar_spec.lua` has a handler
calling `cqueues.sleep(2)` against a 0.15 s budget that must answer 503, and
`sleep` goes through no adapter. Capability-bounded I/O covers everything
akkar mediates and nothing it does not.

What would unblock it is a per-task deadline that costs no descriptor — a
timer heap or a hierarchical timing wheel, which is what every other
cooperative scheduler uses. `timeout.c` is William Ahern's, MIT, O(1), the
same author as cqueues, and cqueues does not embed it.

### B2 — the abandoned controller

A handler abandoned by its deadline leaves a NON-empty controller, still left
to the collector. Not what was measured — every request in that run completed
— but the same shape, and a storm of timeouts would build the same backlog.

### B3 — saturation, never measured

D5 of `bench/runtime/METHOD.md` has never been run. It is the dimension the
descriptor wall lives in, and the box is up with every candidate installed.

---

## Track C — the collector

**Mostly closed, and the closing is the useful part.** Stopping the collector
entirely — a configuration nobody can ship — buys **3.5%**. That is the hard
ceiling on every possible collector tuning, and it means this track cannot be
the answer to anything.

Generational mode was measured at +2.5% and p99 7.50 ms → 5.66 ms, and akkar
had never offered the setting at all. It does now (`app:run { gc = ... }`),
with the default left on Lua's own, because those numbers predate a 21.6% cut
in allocation and less garbage means less for a collector to be good or bad
at.

**C1:** re-run `bench/study/gc-cost.sh` at the current revision and decide the
default with a number. One afternoon on the box.

---

## Track D — what we have not asked

### D1 — is akkar CPU-bound or syscall-bound?

Partly answered this session: 9.84 syscalls per request, against 85 µs of CPU
per request. At roughly a microsecond a call that is on the order of a tenth
of the request. **Not dominant, so allocation and instruction count remain the
lever** — but it puts a number on how much A2-shaped work can ever be worth.

One syscall has already gone: `getpeername` was called once per request for a
value that cannot change on a connection.

### D2 — how much of the OpenResty gap is LuaJIT?

The largest unknown in the project. It is 9.4×, and nobody has split it
between the JIT and nginx-in-C. **F3 is a one-week timebox with its decision
rule written in advance**: below 2× on `/ping`, LuaJIT is refused with a
number and `docs/DECISIONS.md` gets a row.

The cost side is already priced without spending the week: `math.type` is
load-bearing in five modules and the compat shim's version **lies** — it
returns `"integer"` for integral floats, which is exactly the defect
`v.integer` exists to prevent — and `<close>` appears four times in
`static.lua`.

### D3 — where does the TAIL come from?

p99 is 10–13 ms against a p50 of 8.6. Nobody has decomposed it. Candidates:
collector pauses (Track C says at most 3.5% of throughput, but a pause is a
tail event and throughput is a mean), the accept loop, and head-of-line
blocking in a connection's coroutine. **For a service runtime the tail is the
number that matters** — this project's own words about Luvit — and it has had
less attention than throughput.

### D4 — production-shaped headers

Every allocation figure here was taken with identical requests, so every
header is interned after the first. Real traffic has varying cookies, user
agents and request ids. **Every number in `HTTP-OPTIMISATION.md` is a lower
bound**, and nobody knows by how much. A harness that varies header values is
half a day and would re-rank Track A.

---

## What is refused, with the evidence, so nobody re-proposes it

- **io_uring.** Naive swap for epoll: 1.06–1.10× (VLDB 2026), "frequently
  indistinguishable from baseline noise". This project's noise floor is 1.16%.
  It also pays above 50,000 concurrent connections, and our wall is 225.
- **`akkar.fs`, `.dns`, `.process`, `.udp`, `.tty`.** libuv territory with a
  decade of head start. akkar sits on top.
- **An in-process supervisor.** `docs/RUNTIME.md:168` marks it NOT NOW, and
  `akkar.vm` says of itself that it is not a boundary against hostile code.
- **Stopping the collector.** An instrument for bounding what tuning could
  buy, not a setting. A server that ships it does not run slowly; it runs out
  of memory.

---

## Order, and why it is not A1→D4

```
A1 phase breakdown ──┬──► A2 coalesce the write   (cheap, sized)
   (blocks the rest) ├──► A3 header write path
                     ├──► A4 C tokeniser          (months; A1 decides if)
                     └──► A5 stream pooling       (measured, distrusted)

B1 remove the controller ──► the wall, and D5 saturation
   (blocked on a per-task deadline with no descriptor)

C1 re-measure the collector   (one afternoon, decides a default)
D2 LuaJIT spike               (one week, timeboxed, rule written in advance)
D3 the tail                   (unstarted, and it is what a runtime is judged on)
D4 production-shaped headers  (half a day, and it re-ranks Track A)
```

Three of these are cheap enough to do before choosing anything expensive —
**C1, D4 and A1** — and two of them change how the expensive ones are ranked.
That is the order.
