# One header stops lua-http accepting, for ever

> **Status: REPAIRED, and two claims below were wrong.** Reproduced against
> lua-http 0.4 with a 25-line server containing no akkar. `akkar.substrate`
> now repairs it, and `spec/substrate_repair_spec.lua` proves the repair by
> starting a server without it and requiring that one to die.
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
`akkar.substrate` makes the drain REQUIRE progress: during `shutdown`, and
only during `shutdown`, `step` must show that `stats_recv` moved or the drain
is treated as finished. Breaking out early is safe by construction — the
drain is best-effort, and `shutdown` closes the socket immediately afterwards
when the stream did not reach a closed state.

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
rather than fixed, and because anyone running with `repair_substrate = false`
is choosing this list.

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
