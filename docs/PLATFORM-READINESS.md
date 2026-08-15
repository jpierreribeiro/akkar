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
| 1 | **Host-based routing.** `acme.example.com` selects the tenant. Only paths exist today. | Yes — multi-tenant is ordinary |
| 2 | **App as a value, and hot swap.** Build routes and validation from a table; replace a mounted sub-app atomically. | Yes |
| 3 | **Safe SQL composition.** A filter arriving as data becomes a `WHERE`. With `db:many(sql, ...)` taking a string, somebody eventually concatenates. Needs a parameterised fragment that makes concatenation impossible. | **Yes, most of all** |
| 4 | **Tenant-scoped `db`.** A query without `project_id` should be an error, not a convention. | Yes |
| 5 | **Real jobs.** Retry with backoff, delay, scheduling, dead-letter, idempotency. Today a failing job is logged and dropped, by choice. | Yes |
| 6 | **Streaming responses.** A 200 MB export does not fit inside "the handler returns the response". | Yes |
| 7 | **An isolated VM per execution.** Customer-authored logic: memory ceiling, instruction budget, no ambient I/O. | No — only the platform asks for this |

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
