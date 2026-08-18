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
| akkar, the whole suite | **1763 successes / 0 failures / 0 errors / 2 pending** |
| the same suite on Lua 5.4 | 1801 successes / 0 failures / 0 errors / 0 pending |
| 32 of the 38-test difference | `akkar.pq`'s half — one `pq_native.so`, two ABIs; see below |
| the other 6 | `teal_spec` — `tl` is not installed in the 5.5 tree |
| so, of the difference | none of it is Lua 5.5. Both halves are tooling that was never installed twice |

So: **akkar runs on Lua 5.5.** Not one line of akkar changed for it.

This table used to end at "routing and validation work, sockets crash", and
the sections below are the record of walking that back to here — the crash
diagnosed, the C driver built, the gap closed. The summary is left mid-story
in no version of this page but the one you are reading, because a reader who
stops at the first table should not come away with yesterday's answer.

What remains is packaging rather than portability, and `docs/runtime/lua55-stack.sh`
is that packaging, written down and executable. **CI runs that same script**,
so this page cannot quietly drift from the build again.

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

## The crash, and what it actually was

An earlier version of this page said the socket specs crashed under 5.5, in
`auxgetstr` (`lapi.c`), and could not say whether that was 5.5's fault or the
memory corruption already tracked on 5.4.

**It was neither. It was a stale C module, and the whole thing is one
sentence:** `akkar/pq_native.so` in the tree is built for Lua 5.4, and
`spec/db_spec.lua` puts `./?.so` on `package.cpath`.

What makes it nasty rather than obvious:

```
require "akkar.pq_native"   -- succeeds under 5.5
pq.VERSION                  -- reads correctly: "akkar.pq 0.1"
pq.connect_start(...)       -- core dump
```

Loading a C module built for a different Lua is **not** a clean failure. The
`luaopen_` symbol resolves, the table comes back, its fields read fine — and
then the first real call walks a `lua_State` laid out differently than the one
it was compiled against.

Take that one file out of the tree and the whole suite runs:

```
Lua 5.4    1,710 successes / 0 failures / 0 errors / 0 pending
Lua 5.5    1,672 successes / 0 failures / 0 errors / 2 pending
```

The 38-test gap was fully accounted for: `pq_spec` and `db_spec`'s C-driver
half skipped because `pq_native.so` was not built for 5.5, and `teal_spec`
skipped because `tl` is not installed there.

### Then it was built for 5.5, and the gap closed

```
Lua 5.4    1,756 successes / 0 failures / 0 errors / 0 pending
Lua 5.5    1,750 successes / 0 failures / 0 errors / 1 pending
```

The remaining pending is `teal_spec`, and it is a linter that is not installed
rather than anything about Lua 5.5. **The C driver runs, against a real
Postgres, under 5.5.**

Building it needed no root and no `libpq-dev` install, which `src/build.sh`
already documented and nobody had used:

```sh
apt-get download libpq-dev
dpkg -x libpq-dev_*.deb /tmp/libpq
PQ_INC=/tmp/libpq/usr/include/postgresql \
LUA_CFLAGS=-I$HOME/lua55/include \
OUT=/tmp/pq_native_55.so ./src/build.sh
```

Only the HEADER was missing. The runtime is the system's `libpq.so.5`, which
any machine that talks to Postgres already has, and the script links against
the versioned `.so` directly rather than the unversioned symlink that only
ships with the dev package.

The new module reports `LUA_VERSION_NUM = 505`, so the guard below now has
something to check rather than a build with no marker to wave through.

**What is still awkward, stated rather than hidden:** there is ONE
`akkar/pq_native.so` path in the source tree and two Lua ABIs that might want
it. `spec/db_spec.lua` puts `./?.so` on `package.cpath`, so whichever build is
sitting there is the one both interpreters load. The file is gitignored — it
is a build artefact, not a tracked one — so nothing is committed wrong; but
running both suites on one checkout means rebuilding, or swapping, between
them. An installed rock does not have this problem: LuaRocks keeps
`lib/lua/5.4/` and `lib/lua/5.5/` apart.

## The guard this produced

`src/akkar_pq.c` now records `LUA_VERSION_NUM` at compile time, and
`akkar/pq.lua` refuses a module whose marker disagrees with the running Lua.
A segfault becomes an error that names the fix.

A module with **no** marker is allowed through, and that is deliberate: every
`.so` built before this change lacks one, including correct ones, so refusing
them would turn a working 5.4 install into a hard error and drop the C
driver's test coverage with it. The marker closes the hole for every build
from here on. `AKKAR_PQ_SKIP_ABI_CHECK=1` disables the check.

Until a stale `.so` is rebuilt, **remove it before running under a different
Lua** — that is the whole workaround.

## Where this leaves 5.5

Supported, not yet recommended, and `akkar doctor` says exactly that:

```
runtime
  ok    Lua 5.5
        supported; needs luaossl and cqueues built for 5.5 -- see docs/substrate/LUA-55.md
```

The rockspec already allowed `lua >= 5.4, < 5.6`; the doctor was the only
thing hardcoding 5.4, with a reason that had stopped being true.

What stands between 5.5 and "recommended" is packaging, not code — and the
packaging that is missing is **not akkar's**. No distribution ships Lua 5.5
yet, so `luarocks install akkar` has nowhere to land. Upstream of that: a
luaossl whose makefile has a 5.5 rung (its C already compiles, so this is a
list, not a port), and a cqueues whose vendored compat shim is current.
Neither is akkar's to merge.

Until then 5.5 is a from-source proposition, which is a real cost to a user
and the honest reason 5.4 stays the default.

## Reproducing this

**`docs/runtime/lua55-stack.sh`**, and it is the same file CI runs:

```sh
LUA55_PREFIX=~/lua55 bash docs/runtime/lua55-stack.sh
```

Lua 5.5.1 from source with `-fPIC`, luarocks from git configured against it,
luaossl's `openssl.c` compiled directly, cqueues at the pinned commit with
`vendor/compat53/c-api/compat-5.3.h` replaced by v0.15.1's, then `luarocks
install` for lpeg, lpeg_patterns, fifo, binaryheap, basexx, lua-cjson,
compat53, luasocket, luafilesystem and busted. Everything lands in the prefix;
the system Lua and `~/.luarocks` are untouched, and discarding it is `rm -rf`.

An earlier version of this section said the scripts were "a spike, not
infrastructure" and left them uncommitted. That was the wrong call for a
reason worth stating: it made this page the only record of how to get here,
and a page is not runnable. The rockspecs declare `lua >= 5.4, < 5.6` and
`spec/rockspec_spec.lua` asserts that bound — so the upper half of a
**tested-and-declared** range was resting on prose. Now it rests on a job.

One step of the recipe is easy to get wrong by hand and is worth naming.
luaossl stores its Lua modules **flat and dot-named** — `src/openssl.ssl.context.lua`
— and it is the makefile that turns each name into a directory path. Compile
directly and you inherit that translation. Copying the files as they are
leaves `openssl.ssl.context.lua` somewhere `require` will never look, and the
failure surfaces far away, as lua-http not finding `openssl.rand`. The script
does the rename and then asserts `openssl/rand.lua` exists, because that is
the specific thing that goes silently wrong.
