# Optimising the vendored HTTP half: the method, and where the bytes are

Written while doing it, so the wrong turns are in here too. They are the useful
part: three of the five things that looked obviously worth optimising measured
exactly zero, and knowing *why* is what stops the next person repeating them.

## Why this can happen at all

lua-http was monkey-patched at runtime until it was vendored. You cannot
optimise a library you are patching from outside — the patch has to be
defensive about a shape it does not own, and it pays for that defensiveness on
every request. `akkar/substrate.lua` cost 4.1% of throughput once for exactly
that reason.

Owning the source changes what is allowed. This page is what that bought.

## The instrument, and why allocation rather than time

Timing needs a quiet machine, a noise floor and repetitions. Allocation is
exact:

```
15,370 bytes/request
15,370 bytes/request
15,370 bytes/request
```

Three runs, byte-identical. **Zero noise**, so a 400-byte change is visible and
attributable without a benchmark box. That is `spec/allocation_spec.lua`'s rule
4, applied to a new target.

The harness is a real socket, keep-alive over one connection, collector
stopped, server and client in one process.

### What that instrument does NOT see, and it matters

**The client's share is ~1 byte.** Measured against a bare socket server
answering a fixed string: 1 byte/request. Not because the client is free, but
because **Lua interns strings of 40 bytes or less** and this client sends and
receives the same short strings every time.

That cuts both ways, and the second way is a warning: **the benchmark sends
identical requests, so every header name and value is interned after the first
request.** Real traffic has varying header values — cookies, user agents,
request ids — and those allocate. So every figure here is a **lower bound** on
production allocation, and the header-parsing costs specifically are understated.

## Finding the hot code: three attempts, two wrong

`debug.sethook` with a count hook is the right instrument. Getting it to see
the right code took three tries, and the failures are instructive:

1. **Hook installed in the driving coroutine.** Reported 76% in the client and
   0% in the server. `debug.sethook` is **per-coroutine**, and cqueues runs
   every connection in its own.
2. **Hook installed in the akkar handler.** Reported 5 samples out of 3,000
   requests. akkar runs handlers inside `with_deadline`, which wraps them in a
   *fresh nested coroutine per request* — so the hook died with the handler
   and never saw the HTTP layer at all.
3. **Hook installed in `handle_stream`, re-armed per stream.** Works: that runs
   in the connection's coroutine, and every stream gets its own.

The resulting profile is deterministic rather than statistical — the same
request executes the same instructions, so the sampler lands on the same lines
every time. That is fine, and arguably better: it is an instruction-count
attribution with no sampling error.

```
our lua-http    60.0%
akkar           26.7%
other           13.3%   (cqueues, cjson, lpeg, fifo)
```

## Where the bytes are, by differential

Reading code to guess had already been wrong once, so the split was measured by
varying one thing at a time:

| | slope |
|---|---:|
| one extra request header | **+268 bytes** |
| one extra response header | **+292 bytes** |
| one byte of response body | **+2.0 bytes** |

With 3 request headers, 3 response headers and a 13-byte body, that accounts
for about 1,700 of 14,939. **The remaining ~13,200 bytes is fixed per-request
overhead** — neither headers nor body.

By phase, probing at the boundaries the code already has:

| phase | bytes | share |
|---|---:|---:|
| before `onstream` | 2,809 | 18.8% |
| stream setup and read | 3,136 | 21.0% |
| **parse headers + akkar's handler** | **7,165** | **48.0%** |
| write the response | 1,824 | 12.2% |

akkar's own handler is 2,452 of that third row (measured separately through
`app:test`), so **header parsing is roughly 4,700 bytes**.

**Those figures are from the first pass and are kept for the method, not for
the numbers.** After the second pass below, the same three instruments over
`/ping` say:

| | bytes/request |
|---|---:|
| akkar's own chain, through `app:test` | 2,105 |
| the client plus cqueues, against a bare socket echo | 1 |
| everything, over a real socket | 11,450 |

so what is left in the vendored HTTP is about **9,344 bytes**, and akkar is
18% of a request rather than the 26.7% the profile above reported.

### What one stream costs to exist

`new_stream` runs once per request in HTTP/1.1. Priced piece by piece:

| | bytes |
|---|---:|
| `cqueues.condition.new()` × 3 | 289 |
| `fifo()` × 2 | 449 |
| the 22-key table | 840 |
| **total** | **1,496** |

Three conditions and two queues per request, for a protocol that in the
overwhelming case has one request in flight and no pipelining.

## What was changed, and what it was worth

**`never_index` removed from every header entry: −432 bytes, −2.8%.**

**Throughput is NOT measured for this change.** The study box became
unreachable before the run, and `bench/study/regression.sh` is the only
instrument this project trusts for timing. −432 bytes is what is claimed; a
percentage of requests per second is not, and 2.8% of allocation does not
imply 2.8% of anything else.

It is HPACK's flag — "never place this header in HTTP/2's dynamic table" —
which is why `authorization` and `cookie` default to true. HTTP/2 went when the
h1 half was vendored, so the field was carried on every header of every request
and read by nobody. A table constructor sizes its hash part by key count, so
three keys reserve four slots and two reserve two.

## What was tried and measured ZERO

Kept here because each looked obviously worth doing.

**`string.match` → `string.find` for header validation.** `match` returns the
matched text, so `k:match("^[^:\r\n]+$")` looked like it allocated a copy of
every header name. It does not: **Lua interns strings of 40 bytes or less**,
and header names are short. Zero bytes. The change was kept — it avoids the
interning lookup, which is not free even when the allocation is — but it is
honest that allocation did not move.

**`v:sub(-1,-1)` → `v:byte(-1)`.** Same story, same zero.

The lesson generalises: **in a header parser, almost every string is short, so
"this allocates a copy" is usually false.** Optimisations that assume otherwise
will measure nothing.

## The second pass: 14,610 -> 11,660 bytes, and where the estimates went wrong

Four changes, each measured on its own, byte-identical across three runs at
every step. **20.2% of the allocation of a request, gone.**

| | bytes/request | delta |
|---|---:|---:|
| before | 14,610 | |
| two conditions nobody could wait on | 14,450 | −160 |
| ten `nil` keys that were documentation | 14,070 | −380 |
| header index holds an integer until a name repeats | 12,290 | **−1,780** |
| header entry flattened into parallel arrays | 11,660 | −630 |
| `chunk_fifo` built on the first chunk read ahead | 11,450 | −210 |

### Two conditions nobody could wait on

`headers_cond` and `chunk_cond` were created per stream — so per request, in
HTTP/1.1 — and signalled in five places. **Nothing ever waited on either.**

That is not something the vendoring broke. Upstream's own `h1_stream` signals
them and never polls them; only `h2_stream` has real waiters
(`cqueues.poll(self.chunk_cond, ...)`), and h2 went when this half was
vendored. h1 does not need them by construction: a connection reads in one
coroutine and its streams are served by that same coroutine, so there is no
second party to wake. `get_next_chunk` looks in the fifo and, finding it
empty, reads the socket itself.

### Ten `nil` keys that were documentation

`new_stream` wrote twenty-one fields and ten of them were `nil` — there to say
what a stream may later hold. **Lua sizes the hash part of a table from the
syntactic key count in the constructor**, so those ten reserved ten slots that
held nothing and pushed the table from 16 to 32. Measured directly, 20,000
tables each way:

```
9 real keys + 10 nil keys : 850 bytes
9 real keys               : 466 bytes
```

They are comments now and say exactly the same thing.

**The obvious objection, checked rather than argued:** presizing to 32 means
later assignments never rehash, so removing the nils could have traded 384
bytes for a rehash and come out behind. The nine that remain plus the seven a
served request actually assigns come to sixteen, which is exactly what a
16-slot hash holds — and the harness confirmed it, 14,450 → 14,070. A rehash
would have shown up as no change, or as worse.

### The header index, and an estimate that was wrong by six times

The table above predicted **~270 bytes** for making `_index[name]` hold an
integer until a name repeats. It was **1,780**.

The prediction was not badly reasoned; it was reasoning about the wrong half.
It priced the WRITES — one `{n=1, i}` table per distinct header name — and the
cost was in the READS. `get` and `get_comma_separated` went through
`get_as_sequence` unconditionally, so reading one header allocated a table to
hold one string and threw it away, and `get_headers` alone reads
`content-length`, `transfer-encoding`, `connection` and `expect` on the way
through a single request. Both answer the single-occurrence case directly now.

**The lesson is the same one this page opened with, pointing the other way:**
the first pass over-estimated writes because "this allocates a copy" felt
obviously true. This one under-estimated the total because nobody counted how
many times a header is read per request. Both are answered by measuring, and
neither by reading the code more carefully.

### Flattening the entry

`_data` was an array of `setmetatable({name=, value=}, entry_mt)`. Priced
before the change, 50,000 of each:

```
entry table with metatable   125.0 bytes
two parallel array slots      41.9 bytes
```

`_names` and `_values` are parallel arrays now. The entry object was never
visible outside `headers.lua` — `each()` already handed back `name, value` and
nothing anywhere reached into `_data` — so the risk was contained to one file
even though the table above called it high.

Two places needed real care and are commented where they live: `delete` now
does two `table.remove` calls that must stay in step, and `sort` cannot hand
parallel arrays to `table.sort` at all, because it would reorder one and leave
the other, pairing every name with somebody else's value. **Neither failure
raises. Both produce strings.** That is why `spec/vendor_headers_spec.lua`
exists, with fourteen cases written so each fails against a reader that
understands one shape and not the other — and mutation-checked: breaking the
index promotion so the first occurrence is dropped turns it red.

### A queue for chunks that a GET never has

`new_stream` built two fifos. `headers_fifo` is used by every request — `step`
pushes the main headers into it and `read_headers` pops them — and stays
eager, because making it lazy would trade an allocation for a branch and save
nothing. `chunk_fifo` holds body data read ahead of the reader, which for a
GET with no body never happens.

It is built by `queue_chunk` now, on the first chunk that is actually queued.

**The reason this needed its own spec, rather than the suite it already had:**
the two paths that create it are the two paths nothing else exercises.
`stream_common`'s `get_body_chars` and `get_body_until` read whole chunks and
`unget` the surplus, and neither is on akkar's own request path — akkar asks
for the whole body. The suite would have stayed green with `chunk_fifo` nil
and an `attempt to index a nil value` waiting for the first application that
streams a request body. `spec/vendor_stream_body_spec.lua` drives the vendored
client against the vendored server to reach them, and is mutation-checked.

### What a stream object costs now

| | bytes |
|---|---:|
| before this pass | 1,496 |
| **after** | **962** |
| — of which two fifos | 530 |
| — of which one condition | 106 |
| — the table itself | ~326 |

### The cost side, counted

None of the above trades time for memory; the shapes got smaller and no loop
got longer. The one change that could have — smaller socket buffers, below —
was counted with `strace` rather than assumed.

## What an idle connection costs, and where that memory actually was

`bench/runtime/RESULTS.md` reports 19.50 KB of resident memory per idle
keep-alive connection, the one dimension where akkar came last. `docs/PLAN.md`
attributed ~15 KB to lua-http and ~4 KB to akkar, by subtracting Lapis's
figure from akkar's on the study box.

**That attribution was wrong.** Measured in-process instead of by subtraction,
holding 200 idle connections:

```
Lua heap, bare cqueues socket server   2,568 bytes/connection
Lua heap, akkar on vendored lua-http   3,415 bytes/connection
```

Everything akkar and lua-http hold above the cqueues floor is **847 bytes**.
Optimising our own tables was never going to move that number.

The memory is cqueues', and it is not on the Lua heap at all: every socket
gets a 4096-byte input buffer and a 4096-byte output buffer, malloc'd
**eagerly** at creation (`socket.c`, `lso_prepsocket` → `lso_adjbufs` →
`fifo_realloc`). Eight kilobytes per connection whether or not it ever carries
a byte, and invisible to `collectgarbage "count"` — which is why no allocation
ceiling in this project ever saw it.

`socket.setbufsiz(r, w)` with two arguments writes the prototype every later
socket is copied from (`lso_newsocket`, socket.c:817-821); the buffers still
grow on demand. Holding 800 connections against a server process of its own:

| bufsiz | bytes/connection |
|---:|---:|
| 4096 | 14,582 |
| 2048 | 10,977 |
| 1024 | **9,175** |
| 512 | 7,864 |
| 256 | 7,864 |

**And what it costs, counted rather than assumed.** A smaller buffer ought to
mean more `read()` calls for the same bytes, so `strace -c` counted them at
4096, 1024 and 512, over 300 requests, twice — a 13-byte JSON reply and a
256 KB one:

```
small payload   read 2908, write 907   IDENTICAL at all three
large payload   read 2617 / 2619 / 2621 -- four calls, over 76 MB
```

So the buffer bounds what is **preallocated**, not what a `read()` asks for.
`app:run { socket_buffer = 1024 }` is the default; `false` leaves cqueues
alone.

**One warning about the instrument.** The first version of that measurement
ran inside busted and answered ZERO bytes per connection at both buffer sizes.
Not a wrong number — no number: the busted process already had spare pages, so
three hundred more sockets fit in memory it already owned and VmRSS did not
move. An instrument that cannot see the effect it is measuring reports "no
difference", which reads exactly like a regression. The spec spawns its own
server process now.

## Two more that measured ZERO, and one of them cancels a planned phase

**Validation allocates nothing above its own output.** F4 in the plan proposes
compiling a specialised validator per schema. Measured first, 20,000
iterations, collector stopped:

```
validate, 4 fields, all present    152.0 bytes
just the cleaned output table      152.0 bytes
```

Identical. F0 -- pre-expanding schemas at route registration -- already removed
every allocation validation used to make, and what is left is the table the
caller asked for. **Codegen would save zero bytes.** Its remaining case is CPU:
removing the `pairs(schema)` walk and the per-field dispatch in `check_one`.
That is a real cost and it is not measurable with this instrument, so F4 now
needs a CPU measurement on the study box before it is worth building rather
than before it is worth shipping.

**A lazy header index saves 7 bytes.** `new_headers` allocates four tables and
one of them is `_index`; building it on first read instead of incrementally in
`append` looked like a free table for any headers object that is only written
and walked. It is not: `get_headers` reads `content-length`,
`transfer-encoding`, `connection` and `expect` from the request headers, and
`write_headers` reads `:status` from the response headers. Both objects are
read, so laziness defers the table rather than avoiding it.

Reverted. The change added an `index_of` indirection to six readers for seven
bytes, and a slower reader for no memory is the wrong side of the trade.

## What is left, sized

| opportunity | worth | risk |
|---|---:|---|
| pool stream objects across requests on a connection | up to **962 B**, measured | **high, and probably refused**: the controller pool is the leading suspect in `docs/substrate/SEGFAULT.md`, and recycling objects that hold sockets is the same shape |
| a C tokeniser for the request line and header block | unmeasured | high; framing stays in Lua, see `docs/PLAN.md` F5a |
| the remaining ~847 B per idle connection above the cqueues floor | ≤847 B | medium, and small |

The first row is worth stating plainly: **the largest single win left is the
one this project has the most reason to distrust.** Pooling gave the
controller pool 719 bytes a request and is implicated in memory corruption.
That does not prove stream pooling would be unsafe; it does mean it needs the
same experiment, not the same enthusiasm.

It is also worth 962 rather than the 1,496 first quoted, and that is measured
rather than deduced: two conditions, ten hash slots and one fifo have already
left the stream object, so pooling it would recycle something smaller than it
used to be — and the case for taking the risk is smaller with it.

## An instrument that did not work, written down so nobody builds it twice

The obvious way to find the remaining 9,554 bytes is to wrap every lua-http
method and have each report `collectgarbage "count"` across itself, with the
collector stopped and nesting attributed to the outermost frame only. That was
built. It reported **−944 bytes attributed** out of 11,636 measured.

The reason is structural and applies to any version of it: **every one of
those methods yields.** They are cqueues coroutines doing socket I/O, so the
window between the two `collectgarbage "count"` readings contains whatever
other coroutines ran in between — the client in the same process, other
connections, the accept loop. The `depth` counter that suppresses nesting is a
single variable shared across coroutines, so it is wrong for the same reason.

There is no fix that keeps the shape. A per-coroutine allocation counter would
need a custom Lua allocator in C, which is a bigger instrument than the
question deserves. **Ablation is what works here** — change one thing, measure
end to end, keep the number — and it is what produced every figure above.

## Throughput, measured

Allocation is not the claim. This is.

`bench/study/regression.sh` on a reserved c5.2xlarge — two server processes,
pinned cores, generator on its own physical core, trees alternating, restarted
between every repetition. `/ping`, baseline `38122ae` against `ed23e89`:

| | req/s | p50 | p99 | spread | µs/req at 2.00 cores |
|---|---:|---:|---:|---:|---:|
| before | 20,192 | 5.32 ms | 6.38 ms | 0.8% | 99.0 |
| **after** | **22,783** | 4.49 ms | **5.42 ms** | 3.3% | **87.8** |

**+12.8%.** Run again from scratch on an independent invocation:

| | req/s | p50 | p99 | spread | µs/req |
|---|---:|---:|---:|---:|---:|
| before | 20,255 | 4.58 ms | 6.30 ms | 0.4% | 98.7 |
| **after** | **22,740** | 4.56 ms | **5.40 ms** | 1.9% | 88.0 |

**+12.3%**, against a largest spread of 3.3% — about four times the noise
floor, and it reproduced. CPU per request fell from 99.0 to 87.8 µs at a fixed
2.00 cores, so this is work removed rather than queueing rearranged.

A 15.9% cut in allocation yielding ~12.5% more throughput is a coherent ratio,
and it is worth saying that the ratio was **not** predictable in advance: this
project has refused that inference before, and was right to.

### And the route where it is NOT a result

`/users/42`, the same harness, same day:

| | req/s | p50 | p99 | spread | µs/req |
|---|---:|---:|---:|---:|---:|
| before | 6,802 | 11.14 ms | 436.81 ms | 6.0% | 294.0 |
| after | 7,102 | 10.61 ms | 346.66 ms | 6.5% | 281.6 |

+4.4% against a spread of 6.5%. **By this project's own Rule 3 that is not a
result and is not reported as one.** It is directionally consistent — µs/req
fell — but the database dominates that route at 294 µs against `/ping`'s 99,
so a cut in the HTTP layer is diluted to below what the instrument can see.

## The rule this followed

Measure, change one thing, measure again, keep the number. Every figure above
is reproducible with the scripts this page describes, and the ones that
measured zero are written down with the same weight as the ones that did not —
because a negative result nobody records is a negative result somebody re-runs.
