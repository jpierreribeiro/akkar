# Deploying akkar

`docs/RUNTIME.md` makes a promise — `akkar build` emits one binary, and
deployment becomes "copy one file to a server". Until this document existed
that promise had never met a host. akkar had no `Dockerfile`, no `Procfile`
and no written host setup, so the shortest true description of its deployment
story was that there wasn't one.

This is the story, and everything in it was run rather than reasoned about.
Where something was only reasoned about it says so.

---

## What was measured

One machine, one afternoon: Linux 6.8 x86-64, Docker 28.2.2, an 8-core
laptop. Nothing here was measured on Railway itself — see
[What is verified and what is not](#what-is-verified-and-what-is-not).

| | |
|---|---|
| **Final image (`scratch`)** | **6,395,313 bytes — 6.4 MB** |
| The binary inside it | 6,177,544 bytes — 6.2 MB |
| The CA bundle beside it | ~218 KB, the rest of the image |
| Same binary unstripped | 21,759,272 bytes — 21.8 MB |
| Shell-bearing variant (`--target slim`) | 14,492,687 bytes — 14.5 MB |
| Cold build (`--no-cache`) | **3 min 01 s** |
| Rebuild after editing the app | **15 s**, of which 8.8 s is `akkar build` |
| Resident memory, idle, serving | **6.7 MiB** |
| Graceful stop on SIGTERM, no traffic | 0.38 s |

Sizes are decimal MB, which is what `docker images` prints.

**The "~5 MB binary" claim survives contact with a registry, at 6.2 MB.** The
5.08 MB in `docs/RUNTIME.md` was a glibc binary that still linked
`libssl.so` and `libcrypto.so` dynamically; this one has OpenSSL *inside it*
and needs no libc on the host. A megabyte for "runs on an empty image" is the
trade, and it is a good one.

---

## Static linking: it works, and here is exactly how far

`docs/RUNTIME.md` listed two limits under **What this does NOT prove**:

> **Not fully static.** OpenSSL is still linked dynamically. `libssl.a` and
> `libcrypto.a` exist on this machine, so it is reachable; untried.

> **One platform, one libc.** Linux, glibc, x86-64. Nothing here says
> anything about musl, macOS or the BSDs, and `dl_anchor` is exactly the kind
> of thing that differs.

**Both are now answered, and both answers are yes.** Against musl on Alpine,
with `--libs "-static -lm -ldl -lpthread -lssl -lcrypto"`:

```
$ file akkar-app
ELF 64-bit LSB executable, x86-64, statically linked, stripped

$ ldd akkar-app
/lib/ld-musl-x86_64.so.1: akkar-app: Not a valid dynamic program
```

That binary serves HTTP, resolves DNS and queries Postgres from a `scratch`
image containing no libc at all.

### What musl cost: one header

Exactly one thing broke, and it broke immediately:

```
/tmp/cq/src/cqueues.c:40:10: fatal error: sys/queue.h: No such file or directory
   40 | #include <sys/queue.h>  /* LIST_* TAILQ_* */
```

`sys/queue.h` is a BSD header glibc ships and musl does not. Alpine packages
it in `libbsd-dev`, which installs it at `/usr/include/sys/queue.h` — where
cqueues is already looking. **One `apk add`. No patch, no flag, no fork.**

Nothing else needed changing. luaossl, lua-cjson, lpeg, lua-http, pgmoon and
luasocket all built unmodified. The `dl_anchor` problem that
`docs/RUNTIME.md` singles out as "exactly the kind of thing that differs" did
not differ: `akkar/build.lua`'s luaossl recipe already passes
`-DHAVE_DLADDR=0`, and that is as correct on musl as on glibc.

### What static linking cost: remembering to `strip`

Nothing failed. The trap is a size one, and it is worth stating because it
would have made the project's own claim look false:

| | |
|---|---|
| Static, as linked | 21,759,272 bytes |
| Static, after `strip` | 6,177,544 bytes |

**Seventy-two percent of the unstripped artefact is debug tables** — DWARF
from the statically linked C, OpenSSL most of all, put there by `-O2 -g`. An
unstripped static binary is not a 21 MB runtime; it is a 6 MB runtime
carrying its dependencies' symbol tables into your registry.

### What defeated nothing, because it was not attempted

**glibc static was not tried, and the reason is not "it failed".** glibc's
static `getaddrinfo` still wants the NSS shared objects at runtime, so a
`-static` glibc binary in an empty image plausibly cannot resolve a hostname
— and Railway addresses its Postgres by hostname. musl has no such split, so
musl was chosen and the DNS behaviour was then *tested* rather than assumed:

```
$ ./akkar-app run dns.lua
connect example.com:80 ->  CQS Socket  nil
peer:  2  104.20.23.154  80
```

A real outbound connection to a real hostname, from the static binary. Note
this works because **cqueues carries its own resolver** and reads
`/etc/resolv.conf` directly — it never calls libc's `getaddrinfo`, which is
also why the usual static-linking DNS horror stories do not apply here.

Nothing above says a static glibc build is impossible. It says it was
unnecessary and untried.

### The one dependency `akkar archive` has no recipe for

Building the four archives is one CLI call each — `akkar archive cqueues`,
`luaossl`, `lua-cjson`, `lpeg`. A fifth is assembled by hand in the
`Dockerfile`, and it was found by running the binary, not by reading:

```
akkar: [string "pgmoon.util"]:32: module 'mime' not found
```

The rockspec already warned that "pgmoon requires the `mime` module (from
luasocket) without declaring it in its own rockspec". The *shape* of the
failure is the part worth recording: every crypto backend in `pgmoon/crypto.lua`
is `pcall`-guarded, so pgmoon quietly selects luaossl and never looks at
luasocket — and then `pgmoon.util` requires `mime` **unconditionally**, for
base64. So the binary links, boots, and serves HTTP perfectly, and dies on the
first database call. Two objects and one `ar` invocation is the whole fix.

---

## Railway

What Railway needs was checked against its documentation and its live JSON
schema, not assumed.

### The three things that matter

1. **A file named `Dockerfile` at the repository root.** Railway's docs are
   explicit that "the Dockerfile must be named `Dockerfile` with a capital D,
   otherwise Railway will not use it by default". `RAILWAY_DOCKERFILE_PATH`
   overrides the location; `railway.json` pins it anyway.

2. **`PORT` is injected at runtime and the app must read it.** Railway's own
   troubleshooting page: "Your web server should bind to the host `0.0.0.0`
   and listen on the port specified by the `PORT` environment variable, which
   Railway automatically injects into your application." It is 8080 on the
   current runtime, which happens to match akkar's default — *which is exactly
   why hard-coding 8080 is dangerous*: it works until it doesn't.

3. **`0.0.0.0`, not `127.0.0.1`.** `akkar/init.lua` defaults to
   `config.host or "127.0.0.1"`, correct for a laptop and invisible to an
   edge proxy. This is the single most likely cause of "Application failed to
   respond" for an akkar app, and `examples/railway.lua` exists mostly to get
   these two lines right:

   ```lua
   local port = tonumber(os.getenv "PORT") or 8080
   local host = os.getenv "HOST" or "0.0.0.0"
   ```

   Note `PORT` is injected at **run** time, not build time. A `Dockerfile`
   that bakes `$PORT` into a build-stage command finds it empty.

### Deploying

```sh
# once
railway login
railway link          # or: create the project from the GitHub repo in the UI

# every time
git push
```

Railway sees `Dockerfile` and `railway.json`, builds the image and runs it.
There is no start command to configure: the image has an `ENTRYPOINT`.

### `railway.json`

Committed at the repository root. Every key was validated against
`https://backboard.railway.app/railway.schema.json` — the file the
`$schema` URL redirects to — so none of these are invented:

```json
{
  "$schema": "https://railway.com/railway.schema.json",
  "build":  { "builder": "DOCKERFILE", "dockerfilePath": "Dockerfile" },
  "deploy": {
    "healthcheckPath": "/health/ready",
    "healthcheckTimeout": 30,
    "restartPolicyType": "ON_FAILURE",
    "restartPolicyMaxRetries": 10,
    "drainingSeconds": 15,
    "overlapSeconds": 15
  }
}
```

`healthcheckPath` is **`/health/ready`, not `/health/live`**, and the
distinction is `akkar/health.lua`'s whole argument. Railway waits for this
path before sending traffic to a new deployment, which is a readiness
question. Pointing it at `/health/live` would route traffic to an instance
whose database connection has not been established.

**`drainingSeconds` is the one nobody would guess.** Railway's deployment
reference states that the old deployment "is sent a SIGTERM signal. By
default, it is given **0 seconds** to gracefully shutdown before being
forcefully stopped with a SIGKILL." akkar's ten-second drain is worth nothing
against a zero-second budget, so the platform has to be told to wait. The two
numbers are a pair:

| | |
|---|---|
| `shutdown_grace = 10` in `app:run{}` | how long akkar drains |
| `drainingSeconds: 15` in `railway.json` | how long Railway lets it |

The second must exceed the first, or SIGKILL arrives mid-drain and the grace
was decoration.

`app:handle_signals()` must also be called — akkar does not install signal
handlers on its own, and says why in `akkar/init.lua`: "a library that
installs signal handlers behind an application's back is a library that
fights with whatever else the process is doing." Correct as a default,
mandatory in a container. Verified:

```
$ docker stop akkarrun
INFO  signal received
INFO  shutdown: no longer accepting connections
INFO  shutdown: stopped cleanly
```

### Environment variables

Railway injects `PORT` and, if you attach a Postgres, `DATABASE_URL` plus
`PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`. `akkar/db.lua` takes
the parts, not a URL:

```lua
local pool = db.connect {
  host     = os.getenv "PGHOST",
  port     = tonumber(os.getenv "PGPORT") or 5432,
  database = os.getenv "PGDATABASE",
  user     = os.getenv "PGUSER",
  password = os.getenv "PGPASSWORD",
}
```

**Not verified against a Railway-provisioned database.** The variable names
above come from Railway's documented Postgres plugin; the `db.connect` call
is verified against Postgres 16, but in a local container, not on Railway.

---

## Migrations

`akkar/migrate.lua` exists, and works. It was run from the shipped binary,
against Postgres 16, applying two files and then correctly finding nothing to
do on a second run:

```
$ ./akkar-app run migrate.lua
applied this run: 2
    001_widgets.sql
    002_created_at.sql
$ ./akkar-app run migrate.lua
applied this run: 0
```

### The thing you have to know first

**Migrations cannot run from the `scratch` image.** Found by running it, and
it is not obvious from any of the source:

```
akkar.migrate: could not list /migrations:
find "/migrations" -maxdepth 1 -type f -name '*.sql': No such file or directory
```

The "No such file or directory" is **`/bin/sh`**, not the directory — which
was mounted and readable. `akkar/migrate.lua` lists its directory with
`find`, through `io.popen`, and explains the choice:

> Lua has no directory listing and LuaFileSystem is a C dependency this
> project has spent real effort not needing.

`io.popen` needs a shell. `scratch` has none. The proof that this is the only
difference: **the same binary, the same mount and the same database applied
both files when run from `--target slim`**, which differs from `scratch` only
by having busybox in it.

The same applies to Railway's `preDeployCommand`, which is documented as "the
command to run before starting the container" — a command implies something
to run it with. *Not verified on Railway*, but a shell-less image is the
obvious way for it to fail.

### So, three options, in order of preference

**1. Migrate from the slim image, serve from scratch.** One build, two tags,
the same binary in both — which is what makes it safe: there is no chance of
migrating with a different build from the one that serves.

```sh
docker build --target slim -t myapp:migrate .
docker build              -t myapp:serve   .
```

On Railway, set `preDeployCommand` and deploy the `slim` target by pointing
`railway.json` at it — Railway builds one image per service, so a service
that migrates must be the shell-bearing one.

**2. Ship the slim image for everything.** 14.5 MB instead of 6.4 MB, and it
has a shell for debugging. If 8 MB is not a number you care about, this is
the simplest correct answer and there is no shame in it.

**3. Run migrations as a separate one-off.** A Railway cron service, or
`railway run` from a laptop, using the slim image.

### Writing them

Plain `.sql` files in a directory, applied once, in filename order, under a
Postgres advisory lock. `akkar/migrate.lua` documents the constraints and
the reasoning; the two that bite are worth repeating:

- **No `begin`/`commit`/`rollback` in a file.** The runner already has a
  transaction open around it, so that the change and its ledger row commit
  together.
- **No `create index concurrently`.** Postgres refuses it inside a
  transaction, and the module chooses atomicity over it, deliberately.

Also: **there are no down-migrations and there will not be.** The module
argues this out; the short form is that a down-migration is written against a
schema and run against data.

The runner needs a connection it keeps for the whole run, because the
advisory lock is session-scoped. A pool handle that goes back mid-run takes
the lock with it, so use `pool_size = 0` or call the factory once:

```lua
local acquire = db.connect { ..., pool_size = 0 }
local runner  = migrate.new(acquire(), { dir = "migrations" })
for _, name in ipairs(runner:apply()) do log:info("migrated", { file = name }) end
```

Handing `migrate.new` the factory instead of the connection is a mistake the
module catches by name, which is how it was found here.

---

## Health and readiness

`akkar/health.lua` exists. Three lines of application code:

```lua
local probe = health.new { checks = { db = function() return pool():one "select 1" ~= nil end } }
app:get("/health/live",  function() return probe:live() end)
app:get("/health/ready", function()
  local result = probe:ready()
  if result.status == "fail" then error(akkar.unavailable(result)) end
  return result
end)
```

Verified against the running container:

```
$ curl localhost:9200/health/live
{"uptime":8.25,"checks":{},"status":"pass"}

$ curl localhost:9200/health/ready
{"uptime":8.28,"cached":false,"checks":{},"status":"pass"}
```

**Point the platform's restart policy at `/health/live` and its traffic
routing at `/health/ready`**, never the other way round. `live()` touches
nothing — not the pool, not the database, by construction and with a test
that proves it. A liveness probe that opened a database connection would mean
one slow database fails liveness on every instance simultaneously, and every
instance gets restarted at once. The module makes this argument at length; it
is repeated here because the place people get it wrong is the deploy config,
which is this file.

`ready()` caches for five seconds by default, failures included, so twenty
instances probing every second do not turn a struggling dependency into a
hammered one.

---

## Any Linux box, with systemd

The case `docs/RUNTIME.md` actually promises: one file, `scp`, done. The
binary is static, so **the target needs no Lua, no LuaRocks, no OpenSSL and
no matching libc.**

```sh
# on a build machine (or in the container: docker build --target builder .)
scp akkar-app root@host:/usr/local/bin/akkar-app
```

```ini
# /etc/systemd/system/akkar.service
[Unit]
Description=akkar application
After=network-online.target
Wants=network-online.target

[Service]
# DynamicUser gives a per-service UID with no home and no shell, created and
# destroyed with the unit. There is nothing on disk for the service to own:
# the binary carries its Lua, and the state is in Postgres.
DynamicUser=yes
ExecStart=/usr/local/bin/akkar-app
Environment=PORT=8080
Environment=HOST=0.0.0.0

# SIGTERM is what akkar's app:handle_signals() listens for, and 30 s must
# exceed the shutdown_grace in app:run{}, for the same reason Railway's
# drainingSeconds must.
KillSignal=SIGTERM
TimeoutStopSec=30

Restart=on-failure
RestartSec=2

# The descriptor ceiling akkar computes at startup is read from
# /proc/self/limits and sized at 66% of the soft limit, two per in-flight
# request. The default 1024 puts the wall near 500 concurrent requests per
# process; akkar/init.lua records a machine being lost to exactly that.
LimitNOFILE=65535

# Costs nothing for a service with no files of its own.
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
```

```sh
systemctl daemon-reload && systemctl enable --now akkar
```

**Not verified.** No systemd unit was installed or started as part of this
work — there was no VM to install it on. The unit is written from
`akkar/init.lua`'s documented behaviour (SIGTERM handling, the descriptor
ceiling read from `/proc/self/limits`) and standard systemd, and every claim
in it is checkable, but "checkable" is not "checked". Treat it as a starting
point rather than a tested artefact.

### More than one core

One Lua VM is one core, so capacity is processes. `reuseport = true` in
`app:run{}` lets several share a port with the kernel load-balancing between
them — no proxy in front. With systemd that is a templated unit and
`systemctl start akkar@{1..4}`. Also not verified here.

---

## Containers generally

Nothing in the `Dockerfile` is Railway-specific. It builds anywhere BuildKit
runs.

```sh
docker build -t myapp .                       # scratch, 6.4 MB
docker build --target slim -t myapp:slim .    # busybox, 14.5 MB, has a shell
docker build --build-arg APP=app.lua -t myapp .
docker run -p 8080:8080 -e PORT=8080 myapp
```

Three things about the image that are decisions, not defaults:

- **`USER 65532:65532`, a bare numeric UID.** `scratch` has no `/etc/passwd`,
  and the kernel does not need one. Verified: `docker top` shows the process
  running as 65532.
- **The CA bundle is copied in.** An empty image has no trust store, so every
  *outbound* HTTPS call fails certificate verification while inbound HTTP
  works perfectly — a confusing afternoon, avoided by one `COPY`.
- **`/etc/resolv.conf` is deliberately not copied.** The container runtime
  writes it at start; baking one would override the platform's DNS.

An application with its own modules adds one root to the build:

```dockerfile
RUN ... akkar build "$APP" ... --root /build/app/src
```

Not the checkout — a root is collected recursively, and pointing it at the
repository sweeps up every stray `.lua` in it. The same footgun is why
akkar's own source sits alone in `/build/lua` in the `Dockerfile`: `akkar
build` adds akkar's root implicitly by asking `package.searchpath` and taking
the *parent* directory, so a crowded parent silently doubles the module list.

### What the `.dockerignore` is for

`COPY . /build/app` means everything not excluded is uploaded on every build.
The sharpest exclusion is `*.so`: `akkar/pq_native.so` is a glibc x86-64
object built by `src/build.sh` for *this laptop*, and copying it into a musl
builder puts a silently unloadable shared object where something might later
look for one.

---

## What is verified and what is not

Because a deployment document that oversells is worse than none.

### Run, and observed

- `docker build` from a cold cache, to a `scratch` image — 3 min 01 s.
- `docker run` of that image, and `curl` **from the host**, answering on
  `/`, `/health/live`, `/health/ready`, `/echo/7`, and `422` on `/echo/abc`.
  Routing, JSON, health and parameter validation all survived static linking.
- `file` and `ldd` confirming the binary is statically linked.
- A real outbound TCP connection to `example.com:80` by hostname, proving DNS
  from an image with no resolver library.
- `select 1` and a parameterised query against Postgres 16 through
  `akkar.db` and pgmoon, **from the `scratch` image**.
- `akkar/migrate.lua` applying two migrations and then correctly applying
  none, from the shipped binary.
- Migrations *failing* from `scratch` and *succeeding* from `slim`, same
  binary, same mount, same database.
- `docker stop` producing a clean drain via `app:handle_signals()`.
- Non-root execution as UID 65532 (`docker top`).
- Idle resident memory of 6.7 MiB (`docker stats`).
- Every key in `railway.json` checked against Railway's live JSON schema.

### Read in documentation, not run

- Everything Railway does. **Nothing here was deployed to Railway.** That
  `PORT` is injected, that `0.0.0.0` is required, that SIGTERM comes with a
  zero-second default budget, that a root `Dockerfile` is detected — all of
  it is from Railway's own documentation, and all of it is unconfirmed
  against a running Railway service.
- `preDeployCommand` needing a shell. Consistent with the `scratch`
  migration failure, and not tested on Railway.
- The `DATABASE_URL`/`PG*` variable names of Railway's Postgres plugin.

### Not attempted at all

- The systemd unit. Written, never installed.
- `reuseport` across multiple processes in a container.
- glibc static linking; see above for why it was skipped rather than failed.
- ARM64. The build is x86-64 and `akkar build` is not a cross-compiler — it
  says so itself: "it builds for the machine it runs on."
- TLS terminated by akkar. Railway terminates at its edge, so the deployed
  app speaks plain HTTP; `app:run{}`'s `tls` and `ctx` options are untouched
  by any of this.
- Any load. Nothing here says what the image does under traffic;
  `bench/RESULTS.md` is the place for that, and it did not run in a
  container.
