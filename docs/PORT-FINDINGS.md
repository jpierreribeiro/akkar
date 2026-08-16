# What porting a real service found

`docs/UNKNOWNS.md` §10 has said from the day it was written that the largest
gap in this project is that **nobody has built an application with akkar**.
Every defect found so far came from engineering an exposure — a fuzzer, a
benchmark gate, a lifetime audit — and none from use.

This is the first evidence from the other instrument.

## What was ported

One vertical slice of a live escrow platform: **223 Go files, 105 routes, 26
migrations, 132 requests in its Postman collection**, money in integer cents,
running in production behind Railway with an API and a worker.

The slice: `POST /auth/register`, `POST /auth/login`, `POST /auth/logout`,
`GET /me/status`, `POST /invoices/quote`, `POST /invoices` (carrying
`Idempotency-Key`), `GET /invoices`, `GET /invoices/:id`,
`POST /invoices/:id/cancel` and its `DELETE` alias.

Chosen because it touches the parts akkar is opinionated about and the parts
that are easy to get wrong: authentication, validation, a money calculation
whose original source says *"ALL arithmetic is integer-only … eliminates IEEE
754 representation errors"*, a database write, idempotency, listing, and a
state transition.

The port lives outside this repository. The business logic is somebody's
private service; what comes back here is the defects.

**Time to the first defect: under an hour. Nine found across three slices.**

---

## 1. A mounted app's middleware never ran — a way to publish a private API

**Severity: this one can serve an authenticated route to anybody.**

The shape every framework teaches:

```lua
local private = akkar.new()
private:use(auth.middleware { bearer = check_token })
private:get("/invoices", list_invoices)

app:mount("/api", private)
```

akkar answered **200 with no credential**. `App:match` descended into the
mount and returned the route; the request then ran inside the *parent's*
chain, and everything `sub:use()` registered was discarded. No error, no
warning, and the application reads as though it is protected.

`docs/HANDOFF.md` carried this among the open items as *"app:mount not
running sub-app middleware"*, listed beside ergonomic gaps. It is not one.

**Fixed.** `App:match` now reports which app owns a matched route —
outermost-first, so a mount inside a mount runs both — and `dispatch` wraps the
handler in that app's middleware, outside the route-scoped ones and inside the
parent's global chain. `owners` is built only for a mounted route, so an
unmounted request allocates nothing.

Five cases in `spec/port_findings_spec.lua`, including nesting, ordering,
short-circuiting, and that a child's guard does not leak onto the parent's own
routes.

## 2. A misspelled constraint validated nothing, silently

The first schema written against the real API said:

```lua
v.string { pattern = "@" }
```

because `pattern` is what the rest of Lua calls it. akkar calls it `match`.
The rule was accepted, built, and checked nothing — every string passed,
including ones with no `@` in them. `v.string { mn = 5 }` accepted the empty
string just as happily.

The danger is not the typo. It is that **the schema reads as though it
validates**. Nothing in the request, the response or the logs says otherwise;
the first evidence would be a row in the database.

akkar already raised on an unknown schema *type* (`"strng"`). Being strict
about the type and silent about the constraints was the inconsistency.

**Fixed.** Unknown constraint names raise when the rule is built, naming the
constraint and listing the real ones. It happens once at startup, so a bad
schema fails at boot and nothing is added to the request path.

## 3. `v.integer` produced a float from a JSON body and an integer from a query

JSON has one number type, so `cjson` decodes `120000` as the **float**
`120000.0`. `v.integer` accepted it — correctly, it is integral — and passed it
through unchanged. The same rule fed from a query string produced a real
integer, because the coercing path runs `tonumber` on a string.

One rule, two subtypes, depending on where the value arrived. `//`, `%`, the
bitwise operators and `string.format("%d", …)` all behave differently across
that line, and `%d` on a float with no integer representation **raises**.

It mattered here because the service the port copied computes money in integer
cents on purpose and says so in its own source.

**Fixed.** An integer rule now returns `math.tointeger(value)` when the value
fits. A number too large for a Lua integer is left alone rather than mangled
into a different one.

## 4. `Idempotency-Key` arrived and nothing was listening

The service's Postman collection sends `Idempotency-Key` on `POST /invoices` —
the client saying *"a retry of this must not charge twice"*. The port did not
install `akkar.idempotency`, because nothing says you have to.

**The same key posted twice created two invoices, two different ids, for one
payment.** The only evidence anywhere was a row count.

Installing the middleware fixes it, and that is not the finding. The finding is
that akkar has the module, watched the header go past, and said nothing.

**Fixed.** A request carrying the header on a `POST` or `PATCH` when
`akkar.idempotency` was never loaded now logs a warning naming the fix, once
per app. The guard is read before the header is, so after it fires the cost is
one boolean.

## 5. A signed webhook could not be verified at all

**The second slice, and it was a wall rather than a defect.**

The service receives signed webhooks from its payment provider, and its own
test collection has a case asserting an **unsigned delivery is refused with
401**. The scheme:

    signing_key = hex(sha256(secret))
    expected    = hex(hmac_sha256(signing_key, RAW BODY))

akkar read the body, decoded it, and threw the bytes away. `req.body` was all a
handler ever saw. **A digest over `req.body` re-encoded is a different digest**
— an encoder does not reproduce the sender's whitespace and does not reproduce
`1.0`. So verification was not awkward in akkar, it was impossible, and
`docs/HANDOFF.md` had this recorded as an open item without saying that it
blocks every payment integration.

**Fixed.** The bytes reach the handler as `req.raw_body`, `nil` when the request
carried none.

And the fix taught something the fix itself nearly got wrong. Written as one
more field in the request constructor it cost **255 bytes on every request**,
including requests with no body: a Lua table constructor sizes its hash part
from the number of keys written, nil values included, and one more key crossed
a power-of-two boundary. `spec/allocation_spec.lua` refused it at 2,655 against
its 2,600 ceiling. Assigned after the constructor and only when a body exists,
it costs nothing on the requests that do not use it.

That ceiling was written for a different regression a week earlier. It caught
this one on the first run.

## 6. The retry schedule every webhook system uses could not be expressed

**The third slice: the outbound dispatcher**, the worker that POSTs an event to
whatever endpoint a seller registered and retries when it fails.

The original's schedule is the ordinary one — `BaseBackoff * 2^(attempt-1)`
capped at `MaxBackoff`: one minute, doubling, four hours, twenty attempts.

akkar computed `base ^ attempt`, and the two things that could say were both
wrong. `base = 2` retries a customer's dead endpoint after two seconds and
hammers it. `base = 60` goes 60 seconds, then an hour, then two and a half days.

**Fixed**, and without moving anything. The window is now
`first * factor ^ (attempt - 1)`, and `base` sets both, so for every existing
value the old formula and the new one agree exactly — checked for `base` of 2,
3, 5 and 10 across five attempts rather than argued.

```lua
{ first = 60, factor = 2, max = 4 * 60 * 60 }   --> 60, 120, 240, 480, ... 4h
```

## 7. A delay shorter than a second did not exist

Found by a probe misbehaving rather than by reading anything. A dispatcher test
with a 10 ms backoff reported that an endpoint failing every time was tried
**once and then vanished** — not retried, not dead-lettered, gone.

It had been rescheduled correctly. `Store:schedule` computed
`time.now() + delay`, and `time.now()` is `os.time`, which counts whole seconds.
`run_at` was `N + 0.01` and `promote` compared it against `N` until the second
ticked. **Every sub-second delay meant "the next second boundary".**

The consequence is not about tests. `jobs.delay_for` returns a fractional delay
on purpose — full jitter, a uniform draw across the window, which exists so a
hundred jobs failing against a database that has just come back do not all
retry on the same second. With one-second resolution and a two-second default
window, they retried on one of two.

**Fixed in both stores.** The memory store schedules against `monotime`, which
is sub-second and immune to a wall clock being stepped — the same argument
deadlines already won here a day earlier. The Redis store reads the
microseconds from `redis.call('TIME')` that it was already fetching and
discarding.

With that, the dispatcher behaves: three attempts to deliver through two
failures, four attempts and a dead letter when the endpoint never recovers, and
**one** attempt with no retry when it answers 410 — and the receiver verified
our signature on every one.

## 8. Every UUID parameter needs an explicit cast

Postgres returns a `uuid` column as text — the only thing a Lua driver can do
with it — and then refuses the same string as a parameter for a `uuid` column:

```
column "user_id" is of type uuid but expression is of type text
```

`$1::uuid` is the answer and it has to be written at every site. Go's driver
sends a typed `uuid.UUID` and never meets this.

**Not fixed, recorded.** akkar cannot know the column type, and guessing would
be worse. It belongs in the SQL documentation, and the error message could name
the cast.

## 9. There is no `v.uuid`, and route middleware is called `before`

Two small ones from the same hour. Every primary key in this service is a UUID
and the schema had to spell the pattern out by hand. And route-scoped
middleware exists but is `before`, not `middleware`; akkar refused the wrong
name with a clear message naming the route, which is the right behaviour — the
name is simply not the one a hand reaches for.

---

## What the port also confirmed works

Worth recording, because a findings list reads as though nothing worked.

- **The fee arithmetic matched the Go original exactly**, including the
  rounding: 120,000 cents → fee 6,000, seller 4,200, buyer 1,800, net 114,000;
  and 1,000 cents → the 300 minimum, seller 210, buyer 90.
- Validation answered `422` with the failing field named.
- A wrong password answered `401` without telling the caller whether the
  account exists.
- Migrations applied in order through `akkar.migrate`.
- The bearer scheme, `auth.hash_key`, `crypto.hash_password` and
  `crypto.verify_password` all did what the reference said.
- **The error message for a port already in use named the likely cause** — a
  server from a previous run — and it was right, and it is how a stale process
  serving old code was caught.

---

## What this does not cover

- **One slice of eleven endpoints.** The other ninety-four routes include
  disputes, KYC, payouts, webhooks in both directions, milestones and an
  IP-allowlisted admin surface. Webhooks in particular are already known to be
  a gap — `docs/HANDOFF.md` records that signature verification is impossible
  because the raw body is discarded.
- **No worker.** The original runs a separate worker process; jobs were not
  exercised.
- **No frontend, no TLS, no load.** The port ran against a local Postgres and
  Redis on one machine.
- **Byte-for-byte equivalence was not attempted.** The original talks to a
  payment provider; the port does not. The contract was read from the Postman
  collection and the Go source rather than diffed against a running instance.

Three slices done: the invoice API, the inbound webhook, the outbound
dispatcher. What is still untouched is the reconciliation cron, the dispute and
KYC surfaces, the IP-allowlisted admin routes, and anything under real load or
TLS. The dispatcher was exercised against a fake HTTP client rather than a real
socket, so the queue and the retry schedule are proved and the transport is
not.
