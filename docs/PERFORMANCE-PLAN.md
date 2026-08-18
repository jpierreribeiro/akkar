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

### The decomposition, corrected — the first version of this plan had it wrong

An earlier reading said akkar was 18% of a request and the vendored HTTP 82%.
**That was wrong, and the way it was wrong is instructive.** It came from
subtracting `app:test`'s 2,118 bytes, and `app:test` runs outside a cqueues
controller — so `with_deadline` takes its `not cqueues.running()` branch
(`execution.lua:358`) and **never creates the per-request coroutine that
production creates.** The instrument was measuring a different code path and
saying so in a comment nobody connected to the arithmetic.

Measured properly, by building a vendored-HTTP-only server that answers the
same bytes and driving it with the same client:

| | bytes/request | share |
|---|---:|---:|
| bare cqueues socket server, same wire bytes | 1–2 | ~0% |
| **the vendored HTTP** | **6,233** | **54%** |
| **akkar** | **5,048** | **44%** |

### And 55% of a request is two coroutines

| | bytes/request | share |
|---|---:|---:|
| **lua-http's per-request coroutine** (`server.lua:476`) | **3,813** | 33.3% |
| **akkar's `with_deadline` coroutine** (`execution.lua:391`) | **2,288** | 20.0% |
| joint term of the two (nesting) | 182 | 1.6% |
| the two request/response `headers` objects | 1,312 | 11.5% |
| the `h1_stream` object | 737 | 6.4% |
| **all request parsing** — request line, headers, framing | **152** | **1.3%** |
| the whole write path, four short headers | 136 | 1.2% |
| **the entire connection and accept plumbing** | **3** | **0.03%** |

**The mechanism, measured:** a coroutine object is ~1.2 KB and the rest is Lua
**stack reallocation as the coroutine descends**. 40 non-tail frames cost
13,416 bytes; 200 frames cost 54,376. That is why the identical `cq:wrap` line
costs 2,368 bytes in a minimal lua-http server and 3,813 in akkar — same
allocation site, size set by the caller's call depth.

**This re-ranks everything below, and two items lose most of their case:**

- **A C tokeniser would be replacing 152 bytes.** Months of work, a new
  optional rock, and a security-relevant boundary to get right, for 1.3% of a
  request. Unless production-shaped headers change that number by an order of
  magnitude (see D4), it is refused on this evidence.
- **Coalescing the response write was already done by lua-http.** The write
  path buffers: `xwrite(…, "f")` for the status line and each header, `"n"`
  only at `write_headers_done` and the body. One `write()` for the header
  block, one for the body. There are no small syscalls to merge.

**The new first target is call depth**, which nothing in the previous plan
mentioned, because nobody knew a coroutine's cost was set by its caller's
stack.

### And the system calls

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

## Track A — where a request's bytes actually are

**The largest single target, and it is not what anyone expected.**

An instrument that would have attributed it was built and failed, and the
failure is structural: wrapping each lua-http method to report
`collectgarbage "count"` across itself attributed −944 bytes out of 11,636,
because every one of those methods **yields** inside cqueues coroutines — the
measurement window contains whatever other coroutines ran. There is no fix
short of a custom Lua allocator in C.

**So the method was ablation**: change or stub one thing, measure end to end,
restore, keep the number. Slow, and it is what produced every figure this
project trusts.

### A1 — the phase breakdown  ·  **DONE**, and it re-ranked the whole plan

The table in "Where things actually stand" is its output. Three things came
out of it that nothing in the previous plan anticipated:

1. **Two coroutines are 55% of a request.** Not parsing, not writing, not
   header objects — the per-request coroutines themselves.
2. **A coroutine's cost is set by its CALLER'S STACK DEPTH**, not by the
   coroutine. The object is ~1.2 KB; the rest is stack reallocation as it
   descends. 40 frames cost 13,416 bytes, 200 frames cost 54,376.
3. **All request parsing is 152 bytes.** The thing everyone assumed was the
   target is 1.3% of a request.

**A trap for whoever repeats it**, and it is worth reading before trusting any
follow-up number: with the per-request coroutine in place, ablation deltas are
**not additive** — a residual of 128 bytes across the read/write split, and
one change of two locals in `onstream` moved a reading by 1,267 bytes because
a frame-size change crossed a stack-reallocation boundary. With the coroutine
removed, the same ablations are additive to the byte. **Measure the ladder
both ways.**

### A2 — the two coroutines  ·  6,283 bytes, 55% of a request

**This is the whole of Track A now.** Everything else in it is rounding.

**lua-http's**, `server_methods:add_stream` (server.lua:475) — 3,813 bytes.
The ablation is a one-line change: call `handle_stream` inline from
`handle_socket`'s loop. It has been run: 108 specs across http, concurrency,
stream, slow_body, framing, shed, limit, abandoned, lifetime and
deadline_propagation pass. **Risk medium-high**, and the risks are nameable:
pipelined requests serialise (arguably already true — `req_locked` serialises
reads), a blocking handler stalls that connection's loop, CONNECT and upgrade
streams meant to outlive the request break, and `conn:onidle` / `cond:wait()`
at server.lua:171-173 becomes dead code that must be reasoned about rather
than left. A hybrid — inline unless `self.pipeline:length() > 1` — keeps both
properties.

**akkar's**, `with_deadline` (execution.lua:358) — 2,288 bytes. **Risk high:**
this coroutine *is* the abandonment mechanism, and `spec/abandoned_spec.lua`
and `spec/deadline_propagation_spec.lua` exist for it. Removing it is F2/B1,
blocked on a per-task deadline that costs no descriptor.

**Shortening the call chain is NOT the lever, and that is measured.** akkar's
stacks at the two `cq:wrap` sites are 6 and 8 frames — already short — and
`bench/study/coroutine-depth.lua` prices a frame at **64 bytes** in that
range, against a coroutine base cost of **1,216**. Removing two frames saves
128 bytes of a 6,283-byte problem. The mechanism from the Lua source agrees:
the initial stack is 45 slots (`BASIC_STACK_SIZE` 40 + `EXTRA_STACK` 5) at
~720 bytes plus a `lua_State` at ~280, which is the ~1.2 KB measured, and the
stack grows by **doubling** in 5.4 and by 1.5× in 5.5.

### The third option, and it measures ZERO

**Do not create a coroutine per request. Reuse one.**

A dead coroutine cannot be resumed — confirmed, `cannot resume dead
coroutine` — so there is no pooling of finished ones, and OpenResty-style
reset pooling would not help anyway: `luaE_resetthread` **shrinks the stack**,
so it saves the ~280-byte header and not the growth, which is the wrong half.

A **suspended** coroutine can be resumed for ever. `bench/study/coroutine-reuse.lua`
compares a coroutine per unit of work against one long-lived worker parked on
a condition, running whatever it is handed and parking again:

| | bytes per unit of work |
|---|---:|
| a coroutine per unit of work | 1,664 |
| **one long-lived worker** | **0** |

Not reduced. **Zero.** The worker's stack is allocated once at its high-water
mark and never again, and the condition handoff allocates nothing.

**So the 6,283 bytes — 55% of a request — are removable in principle rather
than merely reducible.** That is the largest single item in this document by a
wide margin.

### And it is the same design problem as B1

A worker pool and a deadline-without-a-controller need the identical thing:
**a safe way to abandon work.** Today the per-request controller provides it
by being throwable-away — the orphaned handler sits in a controller nothing
steps, so it is inert. Remove the controller (B1) or reuse the coroutine (here)
and an abandoned handler is running somewhere that outlives the request, wakes
after the 503 has gone out, and touches a connection already back in the pool.

`execution.release` is already idempotent and `db.lua` already marks a
connection broken on a passed budget, so half the machinery exists. What does
not exist is a test proving a late handler cannot touch a recycled connection.

**Write that test first.** It is the gate on both of the two largest wins in
this plan, and it is the only thing either of them is waiting for.

### A3 — the header write path

`write_header` builds `k .. ": " .. v .. "\r\n"` per header. Lua interns
strings of ≤40 bytes, so the benchmark's short headers may be free — and
**production headers are not short**. The allocation harness sends identical
requests, so every value is interned after the first: **every figure in
`HTTP-OPTIMISATION.md` is a lower bound on production.**

Worth measuring with realistic header lengths before deciding it matters.

### A4 — the C tokeniser  ·  REFUSED ON EVIDENCE, pending D4

picohttpparser tokenises the request line and header block; **framing stays in
Lua**, where `spec/framing_spec.lua` (261 lines), `fuzz_spec.lua` (232) and
`encoding_spec.lua` (163) already are. That split is not squeamishness: framing
is where request smuggling lives, llhttp owns that logic and has the CVEs
(2022-32213/32214/32215) to show for it.

Same shape as `akkar.pq`: a separate, optional rock, so libpq — or here, a C
compiler — never becomes a hard dependency of `luarocks install akkar`.

**A1 answered this and the answer is no.** All request parsing — the request
line, both headers, the framing decisions, the fifo push and pop — is **152
bytes**, 1.3% of a request. A C tokeniser would be months of work and a
security-relevant boundary to get right, in exchange for replacing 152 bytes.

The one contained idea that survives: `read_headers` (h1_stream.lua:445) runs
an lpeg `Connection:match` on every request, worth **72 bytes**. A two-string
fast path for `keep-alive` and `close` before the lpeg call, with lpeg kept as
the fallback, is an hour's work at low risk. Its only caller is `read_headers`.

This stays open only against D4: if production-shaped headers move the parsing
number by an order of magnitude, reopen it. Nothing else does.

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

Controllers that do not fit the pool are closed deterministically now, and
**that is measured: the wall is gone and it costs nothing.** Zero non-2xx at
`-c100`, `-c200` and `-c400` on the default `ulimit -n 1024`, descriptors
bounded exactly by `sockets + 2 × eventpoll + 3` with a peak of 482, and the
bistability that gave 0 / 5,721 / 5,826 errors on three identical runs now
gives 0 / 0 / 0. Three `regression.sh` runs, one of them isolated to the
single commit, put the cost at +0.1%, −0.3% and −0.3%, none clearing its
floor.

**Still true, and it is why B1 below is not cancelled:** this bounds the
backlog rather than removing the thing that creates it. Each in-flight request
still costs three descriptors, so the ~225-concurrent ceiling stands.

### B1 — remove the controller from the request path  ·  **the single best item in this plan**

**cqueues already gives a per-coroutine deadline for nothing, and akkar has
been paying an entire nested epoll instance to duplicate it.**

`cqueues.poll` accepts a bare number in its argument list as a deadline. The
manual says so ("A number value is interpreted as a simple timeout, **not** a
file descriptor") and `src/cqueues.c`'s `object_getinfo` has an explicit
`/* optimize simple timeout */` branch that never touches the descriptor path.
The deadline lands in a `struct timer` **embedded in `struct thread`**, on an
LLRB tree, and is fed straight to `epoll_wait`'s own timeout: no malloc, no
descriptor, no userdata. It is the same structure Go, libuv, libev and asyncio
all use — one loop timeout plus one sorted structure keyed by task.

Verified here, against the current implementation, same three outcomes
(completes / overruns / raises) from both:

| | descriptors after 200 calls | bytes per call |
|---|---:|---:|
| a controller per request, today | 8 → **30** | 2,216 |
| a bare number in `poll` | 6 → **6** | **1,624** |

**−592 bytes a request, and the descriptor growth is not reduced but gone.**
`cqueues.running()` returns the controller the connection is already in, so
the handler is wrapped onto that rather than onto a fresh one, and the
deadline is a Lua number — which is not a GC object at all, so there is
nothing for the collector to be late about. **That makes the failure in Track
B's opening paragraph categorically impossible rather than mitigated**, which
is strictly better than the deterministic `close` that ships today.

Prior art in this exact stack, and it is a measurement rather than an
assertion: lua-http issue #32 is the same defect, diagnosed by its maintainer,
with `/proc/PID/fd` showing `anon_inode:[eventpoll]` and `anon_inode:[eventfd]`
held by a nested controller the collector had not reached.

**One blocker remains, and it is the one akkar's own comment named**: an
abandoned handler moved to the shared controller keeps running, wakes after
the 503 has gone out, and touches a connection already returned to the pool —
trading a descriptor leak for a data bug. That is a real design problem and it
is now the ONLY thing between this plan and its largest win. `execution.release`
is already idempotent and `db.lua` already marks a connection broken on a
passed budget, so the pieces exist; what does not exist is a test that proves a
late handler cannot touch a recycled connection.

**Not `timeout.c`.** Two reasons, both checked. cqueues does not embed it and
does not need it — `src/cqueues.c` includes `lib/llrb.h` and no `timeout.h`,
and at n ≈ 225 in-flight a red-black tree is eight comparisons. And
`timeout.c`'s own page offers no benchmark at all, only "preliminary
benchmarking … very promising" from 2014. A timing wheel beats a tree at 10^5
timers, not at 225. **F6 is refused on this evidence** for the request path;
it stays open only for jobs and cron, where the counts might justify it.

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
