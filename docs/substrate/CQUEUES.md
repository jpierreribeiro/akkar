# cqueues — the substrate risk, owned

`docs/why/production-scorecard.md` gives row 4 — "no standard event loop; the
one akkar chose is stagnant and Unix-only" — the verdict **real risk, the
largest one**, and points here for the account. This page is that account:
what is true about upstream as of 2 September 2026, what a `luarocks install`
gets and what CI proves, why the project has not forked, what `akkar build`
does about it, and the conditions under which a fork would be the right
answer after all.

The one-line version: **akkar carries no patch to cqueues, and it does not
need one; what it needs is to ship the commit it tested, and `akkar build` is
how it does that.**

---

## What is true about upstream

Checked against <https://github.com/wahern/cqueues> on the date above.

- **Last release: `rel-20200726`**, 26 July 2020. The tag before it is
  `rel-20200603`. The LuaRocks rock is `cqueues 20200726`, and that is the
  rock the rockspec's `cqueues >= 20200726` resolves to.
- **Master is not abandoned, and the delta is small.** The repository has
  1,035 commits. The compare view from `rel-20200726` to `master` reports
  **16 commits and 12 files changed**, and the ten most recent are all dated
  18 March 2026: "add Lua 5.5", "in lua 5.5 lua_pushvfstring can return
  NULL", "libressl 3.5.0 made bio structs opaque", "handle kqueue/inotify
  (freebsd-15.0 and later)", and a handful of warning fixes. The head of that
  batch, `c366149`, is the commit CI pins. `docs/substrate/SEGFAULT.md`
  measured the same delta from the other side: `cqueues.c` differs by seven
  lines between the release and the pin.
- **Unix only, and Windows has been "planned" for longer than the last
  release has existed.** The README: cqueues "should work on recent versions
  of Linux, OS X, Solaris, NetBSD, FreeBSD, OpenBSD, and derivatives", and
  "Windows support is planned, though initially by relying on BSD `select`".
- MIT licence, one author.

A correction this page owes the tree. The rockspec, `.github/workflows/ci.yml`
and `Dockerfile` each describe master as carrying "six years of fixes on top
of" the rock. Six years is the calendar; sixteen commits is the change, and
almost all of it landed in one afternoon. That is a better fact for akkar
than the phrase suggests — a small, legible delta is what makes pinning a
commit defensible — and a worse one for anyone hoping the pin repairs
something the release had wrong. SEGFAULT.md already found out that it does
not.

---

## Two builds, and only one of them is tested

`akkar-0.1.0-1.rockspec`, lines 46–51:

> ONE HONEST GAP, stated rather than hidden. `cqueues 20200726` is the last
> PUBLISHED rock; upstream master has six years of fixes on top of it,
> including Lua 5.5 support. CI builds from a pinned commit of master
> (`.github/workflows/ci.yml`), which LuaRocks cannot express -- so what a
> `luarocks install` gets and what CI proves are not the same build. That is
> the strongest single argument for `akkar build`; see `docs/RUNTIME.md`.

The mechanics behind that paragraph:

- **CI** exports `CQUEUES_COMMIT: c36614982fe07917b2e1ce5a9e7a0e55b81be262`,
  clones upstream, checks the commit out, runs `make all5.4` against the
  matrix's Lua, and installs the result. Then it asserts that the pin is what
  `require "cqueues"` actually returns, and the assertion exists because for
  a while it was not. The workflow's own comment records it: installing
  `http` — a test dependency, kept because `spec/framing_spec.lua` and
  `spec/fuzz_spec.lua` speak to akkar's server through somebody else's
  client — dragged in the release rock, and LuaRocks moved the hand-built
  `_cqueues.so` aside to make room. "`CQUEUES_COMMIT` has never been what CI
  tested — the release tarball was." The probe that closed it reads
  `cqueues.COMMIT`, a field that only exists when the build passes
  `-DCQUEUES_COMMIT` (`src/cqueues.c:2955`), so the release rock fails the
  check by not having the field at all.
- **`Dockerfile`** pins the same hash as an `ARG`, clones and checks it out
  in the builder stage, and never installs a cqueues rock. The 6.4 MB
  `scratch` image `docs/DEPLOY.md` measures contains the pinned commit and
  nothing else.
- **`luarocks install akkar`** gets `cqueues 20200726`. Nothing in the
  rockspec can say otherwise, because a rockspec names versions and not
  commits.

So there are three ways to obtain akkar and two builds of its event loop
among them, and the one a reader reaches for first is the one CI has never
run. That is the risk, stated as narrowly as it can be. It is not "cqueues is
dead"; it is "the artefact the package manager hands out is not the artefact
the suite ran against".

---

## Why Windows is not the gap

The scorecard says it briefly; the longer form is that Windows would not
become a target by fixing cqueues, because cqueues is the first Unix-shaped
assumption and not the only one.

- `docs/PLATFORMS.md` lists Windows as "not supported, and not planned", and
  `docs/UNKNOWNS.md` had already said "almost certainly not, and saying so is
  better than leaving it ambiguous". CI runs Linux x86-64, Linux arm64 and
  macOS on Apple Silicon.
- `docs/why/one-process-per-core.md` is the capacity model: one Lua VM is one
  core, so capacity is several processes sharing a port through
  `SO_REUSEPORT`, with the kernel balancing accepted connections between
  them and no proxy in front. That is a Unix facility and a Unix way of
  running a service.
- The deployment target is a static executable from `akkar build` in a
  `scratch` container (`docs/DEPLOY.md`), and the C driver, `src/akkar_pq.c`,
  hands libpq's socket descriptor to the event loop (`pq_pollfd`) so a query
  waits without blocking the process. Every one of those is written against
  a POSIX descriptor and a POSIX process.

A port would be a different runtime with the same name, and nobody has asked
for it. The honest sentence is the one PLATFORMS.md already has.

---

## Why not fork, yet

akkar has forked a dependency once, and the reasons are the useful
comparison.

`akkar/vendor/http/PROVENANCE.md` carries lua-http 0.4 because akkar
**patches** it: 11 of its 22 files, with akkar's own denial-of-service
repairs and two upstream fixes backported by hand, against an upstream whose
last release is 2021 and whose last commit is 2024-09-08. The fork is the
patches, and the ledger plus `spec/vendor_provenance_spec.lua` exist because
carrying patches without a ledger went wrong within a day.

cqueues has none of that:

- **Zero akkar patches.** Nothing under `akkar/` modifies cqueues source, and
  no build step applies a diff. `akkar/substrate.lua` reaches into
  lua-http's internals; it does not touch cqueues'.
- **It builds clean from the pin, everywhere it has been tried.** The CI
  matrix compiles it on x86-64, arm64 and macOS, and
  `docs/substrate/LUAJIT.md` compiled the same commit against LuaJIT with
  `make all5.1` and ran it. The Lua 5.5 job builds it against 5.5.
- **The only native crash so far did not need a cqueues change** — see the
  next section.

A fork with no patches is a mirror with a maintenance bill: a second name to
publish, a second place for a CVE to be missed, and — because lua-http's rock
still depends on `cqueues` by name — the exact overwrite CI already fought,
now between a mirror and its original. It would buy a rock that names the
commit, which is a packaging fact, and it can be bought later in an afternoon
if a trigger below fires.

---

## The mitigation that is the answer: `akkar build`

The gap is "the artefact that ships is not the artefact that was tested".
`akkar build` closes it by making the artefact contain the event loop rather
than depend on it. Two subcommands in `bin/akkar`, both implemented in
`akkar/build.lua`.

**`akkar archive cqueues --source DIR --lua-inc DIR [--lua-api 5.4] [-o cqueues.a]`**
turns an unpacked source tree — at whatever commit the caller checked out —
into one static archive. `build.lua` keeps a recipe per library rather than
one algorithm, and its comment says why: every C rock builds differently, and
"a generic 'compile every .c and archive it' gets three of those wrong". The
cqueues recipe runs `make all5.4`, collects `src/5.4/*.o` and `src/lib/*.o`,
and renames on the way in because both directories define `socket.o`,
`dns.o` and `notify.o`. The known recipes are `cqueues`, `luaossl`,
`lua-cjson` and `lpeg`; anything else is a loud failure "rather than a
plausible archive that fails at link time".

**`akkar build app.lua --archive cqueues.a --archive luaossl.a … --lua-lib liblua.a --lua-inc DIR -o myapp`**
emits a C host and links it. The host embeds every Lua module as source in
`package.preload`, and registers every native module under its real name —
which is the detail a generic bundler gets wrong, and the reason akkar writes
its own host. `luaopen__cqueues` is `_cqueues`, not `.cqueues`; `build.lua`
reads the archive's `luaopen_` symbols with `nm`, maps every literal
`require "x"` in the embedded sources forward to its symbol, and treats a
leading underscore as part of the name. The link is `-no-pie -rdynamic`
because luaossl asks the loader for the running image and a
position-independent executable cannot be reopened that way.

The result for this page: the binary contains the cqueues its builder chose
by commit, there is no `_cqueues.so` on the target for a package manager to
replace, and the `Dockerfile` does exactly this from `CQUEUES_COMMIT`. **Ship
the build and the "install ≠ CI" gap does not apply to what shipped.**

What it does not do, so nobody over-reads it. `akkar build` does not fetch
the source or choose the commit — the `Dockerfile`'s `ARG` is where the
decision lives, and moving it "is a decision with a diff". It is not a
cross-compiler; it builds for the machine it runs on. And it does not change
what `luarocks install akkar` gets: the rock path stays on the 2020 release,
and the rockspec keeps saying so, because the alternative is a rockspec that
lies.

---

## The one native crash already hit, and what it says about forking

`docs/substrate/SEGFAULT.md` is the full record. The shape of it matters
here.

An intermittent crash, every instance at the same instruction —
`table_LLRB_FIND`, `src/cqueues.c:1192`, a lookup in a pollset's descriptor
tree — first seen 17 August 2026 and resolved by a core dump on 2 September.
The site is C; the cause is Lua. `akkar/health.lua` allocated a private
controller per probe to arbitrate a timeout and, on timeout, dropped the
controller with the probe socket still registered in it. A later `connect`
that failed made cqueues cancel that descriptor across every controller in
the state (`cstack_cancelfd`), and one of them was the abandoned one. The fix
is akkar's, in `akkar/health.lua` (`8bf1a21`): run the probe as a worker on
the controller the caller is already inside, with the deadline as a bare
number in `cqueues.poll`, which is how `akkar/execution.lua` already runs
handlers. The proof is the CI matrix going green with it in, and at the time
of writing no run carrying it had.

Two things the investigation ruled out are the ones this page leans on.
AddressSanitizer over the whole suite found nothing, which is not
exoneration but does say the bug needed a race. And "the pinned commit is
not the fix": upgrading from the release to the pin changes seven lines of
`cqueues.c`, none of them near the tree. The crash was a misuse of a
correct library, and a fork would not have shortened the diagnosis by an
hour.

---

## When a fork becomes the right answer

Written down so the decision is a check against a list rather than a mood.
Any one of these is sufficient.

1. **akkar needs a patch to cqueues source.** A crash whose cause, unlike the
   one above, is in `cqueues.c`; a CVE upstream does not release for; a Lua
   version akkar supports that upstream does not. The day a diff exists, the
   lua-http pattern applies whole: a `PROVENANCE.md` ledger, a spec that
   asserts every patch is still present, and a row per file.
2. **Master stops building against a Lua akkar ships.** Today the pin builds
   against 5.4 and 5.5 and the `lua55` CI job is the sensor; it is not
   `continue-on-error`, on purpose.
3. **The rock path has to be fixed for people who will never run
   `akkar build`.** If `luarocks install akkar` on the 2020 release is shown
   to differ in behaviour from the pin in a way that matters — nothing has
   shown that yet, and the seven-line delta argues it will not — then a rock
   built from the commit is the fix, and that is a fork of packaging even if
   no source changes.
4. **Upstream becomes unreachable.** `Dockerfile` and CI both clone from
   GitHub at build time. A vendored tarball of the pinned commit in the tree
   is the cheap first step and needs no fork; it should happen before any of
   the above does.

Until one fires, the position is: pin, prove, ship the pin, and keep the
rockspec honest about the rest.

## What this page does not say

- It does not compare cqueues to another event loop. `bench/study/WHERE-THE-GAP-IS.md`
  puts the loop at 11.6 µs of a request, 11% of the whole, and a minimal
  server on it at 1.69x Gin; the loop is not where the time goes, and this
  page is about supply, not speed.
- It does not say the pin is safer than the release. Sixteen commits is too
  few to carry that claim and SEGFAULT.md showed the one crash to date lived
  in neither.
- It does not say the 2020 rock is broken. It says it is untested by this
  project, which is a different sentence, and the reason `akkar build`
  exists.
