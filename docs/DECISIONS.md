# Design decisions

The handler shape was settled once it could be read against a real database.
What remained were the decisions around it. For each one: the real
alternatives, what each costs, and what is implemented today.

None of it is irreversible — but the earlier it is decided, the less code moves.

---

## 1. Validation syntax

### A — short form only

```lua
app:post("/users", { body = { name = "string", email = "string?" } }, handler)
```

A mini-language of five types plus `?`. Learnable in ten seconds. Cannot
express minimums, maximums, formats or enums.

### B — expressive form only

```lua
app:post("/users", {
  body = {
    name  = v.string { min = 1, max = 100 },
    email = v.string { optional = true, match = "^[^@]+@[^@]+$" },
  },
}, handler)
```

Expresses everything. More verbose for the trivial case, which is most cases.

### C — both, with the short one expanding into the long one ✅ **implemented**

`"string?"` is literally sugar for `v.string { optional = true }`. One concept,
two levels of detail. It is the complexity ladder applied inside validation
itself.

### D — none; validate by hand in the handler

```lua
if type(req.body.name) ~= "string" then return akkar.bad_request "name" end
```

Zero framework, zero OpenAPI, repetition on every route.

**Chose C.** The cost is that two spellings exist for the same thing —
acceptable, because one is a prefix of the other.

> Still open inside C: validation currently answers **422**. Gin and Express
> tend to answer 400. 422 is more correct (valid syntax, invalid semantics) and
> is what FastAPI does. Switching to 400 is one line.

---

## 2. How a handler receives the authenticated user

### A — middleware populates `req.user` ✅ **implemented**

```lua
app:get("/me", { before = { authenticate } }, function(req)
  return req.user
end)
```

Familiar from Gin and Express. The classic hazard is `req.user` being `nil`
when the middleware was forgotten — solved here by a **guard**: `req.user`
starts as a table that, when read, raises

```
req.user is not set; this route is missing the authentication middleware
```

instead of `attempt to index a nil value`. Same trick as `req.db`.

### B — declared per route

```lua
app:get("/me", { auth = true }, function(req) return req.user end)
```

The framework guarantees `req.user`. But the framework now knows about
authentication, which `PLAN.md` puts outside the core.

### C — the middleware wraps and passes it as an argument

```lua
app:get("/me", auth(function(req, user) return user end))
```

`user` cannot be nil. Costs nesting, and reads badly with two or three
middlewares.

**Chose A with a guard.** Keeps authentication out of the core and still makes
the mistake obvious at the moment it is made.

---

## 3. Grouping routes

### A — prefix groups

```lua
local api = app:group("/api/v1")
api:get("/users", handler)
```

Familiar (Gin, Express). Introduces a **second kind of object**: a group is not
an app, has similar-but-not-identical methods, and cannot be tested on its own.

### B — mounted sub-applications ✅ **implemented**

```lua
local health = akkar.new()
health:get("/live", handler)
app:mount("/health", health)
```

One concept: a sub-app is an app. And — the part that decides it — **it stays
testable on its own, without knowing which prefix it lives under**:

```lua
health:test():get("/live")            -- standalone
app:test():get("/health/live")        -- mounted
```

Both of those are in `spec/`, passing.

**Chose B.** One fewer kind of object, and testability that A does not offer.

---

## 4. How a deep layer signals HTTP

### A — thread the return value back

```lua
local user, err = find_user(db, id)
if err then return err end
```

Explicit and tedious: every function on the path has to carry the error.

### B — throw the response ✅ **implemented**

```lua
local function find_user_or_404(db, id)
  local user = db:one("select ... where id = $1", id)
  if not user then error(akkar.not_found("user " .. id .. " not found")) end
  return user
end

app:get("/users/:id", function(req)
  return find_user_or_404(req.db, req.params.id)   -- no if, no threading
end)
```

**The same value works as a return and as an error.** `return
akkar.not_found()` and `error(akkar.not_found())` both produce a 404. The
framework tells a thrown response from a genuine error and only turns the
second into a 500.

It costs one honest thing: control flow through exceptions, which some people
dislike.

**Chose B**, and both coexist — a shallow handler still uses `return`.

---

## 5. Database access

### A — a thin adapter ✅ **implemented**

```lua
req.db:one("select id, name from users where id = $1", id)
req.db:many("select ...", ...)
req.db:transaction(function(tx) ... end)
```

Four methods and plain SQL. The minimal surface is exactly what lets the fake
database in `spec/` be a table of four functions rather than a library mock.

### B — a query builder

```lua
req.db:from("users"):where{ id = id }:first()
```

Safer against typos, hides SQL, and is a whole DSL to maintain. `PLAN.md`
already ruled out an ORM; a builder is halfway there.

### C — models

```lua
User:find(id)
```

That is an ORM. Permanently out of scope.

**Chose A.** Note that transactions are closure-scoped — commit at the end,
rollback on any error, including a response thrown from inside. **There is no
path where a `BEGIN` stays open because someone forgot.** Proven against a real
Postgres: the route that inserts and then fails answers 404 and leaves the
table untouched.

---

## 6. Route declaration

### A — one call per method ✅ **implemented**

```lua
app:get("/users/:id", opts, handler)
```

### B — a table of routes

```lua
app:routes {
  { "GET", "/users/:id", opts, handler },
}
```

Easier to generate and inspect programmatically; worse to read, and worse at
pointing at errors, since the error line lands on the table rather than the
route.

**Chose A**, which already records the file and line of every route — that is
what lets the duplicate-route error say *where* both of them are.

---

## 7. The boundary between request data and capabilities ✅ **settled**

`req` carries two different kinds of thing:

```lua
method, path, params, query, body, headers   -- request data, from HTTP
db, cache, log, clock                        -- capabilities, from app:run{}
```

The hazard is well known: `req` decays into a service locator, accumulating
`req.queue`, `req.mail`, `req.storage`, `req.metrics`, `req.recommendations`,
until it is a global by another name.

### Why this could not be deferred

Every entry is permanent. Moving `req.db` to `ctx.db` later would force an edit
to every handler ever written — precisely what the complexity ladder forbids.
It was the one open question with no cheap second chance.

### A — separate the two, `function(req, ctx)`

Clean in theory. But it breaks the ladder the moment it is adopted, and reads
worse: two bags instead of one.

### B — keep `req` flat, close the set by rule ✅ **implemented**

`req` stays flat. What prevents the sprawl is not syntax, it is an **admission
criterion enforced in code**:

> A capability is infrastructure the framework knows how to inject, guard and
> fake. Anything belonging to the application does not qualify.

The set is `db`, `cache`, `log`, `clock`, and it is closed. A mailer, a payment
gateway or a recommendation service does not qualify: handlers close over those
instead.

`clock` and `log` are on the list because deterministic tests need both
injectable, not because the framework ships either one.

### How it is enforced

`app:run{}` and `app:test{}` validate their keys and reject anything unknown,
naming the nearest match:

```
unknown app:run{} option 'timout'; did you mean 'timeout'?
unknown app:test{} option 'mailer'
```

This closes the capability set and fixes a separate foolproofing gap at the
same time: unknown options used to be **silently ignored**, so
`app:run { timout = 5 }` left a server running with a 30 s deadline its author
believed was 5 s.

A capability given as a function is a factory called once per request — that is
how `db` hands out a connection. Anything else is passed through as-is.

---

## 8. Adapters: own the contract, not the implementation ✅ **settled**

The README used to say "all I/O goes through adapters the framework owns".
Owning implementations for Postgres, Redis, S3, SMTP and queues would make
akkar the ecosystem's bottleneck, and there is no version of that this project
can staff.

The rule is narrower and more useful:

> **akkar owns the contract. Libraries implement it.**

akkar defines what a capability must offer, how it is acquired and released,
and how it fails. `akkar.db` is the reference implementation for Postgres, not
the only permitted one.

### The database contract

```lua
db:one(sql, ...)               -- first row, or nil
db:many(sql, ...)              -- array of rows, possibly empty
db:exec(sql, ...)              -- no rows expected
db:transaction(function(tx) end)  -- commit at the end, rollback on any error
```

Four methods. That small surface is exactly what lets the fake database in
`spec/` be a table of four functions rather than a library mock — which is the
real test of whether a contract is the right size.

### The cache contract

```lua
cache:get(key)                 -- the value, or nil when absent
cache:set(key, value, ttl)     -- ttl in seconds, optional
cache:del(key, ...)            -- count removed
cache:incr(key)
cache:expire(key, seconds)
cache:ttl(key)
cache:command(name, ...)       -- escape hatch for everything else
```

`akkar.redis` is the reference implementation. It is **written rather than
depended upon**, and that needed justifying: no non-blocking Redis client
exists for Lua 5.4 on cqueues. Every `lua-resty-*` needs OpenResty cosockets,
`lua-hiredis` blocks, and `lredis` is not packaged for 5.4. A blocking client
would pass every functional test and still stall the event loop on each
command, serialising the whole process — the exact failure the watchdog
reports, and not one to ship deliberately.

RESP2 is small enough that writing it cost less than the risk. The proof it
works is not that `GET` returns a value: it is that eight concurrent one-second
`BLPOP` calls through a pool of four complete in 2.07 s, two waves rather than
eight serial waits.

This is also where the adapter boundary stops being a slogan. Redis reuses
`akkar.pool` unchanged, supplying its own notion of "fit for reuse", and
neither adapter knows the other exists. `req.cache` needed **no framework
change at all** — `cache` was already a guarded slot in the closed capability
set, so passing `cache = ...` to `app:run{}` was the entire integration.

Not yet decided: whether akkar should verify at startup that a configured
capability satisfies its contract. It would catch the mistake at boot rather
than on the first request, matching how duplicate routes already behave. See
`docs/BACKLOG.md`.

---

## 10. Streaming keeps the return, and states what it costs ✅ **settled**

A 200 MB export does not fit inside "the handler returns the response", and
that invariant is the one everything else in akkar rests on: it is why writing
the response twice is structurally impossible.

The way out is that the handler still returns a **value** — one that describes
a body produced on demand rather than one already in hand:

```lua
return akkar.stream(function(write)
  write '{"rows":['
  for row in rows() do write(cjson.encode(row)) end
  write ']}'
end)
```

The producer receives `write` and nothing else. No connection, no status, no
headers — so it still cannot answer twice, and there is still no `c.JSON()`.

**What was rejected.** Handing the handler the `stream` object, which is what
most frameworks do. It would make every existing invariant conditional: a
handler could write and then return a response, or write twice, or set a
status after committing one. One escape hatch would undo the guarantee for
all routes, not just the streaming ones.

**Three costs, stated rather than discovered:**

1. **The status commits with the first byte.** A producer that raises
   afterwards cannot become a 500 — the 200 is already on the wire. akkar logs
   it and drops the connection without the terminating chunk, so the client
   sees a truncated response rather than a complete-looking lie. Validation
   belongs before the first `write`, where an ordinary response still works.

2. **Capabilities outlive the handler.** A stream reading from `req.db` holds
   that connection until the last byte, because releasing it at return would
   hand a live cursor to the next request. A slow client therefore holds a
   pool slot for as long as it reads. That is the real cost of streaming out
   of a database.

3. **The deadline covers the handler, not the body.** An export is meant to
   outlive a 30-second request budget. The watchdog still applies: a producer
   that burns CPU without yielding stalls the process exactly as a handler
   would.

**No content-length is sent**, because the length is not known; its absence is
what makes the response chunked. A `HEAD` gets the headers and the producer is
never run — running it to discard the bytes would perform the side effects of
a body nobody asked for.

## 9. Smaller decisions still open

- **422 or 400** for validation. Currently 422.
- **Error shape**: currently
  `{"error":"validation failed","fields":{"body.name":"required"}}`. The
  alternative is a list rather than a map, to preserve ordering.
- **`body.` / `query.` / `params.` prefixes** on field names. Currently yes,
  because it disambiguates when the same name appears in two places.
- **Unknown fields in the body**: currently ignored. They could be rejected
  (`additionalProperties: false`). Rejecting catches client typos; ignoring is
  more tolerant across versions.

---

## What is proven, running

| | Where |
|---|---|
| Ten HTTP scenarios against a real Postgres | `examples/crud.lua` |
| Twelve in-process tests, no socket and no database, in 0.11 s | `spec/` |
| Transaction rollback with a thrown response | `POST /users/:id/failing-transfer` |
| A sub-app tested standalone and mounted | `spec/` |
| Guards on `req.user` and `req.db` | `spec/` |
| Middleware observing 200, 422 and 404 | `spec/` |
| A 500 that does not leak `password=hunter2` from the traceback | `spec/` |

## Defects the tests found

1. **`normalize` ran outside the `pcall`** — a handler returning an invalid
   value escaped as an unhandled error instead of becoming a 500. Fixed, and
   the same applied to middleware returning garbage.
2. **A parse error did not traverse the middleware** — fixed by making the end
   of the chain a parameter. There is a test pinning that middleware observes
   `{200, 422, 404}`.
