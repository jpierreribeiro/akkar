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

## What is left, sized

Not done, and each with its measured price so the next person can judge:

| opportunity | worth | risk |
|---|---:|---|
| lazy `chunk_fifo` / `chunk_cond` — a GET with no body never uses them | up to ~340 B | medium: they are read on paths that assume they exist |
| lazy `_index` entry — one integer instead of `{n=1, i}` until a header repeats | ~270 B | medium: five readers must handle both shapes |
| flatten the header entry — parallel arrays instead of a table + metatable per header | ~290 B/header | high: changes `:each`, `:modify`, `:clone` |
| pool stream objects across requests on a connection | up to 1,496 B | **high, and probably refused**: the controller pool is the leading suspect in `docs/substrate/SEGFAULT.md`, and recycling objects that hold sockets is the same shape |

The last row is worth stating plainly: **the largest single win here is the one
this project has the most reason to distrust.** Pooling gave the controller
pool 719 bytes a request and is implicated in memory corruption. That does not
prove stream pooling would be unsafe; it does mean it needs the same
experiment, not the same enthusiasm.

## The rule this followed

Measure, change one thing, measure again, keep the number. Every figure above
is reproducible with the scripts this page describes, and the two that measured
zero are written down with the same weight as the one that did not — because a
negative result nobody records is a negative result somebody re-runs.
