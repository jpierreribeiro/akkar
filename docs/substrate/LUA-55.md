# What actually blocks Lua 5.5

The project has carried "luaossl has no 5.5 target" as the reason, and repeated
it in `docs/RUNTIME-1.0.md` and in the README. That was true when written and
two thirds of it has since stopped being true, so here is the current state
with the evidence.

Checked 17 August 2026.

## The three things that had to move

| | then | now |
|---|---|---|
| **cqueues** | no 5.5 | **done, in the commit akkar already pins** |
| **lua-http's `compat53`** | required | **gone, with the h2 cut** |
| **luaossl** | no 5.5 | **still no 5.5 — and this is the whole blocker** |

### cqueues: already solved, and we already pin it

Five commits, all in `c366149` — the commit `.github/workflows/ci.yml` pins:

```
2026-03-06  Add Lua 5.5 support to build system
2026-03-18  regress: add Lua 5.5
2026-03-18  src/cqueues.c: in lua 5.5 lua_pushvfstring can return NULL
2026-03-18  README.md: update to add Lua 5.4 and 5.5
```

The macOS CI run that died in `lua-compat-5.3` was building the RELEASE, not
the pin — `brew install lua` gave 5.5 and the 2020 release cannot take it. That
failure was read as "cqueues blocks 5.5". It was "the 2020 release blocks 5.5",
which is a different sentence with a different fix.

### compat53: removed by a decision made for another reason

`compat53.module` was required by exactly five files: `h2_connection`,
`h2_stream`, `hpack`, `websocket` and `socks`. All five were cut when the
HTTP/1.1 half of lua-http was vendored — a decision taken to shed 3,337 lines
of unused protocol, not to chase Lua 5.5.

`akkar/vendor/http/` requires no compatibility shim.

### luaossl: one line, and somebody has already asked

`GNUmakefile:15`:

```make
KNOWN_APIS = 5.1 5.2 5.3 5.4
```

That is the blocker. It is a **build-system enumeration, not a C API
incompatibility** — `src/openssl.c` guards on `LUA_VERSION_NUM` in three
places, which is not the profile of a library that needs porting.

Upstream issue [#221 "Support Lua 5.5"](https://github.com/wahern/luaossl/issues/221)
is open.

## What this changes

"Blocked upstream indefinitely" was the wrong summary. The accurate one:

> One dependency's makefile does not enumerate 5.5. Everything else akkar
> depends on is ready.

Three routes, in order of how much they cost us:

1. **Wait for #221.** Zero work, unknown date. luaossl is healthy — released
   September 2025, last commit July 2026 — so this is not the abandoned-library
   situation lua-http is in.
2. **Send the patch.** Add `5.5` to `KNOWN_APIS`, build, run luaossl's own
   regress suite under 5.5, open a PR against #221. If the three
   `LUA_VERSION_NUM` guards need work it will surface immediately.
3. **Carry it in our own rock.** The cqueues packaging problem — every user
   installs the 2020 release while CI tests a 2026 commit — is already pushing
   toward publishing pinned rocks. A `luaossl` built with 5.5 in `KNOWN_APIS`
   would ride the same mechanism.

Route 2 is the honest one to try first: it is a small patch to a maintained
library, and if it works it helps everybody rather than only us.

## What is NOT claimed here

Nobody has run akkar under Lua 5.5. This page says the dependency graph looks
ready, not that the runtime works — `<close>` in `akkar/static.lua`, integer
subtypes in `akkar/db.lua`, and every C module's build would all need to be
verified. That is a spike, and it has not been done.
