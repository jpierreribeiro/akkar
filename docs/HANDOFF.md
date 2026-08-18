# Handoff — 18 August 2026

For whoever picks this up, including you next week. What is waiting, what is
now known, and where the programme stands — in that order, because the first
has a cost per hour and the rest do not.

Rewritten rather than appended to. The previous version described a tree from
before the HTTP optimisation pass and before the benchmark box came back.

---

## Waiting on you

**1. PR #6 is open** — https://github.com/jpierreribeiro/akkar/pull/6 — and the
branch has moved a long way past it. This session does not merge.

**2. Two things bill.** The study box `18.205.2.122` (a c5.2xlarge, fully
provisioned and working), and the Railway service `akkar-deploy-test` from an
earlier session.

That is the whole list. The previous handoff's first item — an unreachable
benchmark box — is gone: there is a new one, `bench/runtime/provision.sh` now
brings a bare Ubuntu 24.04 image all the way up, and it has been exercised.

---

## What this session established

### The allocation cut became throughput, and it was measured

Five changes in `akkar/vendor/http/` took a request from **14,610 to 11,450
bytes**, each measured on its own and byte-identical across three runs.
`bench/study/HTTP-OPTIMISATION.md` has every step with its number, including
an estimate that was wrong by six times and why.

| | bytes/request |
|---|---:|
| before | 14,610 |
| two conditions nobody could wait on | 14,450 |
| ten `nil` keys that were only documentation | 14,070 |
| header index holds an integer until a name repeats | 12,290 |
| header entry flattened into parallel arrays | 11,660 |
| chunk queue built only when something is read ahead | **11,450** |

**−21.6%.** And on the reserved box, `/ping`, `38122ae` against `ed23e89`:

| | req/s | p99 | spread | µs/req at 2.00 cores |
|---|---:|---:|---:|---:|
| before | 20,192 | 6.38 ms | 0.8% | 99.0 |
| after | **22,783** | **5.42 ms** | 3.3% | **87.8** |

**+12.8%**, and an independent second invocation gave +12.3%. CPU per request
fell at fixed cores, so this is work removed rather than queueing rearranged.

On `/users/42` the same harness gives +4.4% against a 6.5% spread. **By Rule 3
that is not a result** and is recorded as one that does not clear the floor.

### akkar was returning errors under load, and nobody could see it

The important finding of the session, and it came out of running the benchmark
rather than reading code.

`descriptor_ceiling` in `akkar/init.lua` divided the descriptor limit by 2 —
the cost of a cqueues controller — and forgot that the request also holds the
connection it arrived on. Counted from inside a server process of its own,
holding N requests in a sleeping handler: **3.00 descriptors each**, flat at
50, 100 and 200 in flight.

So the ceiling promised half again as much concurrency as the box could serve.
On the usual `ulimit -n 1024` it offered 337 concurrent requests, which need
1,011 descriptors. At `wrk -c100` akkar answered **18,640 of 111,651 requests**
with `unable to initialize continuation queue: Too many open files`.

**Nobody saw it because the harness read the wrong `awk` field.** `parse_wrk`
took `$4` of `Non-2xx or 3xx responses: 18640` — the literal word
`responses:` — so a truthy string landed in the error-count column and the
gate read as a pass. The `bench/runtime/RESULTS.md` sentence "zero non-2xx
responses anywhere" was never verified by anything, and the 9,627 rps figure
beside it is now withdrawn.

Both are fixed. `spec/concurrency_spec.lua` now **counts** the descriptors
against a fixture server in its own process, and compares the ceiling against
what a real server derived — its old assertion re-derived the formula, divisor
and all, and then asserted `expected >= 16`, which is true for any divisor on
any box. A test that agrees with the code because it *is* the code cannot
report that the code is wrong.

### The 19.50 KB per idle connection was not where the plan said

`docs/PLAN.md` attributed ~15 KB of it to lua-http and ~4 KB to akkar, by
subtracting Lapis's figure from akkar's on the study box. Measured in-process
instead of by subtraction, holding 200 idle connections:

```
Lua heap, bare cqueues socket server   2,568 bytes/connection
Lua heap, akkar on vendored lua-http   3,415 bytes/connection
```

Everything akkar and lua-http hold above the cqueues floor is **847 bytes**.
Optimising our own tables was never going to move that number.

The memory is cqueues', and not on the Lua heap at all: every socket gets a
4 KB input and a 4 KB output buffer, malloc'd **eagerly** at creation, invisible
to `collectgarbage "count"` — which is why no allocation ceiling in this
project ever saw it. `app:run { socket_buffer = 1024 }` writes cqueues'
prototype; the buffers still grow on demand.

**And it costs nothing.** `strace -c` counted `read()` at 4096, 1024 and 512
over 300 requests, for a 13-byte JSON reply and a 256 KB one: identical on the
small payload, four calls different over 76 MB on the large one. The buffer
bounds what is preallocated, not what a read asks for.

Result on the box: akkar went from **worst of four** on that dimension to best
of the three that run a Lua VM.

**The 6.96 KB figure that used to be quoted here is withdrawn**, along with the
15.24 it was compared against. Neither is a per-connection cost: the instrument
divided a fixed per-process allocator step by the connection count. Re-measured
at two sizes, the same binary reports 10.24 KB at 200 connections and 6.40 at
800. `bench/runtime/RESULTS.md` §D3 carries the correction. The direction of
the result survives — the eager 4 KB buffers were real and shrinking them was
real — but the number does not.

### Lua 5.5 is done, C driver included

```
Lua 5.4    1,756 successes / 0 failures / 0 errors / 0 pending
Lua 5.5    1,750 successes / 0 failures / 0 errors / 1 pending
```

The pending is `teal_spec` skipping because `tl` is not installed — tooling,
not code. Building `pq_native.so` for 5.5 needed no root and no `libpq-dev`
install; `src/build.sh` had documented the route since it was written and
nobody had used it.

### The rockspec no longer works by accident

The vendored HTTP needs `basexx`, `binaryheap`, `fifo`, `lpeg` and
`lpeg_patterns`. The rockspec declared none of them; they arrived transitively
through `http >= 0.4`, so `luarocks install akkar` worked and would have
broken the moment somebody acted on "we vendor http, so drop the dependency".
All five are declared now, each with the file that needs it named beside it,
and `http` moved to `test_dependencies` — which is what it is: an independent
client, so a framing bug symmetric between our reader and our writer cannot
pass its own tests.

---

## The benchmark box, which is now reproducible

It was not. `bench/runtime/run.sh` starts four services out of `~/rt/svc` and
three of them were versioned in this repository; **akkar's was not.**
`rt-akkar-serve.lua` had been typed into a terminal on a machine that no
longer exists — the one candidate the whole comparison is about was the one
candidate nobody could rebuild.

Now: `bench/runtime/akkar/serve.lua` is in the tree, `bench/runtime/deploy.sh`
stages all four, and `provision.sh` gained four repairs it needed before it
could provision a genuinely empty box:

- **docker and `wrk` were assumed, not installed.** The first box had them
  from earlier sessions.
- **`m4` was missing**, and cqueues generates `src/errno.c` from an m4
  template. The build stopped right after printing "enabling Lua 5.4", which
  reads like a Lua problem.
- **The published cqueues rock does not build on Ubuntu 24.04.** CI already
  solved this by building from a pinned commit; the box gets the same one, for
  a better reason than convenience — measuring akkar on a substrate CI never
  tests would describe a configuration nobody ships.
- **The Postgres seed was not idempotent.** `on conflict do nothing` with no
  unique constraint meant the second run inserted ten thousand more rows, and
  `postgres rows: 20000` still answers every request correctly.

Five harness defects in `bench/` are fixed and each is commented where it
lives. The one that mattered is `parse_wrk` above.

---

## Where F2 to F6 stand

### F2 — deadline as budget · **half done, and the other half now has a number**

**Done:** the deadline is arithmetic the whole execution can read, and
`req.http` and `req.db` bound their wire calls by what is left. That closed a
cascading-failure defect: `http.lua` opened every outbound call with a fresh
ten seconds regardless of the caller's budget.

**Blocked, still:** removing the controller. `spec/akkar_spec.lua` has a
handler calling `cqueues.sleep(2)` against a 0.15 s budget that must answer
503, and `sleep` goes through no adapter — capability bounds cover everything
akkar mediates and nothing it does not.

**What changed:** the wall is no longer a projection. It is 3 descriptors per
in-flight request, measured, and the default `ulimit -n 1024` puts it at 225
concurrent requests per process. Before this session akkar would have
*claimed* 337 and failed at some number below it, loudly, in production.

### F3 — LuaJIT spike · **partly answered for free**

The 5.5 work priced most of it. LuaJIT's blockers are semantic: `math.type` is
load-bearing in five modules, the compat shim's version **lies** (returns
`"integer"` for integral floats), and `<close>` appears four times in
`static.lua`. Still worth a timeboxed run for the throughput number.

### F4 — validator codegen · **unchanged**

F0 already pre-expands schemas at route registration, which is the insertion
point codegen needs. The hard constraint stands: `akkar.from_spec` passes
schemas that came from **data**, so a generator must never interpolate a field
name into source.

### F5 — the HTTP frontier · **the allocation half is done**

−21.6% per request, +12.5% throughput, and the idle-connection number fixed.
What is left is the C tokeniser, and the largest single remaining allocation
win is the one this project has the most reason to distrust: pooling stream
objects is worth **962 bytes** (measured, down from the 1,496 first quoted)
and is the same shape as the controller pool implicated in
`docs/substrate/SEGFAULT.md`.

### F6 — timing wheel · **unchanged, still downstream of F2**

`timeout.c` is William Ahern's, MIT, O(1), same author as cqueues, and cqueues
does not embed it. For jobs, cron and idle-connection reaping — not the
request path, where the deadline is arithmetic now.

---

## An instrument that did not work, so nobody builds it twice

To find where the remaining ~9,344 bytes of a request live in the vendored
HTTP, every lua-http method was wrapped to report `collectgarbage "count"`
across itself, with the collector stopped and nesting attributed to the
outermost frame. It reported **−944 bytes attributed** out of 11,636 measured.

The reason is structural: **every one of those methods yields.** The window
between the two readings contains whatever other coroutines ran, and the depth
counter that suppresses nesting is shared across them. There is no fix that
keeps the shape short of a custom Lua allocator in C.

**Ablation is what works here** — change one thing, measure end to end, keep
the number — and it produced every figure in `HTTP-OPTIMISATION.md`.

---

## If you have an hour

Re-read `bench/study/HTTP-OPTIMISATION.md`'s "what is left" table and decide
whether the C tokeniser is next or whether F2's controller removal is. Both
are sized; neither is started.

## If you have a day

`bench/runtime/run.sh` has never measured Tarantool, and D5 (saturation) and
D7 (dependency down) have never been run at all. The box is up and every
candidate is installed. D5 is the dimension the descriptor wall lives in.

## If you have a week

F2's second half. The wall is now a measured number rather than an estimate,
which means the fix has a target: 3 descriptors per in-flight request down to
1, and 225 concurrent per process becomes 675.
