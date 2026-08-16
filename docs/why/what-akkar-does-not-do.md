# What akkar deliberately does not do

A list of exclusions is only worth reading if it also lists its own reversals.
This one does, because two entries on it have been retracted and pretending
otherwise would make the rest untrustworthy.

`docs/BACKLOG.md` keeps the live version of this table, "written down because
the list keeps trying to grow". This page explains it and says what to use
instead.

## The retractions, first

### Migrations. Excluded, then built.

`docs/PLAN.md` section 1 lists migrations under "permanently out of scope",
grouped with the ORM. `docs/BACKLOG.md` repeated it. **That exclusion is
retracted**, and `docs/ROADMAP.md` section 2.1 is titled "AND THIS REVERSES A
DOCUMENTED DECISION".

The argument for reversing it is that the grouping was the mistake:

> an ORM is an opinion about modelling, which akkar refuses, while a migration
> runner is a ledger of applied files and a lock, with no opinion about a
> schema at all.

And a second reason that did not exist when the exclusion was written: **`akkar
build` produces a binary whose whole promise is "copy it to a server", and a
binary that cannot bring its own schema forward has an incomplete promise.**

It is now `akkar/migrate.lua`, kept deliberately small: plain SQL files, up
only, applied in order, recorded in a table, guarded by an advisory lock so two
instances starting together cannot both run them. **No down-migrations**, on
the grounds that they are usually wrong under real data and encourage
pretending a deploy is reversible.

The operational catch is in `docs/DEPLOY.md`: migrations cannot run from the
`scratch` image, because `io.popen` needs a shell and `scratch` has none.

### `akkar build`. Excluded for a reason that was wrong.

The entry read:

> Attractive, but Redbean is a *different substrate*, and `cqueues` is a C
> module. That is a substrate change, not a packaging step.

True of Redbean. It does not follow for a C module, because static linking
changes no substrate. A one minute probe put cqueues running an event loop
inside a single 1.5 MB binary. See `docs/why/what-the-runtime-is-for.md`.

### CI, a docs site, versioning, ADRs. Excluded with an audience that changed.

These were out because "the audience is my own use". The audience is now
public, so they came back. `docs/PLAN.md` section 1 keeps the old objective
next to the new one rather than overwriting it.

One piece of that is still deliberately absent, and it is not an oversight:
**there is no version number, no CHANGELOG guarantee and no compatibility
promise until 1.0.** The rockspec stays at `dev-1`. A version number is a
promise, and there are two things this project cannot promise: the substrate
depends on a commit of cqueues that upstream has never released, and the API is
still moving under measurement. Pin a commit and expect it to change.

## What is still excluded, and what to use instead

### An ORM, and models

**Use:** plain SQL through the adapter, and `akkar.sql` when you need to
compose conditions.

`docs/DECISIONS.md` section 5 had a query builder as option B and rejected it
as "halfway" to an ORM. What exists instead is narrower: `akkar.sql` marks
values with `?` and numbers them into `$1, $2` once at assembly, so conditions
added in different places compose without anyone tracking indices. There is no
`where_raw`, because an escape hatch is where the injection goes.

The one place akkar does insist on a builder is tenant scope, and that is for a
structural reason rather than an aesthetic one: a string cannot be scoped
without parsing it, and a SQL parser in the framework would be a second, worse
database.

### Templating, HTML, forms, an asset pipeline, scaffolding

**Use:** a different framework. This is not a gap to be filled later.

`docs/ROADMAP.md` considered the other reading of "a complete web framework" on
16 Aug 2026 and rejected it, and the reason is the one in
`docs/why/handlers-return.md`:

> a renderer wants to stream into a response that is still being assembled,
> which is precisely the mutation the design refuses.

A server-rendered akkar "would not be akkar with more features. It would be a
different framework that happened to share the event loop, and it should be
decided as one, with its own name and its own invariants".

Serving static files is a separate thing and akkar does it. `docs/ROADMAP.md`
is explicit that this is "not a step toward server-rendered HTML: serving a
file and rendering a page are unrelated jobs".

### Vendor adapters for payments, storage and mail

**Use:** the capability contract, with the vendor behind it.

The backlog entry reads "Past 'JSON API framework'. Own the contract, let
libraries implement." Read it as being about *vendor* adapters rather than
about the capability, which is how `docs/ROADMAP.md` reads it when it builds
mail anyway.

Two of the three have since shipped, and how they shipped is the point:

- `akkar/storage.lua` is object storage over HTTP, S3-compatible, and adds **no
  dependency at all**: the transport is `akkar.http` and the arithmetic is
  `akkar.crypto`. It is not an S3 adapter; it speaks the dialect that S3, R2,
  B2, Spaces, MinIO and Garage all share.
- `akkar/email.lua` sends over a provider's HTTP API and **names no provider in
  its interface**.

There is no payments module and there is unlikely to be one.

### SMTP

**Use:** a provider's HTTP API, which is what `akkar/email.lua` does.

The reasoning is worth repeating because it is not squeamishness about work.
Doing SMTP properly means ESMTP negotiation, STARTTLS, AUTH in three
mechanisms, line-ending canonicalisation, dot-stuffing, MIME multipart assembly,
RFC 5322 address parsing and a retry policy with its own state, **and none of
that gets an email delivered**, because a message sent straight from an
application server without SPF, DKIM and a warmed sending IP lands in spam or is
refused outright.

If SMTP is ever wanted it belongs in `akkar/smtp.lua` as a transport
`akkar.email` can be handed. The seam is already there.

### Signing JWTs

**Use:** `akkar.session` for logins, and `akkar.jwt.verify` for assertions
somebody else issued.

`akkar/jwt.lua` has `verify` and nothing that mints. This is the strongest form
of an exclusion in the whole project: a missing function whose absence is the
argument. See `docs/why/sessions-not-jwt.md`.

### An isolated VM for hostile code

**Use:** a separate process with an OS-level sandbox.

`akkar/vm.lua` runs untrusted code in a curated `_ENV` with text-only loading,
an instruction budget and a memory ceiling. Within those limits it is real.
Beyond them it is **not a security boundary against a determined attacker
sharing your process**, and the module refuses to pretend:

> If the code is hostile rather than merely untrusted, run it in a separate
> process with an OS-level sandbox. That is not a nicety; it is the difference
> between a bug and a breach.

The reason is a fact about Lua rather than about akkar: Lua 5.4 cannot create
an isolated state from Lua. That needs C or a subprocess.

`docs/wasm/DECISION.md` studies the alternative honestly, including the part
that favours it: a Wasm module is an address space rather than an allowlist, so
it has no instruction that addresses memory outside itself and cannot *name* a
capability that was not declared as an import. That study is **not decided**,
and it is blocked on a number rather than an argument. It also states what Wasm
would not fix: it carries pure computation, not systems software, because a
component brings no sockets, no TLS and no async runtime.

### A benchmark laboratory in eight frameworks

**Use:** the two comparisons that exist. The backlog's reason is that "the
cheap version captures most of the value: compare against Gin and FastAPI,
which I already write daily and which need no toolchain".

## Things that are missing rather than excluded

The difference matters. These are not decisions, they are work not yet done,
and `docs/ROADMAP.md` sequences them.

- **WebSocket.** lua-http has an implementation. The real question is
  lifecycle: a long-lived connection outside the request and response model
  needs its own capability and its own shutdown story. Marked **"Not small."**
- **Streamed uploads.** A multipart body is buffered in memory under
  `body_limit`.
- **Lua 5.5.** The blocker is luaossl, whose makefile has no 5.5 target.
  cqueues master builds and runs an event loop under 5.5 once its vendored
  `lua-compat-5.3` is updated; the published rock is what pins 5.4. Measured by
  `docs/runtime/lua55-probe.sh`.
- **A static libpq recipe**, without which the C driver cannot ship inside a
  built binary.

## Where the list stops, by decision

`docs/ROADMAP.md` ends with a sentence that is the real summary of this page:

> **akkar is complete when it is complete for JSON APIs.** Tiers 0-4 below are
> that, and there is no Tier 5.

## What to read next

- `docs/BACKLOG.md`, "What is deliberately not being built", for the live table.
- `docs/ROADMAP.md`, for what is coming and in what order.
- `docs/PLAN.md` section 1, for the objective and the version policy.
