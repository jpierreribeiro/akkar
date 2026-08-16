# WebAssembly components in akkar — measured, undecided, and what would settle it

> **Status: NOT DECIDED, and not blocked on an argument.** It is blocked on
> one number that can be measured in an afternoon. This page says which
> number, why it is the one that matters, and what is already known so that
> nobody re-researches it.
>
> The order stands: the Postgres driver first. This is a study to make the
> decision cheap when it arrives, not a proposal to start building.

## The problem Wasm is a candidate for

Not performance. akkar owns its hot path deliberately — HTTP parsing, router,
socket polling, buffers, Postgres — and putting Wasmtime in the middle of that
would give away the property the project is built around.

The problem is the one `akkar/vm.lua` states about itself in its own header:
it is a sandbox inside a single Lua state, **not a boundary against hostile
code**, and its advice for hostile code is to run it in a separate process
under an OS sandbox. Wasm is the thing that turns that into a boundary inside
the process. Secondarily it is an answer to the ecosystem problem — a library
does not have to be a Lua library to be usable — which is the argument that
makes it interesting beyond security.

## What was verified, with the corrections first

**WASI 0.3 is real.** Released 11 June 2026, ratified by the WASI Subgroup,
adding `async func`, `stream<T>` and `future<T>` to the Component Model. This
was checked because it sounded too convenient to be true. It is true.

**A C host CAN instantiate components today.** This was the premise most
likely to kill the idea and it is out of date: Wasmtime's C API ships 154
`wasmtime_component_*` symbols with a typed host-function linker, resources,
and an AOT path. A minimal C host was compiled and run against the official
`libwasmtime.a` to confirm it rather than to trust the header count.

**WASI 0.3 does NOT reach the C API.** `nm` over `libwasmtime.a` finds zero
`wasip3` symbols; the component linker in C offers `add_wasip2` and nothing
newer. Issue #13705, open since 22 June 2026, asks for the status of async
Component Model in the C API and lists what is missing; no maintainer has
answered. **So for a C host the ceiling is components plus WASI 0.2**, and the
headline feature of the June release is Rust-only territory today.

**`wit-bindgen` is guest-side only**, and says so: *"Executing a component in
a host is not managed in this repository."* There is no host binding generator
for C, so marshalling is hand-written against a 23-case tagged union, with no
static checking. The "any language via WIT" story is true for whoever *writes*
the plugin and is manual labour on akkar's side.

## The number that decides it

| | measured |
|---|---|
| akkar today | **5.08 MB** |
| C host that merely touches the component API, stripped | **24.8 MB** |
| `libwasmtime.a`, full | 65 MB |
| Wasmtime `min/` build | 2.6 MB — and runs **no** components, no WASI, not even `wasmtime_module_new` |

**Six times the binary**, against a number that is in the project's own pitch:
`docs/RUNTIME.md` sells a single self-contained artefact you copy to a server.
Going from 5 MB to 30 MB does not destroy that pitch, but it is a real cost
paid in the one dimension the runtime was justified on.

The alternatives do not help:

| | size | components? |
|---|---|---|
| WAMR / iwasm | ~1 MB on x86-64 | **none** — zero mentions of the Component Model in the repository |
| wasm3 | 422 KB | **none**, and last tagged release is June 2021 |
| WasmEdge | 110 MB host | absent from the C API; roadmapped for Q3 2026, not delivered |

> The famous WAMR footprint of ~58.9 KB is Cortex-M4F, not x86-64. Quoting it
> for a server build would be the same class of mistake as comparing 330 us
> against 32 us across two different machines, which this project made and
> corrected in `bench/driver/RESULTS.md`.

Without components, "a plugin in any language via WIT" becomes "a plugin in
C or Rust with an integer ABI", which is a different and much smaller idea.

## THE EXPERIMENT

One spike, on the study machine, answering one question:

> Built from source with the minimum feature set that still runs components —
> `component-model,component-model-async,cranelift`, without `wasi`,
> `wasi-http`, `gc`, `winch`, `profiling` or `cache`, at `opt-level=s`,
> `panic=abort`, `lto=true` — linked into a C host that instantiates a
> component exporting `transform(string) -> string` and importing one
> host function shaped like `db`:
>
> **does the resulting binary come in under about 10 MB?**

- **Under 10 MB:** the rest is engineering, and this page becomes a plan.
- **Still 25 MB:** the honest answer is that akkar keeps `akkar/vm.lua` for
  hooks that are untrusted but not hostile, moves genuinely hostile code out
  of the process, and Wasm goes back in the drawer until the C API slims down.

A known obstacle to that build: `--no-default-features` with
`component-model` **does not compile** in Wasmtime v47.0.3 — 21 errors from a
macro the C API's component feature needs and the default set supplies. The
spike has to find a working minimal set, and that is part of the answer.

As a by-product the same spike measures the async story on real hardware,
which is the second open question below.

## Async, which is better than expected and has one sharp edge

**"Wasm plugins must be short and pure" is not the honest answer.** There is
real yielding, at two levels:

- `wasmtime_context_epoch_deadline_async_yield_and_update` **preempts the
  guest**. This is strictly more than akkar can do to a C function:
  `akkar/work.lua` documents that a C function running 250 ms cannot be
  yielded because there is no point at which Lua resumes control. A Wasm guest
  can be interrupted; an opaque C function never will be. **Wasm is better
  than C on exactly the axis this project worries about C.**
- Host functions can suspend: the async continuation returns false to keep
  yielding, so a plugin's `db.select` can wait for Postgres while cqueues runs
  other requests.

The sharp edge, and it is imposed rather than chosen: Wasmtime issue #12991
(open) — `wasmtime_call_future_poll` uses a no-op waker, so the caller cannot
know when the future can make progress and must **busy-poll**. In a
cooperative loop that means spinning instead of sleeping. Workable by polling
on the cqueues tick; it needs measuring, not assuming.

Two more costs to size: the default async fiber stack is **2 MiB per
execution**, which is orders of magnitude more than a Lua coroutine and scales
with concurrency; and one live future per store at a time pushes toward a
store per request, which is good for isolation and costs instantiation.

## What the design already decides, regardless of the size answer

`docs/wasm/akkar.wit` is written, and two of its properties are forced rather
than chosen:

- **The world imports exactly `db`, `cache`, `log` and `clock`.** akkar's
  capability set is closed and a plugin must not widen it. The linker is built
  **per request**, with each host function closing over that request's
  capabilities, so a plugin cannot reach `db` when the request did not carry
  one — the function is simply not defined in that instance's linker. Unknown
  imports trap rather than resolving to stubs.
- **There is no `query(string)`, and there cannot be.** `akkar/scope.lua:15`
  refuses raw SQL and says why: *"a string cannot be scoped without parsing
  it."* Tenant scope is what makes a multi-tenant application safe by
  construction, and an interface taking a SQL string hands a plugin the one
  value that escapes it. So the database interface is builder-shaped and the
  **scope is not a parameter anywhere in it** — the host takes it from the
  running request, so a plugin has no vocabulary for the question.

That second point is the most useful thing this study produced, because it
holds whether or not Wasm is ever adopted: any extension mechanism akkar
grows, in any technology, has to be builder-shaped for the same reason.

## What is deliberately not being considered

- **Compiling akkar itself to Wasm.** It would give away sockets, polling and
  buffers — the hot path the runtime exists to own.
- **Running Lua inside Wasm inside akkar.** Only makes sense where Wasm is the
  requirement, such as a browser.
- **Replacing native extensions with Wasm wholesale.** For the Postgres
  protocol, TLS and JSON, native is the right answer and the driver measured
  in `bench/driver/RESULTS.md` is the evidence.
