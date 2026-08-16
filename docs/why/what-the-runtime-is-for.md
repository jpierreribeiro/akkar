# What `akkar build` is for, and what it is not

`akkar build` compiles an application and the whole framework into one
executable file.

```
$ akkar build serve-app.lua -o myapp --root ... --archive ...
akkar build: 369 Lua modules, 46 native modules -> myapp

$ ./myapp 8375 &
$ curl -i http://127.0.0.1:8375/users/7
HTTP/1.1 200 OK
x-request-id: 3824249f000001
content-type: application/json

{"id":7}
```

Routing, parameter validation, JSON, the request id, the whole cqueues and
lua-http stack, in one file.

## Start with what it does not buy

**It is not faster.** Nothing in `docs/RUNTIME.md` or `docs/DEPLOY.md` claims a
speed improvement, and there is no measurement of one anywhere in this
repository, because there is nothing to measure. The binary runs the same
Lua 5.4 VM on the same cqueues event loop, executing the same bytecode. The
probe that proved the idea says so in one line:

> The same cqueues, the same Lua 5.4 VM. Only the linkage changed.

Static linking changes where code is loaded from, not how it runs. If you are
reading this hoping for the throughput numbers in `bench/study/RESULTS.md` to
improve, they will not, and anyone who tells you a single binary is faster
should be asked for the before and after.

It also does not remove a dependency from your program. Every module is still
there; they are inside the file instead of beside it.

## What it does buy

### 1. Deployment stops needing a Lua environment

This was the whole problem. Deploying Lua normally means having Lua 5.4 on the
target, plus LuaRocks, plus a set of C modules that compile against the right
OpenSSL, plus the ability to reproduce that set on the next machine.
`docs/DEPLOY.md` opens by admitting that before it existed, "the shortest true
description of its deployment story was that there wasn't one".

The measured result, all of it from one afternoon on Linux 6.8 x86-64 with
Docker 28.2.2:

| | |
|---|---|
| Final image, `scratch` | **6,395,313 bytes, 6.4 MB** |
| The binary inside it | 6,177,544 bytes, 6.2 MB |
| The CA bundle beside it | about 218 KB, the rest of the image |
| Shell-bearing variant, `--target slim` | 14,492,687 bytes, 14.5 MB |
| Cold build, `--no-cache` | 3 min 01 s |
| Rebuild after editing the app | 15 s, of which 8.8 s is `akkar build` |
| Resident memory, idle, serving | 6.7 MiB |
| Graceful stop on SIGTERM, no traffic | 0.38 s |

A `scratch` image has no libc in it at all, and that binary still serves HTTP,
resolves DNS and queries Postgres from inside it.

Note the honest correction attached to those figures. `docs/RUNTIME.md` reports
**5.08 MB**, and that was a glibc binary still linking `libssl.so` and
`libcrypto.so` dynamically. The 6.2 MB one has OpenSSL inside it and needs no
libc on the host. `docs/DEPLOY.md` frames the difference as the trade it is:
"A megabyte for 'runs on an empty image'".

There is a second correction hiding in the size. The static binary as linked is
**21,759,272 bytes** and after `strip` it is 6,177,544. **Seventy-two percent
of the unstripped artefact is debug tables**, DWARF from the statically linked
C, OpenSSL most of all. An unstripped static binary is not a 21 MB runtime; it
is a 6 MB runtime carrying its dependencies' symbol tables into your registry.

### 2. Dependency control

The build reads every literal `require` out of the sources it is about to embed
and maps names to symbols forward, then checks the archive defines them. Nobody
guesses. `docs/RUNTIME.md` explains why that mattered: reversing the C naming
convention is ambiguous, because `luaopen__openssl_x509_verify_param` reads
equally well as `_openssl.x509.verify.param` and `_openssl.x509.verify_param`,
and a bundler that guesses produces a binary that dies with "module not found"
for a module demonstrably linked into it.

The practical effect is that what is in the artefact is exactly what a real
request touched. The module list for the first full link was not written by
hand: a script started an app, served one request to itself, and dumped
`package.loaded`.

### 3. Process per tenant becomes cheap

This is the one that changes what akkar could be, and `docs/RUNTIME.md` puts it
at the end of a longer argument.

The tempting third product is a supervising runtime that hosts several tenants'
code in one process, hot-swapped. akkar already has the loading half
(`akkar.from_spec`, `App:swap_host`) and does not have the isolation half.
`akkar/vm.lua` says so about itself: it is a sandbox inside one Lua state, not
a boundary against hostile code, and if the code is hostile rather than merely
untrusted it belongs in a separate process with an OS-level sandbox.

> Building the supervising runtime now would mean offering, as a product, the
> guarantee the code explicitly disclaims.

What unblocks it is not more code in akkar. It is a process per tenant, which
the binary makes cheap: a 6 MB self-contained executable with no interpreter to
install is a very different proposition from "provision a Lua environment per
customer". The isolation story becomes the operating system's.

## This was excluded, and the exclusion was wrong

`docs/BACKLOG.md` carried `akkar build` in the table of things deliberately not
being built, with this reason:

> Attractive, but Redbean is a *different substrate*, and `cqueues` is a C
> module. That is a substrate change, not a packaging step.

The first clause is true of Redbean. **The second does not follow, and it was
never measured.** Being a C module makes something harder to link, not
impossible; static linking is the ordinary answer and it changes no substrate
at all.

`docs/runtime/build-probe.sh` is the disproof and runs in about a minute:

| Probe | Result | Size |
|---|---|---|
| Pure Lua script | ran | 302 KB |
| Plus a C module (`lua-cjson`) | encoded and decoded | 328 KB |
| Plus `cqueues`, running an event loop | `ticks=3` | 1.5 MB |

The third is the one that mattered: akkar's entire concurrency substrate ran
inside a single executable.

The backlog entry is now struck through and marked retracted rather than
deleted, which is the pattern this project uses everywhere and the reason its
claims are worth reading.

## What it costs

### A platform matrix, which is a permanent maintenance surface

`docs/RUNTIME.md` listed "one platform, one libc" and "not fully static" under
what the probe does not prove. `docs/DEPLOY.md` answered both, and both answers
are yes: against musl on Alpine the binary is `statically linked, stripped`,
and `ldd` reports `Not a valid dynamic program`.

What that cost was **one header**. `sys/queue.h` is a BSD header glibc ships
and musl does not, packaged by Alpine in `libbsd-dev`, installed where cqueues
already looks. One `apk add`. luaossl, lua-cjson, lpeg, lua-http, pgmoon and
luasocket all built unmodified.

But look at what is still open, because this is the cost:

- **glibc static was not tried**, and the reason is not that it failed. glibc's
  static `getaddrinfo` still wants the NSS shared objects at runtime, so a
  `-static` glibc binary in an empty image plausibly cannot resolve a hostname.
  musl was chosen and the DNS behaviour was then *tested* rather than assumed.
  (It works because cqueues carries its own resolver and reads
  `/etc/resolv.conf` directly, never calling libc's `getaddrinfo`.)
- **No macOS, no BSD.** Nothing has been run there.
- **No cross-compilation.** It builds for the machine it runs on.

Every platform anyone wants is a platform somebody has to keep green.

### akkar becomes a distributor of a build, not only a library

This is the structural cost and it is easy to underrate. A framework that is
`require`d only has to be correct. A framework that produces executables has to
know how to build every native dependency it embeds, on every platform it
claims.

- `akkar archive` has recipes for four archives: cqueues, luaossl, lua-cjson,
  lpeg. A **fifth is assembled by hand in the `Dockerfile`**.
- That fifth was found by running the binary rather than by reading:
  `akkar: [string "pgmoon.util"]:32: module 'mime' not found`. pgmoon requires
  `mime` from luasocket without declaring it, and every crypto backend in
  `pgmoon/crypto.lua` is `pcall`-guarded, so pgmoon quietly selects luaossl and
  never looks at luasocket, and then `pgmoon.util` requires `mime`
  unconditionally for base64. The binary links, boots, serves HTTP perfectly,
  and dies on the first database call.
- **A static libpq recipe for `akkar build` does not exist.**
  `docs/BACKLOG.md` lists it as owed: the Debian `libpq.a` drags in pgcommon,
  pgport, curl, ssl, gssapi and ldap. So the C driver of
  `docs/why/adapters.md` cannot currently be shipped in the binary.
- A native module written for dynamic loading may hold assumptions that only
  static linking violates. luaossl's `dl_anchor()` calls `dladdr` on its own
  entry point and then `dlopen`s the file it lands in, which for a static build
  is the executable, and `dlopen` on an executable fails by definition. The
  error surfaces as `openssl.init: cannot dynamically load executable`, from a
  module nobody mentioned, and `openssl.init` turns out to be an error label in
  C rather than a module at all. The fix is `-DHAVE_DLADDR=0`. Finding it took
  reading luaossl's C.

### An empty image has no shell, and some things need one

**Migrations cannot run from the `scratch` image.** `io.popen` needs a shell
and `scratch` has none. This was found by running it, and the proof that the
shell is the only cause is that the same binary runs migrations from the
`--target slim` image, which differs only by having busybox in it.

`docs/DEPLOY.md` gives three options in order of preference: migrate from the
slim image and serve from scratch; ship slim for everything at 14.5 MB instead
of 6.4 MB; or run migrations from a laptop. That is a real operational
consequence of a 6 MB image, not a footnote.

### Rebuilding to change a line

The application is compiled in. Editing it means rebuilding, which is 15 s
here. That is why `akkar run app.lua`, the binary hosting an application it
reads at startup, is next and is deliberately small: "it makes the
edit-and-restart loop possible without a compiler, which is how anyone actually
develops".

Its real cost is not code either. It creates a **second versioned interface**,
between the runtime binary and the application source, at a moment when this
project has deliberately promised no compatibility at all. So `akkar run` will
state which akkar built the binary and stop there.

## What to read next

- `docs/RUNTIME.md`, for the probes and the design question.
- `docs/DEPLOY.md`, for the numbers above and a real Railway deployment.
- `docs/why/what-akkar-does-not-do.md`, for the other retracted exclusions.
