# Seven items, parked

From an evaluation of whether akkar could carry a spreadsheet-to-AppSpec
platform. **Parked, not scheduled** — performance came first, and the
positioning question that would justify these is still open.

Worth keeping because six of the seven make akkar better regardless of that
platform, and two of them are the most akkar-shaped ideas anyone has proposed
for it.

## The gap underneath all of them

akkar assumes the person declaring routes is a programmer, at boot. A platform
inverts that: routes, validation schemas and the OpenAPI document come from
**data** — a spec per tenant — and change when a customer clicks publish,
without a restart.

akkar is closer to that than it looks. A handler returns a value, a sub-app is
an ordinary app mounted under a prefix, and a schema is a table. What is
missing is structural rather than large.

```lua
local app = akkar.from_spec(spec)                  -- an app built from data
platform:mount_host("acme.example.com", app)
platform:swap_host("acme.example.com", new_app)    -- atomic, no request dropped
```

## The list

| # | Item | Useful without the platform? |
|---|---|---|
| 1 | ~~**Host-based routing.**~~ **Done** — `App:host`, `App:for_host` | Yes — multi-tenant is ordinary |
| 2 | ~~**App as a value, and hot swap.**~~ **Done** — `akkar.from_spec`, `App:swap_host` | Yes |
| 3 | ~~**Safe SQL composition.**~~ **Done** — `akkar/sql.lua` | **Yes, most of all** |
| 4 | ~~**Tenant-scoped `db`.**~~ **Done** — `akkar/scope.lua` | Yes |
| 5 | ~~**Real jobs.**~~ **Done** — retries, jitter, delay, dead letters, idempotency | Yes |
| 6 | ~~**Streaming responses.**~~ **Done** — `akkar.stream` | Yes |
| 7 | ~~**An isolated VM per execution.**~~ **Done, with its limits stated** — `akkar/vm.lua` | No — only the platform asks for this |

## Why 3 and 4 are the ones to start with

akkar's thesis is that a common mistake becomes an impossible state: a double
response, an orphaned `BEGIN`, untestable I/O. The translation here is direct:

> **It is impossible to issue a query without tenant scope, and impossible to
> build a `WHERE` by concatenation.**

Cross-tenant leakage is the bug that closes a SaaS company. Making it
structurally impossible — the way double responses already are — would be a
reason for akkar to exist that defends itself, with or without any platform.

Both are also small, and both can be validated with no platform in sight: one
test proving a query without `project_id` fails, another proving a hostile
filter arriving as JSON cannot escape parameterisation.

## The tension in item 6

"Handlers return the response; they never mutate a context" is akkar's central
invariant, and streaming appears to break it. The clean way out is for the
handler to keep returning a **value** — one that describes a body produced on
demand:

```lua
return akkar.stream(function(write)
  for row in cursor do write(encode(row)) end
end)
```

Still a return. Still no `c.JSON()`. But that is a real design decision and
belongs in `docs/DECISIONS.md` before it becomes code.

## What is deliberately not decided here

Whether akkar ever becomes that platform's backend. The evaluation's own
conclusion was that the platform should be TypeScript end to end for good
reasons, and that if akkar never enters it, that is not a failure of akkar.
These seven are about making akkar stronger; where it gets used is a separate
question, answered later.


---

# What landed for 3 and 4

Both shipped together, because a tenant scope that cannot be applied to a
query is not a scope, and a query builder with no reason to exist is not
worth its weight.

## 3 — `akkar.sql`

A value can never become SQL text. `?` marks a value; numbering into `$1, $2`
happens once, at assembly, so fragments added in different places compose
without anyone tracking indices by hand — which is the *other* half of why
people give up and concatenate.

```lua
local q = sql.select("id, name"):from "documents"
if req.query.name then q:where("name like ?", req.query.name .. "%") end
q:order_by(req.query.sort, { "id", "name", "created_at" }):limit(20)
return req.db:many(q)
```

Three decisions worth stating, because each rejects an easier option:

- **There is no `where_raw`.** An escape hatch is where the injection goes. A
  test asserts the door does not exist rather than trusting nobody opens it.
- **Identifiers are allow-listed, not escaped.** Postgres has no placeholder
  for a column name, so ordering by a client-supplied field is checked against
  a list the route declares. The pattern rejects a crafted string; the list
  rejects a *real* column the route never meant to expose, like
  `password_hash`.
- **`UPDATE` and `DELETE` with no `WHERE` are refused.** That shape is
  legitimate in a migration and almost never in a handler, so it must be asked
  for by name — `:all_rows()` — rather than reached by forgetting a line.

## 4 — `akkar.scope`

```lua
local db = req.db:scope("project_id", req.user.project_id)
return db:many(sql.select("*"):from "documents")
```

A scoped handle **refuses raw SQL outright**, because a string cannot be
scoped without parsing it, and a SQL parser inside the framework would be a
second, worse database. Against a builder it applies the condition itself, so
the unscoped statement is never assembled — there is no window in which it
could be sent. The test asserts exactly that: after a refused raw query, the
fake database's log is empty.

The parts that took the most thought were not the happy path:

- **An insert overrides a `project_id` the client supplied.** A body claiming
  another tenant's id must not be able to write into it.
- **A `nil` tenant id raises** rather than quietly matching every row — the
  failure mode where a missing session turns a scoped query into a full dump.
- **Scoping twice narrows.** An organisation and a project are both true at
  once; replacing the outer scope would widen the query.
- **A transaction hands the closure the *scoped* handle**, so nothing inside
  can escape by reaching past it.
- **The escape hatch is named at the call site.** `req.db:unscoped()` is a
  no-op that exists to make `grep -rn ':unscoped()'` the complete list of
  queries that cross tenants. A short list someone can actually read beats a
  rule nobody can verify.

Scoping lives at the **contract** level, not inside `akkar.db`, so
`akkar.db.memory` scopes through the same code. A fake whose safety property
differs from the real one is how a test proves the wrong thing.

## Status

| # | Item | State |
|---|---|---|
| 1 | Host-based routing | **done** — `App:host`, `App:for_host`, 14 tests |
| 2 | App as a value + hot swap | **done** — `akkar.from_spec`, `App:swap_host`, 12 tests |
| 3 | Safe SQL composition | **done** — `akkar/sql.lua` |
| 4 | Tenant-scoped `db` | **done** — `akkar/scope.lua` |
| 5 | Real jobs | **done** — 23 tests, 7 against a live Redis |
| 6 | Streaming responses | **done** — `akkar.stream`, 10 tests |
| 7 | Isolated VM per execution | **done** — `akkar.vm`, 26 tests, most of them attempted escapes |

## What landed for 1 and 2

**Host routing selects the whole application**, not just its routes — its
middleware, its error handling, its OpenAPI document. Selecting only the
routes would run the wrong app's authentication against the right app's
handler, which is a worse bug than having no host routing at all.

The tests that carry the weight are the ones about what must *not* match. A
`*.example.com` treated as "ends with example.com" hands `evil-example.com` to
the tenant application; treated as a Lua pattern without escaping, it matches
`x.exampleXcom`. Both are covered, along with the bare domain and the
two-label case. This is the same failure the tenant-scoped database prevents,
one layer up.

**A spec cannot introduce code.** Handlers are named and resolved against a
table the caller supplies. A spec that carried executable code would mean
anyone who can publish a spec can run anything in the process — and the specs
that most want this shape are exactly the ones arriving from outside. That is
item 7's problem, and answering it here by accident would answer it wrong.

Schemas needed no translation: `"string?"` and `{ kind = "integer", min = 1 }`
were already the data form. A test round-trips a whole spec through
`cjson.encode` and back, because a spec that does not survive encoding is not
data — it is Lua that looks like it.

**The swap is atomic**, and the reason is worth stating rather than asserting:
one Lua VM runs one coroutine at a time and switches only at a yield, and
assigning a field yields nowhere. A request already in flight finishes against
the app it was routed to, which a test proves by swapping while a handler
sleeps.


## What landed for 7, and what it does not claim

`akkar.vm` is a **sandbox inside one Lua state, not an isolated VM**. Lua 5.4
cannot create a separate state from Lua; that needs C or a subprocess. What it
does have is a curated `_ENV`, text-only loading, an instruction budget and a
memory ceiling.

Within those limits it is real. Beyond them it is not a boundary against a
determined attacker sharing the process, and the module says so at the top:
**if the code is hostile rather than merely untrusted, run it in a separate
process with an OS-level sandbox.**

Four escapes are worth recording, because three of them are quiet and two were
found by tests written to prove they could not happen:

- **Bytecode.** Crafted bytecode reads and writes arbitrary memory; the VM
  validates very little. Loading is `"t"` with no way to ask for anything else.
- **Coroutines.** A hook is installed on *one* coroutine, so
  `coroutine.wrap(function() while true do end end)()` runs with no budget and
  hangs the process. `coroutine` is not in the environment. This is the one
  most likely to be missed, because the sandbox otherwise looks complete.
- **A `pcall` that swallows the budget.** A budget enforced by raising is
  enforced only if the error escapes, and `while true do pcall(...) end`
  catches every overrun forever. Lua has no uncatchable error, so the
  sandbox's `pcall` re-raises anything thrown after the budget is gone. *Found
  by the test asserting it was impossible — which hung the suite.*
- **Method syntax on strings.** `("x"):rep(2^30)` resolves through the shared
  string metatable to the **real** `string` library, never through the copy in
  the sandbox's `_ENV`. Bounding the sandbox's own `string.rep` did nothing. A
  curated `_ENV` does not cover strings at all. *Also found by a test.*

One bound was **removed** after a test disproved its premise: `string.format`
was guarded against a wide field like `%099999999d`, but Lua 5.4 rejects any
width of 100 or more, so a directive can produce at most 99 bytes. The check
cost a pattern match per call and bought nothing.
