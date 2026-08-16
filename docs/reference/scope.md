# akkar.scope

A database handle that cannot issue an unscoped query. Every query that passes
through it gets `column = value` added before it runs, and the unscoped statement
is never assembled.

**When you need it.** Any table whose rows belong to one account, one tenant or
one project. Reach for it through `req.db:scope(column, value)`; this page
documents the handle that comes back.

```lua no-run
local scope = require "akkar.scope"
```

You will rarely require it by name. `akkar.db` and `akkar.db.memory` both expose
it as `db:scope(column, value)`, and `akkar.db.scope` is the same function as
`scope.wrap`. It lives at the contract level rather than inside `akkar.db` so the
in-memory adapter scopes identically: a fake whose safety property differs from
the real one is how a test proves the wrong thing.

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`scope.Scoped`](#scoped) | metatable |
| [`scope.wrap`](#scopewrapdb-column-value) | function |
| [`Scoped:close`](#scopedclose) | method |
| [`Scoped:exec`](#scopedexecquery) | method |
| [`Scoped:many`](#scopedmanyquery) | method |
| [`Scoped:one`](#scopedonequery) | method |
| [`Scoped:release`](#scopedrelease) | method |
| [`Scoped:scope`](#scopedscopecolumn-value) | method |
| [`Scoped:transaction`](#scopedtransactionfn) | method |
| [`Scoped:unscoped`](#scopedunscoped) | method |

## scope.wrap(db, column, value)

Wraps a database handle. Reachable as `db:scope(column, value)` on both adapters,
and exported as `akkar.db.scope`.

| argument | type | meaning |
|---|---|---|
| `db` | table | the handle to wrap: a connection, or another Scoped |
| `column` | string | the column the condition names |
| `value` | any | the value it must equal. Anything except `nil` |

**Returns** a Scoped.

**Raises** `db: scope value for '<column>' is nil; a missing tenant id has to
fail here rather than quietly match every row` when `value` is nil. This is the
one that catches a `req.auth.user_id` read before anybody logged in.

```lua
local sql    = require "akkar.sql"
local memory = require "akkar.db.memory"

local db = memory.new()
db:on(".", function() return {} end)

local mine = db:scope("user_id", 7)

mine:many(sql.select("id, title"):from "tasks")
print(db.log[1].sql)
print("value:", db.log[1].args[1])

-- The scope wins over a user_id the caller put in the row.
local row = { title = "buy milk", user_id = 999 }
mine:exec(sql.insert_into("tasks", row, { "title", "user_id" }))
print(db.log[2].sql)
print("owner:", db.log[2].args[2])

-- A raw string cannot be scoped, so it is refused.
local ok, why = pcall(function() return mine:many "select * from tasks" end)
print("raw sql:", ok)
print(why)

-- A nil tenant id is refused rather than matching every row.
print(select(2, pcall(function() return db:scope("user_id", nil) end)))
```

## Scoped

The handle `scope.wrap` returns. It carries the same five query methods a
connection does, plus `unscoped`.

Every one of `many`, `one` and `exec` refuses a string:

```
db: this handle is scoped to <column>, so it takes an akkar.sql query rather
than raw SQL -- a string cannot be scoped without parsing it. Use db:unscoped()
if the query genuinely covers every tenant.
```

The reason is in the message. Adding a condition to a statement means
understanding the statement, and a string is just letters: where does the `where`
go, is there one already, is this a select inside a select. Answering that means
a SQL parser inside akkar, and a parser that disagrees with Postgres about what a
query means would be wrong quietly.

### Scoped:close()

Passes through to the wrapped handle's `close`.

### Scoped:exec(query)

Scopes an `akkar.sql` builder and runs it for its effect.

**Returns** whatever the wrapped handle's `exec` returns, which for
`akkar.db` includes `affected_rows`.

**Raises** the refusal above when `query` is a string, or anything else with no
`scope` method.

### Scoped:many(query)

Scopes an `akkar.sql` builder and runs it.

**Returns** the rows.

**Raises** the refusal above when `query` is not a builder.

### Scoped:one(query)

**Returns** the first row, or `nil`. A row that exists but belongs to another
tenant is `nil` here, which is why an ownership check ends up answering `404`
without any handler choosing to.

**Raises** the refusal above when `query` is not a builder.

### Scoped:release()

Passes through to the wrapped handle's `release`, returning a pooled connection.

### Scoped:scope(column, value)

Scoping twice **narrows** rather than replaces. An organisation and a project are
both true at once, and dropping the outer one would widen the query.

**Returns** a new Scoped wrapping this one. Both conditions are ANDed, innermost
first.

### Scoped:transaction(fn)

Runs `fn` inside the wrapped handle's transaction. The closure receives the
**scoped handle**, not the connection, so nothing inside a transaction can escape
the scope by reaching past it.

**Returns** whatever the wrapped handle's `transaction` returns.

### Scoped:unscoped()

**Returns** the handle underneath, with no condition attached.

It is a wordy name at the call site, and that is the feature:
`grep -rn ':unscoped()'` gives the complete list of every query in an
application that crosses between tenants. A short list somebody can read beats a
rule nobody can check.

```lua
local sql    = require "akkar.sql"
local memory = require "akkar.db.memory"

local db = memory.new()
db:on(".", function() return {} end)

-- Scoping twice narrows: both conditions hold at once.
db:scope("org_id", 1):scope("project_id", 7)
  :many(sql.select("*"):from "documents")
print(db.log[1].sql)

-- The closure is handed the scoped handle, not the connection.
db:scope("user_id", 7):transaction(function(tx)
  tx:exec(sql.delete_from("tasks"):where("done = ?", true))
  return true
end)
for _, entry in ipairs(db.log) do print(entry.sql) end

-- The escape hatch, named at the call site so grep can find it.
db:scope("user_id", 7):unscoped():many "select count(*) from tasks"
print(db.log[#db.log].sql)
```

## What "scoped" means per statement

The condition is applied by the builder's own `scope` method, so where it lands
depends on the statement. `akkar.scope` itself does not know SQL.

| statement | what happens |
|---|---|
| `select` | `and column = ?` is added to the where clause |
| `update` | the same, alongside the handler's own conditions |
| `delete` | the same. A delete that matches no rows is how another tenant's row survives |
| `insert` | the column is **set**, overriding whatever the row carried. A caller who puts somebody else's id in a request body writes into their own account anyway |

## Not here

**No raw SQL, and no option that promises you added the filter yourself.** From
the module's own docstring: "a string cannot be scoped without parsing it, and a
SQL parser in the framework would be a second, worse database". An option to pass
a string with a promise attached is exactly where the missing filter goes.
`Scoped:unscoped()` is the escape hatch, and it is deliberately wordy so that
`grep` finds it.

**No automatic scope.** Nothing reads `req.auth` for you and nothing applies a
scope to a handle you did not wrap. The one call at the top of a handler is the
whole interface, and a scope applied invisibly would be a scope nobody could
audit.

## See also

- [akkar.auth](auth.md), which is where the value you scope on comes from
- guide page [8. Only your own tasks](../guide/08-only-your-own.md), for the bug
  this removes, shown before it is fixed
- the module source, `akkar/scope.lua`, and `spec/scope_spec.lua`, which asserts
  that the unscoped statement never reaches the database
