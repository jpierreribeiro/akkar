# Handoff — 17 August 2026

For whoever picks this up, including you next week. What is waiting, what is
now known, what the vendoring left half-done, and where the programme actually
stands — in that order, because the first has a cost per hour and the rest do
not.

Rewritten rather than appended to. The previous version described a tree from
before lua-http was vendored and before Lua 5.5 ran.

---

## Waiting on you

**1. The benchmark box is unreachable.** `100.48.219.220` answered at 13:30 and
stopped by 18:00 — no SSH, no ping. There is no AWS CLI configured here, so
this needs the console. If the instance is not on an Elastic IP, a stop/start
changed its public address and the scripts need the new one.

Until it is back, **`bench/study/regression.sh` cannot run**, and that is the
only timing instrument this project trusts. Everything below that carries a
throughput number was measured before it went; everything that does not, says
so.

**2. PR #6 is open** — https://github.com/jpierreribeiro/akkar/pull/6 — and
nineteen commits have landed on the branch since. This session does not merge.

**3. Two things bill.** The EC2 above, and the Railway service
`akkar-deploy-test` from an earlier session.

---

## What we know now that we did not

### akkar is faster than the nearest comparable Lua framework

First measurement ever taken against the neighbours akkar actually has.
`bench/runtime/` — method written before any service existed.

| | req/s | spread | p99 |
|---|---:|---:|---:|
| OpenResty | 107,478 | 2.2% | 1.02 ms |
| Luvit | 11,831 | **25.6%** | 27–51 ms |
| **akkar** | **9,627** | 1.2% | 13.1 ms |
| Lapis | 8,244 | 1.6% | 15.2 ms |

**akkar is 16.8% faster than Lapis on the same substrate** — same cqueues, same
lua-http, same rocks. The prediction written in advance said Lapis would win.
It did not, and the decision rule had no row for that, which is recorded.

Luvit is faster in the middle and 2–4× worse in the tail, at 25.6% spread. For
a service runtime the tail is the number that matters. `akkar-substrate-luv`
stays parked, now on evidence rather than taste.

**The unfavourable number:** akkar costs **19.50 KB per idle keep-alive
connection**, the worst of the four. OpenResty is 46× cheaper.

### akkar runs on Lua 5.5

| | |
|---|---:|
| Lua 5.4 | 1,731 passing, 0 failures |
| Lua 5.5 | 1,672 passing, 0 failures, 2 pending |

The gap is fully accounted for: `pq_spec` and `db_spec`'s C-driver half skip
because `pq_native.so` is not built for 5.5, and `teal_spec` skips because `tl`
is not installed there. **Nothing fails.**

akkar itself needed **two lines** — Lua 5.5 makes for-loop control variables
const, and `etag.lua` and `static.lua` both reassigned one.

What is left is packaging, not code: luaossl's makefile does not list 5.5
(issue #221 open, and its C compiles clean), and cqueues vendors a
`lua-compat-5.3` from 2020 that stops at 5.4. One patch each, upstream.
`docs/substrate/LUA-55.md` has the whole account.

### The suite segfaults, and it is not ours to fix yet

Every recorded crash lands on one instruction: `table_LLRB_FIND` in cqueues,
walking a pollset's file-descriptor tree. **It predates every change made this
week.**

A controlled experiment implicated the controller pool: 3 crashes in 6 runs
with recycling on, 0 in 6 with it off. Then the fix was priced — **−6.9%
throughput and a 37% worse p99** — and put back, because p ≈ 0.09 does not buy
that. `docs/substrate/SEGFAULT.md` has the reasoning, and what would change the
answer: twenty runs an arm, or the actual defect.

### Where a request's bytes go

`bench/study/HTTP-OPTIMISATION.md`, measured rather than read:

| | |
|---|---:|
| one extra request header | +268 bytes |
| one extra response header | +292 bytes |
| one byte of body | +2.0 bytes |
| **fixed per-request overhead** | **~13,200 bytes** |
| — of which one stream object | 1,496 (3 conditions, 2 fifos, a 22-key table) |

**A warning about that instrument:** the benchmark sends identical requests,
and Lua interns strings of 40 bytes or less, so every header is interned after
the first request. Real traffic has varying cookies and user agents. **Every
figure there is a lower bound.**

---

## What the vendoring left pending

`akkar/vendor/http/` is 5,523 lines of lua-http's HTTP/1.1 half, with h2,
hpack, websocket and socks cut. Three things it did not finish:

### 1. The rockspec declares the wrong dependencies — latent, not broken

The vendored code requires **`basexx`, `binaryheap`, `fifo`, `lpeg`,
`lpeg_patterns`, `zlib`**. The rockspec declares **none of them**. They arrive
transitively because `http >= 0.4` is still declared.

So `luarocks install akkar` works today, and breaks the moment somebody acts on
the obvious thought — "we vendor http, so drop the dependency". The fix is to
declare those six directly and demote `http` to what it now is: **a test-only
dependency**, used by the specs as an independent client so a symmetric framing
bug cannot pass its own tests.

### 2. `pq_native.so` is still a Lua 5.4 build

It is in the tree, and `spec/db_spec.lua` puts `./?.so` on `package.cpath`.
Under 5.5 it loads, reads its fields correctly, and core dumps on first use —
which is what the whole "Lua 5.5 is unstable" story turned out to be.

`src/akkar_pq.c` now stamps `LUA_VERSION_NUM` and `akkar/pq.lua` refuses a
mismatch, so this is an error rather than a segfault **for builds made from
here on**. The `.so` in the tree predates the marker and is allowed through.
Rebuilding it needs `libpq-dev`, which is not installed here.

### 3. The CI still installs upstream `http` and says why in a stale comment

`.github/workflows/ci.yml` explains the install order in terms of `http`
pulling in cqueues. Still true, still needed — the specs use upstream `http` —
but the comment reads as though akkar depends on it, and akkar does not.

---

## Where F2 to F6 actually stand

Honest reassessment. Two of them moved for reasons that were not in the plan.

### F2 — deadline as budget · **half done, half blocked**

**Done:** the deadline is a number the whole execution can read, keyed by
coroutine, and `req.http` bounds outbound calls by what is left. That closed a
cascading-failure defect that was in the tree: `http.lua` opened every call
with a fresh 10 seconds regardless of the caller's budget.

**Done:** `req.db` now bounds its wire call too, so a deadline actually stops
the query. That change alone surfaced three defects, each caught by an existing
test, and the third is the interesting one: the obvious fix — mark the
connection broken on any query failure — is **wrong**, and `spec/db_spec.lua`
says why in its own name.

**Blocked:** removing the controller. The plan assumed capability-bounded I/O
made it redundant. It does not — `spec/akkar_spec.lua` has a handler calling
`cqueues.sleep(2)` against a 0.15 s budget that must answer 503, and `sleep`
goes through no adapter. Capability bounds cover everything akkar mediates and
nothing it does not. **So the ~500-concurrent-request wall stands.**

### F3 — LuaJIT spike · **partly answered for free**

The Lua 5.5 work priced most of what the spike was for. LuaJIT's blockers are
semantic, not syntactic: `math.type` is load-bearing in five modules, the
compat shim's version **lies** (returns `"integer"` for integral floats), and
`<close>` appears four times in `static.lua`. Still worth a timeboxed run for
the throughput number, but the cost side is now known without spending a week.

### F4 — validator codegen · **unchanged, and cheaper than it was**

F0 already pre-expands schemas at route registration, which is the same
insertion point codegen needs. The hard constraint stands: `akkar.from_spec`
passes schemas that came from **data**, so a generator must never interpolate a
field name into source.

### F5 — the HTTP frontier · **the vendoring was its prerequisite, and it is done**

The C tokenizer is now an edit to our own code rather than a patch on somebody
else's. `bench/study/HTTP-OPTIMISATION.md` sizes four remaining wins and flags
the largest as the one to distrust: pooling stream objects is worth up to 1,496
bytes and is the same shape as the controller pool implicated in the segfault.

The 19.50 KB per idle connection is still unattacked. ~15 KB of it is lua-http
(Lapis pays the same) and ~4 KB is akkar.

### F6 — timing wheel · **unchanged, and still downstream of F2**

`timeout.c` is William Ahern's, MIT, O(1), same author as cqueues, and cqueues
does not embed it. For jobs, cron and idle-connection reaping — not the request
path, where the deadline is arithmetic now.

---

## What is done

- **F0** schema pre-expansion — −528 bytes/request, and the two spellings of a
  schema now cost the same
- **F1** Execution Scope, all four steps — −317 bytes/request, and
  `spec/execution_spec.lua` exercises the module with no `akkar` require
  anywhere, which is what proves the separation is real
- **Platform matrix** — Linux x86-64, Linux arm64, macOS arm64, all green
- **lua-http vendored**, both DoS repairs folded into the source, monkey-patch
  retired
- **Lua 5.5** runs the suite
- **`.gitattributes`** — the language bar counted 5,523 lines of lua-http as
  akkar's own

---

## If you have an hour

Rebuild `pq_native.so` (needs `libpq-dev`) and re-run the 5.5 suite. It is the
only thing between "1,672 passing with 2 pending" and a clean 5.5 story.

## If you have a day

Fix the rockspec dependencies. It is a latent break, it is well understood, and
it is the difference between `luarocks install akkar` working by accident and
working by design.

## If you have a week

Get the box back and run `bench/runtime/run.sh` again. Four of this session's
measurements have no throughput number beside them, and the 16.8% Lapis margin
is now the most sensitive regression detector this project has — it compares
akkar against the same substrate, so a hot-path regression shows there first.
