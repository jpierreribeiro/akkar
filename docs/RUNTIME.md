# akkar as a runtime

> **Status.** Open, and it starts with a retraction. The feasibility question
> is **answered**; the design question is not.

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

**That is a `luastatic` naming problem, not an akkar one, and it is the
argument for `akkar build` emitting its OWN host** rather than leaning on a
general-purpose bundler. A host akkar generates knows exactly which
`luaopen_` belongs to which module name, because it wrote both.

## What this does NOT prove

Written here rather than left to be discovered, because a feasibility probe
that oversells is worse than none.

- **No request has been served from the binary.** It loads, and it stops at
  the module above. The event loop probe is the strongest positive result;
  the full stack is "links and starts", not "serves".
- **The binary is not fully static.** It still links `libssl.so` and
  `libcrypto.so` dynamically. `libssl.a` and `libcrypto.a` exist on this
  machine, so a fully static link is reachable — untried.
- **One platform, one libc.** Linux, glibc, x86-64. Nothing says anything
  about musl, macOS or the BSDs.
- **Nothing about the size or startup cost of the real thing.** 1.5 MB is
  cqueues; akkar, lua-http and pgmoon are on top of that.

## The design question, which is the hard one

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
