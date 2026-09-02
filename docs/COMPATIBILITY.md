# Compatibility and versioning

> Written 2 September 2026. `CHANGELOG.md` already carries the reasoning for
> the *number* — "Why 0.1.0 and not 1.0.0" — and this document does not repeat
> it; it states the *policy* that number is shorthand for: what a version means,
> where the promise begins and ends, and which surface it is a promise about.
> `docs/PLAN.md` §1 is the source of the one rule everything here serves: **the
> public API never depends on the implementation of the substrate.**

## 1. What a version number means here

akkar follows [Semantic Versioning](https://semver.org) over its **stable
surface** (§3), with the ordinary 0.x carve-out and one akkar-specific
refinement.

| change | before 1.0 (`0.MINOR.PATCH`) | after 1.0 (`MAJOR.MINOR.PATCH`) |
|---|---|---|
| Breaks the stable surface | allowed on a **MINOR** bump, listed in the changelog | **MAJOR** only |
| Adds to the stable surface | MINOR | MINOR |
| Fixes without changing the surface | PATCH | PATCH |
| Rockspec-only change, no source change | **rockspec revision** (`-1` → `-2`) | rockspec revision |

Two refinements worth stating out loud, because they are not free-floating
conventions but fall straight out of decisions already made:

- **A MINOR is additive by construction, not by promise.** `docs/PLAN.md` §2's
  complexity ladder — *"climbing a rung must never require editing code written
  on the rung below"* — is the same guarantee SemVer calls a backward-compatible
  addition. A new capability, a new module, a new `app:run{}` option: each is a
  new rung, and the ladder's checkable rule is why adding it is a MINOR and not a
  MAJOR.
- **The rockspec revision is packaging, never code.** `akkar-0.2.0-**1**` and a
  hypothetical `akkar-0.2.0-**2**` install the *same tagged source*. A revision
  bump fixes the rockspec — a dependency bound, a missing module line — and moving
  code into it would defeat the reason the tag is pinned in the first place
  (`docs/PLAN.md` §5: *pin versions, commit the rockspec*).

## 2. The 0.x contract, and what 1.0 would add

Today akkar is `0.x`. Under `0.x`:

- The stable surface (§3) **may change on a MINOR bump**, and every change that
  breaks working code is listed in `CHANGELOG.md` under its existing heading,
  **"Changed — these break code that works today."**
- A **PATCH** (`0.x.y` → `0.x.(y+1)`) never breaks the stable surface. It carries
  fixes and corrections only.
- **Depend on akkar by pinning the version.** `luarocks install akkar` resolves
  the newest, which may have moved under you; a service pins `akkar == 0.2.0` and
  reads the changelog before it moves.

**1.0 is not a maturity badge; it is the moment three specific things become
true.** Two are named in `CHANGELOG.md` and one in `docs/PLAN.md` §1:

1. **A real application built on akkar by someone who did not write it.** Every
   defect found so far was found by engineering an exposure, not by use. `1.0`
   published before that would promise stability nobody has stressed —
   `CHANGELOG.md` and `docs/UNKNOWNS.md` make the case in full.
2. **A cqueues pin that survives one upstream release** — so that what
   `luarocks install` fetches and what CI proves are the same build. Until then
   the substrate promise has a hole in it (§5, and `RELEASE.md` §"The one honest
   gap").
3. **The three boundary breaches in `docs/PLAN.md` §1 closed** — `akkar.null`
   re-exporting cjson's sentinel, five modules requiring cjson directly, and
   `ctx` handing a luaossl context and lua-http's expectations into application
   configuration. These are the places the substrate implementation actually
   reaches the public API, and a stability promise cannot be made over a surface
   that still leaks the substrate's types.

`1.0` then commits to the ordinary SemVer promise: **no change to the stable
surface without a MAJOR bump**, for as long as 1.x lives.

## 3. Where the public API boundary is

This is the crux. A compatibility promise is meaningless until it says *which
surface* it is a promise about. akkar's boundary is drawn by a single test,
which is the same test `docs/DECISIONS.md` §8 uses for adapters:

> **The stable surface is what an application is invited to name.** Everything an
> application never types is an implementation detail, and implementation details
> carry no compatibility promise — not even across a PATCH.

### Stable — the promise is about these

- **The application API on `app` and `req`.** `require("akkar").new()`; the route
  verbs `app:get/post/put/patch/delete` and friends; `app:use`, `app:mount`,
  `app:run{}`, `app:test{}`, `app:stop`. On `req`: the request data
  (`method`, `path`, `params`, `query`, `body`, `headers`), the closed capability
  set (`db`, `cache`, `log`, `clock` — `docs/DECISIONS.md` §7), and the identity
  fields (`req.id`, `req.client_request_id`).
- **The handler contract.** A handler *returns* its response; it never mutates a
  context. Returning a table is JSON; returning nothing is 204; `error()` is a
  500 with the traceback in the log and never in the body. These invariants
  (`docs/PLAN.md` §3) are load-bearing and are part of the promise.
- **The middleware contract.** `function(req, next) ... return res end` — `next`
  takes the request and *returns* the response, so a middleware can post-process.
- **The adapter / capability contracts.** The method sets a third-party
  implementation must satisfy: `db:one/many/exec/transaction`,
  `cache:get/set/del/incr/expire/ttl/command` (`docs/DECISIONS.md` §8). akkar owns
  the *contract*; `akkar.db`/`akkar.redis` are reference implementations, not the
  only permitted ones, and the contract is what is stable.
- **The public modules documented in `docs/reference/`.** `akkar.sql`,
  `akkar.stream`, `akkar.jobs`, `akkar.http`, `akkar.crypto`, `akkar.jwt`,
  `akkar.auth`, `akkar.session`, `akkar.scope`, `akkar.migrate`, `akkar.storage`,
  `akkar.email`, `akkar.limit`, `akkar.idempotency`, `akkar.etag`, `akkar.metrics`,
  `akkar.health`, `akkar.compress`, `akkar.static`, `akkar.websocket`, and the
  response helpers (`akkar.created`, `akkar.no_content`, `akkar.not_found`, …).
- **The CLI.** `akkar`, `akkar doctor`, and the launcher verbs as they are
  documented in `docs/reference/cli.md`.

**The rule of thumb: if it is documented in `docs/reference/` or shown in the
guide, it is stable surface. If it is not, it is not.**

### Explicitly NOT stable — no promise, at any bump

- **`akkar.vendor.*` — the vendored HTTP substrate.** The HTTP/1.1+2 half of
  lua-http lives under `akkar/vendor/http/`. It is the *current implementation*
  of the HTTP substrate and nothing else. An application must never
  `require "akkar.vendor.http.*"`. It may be optimised in place, re-vendored from
  a newer upstream, or replaced wholesale by a native transport, and none of that
  is a breaking change, because nothing on the stable surface names it.
- **`akkar.pq_native` — the C driver ABI.** The boundary between the C half
  (shipped by `akkar-pq`) and the Lua half (`akkar.pq`, shipped by `akkar`) is
  private. It is kept coherent not by a promise but by the lockstep pin in
  `akkar-pq`'s rockspec (`akkar >= 0.2.0, < 0.3.0`): a C module is never paired
  with a Lua half whose contract has moved. Application code passes
  `db.connect { driver = "pq" }`; it never touches `pq_native`.
- **The substrate build itself.** The pinned cqueues commit, the OpenSSL version,
  the exact JSON library — these are the replaceable details `docs/PLAN.md` §1
  names. Which cqueues is underneath is not a promise; *that akkar answers
  `app:get`* is.
- **Anything under `akkar.*` not in `docs/reference/`.** `akkar.substrate`,
  `akkar.bitwise`, `akkar.text`, `akkar.random`, `akkar.pool` internals and the
  like are machinery. Reach for them and you are on the wrong side of the line.

## 4. The vendoring answer

The handoff of 23 August (`docs/HANDOFF-2026-08-23.md`, "One premise to confirm")
flags a real-looking contradiction: project notes recorded the substrate
decision as *pin the upstream commit and write the executable contract,
explicitly **not** vendor or fork* — and the tree now contains
`akkar/vendor/http/`. It asks whether vendoring put akkar *"on the wrong side of
'the public API never depends on the substrate implementation'"* (`docs/PLAN.md`
§1). This is where that gets an answer rather than staying open.

**It did not, and the reason is that the rule governs a direction of dependency
at the API surface, not the packaging of the substrate below it.**

- The rule is about what an application may *name and rely on*. Before vendoring,
  akkar depended on the upstream `http` rock; after, it depends on its own copy
  under `akkar.vendor.http`. In **both** cases the dependency is internal, sits
  below the adapter boundary, and **no handler, no middleware and no stable
  module names it.** The public API's dependence on the substrate implementation
  was zero before and is zero after. Vendoring changed *who ships the bytes* — a
  packaging and lifecycle decision — not *whether the public API reaches through
  the boundary*.
- The proof that the boundary is intact is executable and predates the vendoring:
  `spec/substrate_spec.lua` is the statement of what any HTTP substrate must
  answer, and the vendored copy is one thing that answers it. A native transport
  that answered the same spec would be a MINOR-or-patch substrate swap, invisible
  to every application — which is the whole point of the boundary and the reason
  §3 declares `akkar.vendor.*` non-public.
- So vendoring is *on the correct side* of the rule, and this policy makes that
  structural: `akkar.vendor.*` carries **no** compatibility promise (§3), which
  is exactly what "a replaceable detail of the substrate" has to mean to be true
  rather than aspirational.

**What the rule is genuinely breached by is named, and it is not vendoring.** The
three breaches are in `docs/PLAN.md` §1: `akkar.null` re-exporting cjson's C
sentinel as public API, five modules requiring cjson directly, and `ctx` handing
luaossl and lua-http types into application configuration. Those are the places a
substrate type actually crosses onto the stable surface, and closing them is 1.0
work (§2). Conflating them with vendoring would let the real breaches hide behind
a packaging decision that is not one of them.

One caveat this policy does bind itself to, so the answer stays honest: **a stable
API must never begin returning or accepting a `akkar.vendor.*` value.** The moment
a documented function hands an application a vendored object, the boundary has
moved and that is a breaking change like any other. The vendored half is a
supplier of behaviour, never of types that reach the caller.

## 5. The substrate pin, stated rather than hidden

`akkar-0.2.0-1.rockspec` bounds `cqueues >= 20200726, < 20300000`. `20200726` is
the last *published* cqueues rock; the substrate akkar is actually tested against
is a pinned **commit of upstream master**, six years of fixes newer, built by hand
in CI (`.github/workflows/ci.yml`). **LuaRocks cannot express "install cqueues at
commit X of master,"** so what `luarocks install akkar` gets and what CI proves
are not the same build. The vendored HTTP half reaches into cqueues' behaviour,
which is why the pin exists at all.

This is a real limit on the 0.x promise and it is the strongest single argument
for `akkar build` (`docs/RUNTIME.md`, `docs/RUNTIME-1.0.md` §4): a distribution
that carries its own tested substrate closes the gap that LuaRocks structurally
cannot. Until then the honest statement is the one `RELEASE.md` makes: the
LuaRocks install is supported on a best-effort basis against the last published
cqueues, and the reproducible, tested platform is the built binary. Closing this
is one of the three conditions for 1.0 (§2).

## 6. Platforms

`CHANGELOG.md` states the tested matrix and this policy inherits it unchanged:
**Linux x86-64 and aarch64/musl are tested; macOS, Windows, 32-bit and everything
else are untested and named rather than implied** (`docs/UNKNOWNS.md`). A platform
moving from untested to supported is an additive change (MINOR). Lua 5.4 is the
default; Lua 5.5 runs the full suite but nothing packages it yet, so it is not a
supported install target — also a MINOR when it lands.

## 7. What to read next

- `CHANGELOG.md` — the running record, and "Why 0.1.0 and not 1.0.0".
- `RELEASE.md` — what a release runs, and what blocks one today.
- `docs/PLAN.md` §1 and §5 — the rule this policy serves, and "pin versions".
- `docs/DECISIONS.md` §7–§8 — the capability set and the adapter contracts, which
  are the stable surface §3 points at.
