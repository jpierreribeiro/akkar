# One header stops lua-http accepting, for ever

> **Status.** Reproduced against lua-http 0.4 with a 25-line server containing
> no akkar. Not reported upstream yet. This is the most serious thing found in
> this repository so far, and it is not akkar's to fix.

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

Nothing is answered after that, by anyone, for ever. `Content-Length: -5` does
the same.

## What state the process is in

Alive. The listening socket is still open — and that is what makes it nasty,
because every liveness check that tests "is the port open" says the server is
healthy.

```
$ ss -ltn | grep 8356
LISTEN 3      4096       127.0.0.1:8356       0.0.0.0:*
```

`Recv-Q` is 3: three connections completed by the kernel and never accepted by
the process. The accept loop has stopped. `server:loop()` has not returned —
a `pcall` around it never fires — so from inside, nothing looks wrong either.

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

Stated plainly rather than left implicit:

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
