# akkar as a runtime

> **Status.** `akkar build` exists and **serves requests**. The feasibility
> question is answered twice over; the design question below is still open.
>
> ```
> $ akkar build serve-app.lua -o myapp --root ... --archive ...
> akkar build: 369 Lua modules, 46 native modules -> myapp
>
> $ ./myapp 8375 &
> $ curl -i http://127.0.0.1:8375/users/7
> HTTP/1.1 200 OK
> x-request-id: 3824249f000001
> content-type: application/json
>
> {"id":7}
> ```
>
> 5.08 MB. Routing, parameter validation (`/users/abc` answers 422), JSON,
> the request id, the whole cqueues and lua-http stack. `ldd` shows OpenSSL,
> libm and libc: no Lua, no LuaRocks, no shared modules.

## What this changes, and why it is a reversal

`docs/BACKLOG.md` carried `akkar build` in the table of things deliberately
not being built, with this reason:

> Attractive, but Redbean is a *different substrate*, and `cqueues` is a C
> module. That is a substrate change, not a packaging step.

The first clause is true of Redbean. **The second does not follow, and it was
never measured.** Being a C module makes something harder to *link*, not
impossible; static linking is the ordinary answer and it changes no substrate
at all.

`docs/runtime/build-probe.sh` is the disproof, and it runs in about a minute:

| Probe | Result | Size |
|---|---|---|
| Pure Lua script | ran | 302 KB |
| Plus a C module (`lua-cjson`) | encoded and decoded | 328 KB |
| **Plus `cqueues`, running an event loop** | **`ticks=3`** | **1.5 MB** |

The third is the one that matters: **akkar's entire concurrency substrate ran
inside a single executable.** The same cqueues, the same Lua 5.4 VM. Only the
linkage changed. `ldd` on the first two shows `libc` and `libm` and nothing
else.

Two build facts came out of it, both mechanical:

- cqueues has **no static target**, but its own build already emits
  `src/lib/libnonlua.a` plus per-API objects, so producing an archive is one
  `ar` call. The object names collide across `src/lib` and `src/5.4` and have
  to be renamed first.
- `luastatic` turns the first underscore of a `luaopen_` symbol into a dot, so
  `luaopen__cqueues` registers as `.cqueues` and the module is not found. Any
  module beginning with an underscore hits this. A real `akkar build` emits
  its own host and never meets it.

## The whole stack links, and stops one plumbing detail short of serving

The second attempt went further: **every C dependency and all 102 Lua modules
a running akkar app loads**, in one 2.9 MB executable.

| | |
|---|---|
| `_cqueues.a` | 2.1 MB, all entry points |
| `_openssl.a` | 26 entry points |
| `cjson.a`, `lpeg.a` | |
| Lua modules | 102 — akkar, lua-http, cqueues, lpeg_patterns, openssl wrappers, basexx, fifo, binaryheap |
| Result | **links, and runs** |

The module list was not guessed. A script starts an app, serves one request to
itself and dumps `package.loaded`, so what gets bundled is what a real request
touches.

It stops here, precisely: the binary loads akkar, reaches `http.server`, which
requires `http.h2_connection`, which requires `openssl.rand`, whose one-line
Lua wrapper does `require "_openssl.rand"` -- and that does not resolve to the
statically linked C module. The searcher falls through to `dlopen` on the
executable itself, which fails with *cannot dynamically load executable*.
`-no-pie` does not fix it; nor does rewriting all 49 C-module registrations
from their `luaopen_` symbols, which is verifiably done in the generated
source.

**That is a `luastatic` naming problem, not an akkar one, and it was the
argument for `akkar build` emitting its OWN host** rather than leaning on a
general-purpose bundler. That host is now `akkar/build.lua`, and the section
below is what it took.

## What the host had to know that a bundler could not

**Reversing the C naming convention is ambiguous.**
`luaopen__openssl_x509_verify_param` reads equally well as
`_openssl.x509.verify.param` and as `_openssl.x509.verify_param`. The module
is the second. No rule over symbols can tell, and a bundler that guesses
produces a binary that dies with "module not found" for a module demonstrably
linked into it.

akkar does not guess. The code that requires the module is going into the same
binary and names it exactly, so `akkar.build` reads every literal `require`
out of the sources it is about to embed and maps FORWARD -- name to symbol,
dots to underscores, which is unambiguous in that direction -- then checks
whether the archive defines it. The guess becomes a lookup. The symbol rule
survives only as a fallback for a module nothing requires by a literal name.

**The second obstacle was not naming at all**, and it took reading luaossl's C
to find. `dl_anchor()` does `dladdr` on its own entry point and then `dlopen`s
the file it lands in, to stop the loader unlinking the module while OpenSSL
holds a callback into it. Statically linked, that concern cannot arise -- the
code is in the executable and can never be unloaded -- but `dladdr` returns
the executable's path and `dlopen` on an executable fails by definition. The
error surfaces as `openssl.init: cannot dynamically load executable`, from a
module nobody mentioned, and `openssl.init` turns out to be an error label in
C rather than a module at all.

luaossl's own `#else` branch already does the right thing, so a static build
compiles it with `-DHAVE_DLADDR=0`. **A native module written for dynamic
loading may hold assumptions that only static linking violates**, and that is
the general lesson worth carrying into the next one.

## What this does NOT prove

Written here rather than left to be discovered, because a probe that oversells
is worse than none.

- **One platform, one libc.** Linux, glibc, x86-64. Nothing here says anything
  about musl, macOS or the BSDs, and `dl_anchor` is exactly the kind of thing
  that differs.
- **Not fully static.** OpenSSL is still linked dynamically. `libssl.a` and
  `libcrypto.a` exist on this machine, so it is reachable; untried.
- **The archives are built by hand.** `akkar build` consumes `.a` files and
  does not produce them: turning a rock into an archive is still a manual
  `make` and `ar`. That is the next piece of work, not a footnote.
- **No cross-compilation.** It builds for the machine it runs on.
- **The binary is not fully static.** It still links `libssl.so` and
  `libcrypto.so` dynamically. `libssl.a` and `libcrypto.a` exist on this
  machine, so a fully static link is reachable — untried.
- **One platform, one libc.** Linux, glibc, x86-64. Nothing says anything
  about musl, macOS or the BSDs.
- **Nothing about the size or startup cost of the real thing.** 1.5 MB is
  cqueues; akkar, lua-http and pgmoon are on top of that.

## The design question, answered

Three shapes were on the table. The recommendation, and the reasoning, because
the reasoning is what will still be useful when the recommendation is wrong.

**1. `akkar build` — the application compiled in. SHIPPED, and it is the
default.** One binary per application; changing the app means rebuilding.
Deployment stops needing Lua, LuaRocks or a shared object, which was the whole
problem. Nothing about it needs a compatibility promise, because the framework
and the application are compiled together and ship as one artefact — which
matters, since this project has decided not to make one yet.

**2. `akkar run app.lua` — the binary hosts an app it reads at startup.
NEXT, and small.** The host already embeds akkar; running an app from a file
instead of from the bundle is a handful of lines. It is worth having because
it makes the edit-and-restart loop possible without a compiler, which is how
anyone actually develops.

Its real cost is not code. It creates a SECOND versioned interface -- between
the runtime binary and the application source -- at a moment when the project
has deliberately promised nothing. So `akkar run` states which akkar built the
binary and leaves it at that. No compatibility checking theatre for a contract
nobody has agreed to.

**3. The supervising runtime, apps as data. NOT NOW, and the reason is
concrete rather than a matter of taste.** Its whole appeal is running code
somebody else wrote -- several tenants, hot-swapped, in one process. akkar
has the loading half of that already (`akkar.from_spec`, `App:swap_host`) and
does not have the isolation half. `akkar/vm.lua` says so in its own header:
it is a sandbox inside one Lua state, not a boundary against hostile code, and
**if the code is hostile rather than merely untrusted, run it in a separate
process with an OS-level sandbox.**

Building the supervising runtime now would mean offering, as a product, the
guarantee the code explicitly disclaims.

### What actually unblocks the third one

Not more code in akkar. A process per tenant, which the binary above makes
cheap: a 5 MB self-contained executable with no interpreter to install is a
very different proposition from "provision a Lua environment per customer".
The isolation story becomes the operating system's, which is the only place it
has ever been true.

That is why the order is 1, then 2, then 3 -- and why 3 is a decision to make
after 2 exists, not before.

## The design question as it was posed

Feasibility was the cheap half. What `akkar build` should *mean* is not
settled, and these are different products:

1. **`akkar run app.lua`** — one binary that hosts an application it reads at
   startup. Deployment stops needing a Lua installation, LuaRocks, or any
   `.so` on the target.
2. **`akkar build` → `myapp`** — the application compiled *into* the binary.
   One artefact, `scp` it and run it.
3. **A supervising runtime** — process supervision, metrics, TLS termination
   and hot reload in the same executable, with applications as data. This is
   where `akkar.from_spec` and `App:swap_host` already point.

Each of the three implies a different answer about what is configuration,
what is code, and what a version number covers.

## Sequence

Nothing here should start before the **executable substrate contract**. The
whole value of a runtime is that the application above it does not change when
the substrate below it does — and today that boundary leaks in three measured
places (`akkar.null` re-exporting cjson's sentinel, five modules requiring
cjson directly with no serializer contract, and `ctx` handing luaossl and
lua-http to application configuration). Building a runtime on a boundary that
leaks would harden the leaks into the artefact.

So: contract first, then TLS and a served request in the probe, then the
design decision above, then build it.
