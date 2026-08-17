# Lua 5.5: what was tried, what works, what does not

An earlier version of this page reasoned from commit logs and concluded the
dependency graph "looks ready". It was right about some of that and wrong about
the most important part. This version is written from a build.

Everything below was done on 17 August 2026, in an isolated prefix (`~/lua55`),
touching neither the system Lua 5.4 nor `~/.luarocks`.

## The result, first

| | |
|---|---|
| Lua 5.5.1, luarocks 3.13 | build clean |
| luaossl's C | **compiles against 5.5 with zero errors** |
| cqueues | **builds and runs an event loop** — after one fix, below |
| the nine pure-Lua rocks | install unchanged |
| akkar: routing, validation, schemas | **works** — 190/190 logic specs pass |
| akkar: sockets and event loops | **crashes** |

So: **akkar's own semantics are compatible with Lua 5.5.** Its socket layer is
not yet, and that is where the work is.

## The correction this page owes

The previous version said cqueues was "done, in the commit akkar already pins",
citing five upstream commits including "Add Lua 5.5 support to build system".

**The build target exists. The compile fails.**

```
vendor/compat53/c-api/compat-5.3.h:404: error: "unsupported Lua version
                                 (i.e. not Lua 5.1, 5.2, 5.3, or 5.4)"
```

cqueues vendors `lua-compat-5.3` at v0.9, from 2020, and the commit that added
the 5.5 build target did not update the submodule. That is the identical error
the macOS CI run hit, so the evidence was in front of us and got read as
"cqueues is ready" because the commit messages said so.

**Reading a changelog is not building the thing.**

The fix: `lua-compat-5.3` gained 5.5 in March 2026 and released 0.15.1 in July.
Dropping that header into the cqueues tree makes it build, and the resulting
module runs an event loop under 5.5. It is a one-file swap, and it is available
only to somebody who builds cqueues rather than installing it.

## luaossl: the blocker is the build system, and only that

`GNUmakefile:15` reads `KNOWN_APIS = 5.1 5.2 5.3 5.4`, and patching it is not
enough because `mk/luapath` detects library versions by probing for symbols on
a ladder that stops at 503.

None of that is the C. Compiled by hand:

```sh
cc -O2 -std=gnu99 -fPIC -shared -o _openssl.so -I$PREFIX/include \
   src/openssl.c -lssl -lcrypto
```

**Zero errors.** It loads under 5.5, `openssl.ssl.context` and `openssl.rand`
work, and `setAlpnSelect` is present — which is what akkar's TLS needs.

Upstream issue [#221](https://github.com/wahern/luaossl/issues/221) is open.
The patch to send is the makefile, not the source.

> A warning for whoever tries this: `cc ... 2>&1 | head -25` kills the
> compiler with SIGPIPE partway through and leaves no output file, which reads
> exactly like a compile failure. That cost one wrong conclusion here.

## What akkar itself needed: two lines

Compiling every file in the tree under 5.5 found **two** incompatibilities, and
they were the same one twice:

```lua
for candidate in header:gmatch '[^,]+' do
  candidate = candidate:match "^%s*(.-)%s*$"   -- error in 5.5
```

Lua 5.5 makes a for-loop control variable `const`. `akkar/etag.lua:124` and
`akkar/static.lua:727` both did this; both now trim into a separate local,
which is clearer code under 5.4 as well.

Nothing else. No `<close>` problem, no integer-subtype problem, no C API
problem in akkar's own C. For a codebase of 15,000 lines that is a smaller
blast radius than anyone predicted.

## What the attempt found in our own test harness

Running the suite under 5.5 produced 22 framing failures reading `the server
never started listening; it said: lua5.4:`.

Not a protocol defect: `spec/support/raw_client.lua` spawned `lua5.4` — found
correctly on PATH — and handed it 5.5's `LUA_PATH`, so every spawned server
died on its first `require`. The harness assumed the interpreter's name instead
of using the one it was running under.

Fixing that took two wrong turns worth recording, because both are mistakes
this project has made before in other places:

1. `readlink -f /proc/self/exe` through `io.popen` returns
   **`/usr/bin/readlink`** — inside the popen'd process, `/proc/self` is
   readlink. `spec/concurrency_spec.lua` documents the identical trap for
   descriptor counting.
2. `arg[-1]` is **not** the interpreter. luarocks launches busted as
   `lua5.4 -e '<chunk>' /path/to/busted`, so `arg[-1]` is that chunk. Passing
   it to a shell produced 407 failures reading `sh: 1: Syntax error: "("
   unexpected`.

The interpreter is `argv[0]` from `/proc/self/cmdline`, read as a file, with a
walk to the most negative `arg` index as the fallback. The harness is now
version-agnostic, which is what a multi-version CI needs anyway.

## What is still broken

The socket and event-loop specs crash under 5.5 — `akkar_spec`,
`concurrency_spec`, `substrate_repair_spec`. The crash is in `auxgetstr`
(`lapi.c`), which is a different signature from the `table_LLRB_FIND` crash
`docs/substrate/SEGFAULT.md` tracks on 5.4.

Two possibilities, and this page does not choose between them:

- 5.5 has a real incompatibility with cqueues, this build of it, or the updated
  compat shim
- the memory corruption already known on 5.4 surfaces differently under a
  different allocator

Both deserve the same instrument: a cqueues built for 5.5 under
AddressSanitizer. That has not been done.

**So Lua 5.5 is not adopted, and akkar still ships on 5.4.** What changed is
that the blocker is now specific and local instead of "upstream, indefinitely":
one makefile patch to send, one vendored header to update, and one crash to
diagnose.

## Reproducing this

Scripts are not committed — they build into `~/lua55` and are a spike, not
infrastructure. The order was: Lua 5.5.1 from source with `-fPIC`, luarocks
from git configured against it, luaossl's `openssl.c` compiled by hand,
cqueues at the pinned commit with `vendor/compat53/c-api/compat-5.3.h` replaced
by v0.15.1's, then `luarocks install` for lpeg, lpeg_patterns, fifo,
binaryheap, basexx, lua-cjson, compat53, luasocket and busted.
