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

### ~~HTTP/2, and therefore gRPC~~ — BUILT, 2026-08-18

**This section was written as an exclusion and survived about an hour.** It is
kept rather than deleted because how it fell is the useful part.

The argument for excluding h2 was that reintroducing it meant a second framing
layer, HPACK, flow control and a CVE surface of its own. Every clause of that
is true about WRITING an HTTP/2 stack. None of it was true about akkar's actual
situation, and the section did not check which one it was in.

What was actually required: the h2 half of **lua-http 0.4** — `h2_connection`,
`h2_stream`, `hpack`, `h2_error`, and the `bit` shim they share — is the same
release the h1 half here was vendored from. It was already installed on the
machine as a declared dependency. Bringing it in was a copy with the `require`
prefixes rewritten, plus four edits to the server: offer `h2` in `alpn_select`,
branch on it during negotiation, gate the cleartext preface sniff behind
`h2c`, and construct an `h2_connection` when the version is 2.

**Two things made that cheap, and both were decisions rather than luck.**

1. `connection_common`, `stream_common`, `tls` and `util` were never modified
   when the h1 half was vendored, so the h2 half found the interfaces it
   expected. Divergence is a tax paid later, and here the bill was zero.
2. When the per-request coroutine was removed from `handle_socket` for the
   3,900 bytes it cost, the inline call went behind `conn.version < 2` instead
   of replacing `add_stream`. That condition was written specifically so h2
   could return without anyone rediscovering which line mattered — and it is
   the reason multiplexing worked on the first try.

**One thing was NOT cheap and had to be checked rather than assumed.** akkar's
`headers.lua` diverges from upstream by 239 lines, and one of those changes
dropped `never_index` from every header entry for 432 bytes a request, on the
stated grounds that it is HPACK's flag and HPACK had gone. HPACK reads that
flag in two places. Neither breaks — Lua discards the extra argument and the
missing third return reads as nil — so every field takes the ordinary indexed
path. What is lost is the ability to mark a field "never place this in the
dynamic table", a hint upstream only ever set when asked. `spec/http2_spec.lua`
asserts what is not lost: names, values and count survive a full round trip.

**Measured on this machine**, six 0.5 s requests over one connection:

| | wall clock |
|---|---:|
| HTTP/2, one connection, six streams | **552 ms** |
| HTTP/1.1, one connection | 3,071 ms |

And ALPN had one silent failure worth recording, because nothing reports it.
akkar builds its own TLS context from `certificate` and `key` rather than going
through lua-http's `new_ctx`, so it never received the ALPN callback: a browser
negotiated HTTP/1.1 against a server that spoke h2 perfectly well, the
handshake succeeded, the request was answered, and the multiplexing simply
never happened. **A feature that is merely unreachable produces no error at
all.**

**What is still excluded is HTTP/3**, and that exclusion is the one this
section's argument actually fits. QUIC is a UDP transport with its own
congestion control and TLS integration; neither cqueues nor lua-http has it,
and there is no half of anything sitting on disk to vendor. Behind a proxy it
costs nothing, which is where h3 is terminated in practice.

**And h2's framing has no fuzz suite here yet.** `spec/fuzz_spec.lua` covers
h1, where request smuggling lives. The h2 framing layer is upstream's,
unmodified, but akkar has not fuzzed it — that is a gap, and it belongs on this
page rather than in a commit message.

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

> **Half of this was overtaken, 2 September 2026.** There *is* now a version
> number (`0.1.0`), a CHANGELOG, and a compatibility policy at
> `docs/COMPATIBILITY.md`. What survives unchanged is the part that was ever the
> point: **no stable-API promise until 1.0**, and for exactly the two reasons
> above — the unreleased cqueues commit, and an API still moving under
> measurement. A `0.x` number is a way of publishing that honesty on
> luarocks.org, not a retraction of it; `RELEASE.md` is what publishing takes.

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

- ~~**WebSocket.**~~ **Built 2026-08-19.** The lifecycle question was the real
  one and it had an answer that did not cost the invariant: a socket is three
  callbacks and an object, not a handler that runs for hours, so handlers still
  return. The two halves that looked hard turned out to be the same decision --
  capabilities are acquired per MESSAGE through `ws:scope`, because a message
  is the unit of work a request already is, and `app:stop` TELLS sockets to go
  with a 1001 close frame rather than draining on connections that have no
  reason to end. It cost no new dependency: `basexx`, `lpeg` and
  `lpeg_patterns` were already declared for the vendored `request.lua`, and the
  `compat53` requires are guarded behind `string.pack`, which Lua 5.4 has.
- **Streamed uploads.** A multipart body is buffered in memory under
  `body_limit`.
- **Lua 5.5 packaging** — and the blocker this bullet used to describe is
  gone. luaossl's makefile still has no 5.5 rung, but its C compiles clean
  under one `cc`, and cqueues runs an event loop under 5.5 once its vendored
  `lua-compat-5.3` is refreshed. `docs/runtime/lua55-stack.sh` builds the whole
  stack into a prefix, **CI runs that same file as a blocking job**, and the
  suite passes: 1,763 tests, zero failures. What is left is packaging alone —
  no distribution ships 5.5 yet, so `luarocks install akkar` cannot, and 5.4
  stays the default for that reason and no other.
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
