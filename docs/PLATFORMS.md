# Where akkar runs

`docs/UNKNOWNS.md` §1 carried this as the largest known gap: every measurement
in this repository had been taken on one machine, and CI was `ubuntu-24.04` and
nothing else. There was no mention of `arm64`, `macos` or `darwin` anywhere in
`.github/workflows/`.

This page is what happened when that stopped being true. Everything below is
from a CI run, not from reasoning about what should work.

## The matrix

| platform | runner | status |
|---|---|---|
| Linux x86-64 | `ubuntu-24.04` | supported, full suite |
| Linux arm64 | `ubuntu-24.04-arm` | supported, full suite |
| macOS arm64 | `macos-14` | supported, with four differences below |
| Windows | — | not supported, and not planned |

ARM64 had been measured once, by hand. It is now a CI fact, and it went green
on the first run with no changes at all.

macOS took seven runs. **None of the seven found a problem with akkar's
concurrency, its HTTP handling or its request lifetime** — six were about the
harness and the build, and the seventh is the one real difference.

## What macOS actually required

### Lua 5.4, said out loud

`brew install lua` is **Lua 5.5** now. The first run installed it and died in
cqueues' vendored `lua-compat-5.3`, which is at v0.9 and stops at 5.4:

```
compat-5.3.h:404: error: "unsupported Lua version (i.e. not Lua 5.1, 5.2, 5.3, or 5.4)"
```

The job had accidentally become a Lua 5.5 probe, and it reproduced in CI the
blocker `README.md` already documents. The formula to install is `lua@5.4`,
which is keg-only, so every path has to come from its own prefix — and the
version is now asserted rather than assumed, because this went unnoticed once.

### OpenSSL, pointed at

Homebrew's `openssl@3` is keg-only, so `openssl/ssl.h` is in nobody's default
include path, and cqueues' makefile reads `CPPFLAGS`, not the `OPENSSL_DIR`
that luarocks uses. Two flags.

### The pinned cqueues, installed last

Not a macOS problem — a problem macOS **exposed**, which had been true on Linux
since the workflow was written. `http` depends on cqueues, luarocks cannot see
a hand-built copy, so it fetched the release rock and said so:

```
Warning: /usr/local/lib/lua/5.4/_cqueues.so is not tracked by this installation
of LuaRocks. Moving it to /usr/local/lib/lua/5.4/_cqueues.so~
cqueues 20200726.54-0 is now installed in /usr/local
```

Every green run had tested release 20200726, not the commit `CQUEUES_COMMIT`
pins. `akkar/substrate.lua` patches cqueues' internals, so that mattered. The
pinned build now goes in last, and `require("cqueues").COMMIT` is asserted —
the field only exists when built with `-DCQUEUES_COMMIT`, which the release
rock is not.

## The four real differences

### 1. A controller costs three descriptors, not two

**This is the one that changes an answer.**

| | per cqueues controller |
|---|---|
| Linux (epoll) | **2.00** |
| macOS (kqueue) | **3.00** |

akkar spends one controller per in-flight request for its deadline, so this
number is most of the concurrency ceiling — and the word is *most*, because
the request also holds its own socket.

**`descriptor_ceiling()` divided the limit by 2, and 2 was the controller
alone.** A request in flight costs **three** descriptors on Linux, counted
from inside a server process of its own while N were held in a sleeping
handler:

| in flight | descriptors | per request |
|---:|---:|---:|
| 50 | 150 | 3.00 |
| 100 | 300 | 3.00 |
| 200 | 600 | 3.00 |

Dead flat, which is what a per-request cost looks like. So the ceiling was
**fifty percent higher than the box could serve**: on the usual `ulimit -n
1024` it promised 337 concurrent requests, which need 1,011 descriptors —
more than the whole limit, never mind the third it holds back. It divides by 3
now and promises 225.

That was not hypothetical when it was found. `bench/runtime/run.sh` at 100
connections had akkar answering 18,640 of 111,651 requests with `unable to
initialize continuation queue: Too many open files` — one request in six, on a
run that published a throughput number. Nobody saw it because that harness
read the wrong `awk` field for the error count. Both are fixed, and
`spec/concurrency_spec.lua` now **counts** the descriptors rather than
re-deriving the formula: its old assertion computed `expected` with the same
arithmetic as `init.lua`, divisor and all, and then asserted `expected >= 16`
— true for any divisor on any box. A test that agrees with the code because it
*is* the code cannot report that the code is wrong.

**On a Mac the number is four**, not three: a controller costs three
descriptors on kqueue and the socket is the fourth.

Today that is **latent**: the same function reads `/proc/self/limits`, so off
Linux it derives nothing at all and `max_concurrent` stays unset. A Mac has no
wrong ceiling; it has no ceiling. `akkar/limit.lua` already warns once when
`shed` is installed without one.

Verified as a substrate difference rather than an instrument artefact: macOS
counts descriptors with `lsof` where Linux uses `/proc`, so both instruments
were run against the same 50 controllers on Linux and **both said exactly
2.00**. The specs now pin the expected number per platform rather than widening
into a range that would pass on both and notice neither.

**Open decision:** whether `descriptor_ceiling` should derive a limit off Linux
(`ulimit -n` is POSIX) and divide by the platform's real cost. Not done here —
it is a design change, not a portability fix.

### 2. `akkar watch` was silently dead — fixed

`stat -c %Y` is GNU coreutils; BSD stat rejects `-c` and spells it `-f %m`.
Every mtime read returned nil, every snapshot compared nil to nil, and the
watcher reported no changes for ever. No error, no output, a watcher that had
simply stopped watching.

Fixed in `akkar/watch.lua`: both spellings are tried once at load, against a
path that certainly exists. `M.can_stat` says whether either worked.

### 3. Resident size read zero — fixed

`Registry:memory()` read `/proc/self/statm` and reported `0` where there is no
/proc. Zero is worse than nothing: the pair of numbers exists so a leak
*outside* the Lua heap is visible. It now falls back to `ps -o rss=`, on the
fallback path only, so Linux still does not pay for a subprocess per scrape.

### 4. The test harness assumed Linux — fixed

`timeout` is coreutils, `setsid` is util-linux, `ss` is iproute2,
`touch -d @epoch` is a GNU extension, and `/proc` is not a filesystem a Mac
has. The first macOS suite run reported 318 failures, **299 of them the single
line `sh: timeout: command not found`** — which read as 299 broken
documentation examples.

`spec/support/portable.lua` resolves these by asking the system what it has
(`command -v`) rather than asking which system it is. Where nothing can answer
it returns nil and the caller reports pending — never zero, which would have
meant "nothing leaked".

## What is pending rather than passing on macOS

The two jobs run the same 1563 tests. Linux passes 1551 with 12 pending;
macOS passes 1549 with 14. The twelve are the same on both — Postgres, Redis
and the C driver, none of which the unit job has. The two extra are:

| test | why |
|---|---|
| `spec/concurrency_spec.lua:156` | no `/proc/self/limits`, so the ceiling is not derived here at all — see difference 1 |
| `spec/build_spec.lua:263` | `akkar build` needs `liblua5.4.a`, and Homebrew's `lua@5.4` does not ship a static library |

The second means **`akkar build` is unverified on macOS**. It is not known to
be broken; it is known not to have been run. Building the single binary there
would need a static Lua from source.

## What is still unmeasured

- **32-bit.** `lua_Integer` is 64-bit on a 64-bit build, and akkar's C driver
  binds integers as `int8` on that assumption.
- **musl.** Alpine is the common container base and has not been run.
- **Intel macOS.** The matrix uses `macos-14`, which is Apple Silicon. The
  Homebrew prefix is resolved rather than hardcoded, so it should work, and
  "should" is the word doing the work.
- **The C driver on macOS.** `akkar-pq` is a separate rock and the matrix does
  not build it.
