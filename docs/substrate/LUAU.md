# Luau — why the substrate cannot host it, and what akkar does instead

> **Status: DECIDED, 2 September 2026.** akkar's answer to static typing is a
> generated contract and editor annotations — path (c) below — not a typed
> dialect on the runtime. The reopen condition for path (a) is written at the
> end, and it is a product question, not a technical one.

`docs/why/production-scorecard.md` row 1 concedes the critique: Lua has no
static types, and the ecosystem's four answers do not agree with each other.
The obvious follow-up is "then why not Luau, which has a gradual type system
and a JIT and Roblox's engineering behind it?" This page is the answer, and
it sits beside `docs/substrate/LUAJIT.md` because it is the same kind of
question — a different runtime under the same code — with a harder wall.

---

## What Luau is

Checked against <https://luau.org>, <https://luau.org/compatibility> and
<https://github.com/luau-lang/luau> on the date above.

- "A small, fast, and embeddable programming language based on Lua with a
  gradual type system." It "aims to be backwards-compatible with Lua 5.1 and
  at the same time to incorporate features from later revisions of Lua", and
  offers "an extended version of Lua's C API".
- Written in C++: "the runtime requires C++11, while the compiler and
  analysis components require C++17". MIT.
- **It ships its own `lua.h`** — `VM/include/lua.h` in the repository, whose
  header says it "is based on Lua 5.x implementation", and which declares
  `luau_load` (a bytecode loader), `lua_newuserdatadtor`,
  `lua_pushcclosurek` and other extensions, and does not declare `lua_load`.
  The README states the consequence plainly: the runtime "mostly preserves
  Lua 5.1 API, so existing bindings should be more or less compatible with a
  few caveats" — source has to be compiled separately before it is loaded,
  and there is no `__gc`; a userdata gets a destructor through
  `lua_newuserdatadtor` instead.
- **What it refuses from 5.2–5.4**, with its own reasons, from the
  compatibility page: `goto` ("complicates the compiler, makes control flow
  unstructured and doesn't address a significant need"); 64-bit integers
  ("backwards compatibility and performance implications"), and therefore
  the integer subtype; bitwise operators (without native integers they "make
  less sense, as integers aren't a first class feature"); and `<close>`
  ("the syntax is inconsistent with how we'd like to do attributes
  long-term; no strong use cases in our domain"). It does have
  `string.pack` and a `utf8` library.

None of that is a criticism. Luau is a 5.1 dialect with a type system, built
for a host that owns every binding, and it is very good at being that.

---

## The asymmetry: one `lua.h` per process

akkar is Lua on top of a native layer, and every piece of that layer is C
compiled against **PUC-Lua 5.4's** `lua.h`:

| native module | what it is to akkar | where |
|---|---|---|
| `_cqueues` | the event loop, sockets, DNS, signals, threads | rockspec, CI pin, `Dockerfile` |
| `_openssl` (luaossl) | TLS, hashing, randomness | same |
| `cjson`, `lpeg`, luasocket | JSON, header grammars, one probe | `Dockerfile` |
| `akkar.pq_native` | the Postgres driver's C half | `src/akkar_pq.c` |

Each of them enters the VM through a `lua_State *` and the functions 5.4's
header declares. `src/akkar_pq.c` is the one akkar wrote itself, and it is a
fair sample: `#include <lua.h>`, a `lua_State *L` on every entry point,
`lua_newuserdata` for the connection, `luaL_newmetatable` for its type, and
`lua_pushinteger(L, (lua_Integer)strtoll(n, NULL, 10))` at lines 530 and 546
to hand an `int8` column back as a 64-bit integer. The cqueues source CI
builds installs `__gc` metamethods eight times, once per kind of resource it
hands to Lua.

Against Luau's header every one of those is either absent or means something
else. There is no `__gc`, so a cqueues socket would never close; there is no
64-bit `lua_Integer`, so a bigint column would round; there is no `lua_load`,
so `akkar.vm`'s loading of source into a sandbox would need Luau's compiler
in front of it. And it is not a matter of loading a 5.4 module into a Luau
state with a shim, because the two headers export the same `lua_*` symbol
names for different implementations — link both VMs into one image and
either the linker refuses or the loader silently picks one. **A process
holds one `lua.h`.** LuaJIT got as far as it did in `docs/substrate/LUAJIT.md`
precisely because it implements the 5.1 C API faithfully enough that cqueues
carries a `make all5.1` target for it; Luau's page says "more or less
compatible with a few caveats", and the caveats are the ones above.

This is the difference from the LuaJIT decision. LuaJIT was refused with a
measurement — 1.62x against a bar of 2x — after the substrate built. Luau
never reaches the measurement, because the substrate does not build.

---

## Why Astra can offer Luau and akkar structurally cannot

Astra (<https://github.com/ArkForgeLabs/Astra>) describes itself as "a Rust
based runtime environment for Lua (5.1-5.5), Luau and LuaJIT", and its
`Cargo.toml` says how: one dependency, `mlua = { version = "0.11.6", features
= ["anyhow", "async", "macros", "send", "serialize", "vendored"] }`, and a
feature per VM — `luajit` (the default), `luajit52`, `luau` (mapped to
`mlua/luau-jit`), `lua51` through `lua55`. mlua's own README states the
contract: "you have to enable one of the features: lua54, lua53, lua52,
lua51, luajit(52) or luau, according to the chosen Lua version."

That works because **every binding in Astra is Rust written against mlua's
abstraction, not C written against a `lua.h`.** Choosing a VM is a compile
flag; the bindings recompile against whichever header the flag selects; the
HTTP server, the database driver and the event loop are Tokio and SQLx and
never touch the VM at all. The VM is a guest of the runtime.

akkar is the other way round. The VM is the host; the event loop, TLS and the
driver are C modules that live inside it and were written by other people
against 5.4's header. There is no flag to flip, because there is no
abstraction layer between akkar's native modules and `lua.h` — and adding
one would mean rewriting cqueues, luaossl and the driver against it, which is
the work of building a different runtime. This is not "akkar has not got
round to it". It is what "Lua on cqueues" means.

The trade Astra makes for that flexibility is recorded elsewhere and is not
this page's argument: `docs/why/one-process-per-core.md` cites the audit of
Astra at `885586c` — one global VM behind mlua's `ReentrantMutex`, held for
the whole of a non-yielding handler — as the shape akkar avoids by having no
thread knob at all.

---

## The three paths, priced

**(a) Luau as a guest VM for handlers only.** Keep 5.4 as the host for
cqueues, lua-http and `pq`; embed Luau's C++ runtime as a second VM; marshal
`req`, the response and every `db` call across the boundary. It is feasible —
Luau is built to be embedded — and the plan that approved this page priced
it as multi-month work that **regresses two properties akkar measures**. The
allocation ceiling: validating four fields costs 152 bytes today
(`bench/study/HTTP-OPTIMISATION.md`), which is the cleaned output table and
nothing else, and a handler in a second heap means copying every field of it
across, twice per request. The deadline and the watchdog: today a deadline is
a number carried into `cqueues.poll` on the loop the handler runs on
(`akkar/execution.lua`); a handler on a second interpreter is interruptible
only through that interpreter's own callback, and every `db` call inside it
is a host call back across the boundary, each of which has to honour the
deadline again. What it buys is a sandbox, and `docs/wasm/DECISION.md` has
already worked out that the positioning does not ask for one — and that if it
ever does, a Wasm component is a stronger boundary than any Lua-family VM,
because it is an address space rather than an allowlist.

**(b) Luau's type tooling over akkar's 5.4 source.** Run `luau-analyze` on
the tree, ship on 5.4. This is a non-starter twice over. A `: type`
annotation is a syntax error to the 5.4 parser, so the annotated file cannot
be the file that runs without a strip step in the build — a dialect and a
compiler, which is the thing choosing one runtime was meant to avoid. And
Luau's parser rejects akkar's idioms outright: the inventory in
`docs/substrate/LUAJIT.md` — fourteen bitwise sites across seven files, four
`<close>` in `static.lua`, `//` in three files, `math.type` at six sites,
`goto` in `akkar/jobs.lua` — is exactly the list of things Luau's
compatibility page declines to implement. The runtime would have to be
written in Luau's subset of Lua to be checked by Luau's checker, and the
subset is the one without integers.

**(c) A generated contract plus editor annotations.** The route schema is the
type, it already runs (`akkar.validate`), it already projects to an OpenAPI
document (`akkar/openapi.lua`), and `akkar gen` (`akkar/gen.lua`) projects
the same document to a TypeScript client whose wrong calls are `tsc` errors —
proved red/green in `spec/gen_spec.lua`, kept current by the `--check` step
in CI. The Lua side of the same projection — per-route Teal records so
`tl check` sees `req.body`'s real shape instead of `any`, and LuaLS
`---@class`/`---@field` annotations that cost nothing at runtime and need no
dialect — is **in progress**; today `types/akkar.d.tl` types `params` as
`{string: any}` and there are zero `---@` annotations under `akkar/`. No
change to the substrate, no second VM, no build step between the file the
author writes and the file that runs.

---

## The decision

**(c).** It is the only path consistent with a runtime whose value is that
it chose one Lua and one native layer, and it is the one that has already
delivered something: a frontend cannot call a route with the wrong field.

What (c) does not give, said plainly so the choice is understood as a trade.
It types the **boundary** of a handler, not its body. A Luau handler would
have `local total: number = order.amount * qty` checked on the author's
screen; an akkar handler has `order.amount` guaranteed an integer at least 1
by the time the body runs, and nothing checking what the body does with it
until Teal or LuaLS records exist for that route. Row 1 of the scorecard
calls that "neutralized for safety; a DX gap remains", and this page is the
reason the gap is closed with annotations rather than with a runtime.

**Reopen (a) when** running handler code the operator does not trust becomes
a product goal — customer plugins, real multi-tenancy, the hosted shape the
design notes keep circling. That is the same trigger `docs/wasm/DECISION.md`
names, and when it fires the comparison is Luau-as-guest against
Wasm-as-guest, both paying the marshalling cost, with Wasm holding the
stronger isolation claim. Nothing about types reopens it: the types will be
in the contract by then.

## What this page does not say

- It does not measure anything. LUAJIT.md had a number to refuse with; this
  page has a header file, and a header file is a wall rather than a
  measurement. If somebody builds cqueues against Luau's `lua.h` and it
  loads, the argument above is wrong and this page should say so.
- It does not rank Luau's type system against Teal or LuaLS. Inside a
  function body Luau's checker is the best of the three, and (c) leaves that
  on the table on purpose.
- It does not close the "DX gap" of scorecard row 1. The in-progress items
  do, and they are marked as such rather than counted.
