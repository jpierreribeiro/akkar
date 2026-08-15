# Next — deadline correctness and five borrowed ideas

> **Status.** Items 0, 1, 2, 3 and 5 are **done**. Item 4 (`If-Match` → 412)
> remains. Rate and concurrency limiting, which was not on this list, was
> added as `akkar.limit` after the study measured the need for it.
>
> Item 0 was confirmed against real servers, and the consequence written here
> was wrong in a way worth keeping: there is **no cross-request data leak on
> Postgres**, because pgmoon refuses a busy connection with an error. What
> happens instead is that the pool slot is poisoned **permanently** — a pool
> of ten dies after ten timed-out queries.
>
> On **Redis** it is a real leak, and that was not in this plan at all: RESP
> matches replies to commands by order and nothing else, so a request received
> the abandoned `BLPOP`'s reply as its own answer, and then the stream
> realigned and everything looked normal again.
>
> A third failure came out of the same investigation and is not in this plan
> either: every in-flight request holds a controller costing **exactly two
> file descriptors**, which puts a hard wall at ~500 concurrent requests per
> process against `ulimit -n 1024`. See finding 9 in `PERFORMANCE-STUDY.md`.

Written 2026-08-15. Meant to fold into `docs/BACKLOG.md` once the items land;
kept separate so it does not conflict with work already in flight.

Item 0 is a defect, not a feature. Items 1–5 are borrowed from frameworks that
solved something akkar has not. Everything here passed one filter before being
written down: **does it turn a common mistake into an impossible state or an
explicit error?** Ideas that were only features are in "Considered and
rejected" at the bottom, with the reason.

---

## 0. A timed-out request can return a busy connection to the pool 🔴

**The defect.** When the deadline fires, `with_deadline` abandons the handler
but the handler keeps running inside its controller — `init.lua:492` says so
and, for that reason, refuses to reuse the controller:

> Only an empty controller goes back. A handler abandoned by the deadline is
> still running inside its controller, and reusing that would hand the next
> request someone else's unfinished work — the same class of bug as a pooled
> database connection with a transaction still open.

The connection gets no such protection. `init.lua:1191` runs `release_all()`
on the timeout path, and the fitness predicate in `db.lua:230` is

```lua
return not conn.in_transaction and not conn.broken and conn.pg ~= nil
```

A plain `select` suspended mid-flight sets none of those three. `Db:query` has
no in-flight flag at all. So the connection is judged fit, returns to the pool,
and the next request's `pg:query` reads the **previous request's result rows**
off the socket before its own. User A's data in user B's response.

The defence was built for the controller and not for the connection, and the
comment that describes the bug is sitting three hundred lines above the code
that commits it.

**Reachability.** Needs a query in flight when the deadline expires. Rare at
the 30 s default; not rare at `timeout = 5` given the measured p99 of 191 ms
with 100 connections against `pool_size = 10`, where ninety requests queue for
a connection.

**The fix.** A flag on the connection, set around the wire call, read by the
predicate — `broken` already exists and does exactly this job for another case:

```lua
function Db:query(sql, ...)
  self.in_flight = true
  local res, err = self.pg:query(statement(sql, ...))
  self.in_flight = false
  if not res then error("db: " .. tostring(err), 0) end
  return res
end
```

`in_flight` joins the predicate; a connection abandoned mid-query is closed
rather than pooled. Note the flag must **not** be cleared by an error path that
never ran — the assignment after the call is skipped when the coroutine is
abandoned, which is precisely the state we want to detect.

**Verification.** Not busted alone. A route that sleeps inside a query against
a real Postgres, `timeout` set below it, then a second request on the same pool
asserting it gets its own rows. The suite has the ingredients already:
`spec/db_spec.lua` skips cleanly without a database, and `bench/` has the
harness for a live server.

**Honest limit.** This closes the reuse hole; it does not stop the abandoned
query from running to completion on the server. That is item 1.

---

## 1. Deadline propagation — `context.Context` (Go)

**What Go has that akkar does not.** A deadline that reaches the driver. In Go
the context cancels the query; in akkar the deadline only wins a race in the
process, and Postgres never hears about it. After the 503 the query keeps
running, holding a backend and — until item 0 lands — a pool slot. Under load
the timeout makes exhaustion *worse*, which is the opposite of the point.

**Shape.** `req.deadline` exposed as an absolute monotonic time, and `db.lua`
sending the remaining budget to the server:

```sql
set local statement_timeout = <remaining ms>
```

`set local` scopes it to the transaction, so it cannot leak into the next user
of a pooled connection — the same hazard the whole item is about.

**Why this is the right fix and item 0 is the floor.** Item 0 stops the
corruption by throwing the connection away. Item 1 means there is nothing to
throw away: the server kills the query, the connection comes back clean, and
the slot is genuinely returned rather than reopened.

**Verification.** Record the prediction before measuring, per `METHOD.md`
practice. The question worth a number: at `pool_size = 10` with a load that
times out 20% of requests, does throughput hold, or does connection churn from
item 0 eat it? That comparison is the argument for item 1 existing.

**Honest limit.** `statement_timeout` covers time in Postgres. A handler
abandoned while waiting on Redis, or on a future outbound HTTP call, needs the
same treatment per adapter. The deadline is a capability-boundary concept, not
a database one, and the contract in `PLAN.md` should say so before a second
adapter grows its own version.

---

## 2. A replaceable error handler — `HTTPErrorHandler` (Echo)

**The gap.** `grep -n "on_error\|error_handler" akkar/init.lua` returns
nothing. The 500 is assembled inside `dispatch` and the original error never
leaves it. Middleware sees the 500 come back through the chain — deliberate,
and correct — but nothing can see the cause. Sentry, an internal error code, or
RFC 7807 output all have nowhere to attach.

**Shape.**

```lua
app:on_error(function(err, req)
  sentry:capture(err, { request_id = req.id, route = req.path })
  return akkar.response(500, {
    type = "https://errors.example.com/internal",
    title = "internal server error",
    instance = req.id,
  })
end)
```

**Two rules that keep the invariants.** The return value goes through
`normalize` like any other response, so a handler returning garbage becomes a
500 rather than escaping. And if the error handler itself raises, the built-in
500 takes over — otherwise a bug in the error handler crashes the server
through the exact path that existed to prevent that.

**What must not change.** The default stays as it is: `{"error": "internal
server error"}` and nothing more. A Lua error carries file paths, line numbers
and sometimes SQL. The detail belongs in the log next to `request_id` and
`route.where`, which is already how it works and is the reason the header
carries the id.

**Verification.** Three cases: a handler that formats, a handler that raises, a
handler that returns a non-response. All three are in-process, so busted covers
this one honestly.

---

## 3. `Idempotency-Key` (Stripe)

**The mistake it makes impossible.** Client posts, times out, retries, gets
charged twice. It is the most common distributed-systems bug in a JSON API and
handlers currently have to solve it individually, which means most will not.

**Why it fits here.** The hard part is storage with expiry, and akkar already
has it: the `cache` capability, with the Redis adapter and `cache.memory` both
obeying the same contract including ttl semantics. The semantics can be tested
against both stores from one description, exactly as `akkar.jobs` already does.

**Shape.** Middleware, not core — same reasoning as `akkar.cors`: a key policy
is application knowledge.

```lua
app:use(akkar.idempotency { ttl = 86400, methods = { "POST" } })
```

First request with a given key runs and its response is stored. A repeat
returns the stored response. A repeat **while the first is still in flight**
gets 409, because returning nothing or running twice are both worse. A repeat
with the same key and a *different* body is 422 — the key is a promise about
which request it is.

**Honest limit.** Storing the response means storing a body, so it needs a size
cap and must say what happens past it. And the guarantee is only as strong as
the cache: with `cache.memory` it is per-process, which is not idempotency
across a fleet. The docs must say which one the reader is getting.

---

## 4. `If-Match` → 412 (Rails, and HTTP itself)

**The mistake it makes impossible.** Lost update. Two clients read the same
row, both write, one write vanishes with no error anywhere.

**Shape.** An ETag on the response, `If-Match` honoured on PUT/PATCH, 412 when
it does not match, and 428 when the route requires one and the client sent
none. That last status is the difference between a feature and an invariant: a
client that forgets the header gets told, instead of silently racing.

**Where it plugs in.** Next to the `response` schema, which already knows the
shape of the success body — an ETag derived from the filtered body is
consistent by construction with what the client actually received.

**Honest limit.** A body-derived ETag is not a row version. Two writes that
produce the same body are indistinguishable, and a client that reads through a
cache may match against something stale. A row version column is the strong
version, and that is an application's decision, not the framework's.

---

## 5. `traceparent` (W3C Trace Context)

**Cheapest item on the list.** The mechanism is already built: a request id is
taken from `x-request-id` when the client sends one so a trace survives across
services, generated otherwise, and bound into `req.log`. Extending the same
place to accept and propagate `traceparent` is a handful of lines and it is
what makes cross-service debugging work at all.

**Scope discipline.** Accept, propagate, expose on `req` and on the log line.
Do **not** ship a span exporter — that is an OpenTelemetry dependency and an
adapter, and it belongs behind the same boundary as everything else.

---

## Sequencing, and which of these can run in parallel

Grouped by the files they touch, because two agents editing `init.lua` at once
is the one thing that reliably wastes a round.

| Track | Items | Files | Notes |
|---|---|---|---|
| **A** | 0, then 1 | `akkar/db.lua`, `akkar/pool.lua` | Same investigation. Item 0 is the floor, item 1 is the real fix. Start here. |
| **B** | 2, then 5 | `akkar/init.lua` | Both live in dispatch / request-id. One agent, sequential. |
| **C** | 3 | `akkar/idempotency.lua` (new), `spec/` | Independent. New file, so no conflict with A or B. |
| **D** | 4 | `akkar/init.lua` | Waits for B to land — same region. |

A, B and C can run at once. D follows B.

**Research that would pay before implementing**, if agents are going to be
pointed at something: how Stripe handles the in-flight-repeat case and the
body-mismatch case, since item 3's 409/422 choices above are reasoned rather
than verified; and whether `set local statement_timeout` behaves as assumed
outside an explicit transaction, which decides the shape of item 1.

---

## Considered and rejected

| Rejected | Why |
|---|---|
| Signed cookies, sessions, CSRF | `PLAN.md` §1 excludes HTML, and CSRF is a cookie-auth problem. A JSON API with bearer tokens does not have it. |
| Response compression | The proxy in front does it, and doing it here costs CPU on the event loop for something already solved one hop away. |
| RFC 7807 as the built-in error format | Should be an *output* of item 2, chosen by the application, not a shape baked into core. |
| `Context` object with `c:json(status, body)` (Echo, Gin) | Handlers return; they do not write. That is what makes a double response impossible to represent rather than merely discouraged. Adopting it would import the bug akkar was built to remove. |
| Leaking `tostring(err)` to the client | File paths, line numbers, SQL fragments. The `request_id` already links the response to the full detail in the log. |
