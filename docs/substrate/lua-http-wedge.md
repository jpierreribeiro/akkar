# One header stops lua-http accepting, for ever

> **Status: REPAIRED, and two claims below were wrong.** Reproduced against
> lua-http 0.4 with a 25-line server containing no akkar. The repair lives in
> the drain loop of `akkar/vendor/http/h1_stream.lua`, and
> `spec/substrate_repair_spec.lua` proves it by swapping akkar's copy of that
> module for the upstream rock's and requiring that server to die.
>
> This page originally ended "it is not akkar's to fix". That was true of
> REPORTING it -- lua-http's last commit is September 2024 -- and false of
> surviving it. lua-http is pure Lua. The corrections are marked below.

## The reproduction

`docs/substrate/lua-http-wedge.lua` is the whole of it: a server that reads
headers, answers 200, and shuts the stream down. Then:

```
$ curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8355/
200

$ curl -o /dev/null -w '%{http_code}\n' -X POST \
       -H 'Content-Length: banana' --data x http://127.0.0.1:8355/
503

$ curl -o /dev/null -w '%{http_code}\n' --max-time 5 http://127.0.0.1:8355/
000
```

Nothing is answered after that, by anyone, for ever.

> **CORRECTION.** This said `Content-Length: -5` "does the same". It does not.
> It is a second, different defect that happens to arrive through the same
> header, and it was found only when the first one was repaired and execution
> could reach it.
>
> `-5` parses to `body_read_left = -5` with a body type of `"length"`, and
> `read_next_chunk` answers that with a bare `error("invalid length: -5")`
> (`h1_stream.lua:869`). `http/server.lua` calls `stream:shutdown()` with no
> pcall around it, so the raise leaves the coroutine, `cq:loop()` returns it,
> and `server:loop()` returns. **The process exits and the port closes** — and
> the malformed request is answered `200` on the way out.
>
> Less dangerous than the wedge, because a supervisor restarts it and a port
> check does detect a closed port. Still a denial of service costing one
> request.

## What state the process is in

Alive. The listening socket is still open — and that is what makes it nasty,
because every liveness check that tests "is the port open" says the server is
healthy.

```
$ ss -ltn | grep 8356
LISTEN 3      4096       127.0.0.1:8356       0.0.0.0:*
```

`Recv-Q` is 3: three connections completed by the kernel and never accepted by
the process. `server:loop()` has not returned — a `pcall` around it never
fires — so from inside, nothing looks wrong either.

> **CORRECTION.** This said "the accept loop has stopped". It has not stopped;
> it is STARVED, and the difference is what made a repair possible.
>
> The process is not parked, it is SPINNING. Measured two ways:
> `voluntary_ctxt_switches` stays frozen at 1 while the process burns CPU
> continuously — it makes no blocking syscall at all — and its state stays
> `R` with `utime` climbing about a second per second. One coroutine that
> never yields starves every other coroutine in the cqueues controller,
> including the accept loop and including a one-second timer added to test
> exactly this, which stops firing the moment the malformed request lands.

## The mechanism

Read off a running process rather than reasoned about, and every field below
was printed by an instrumented server:

  * `stream:shutdown()` ends by draining what is left of the request so the
    connection can be reused (`h1_stream.lua:190`). It loops while the stream
    is open and `step(0)` keeps returning true.
  * `step` takes its read branch when `body_read_left ~= 0` (line 224). An
    invalid `Content-Length` leaves that field **nil**, and nil is not zero.
  * `read_next_chunk(0)` answers `nil, nil, nil` — nothing to read, no error
    — and `step` reads that as success and returns **true** (line 228).
  * So `stats_recv` never advances, the state never changes, and the 500 KB
    drain limit is never approached. Confirmed at 50,000 `step` calls with
    `state="half closed (local)"`, `body_read_left=nil`, `stats_recv=0`.

Two repairs that look obvious do not work, and both were tried. Setting
`body_read_left = 0` skips the read branch — and `step` then falls through to
the unconditional `return true` at the end of the function, so the loop spins
in the same place for a different reason. Answering 400 before the stream
shuts down does not help either, which the bare server in the reproduction
already demonstrates: it catches the raise too, and still wedges.

What is actually wrong is that `step` reports progress where progress is
impossible, and the drain loop trusts it as its only stopping condition. So
akkar makes the drain REQUIRE progress: `step` must show that `stats_recv`
moved or the drain is treated as finished. Breaking out early is safe by
construction — the drain is best-effort, lua-http's own comment calls it
"read any remaining available response and get out of the way", and
`shutdown` closes the socket immediately afterwards when the stream did not
reach a closed state. Ending it early means the connection is not reused,
which for a request whose framing cannot be parsed is the correct outcome
anyway.

**Eight idle steps is the limit.** One would do, since the wedge produces
fruitless steps without limit, but a healthy stream can legitimately answer
"nothing available right now" once or twice against a slow peer, and being
generous costs a few microseconds on a path that is already tearing a
connection down.

## The second failure mode, and why swallowing the raise is defensible

`Content-Length: -5` is not the spin — it is the raise described in the
correction above, and it needed a repair of its own. Shutting a connection
down is cleanup, and cleanup that raises has nothing useful to say. The
narrower argument: `handle_stream` in `http/server.lua` calls
`stream:shutdown()` with no pcall around it, so lua-http *already* treats
`shutdown` as a method that does not throw. Where it throws anyway, catching
it is honouring the contract lua-http's own caller assumes. The rescue path
then performs the same teardown `shutdown` does on its own unhappy path —
socket shutdown, state set to closed — so a connection is never left open by
it.

## Where the repair lives, and where it used to live

<a id="history"></a>

It is eight lines inside the drain loop of
`akkar/vendor/http/h1_stream.lua`. It was not always there, and the move is
worth recording because it is most of why lua-http was vendored at all.

**Before: `akkar/substrate.lua`, a runtime monkey-patch.** It reached into
`http.h1_stream.methods` and replaced `shutdown`, which installed a guarded
`step` on the stream instance with `rawset` for the duration of one call and
removed it afterwards under `pcall`. About 110 lines: instance overrides,
`rawset` juggling, defensive shape checks that refused to patch an
`h1_stream` it did not recognise, and a `repair_substrate` config flag to
turn the whole thing off. It was applied from `App:run` rather than at
require time, on the principle that importing a module should not mutate a
third-party library as a side effect.

**Why it moved.** Sixty lines of that machinery became eight lines in the
loop, and — the part that mattered — a patch keyed on the shape of somebody
else's table can silently stop applying when that shape changes. In the
source it cannot. The shape check that made the monkey-patch safe was also
the thing that would have quietly disabled the repair on an upstream bump.

**What the monkey-patch cost, measured.** The guard was originally a closure
built inside `shutdown`, which meant a closure, a hash insert and a
`table.pack` table allocated on **every stream** — and in HTTP/1.1 keep-alive
a stream is a request. On the study machine that cost **4.1% of `/ping`
throughput**: 19,383 req/s against 20,208. Hoisting the guard to a single
shared function and moving its two counters onto the stream recovered it.
`spec/allocation_spec.lua` records the same repair at +511 bytes per request
before that fix and free after it. This is the record of why a guard on a
per-request path is written the way it is, and it is the reason the vendored
version keeps its state in two locals rather than a closure.

**The retirement.** Once the repair was in the vendored source,
`akkar.substrate` patched a module akkar no longer loads, and its `apply()`
was reduced to returning `{ h1_shutdown_spin = { applied = false } }`. It was
kept as a no-op for a while on the grounds that its header was the only
written account of the wedge. That account is now this page, so the module,
its reference page and the `repair_substrate` flag were removed — the flag in
particular, because a documented option that gates a call returning a
constant tells a reader they have opted out of something when they have not.

## Where it starts

`stream:get_headers()` raises `invalid content-length`. akkar catches that and
answers 400 (`akkar/init.lua`, "A REQUEST WHOSE FRAMING lua-http REFUSES TO
PARSE"), which is a better answer than the 503 lua-http produces on its own —
the request was malformed, and 503 blames the server for the client's
mistake.

**It does not prevent the wedge.** The bare server above catches the raise too
and still stops accepting, so whatever breaks is inside lua-http's connection
machinery and above anything a handler can reach.

## What this means for running akkar

**With the repair, none of the below applies any more**; it is kept because it
is exactly what a deployment looks like when a substrate defect is carried
rather than fixed, and because anyone running lua-http directly rather than
through akkar's vendored copy is living with this list.

- **Behind a reverse proxy that validates framing** — nginx, HAProxy, any
  managed load balancer — the malformed request never arrives, and this cannot
  be triggered from outside.
- **Exposed directly to the internet, it is a denial of service that costs one
  request.** No volume, no timing, no authentication: a single header.
- **A port check will not detect it.** Health checking must make a real
  request and read a real answer, which is good practice anyway and is now
  load-bearing.

## Why it was not found earlier

Every fuzzing harness in this project went through an HTTP client, and a
client will not send `Content-Length: banana` — it computes the header itself.
`spec/framing_spec.lua` exists precisely to send bytes no client would, and it
found this on its first complete run.

It also explains a shape seen and misread earlier in the same session: a
corpus where the first three cases answered and everything after them timed
out, which looked like a broken harness and was the server dying on case four.
