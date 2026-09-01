# akkar.db

The Postgres adapter. It turns a configuration table into a factory that opens
connections, and gives every connection four methods: `one`, `many`, `exec`
and `transaction`.

**When you need it.** Once, at startup, to build the factory you hand to
`app:run { db = open }`. Inside a handler you use `req.db`, which is one of
these connections, and you never call this module again.

```lua no-run
local db = require "akkar.db"
```

## Index

Every public symbol on this page, in alphabetical order. `conn` is what the
factory returns; `fake` is an `akkar.db.memory` instance.

| symbol | kind |
|---|---|
| [`conn:close`](#connclose) | method |
| [`conn:exec`](#connexecsql-) | method |
| [`conn:many`](#connmanysql-) | method |
| [`conn:one`](#connonesql-) | method |
| [`conn:query`](#connquerysql-) | method |
| [`conn:release`](#connrelease) | method |
| [`conn:scope`](#connscopecolumn-value) | method |
| [`conn:transaction`](#conntransactionfn) | method |
| [`conn:unscoped`](#connunscoped) | method |
| [`db.connect`](#dbconnectconfig) | function |
| [`db.Pool`](#dbpool) | re-export |
| [`db.scope`](#dbscopehandle-column-value) | re-export |
| [`fake:close`](#fakeclose) | method |
| [`fake:count`](#fakecountpattern) | method |
| [`fake:drop`](#fakedroppattern) | method |
| [`fake:exec`](#fakeexecsql-) | method |
| [`fake:fail`](#fakefailpattern-message) | method |
| [`fake:hang`](#fakehangpattern-seconds) | method |
| [`fake:many`](#fakemanysql-) | method |
| [`fake:on`](#fakeonpattern-response) | method |
| [`fake:one`](#fakeonesql-) | method |
| [`fake:query`](#fakequerysql-) | method |
| [`fake:received`](#fakereceivedpattern) | method |
| [`fake:release`](#fakerelease) | method |
| [`fake:reset`](#fakereset) | method |
| [`fake:scope`](#fakescopecolumn-value) | method |
| [`fake:transaction`](#faketransactionfn) | method |
| [`fake:unscoped`](#fakeunscoped) | method |
| [`memory.factory`](#memoryfactoryconfigure) | function |
| [`memory.new`](#memorynew) | function |

Also on this page: [The pool](#the-pool), [The pq driver](#the-pq-driver) and
[Not here](#not-here).

## db.connect(config)

Builds a factory. It does not connect: nothing reaches Postgres until the
factory is called, and nothing in `config` is checked until then either.

| field | type | default | meaning |
|---|---|---|---|
| `host` | string | `"127.0.0.1"` | where Postgres is |
| `port` | number | `5432` | its port |
| `database` | string | none | the database name |
| `user` | string | none | the role to log in as |
| `password` | string | none | its password |
| `pool_size` | number | `10` | how many connections to keep; `0` means no pool |
| `statement_timeout` | number | none | seconds, set on the connection with `set statement_timeout` |
| `driver` | string | `"pgmoon"` | `"pgmoon"` or `"pq"` |
| `buffered_reads` | boolean | `true` | pgmoon only; `false` puts pgmoon's own per-message socket reads back |
| `ssl` | boolean | `false` | pgmoon only; ask the server for TLS |
| `ssl_required` | boolean | **follows `ssl`** | pgmoon only; refuse to continue if the server declines TLS |
| `ssl_verify` | boolean | `false` | pgmoon only; verify the server certificate against a CA store and the host name |
| `cafile` | string | none | pgmoon only; a CA bundle to trust instead of the system defaults |
| `cert` / `key` | string | none | pgmoon only; a client certificate and its key |
| `ssl_version` | string | `"TLS"` | pgmoon only; the OpenSSL protocol name |
| `cqueues_openssl_context` | object | none | pgmoon only; your own OpenSSL object, used as-is |

`statement_timeout` is what stops the query, as opposed to stopping the wait
for it. akkar can abandon a slow query, but only Postgres can stop running one,
so a deployment with a request deadline and no `statement_timeout` gets a
startup warning naming the setting.

**Returns** `open`. With `pool_size = 0` it is a plain function of no arguments
returning a [Connection](#connection). Otherwise it is a callable table whose
`pool` field is the [akkar.pool](pool.md) behind it, so `app:run` can close it
at shutdown.

**Raises** nothing. `open` raises:

- `db: could not connect to <host>:<port> (database "<db>", user "<user>") -- <reason>`,
  with `Nothing is listening there. Is the database running?` added when the
  reason mentions a refused connection
- `db: could not set statement_timeout: <reason>`, after disconnecting
- `db: unknown driver '<name>'; expected 'pgmoon' or 'pq'`
- `db: driver 'pq' needs the C module akkar.pq_native, which is a separate rock: luarocks install akkar-pq ...`
- `the server does not support SSL connections`, wrapped in the same
  `db: could not connect to ...` sentence, when TLS was asked for and refused

```lua
local db = require "akkar.db"

local open = db.connect {
  host      = "127.0.0.1",
  port      = 55432,
  database  = "akkar",
  user      = "postgres",
  password  = "akkar",
  pool_size = 0,
}

local conn = open()
print(conn:one("select 1 as n").n)
conn:close()
```

### TLS to Postgres

pgmoon only — the `pq` driver takes libpq's `sslmode` instead.

```lua no-run
local open = db.connect {
  host     = "db.internal",
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  ssl        = true,
  ssl_verify = true,
  cafile     = "/etc/ssl/certs/internal-ca.pem",   -- optional; system store otherwise
}
```

**`ssl_required` defaults to whatever `ssl` is.** Asking for TLS means
requiring it, and the reason is the shape of the protocol: PostgreSQL
negotiates TLS **in cleartext**. The client sends an SSLRequest and the server
answers a single byte, `S` for yes or `N` for no. A driver that treats `N` as
"fine, carry on" continues on the plain socket — and everything `ssl_verify`
set up is then skipped, because no handshake ever happens: no certificate is
presented, no CA is consulted, no host name is checked. Anyone able to answer
that byte strips the encryption, and the connection reports success.

So `ssl = true` alone refuses a server that declines, with `the server does not
support SSL connections`. Opportunistic TLS — try it, accept cleartext if the
server says no — is still available and has to be said out loud:

```lua no-run
local open = db.connect {
  host = "127.0.0.1", database = "akkar", user = "postgres", password = "akkar",
  ssl = true, ssl_required = false,       -- deliberately allows a downgrade
}
```

`ssl_verify = true` is what makes the certificate mean anything. It builds an
OpenSSL client with `VERIFY_PEER`, a CA store (`cafile`, or the system
defaults), and a verify parameter carrying the name the certificate has to
match — `setHost` for a host name, with SNI sent, and `setIP` for an IP
literal, without. Without it pgmoon's own context verifies nothing, so
`ssl = true` on its own gets you an encrypted connection to whoever answered.
`cert` and `key` add a client certificate; `cqueues_openssl_context` replaces
the whole construction with an object you built yourself. `db.tls_client(config)`
is that construction, exposed so it can be inspected in a test.

`spec/db_tls_downgrade_spec.lua` is the proof: a fake server that answers `N`
and nothing else. The required case must refuse; the opportunistic case must
get *further*, as far as a startup response that never comes.

## db.Pool

The [akkar.pool](pool.md) module, re-exported. `db.Pool == require "akkar.pool"`.

Present so a caller who already has `akkar.db` can build a pool of something
else without a second `require`.

```lua no-run
local db = require "akkar.db"
local pool = db.Pool.new(open_something, 4)
```

## db.scope(handle, column, value)

`akkar.scope`'s `wrap`, re-exported. It wraps any database handle so every
query it runs carries `column = value`. Same function as
[`conn:scope`](#connscopecolumn-value), reachable without a connection in hand,
and the same one `akkar.db.memory` uses.

**Returns** a [Scoped](scope.md#scoped) handle: `one`, `many`, `exec`,
`transaction`, `scope`, `unscoped`, `release`, `close`.

**Raises** `db: scope value for '<column>' is nil; a missing tenant id has to
fail here rather than quietly match every row`.

```lua
local db     = require "akkar.db"
local memory = require "akkar.db.memory"
local sql    = require "akkar.sql"

local fake = memory.new():on("project_id", { id = 1, title = "notes" })
local scoped = db.scope(fake, "project_id", 42)

print(scoped:one(sql.select("id, title"):from "ref_db_documents").title)
print(fake.log[1].sql)
```

## Connection

What `open()` returns. A row is a plain Lua table with one field per column. A
SQL `NULL` is left out of the row entirely, so a column that was null reads as
`nil` rather than as a sentinel.

Every method takes either SQL text plus values, or an
[akkar.sql](sql.md) query, which it builds for you.

### conn:close()

Disconnects. The connection is unusable afterwards and does not go back to any
pool.

Use [`release`](#connrelease) instead for a pooled connection.

**Returns** nothing.

```lua no-run
conn:close()
```

### conn:exec(sql, ...)

Runs a statement for its effect. The same call as `many` under a different
name, so `grep` can tell an insert from a read.

**Returns** whatever the driver answers, which is not the same shape for every
statement: a table with `affected_rows` for `insert`, `update` and `delete`,
the boolean `true` for DDL such as `create table`, and the rows for a statement
with `returning`.

**Raises** `db: <message from Postgres>`.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "create table ref_db_notes (id serial primary key, body text)"
conn:exec("insert into ref_db_notes (body) values ($1), ($2)", "one", "two")

local gone = conn:exec("delete from ref_db_notes where body = $1", "one")
print(gone.affected_rows)

conn:exec "drop table ref_db_notes"
conn:close()
```

### conn:many(sql, ...)

Runs a statement and returns its rows.

**Returns** a list of rows, empty when nothing matched. A statement that
answers no result set at all (`create table`) gives an empty list rather than
the driver's own value.

**Raises** `db: <message from Postgres>`.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local rows = conn:many "select 1 as n union all select 2 order by n"
for _, row in ipairs(rows) do print(row.n) end
print(#conn:many "select 1 where false")

conn:close()
```

### conn:one(sql, ...)

Runs a statement and returns its first row.

**Returns** a row, or `nil` when nothing matched. This is why
`or akkar.not_found "..."` reads well after it.

**Raises** `db: <message from Postgres>`.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

print(conn:one("select $1::text as greeting", "hello").greeting)
print(conn:one "select 1 as n where false")

conn:close()
```

### conn:query(sql, ...)

The one call the other three are built on. It returns the driver's answer
untouched, so nothing normalises a missing result set into an empty list.

Prefer `one`, `many` or `exec`. This is here because it is public and because
a connection that raised inside it is marked broken and will not go back to the
pool.

**Returns** the driver's result.

**Raises** `db: <message>` for both a returned error and a raised one.

```lua no-run
local rows = conn:query("select id from ref_db_notes where id = $1", 1)
```

### conn:release()

Returns the connection to the pool it came from, or closes it when there is no
pool.

A connection still inside a transaction, one whose rollback failed, and one
with a query still in flight are discarded rather than pooled. akkar calls this
for you at the end of every request, on every exit path.

**Returns** nothing.

```lua no-run
conn:release()
```

### conn:scope(column, value)

Returns a handle that cannot issue an unscoped query. Every
[akkar.sql](sql.md) query passing through it gets `column = value` added, and
raw SQL text is refused outright, because a string cannot be scoped without
parsing it.

Scoping a scoped handle narrows it. Both conditions apply.

**Returns** a [Scoped](scope.md#scoped) handle.

**Raises** `db: scope value for '<column>' is nil ...` at wrap time, and
`db: this handle is scoped to <column>, so it takes an akkar.sql query rather
than raw SQL ...` when it is handed a string.

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec [[create table ref_db_docs (
  id serial primary key, project_id int not null, title text not null)]]
conn:exec "insert into ref_db_docs (project_id, title) values (1, 'ours'), (2, 'theirs')"

local mine = conn:scope("project_id", 1)
for _, row in ipairs(mine:many(sql.select("id, title"):from "ref_db_docs")) do
  print(row.title)
end

local ok, why = pcall(function()
  return mine:many "select title from ref_db_docs"
end)
print(ok, why)

conn:exec "drop table ref_db_docs"
conn:close()
```

### conn:transaction(fn)

Runs `fn(tx)` between `begin` and `commit`. `tx` is this same connection.
Anything raised inside rolls back and is re-raised, so a response thrown with
`error(akkar.bad_request "...")` still reaches the caller.

**Returning a 4xx from inside commits.** A closure that returned did not fail,
so the transaction succeeded. Raise to refuse.

**Returns** whatever `fn` returned.

**Raises** whatever `fn` raised, unchanged. A connection whose `rollback` also
failed is marked broken and will not be pooled again.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "create table ref_db_ledger (id serial primary key, body text)"

conn:transaction(function(tx)
  tx:exec("insert into ref_db_ledger (body) values ($1)", "kept")
end)

local ok = pcall(function()
  conn:transaction(function(tx)
    tx:exec("insert into ref_db_ledger (body) values ($1)", "undone")
    error "changed my mind"
  end)
end)

print(ok, conn:one("select count(*)::int as n from ref_db_ledger").n)

conn:exec "drop table ref_db_ledger"
conn:close()
```

### conn:unscoped()

Returns the connection itself. It does nothing.

It exists so that `grep -rn ':unscoped()'` is the complete list of queries that
cross tenants. On a handle from [`scope`](#connscopecolumn-value) it returns
the connection underneath, which is where the escape actually happens.

**Returns** the connection.

```lua no-run
local everyone = req.db:unscoped():many "select count(*) from documents"
```

## The pool

With `pool_size` above zero, the factory is a callable table and `open.pool` is
the [akkar.pool](pool.md) instance. Calling the factory takes a connection out;
[`release`](#connrelease) puts it back.

A connection goes back only when it is fit for reuse: not inside a transaction,
not marked broken, not holding a query nobody read, and not already closed.
Anything else is closed and its slot freed, so the next request opens a fresh
one.

When the pool is full, a caller yields until one is returned. It does not block
the process and it does not open an eleventh connection.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  pool_size = 4,
}

local conn = open()
print(conn:one("select 1 as n").n)

local stats = open.pool:stats()
print("size", stats.size, "live", stats.live, "idle", stats.idle)

conn:release()
print("idle after release", open.pool:stats().idle)

open.pool:close()
```

## The pq driver

`driver = "pq"` uses `akkar.pq`, a driver over libpq that waits in Lua.

### Installing it

The C half is a **separate rock**, because linking libpq into `akkar` itself
would break `luarocks install akkar` for everyone who does not use Postgres:

```sh
luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir)
```

`PQ_INCDIR` is needed on Debian and Ubuntu, where `libpq-fe.h` lives in
`/usr/include/postgresql` rather than anywhere LuaRocks looks by default. On a
system that puts it somewhere standard, plain `luarocks install akkar-pq`
works. From a checkout, `src/build.sh` does the same thing.

Without the C module the factory raises and names the install line — the
option fails loudly at connect time, not quietly at the first query.

### What it buys, and why it is not the default

Measured end to end over HTTP on a reserved machine, against pgmoon:

| route | pgmoon | akkar.pq |
|---|---:|---:|
| one row | 7,040 req/s | **8,969** (1.27x) |
| a hundred rows | 2,392 | **5,031** (2.10x) |
| a thousand rows | 333 | **928** (2.79x) |
| p99, a thousand rows, saturated | 1300 ms | **475 ms** |

**pgmoon is still the default, and not because of any doubt about `akkar.pq`.**
The C half is a separate rock, so a default of `pq` would fail at the first
query for everyone who installed only `akkar`. That is packaging, not judgement.

An earlier consistency objection has been **withdrawn**. It reported that
`akkar.pq` lost two windows in thirty where pgmoon lost none; investigated, the
number does not reproduce — 1.8% spread and zero anomalous windows at the same
configuration — and the one raggedness that does reproduce is the harness
splitting a small number of connections across processes, which hits pgmoon
harder. `bench/driver/ANOMALY.md` has the four experiments, two of which
refuted a hypothesis.

So: **if you install `akkar-pq`, use it.** Both numbers and the correction are
in `bench/driver/RESULTS.md` §5.

Everything on this page behaves the same either way: the shim gives `akkar.pq`
pgmoon's shape, and `Connection`, the transaction, the scope wrapper and the
pool never learn which driver is underneath.

Three configuration fields reach `akkar.pq` and are ignored by pgmoon:
`application_name` (default `"akkar"`), `sslmode` and `connect_timeout`.

```lua no-run
local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  driver = "pq",
  application_name = "reports",
}
```

## akkar.db.memory

A separate module, `require "akkar.db.memory"`, answering the same four
methods. It is not a SQL engine: it does not parse the query, it matches it
against responses you programmed, and a query nobody programmed raises.

**When you need it.** Testing a handler whose database work is not the thing
under test, and testing failure shapes that a real database will not produce on
demand: a dropped connection, a query that hangs.

```lua no-run
local memory = require "akkar.db.memory"
```

### memory.factory(configure)

Builds one instance, runs `configure(instance)` on it if given, and wraps it in
the callable shape `app:run{}` and `app:test{}` expect for `db`.

Every call returns the same instance, so a test can program it once and assert
on it afterwards through `factory.instance`.

**Returns** a callable table with an `instance` field.

```lua
local akkar  = require "akkar"
local memory = require "akkar.db.memory"

local factory = memory.factory(function(fake)
  fake:on("^select id, title from ref_db_tasks", { id = 1, title = "buy milk" })
end)

local app = akkar.new()
app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  return req.db:one("select id, title from ref_db_tasks where id = $1",
                    req.params.id)
end)

local res = app:test { db = factory }:get "/tasks/1"
print(res.status, res.body.title)
print(factory.instance:received "ref_db_tasks")
```

### memory.new()

A fresh instance with nothing programmed.

Passing the instance itself as `db` works too: `app:test{}` accepts a table as
well as a factory, and every request then shares it.

**Returns** a Memory instance.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new()
print(pcall(function() return fake:one "select 1" end))
```

### Memory

Methods below are on the instance. `on`, `fail`, `hang` and `drop` return the
instance, so they chain.

Patterns are Lua patterns, matched anywhere in the SQL with `string.find`. A
plain string with no magic characters in it therefore works as a substring
match. `^` anchors to the start of the statement; `-`, `%`, `(`, `.` and `+`
mean what they mean in a Lua pattern.

**The first programmed pattern that matches wins**, in the order they were
added. A broad `:on "^select"` added first shadows every `select` programmed
after it.

#### fake:close()

Does nothing. Present so the handle answers the same contract as a real
connection.

#### fake:count(pattern)

How many received queries match `pattern`. With no argument, how many queries
were received at all, which includes the `begin` and `commit` a transaction
sent.

**Returns** a number.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():on("^insert", { id = 1 })
fake:transaction(function(tx) tx:exec "insert into ref_db_tasks (title) values ($1)" end)

print(fake:count "^insert", fake:count())
```

#### fake:drop(pattern)

Programs a matching query to kill the connection, not merely to fail. It raises
`db: connection reset by peer`, and **every** query afterwards raises the same
thing, which is what a closed socket does. Only [`reset`](#fakereset) undoes
it.

The difference from `fail` is what a pool must do about it: a failed query
leaves a healthy connection, a dropped one must never go back.

**Returns** the instance.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():drop("^select 2"):on("^select", { n = 1 })

print(fake:one("select 1").n)
print(pcall(function() return fake:one "select 2" end))
print(pcall(function() return fake:one "select 1" end))

fake:reset()
print(fake:one("select 1").n)
```

#### fake:exec(sql, ...)

As `many`, under the other name.

#### fake:fail(pattern, message)

Programs a matching query to raise `db: <message>`, defaulting to
`db: query failed`. The connection stays usable.

**Returns** the instance.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new()
fake:fail("^insert into ref_db_tasks", "duplicate key value violates unique constraint")

print(pcall(function()
  return fake:exec "insert into ref_db_tasks (title) values ($1)"
end))
```

#### fake:hang(pattern, seconds)

Programs a matching query to wait `seconds` (60 by default) and then raise
`db: query hung and was never answered`.

The wait is real and it yields, which is the point: it stages a coroutine
abandoned mid-query, which raising immediately does not.

**Returns** the instance.

```lua
local memory = require "akkar.db.memory"
local time   = require "akkar.time"

local fake = memory.new():hang("pg_sleep", 0.1)

local started = time.monotime()
print(pcall(function() return fake:one "select pg_sleep(30)" end))
print("waited:", time.monotime() - started >= 0.1)
```

#### fake:many(sql, ...)

Finds the first matching response and returns it as a list of rows.

A response that is a function is called as `response(sql, ...)`. A response
that is a single row is returned as a one-row list, so `one` and `many` both
work against the same programming. A response of `nil`, including a function
returning nothing, is an empty list.

**An empty table is one empty row, not zero rows.** `{}` has no `[1]`, so it
takes the single-row branch and `one` hands back a truthy table with nothing in
it. To program a miss, use a function:

```lua no-run
fake:on("where id", function() return nil end)   -- zero rows
fake:on("where id", {})                          -- ONE row, with no columns
```

And `reset` does not unprogram anything — it clears the log and the transaction
flags. Since `many` returns the **first** pattern that matches, programming the
same pattern again never wins. Build a new fake for a scenario that needs a
different answer to the same query.

**Returns** a list of rows.

**Raises** `akkar.db.memory: no response programmed for query: <sql>` and
`akkar.db.memory: query needs SQL, got <type>`.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new()
  :on("^select id, title", { id = 1, title = "buy milk" })
  :on("^insert into ref_db_tasks", function(_, title)
        return { id = 42, title = title }
      end)

print(#fake:many "select id, title from ref_db_tasks")
print(fake:one("insert into ref_db_tasks (title) values ($1) returning id, title",
               "walk the dog").title)
```

#### fake:on(pattern, response)

Programs a response. `response` is a row, a list of rows, or a function called
as `response(sql, ...)` whose return value is used the same way.

**Returns** the instance.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new()
  :on("^select id from ref_db_tasks", { { id = 1 }, { id = 2 } })
  :on("^select count", { n = 2 })

print(#fake:many "select id from ref_db_tasks")
print(fake:one("select count(*) as n from ref_db_tasks").n)
```

#### fake:one(sql, ...)

The first row of `many`, or `nil`.

#### fake:query(sql, ...)

What `one`, `many` and `exec` are built on. An [akkar.sql](sql.md) query is
built here, exactly as the real adapter builds it, so the log holds the SQL a
server would have sent.

`begin`, `commit` and `rollback` are answered by the adapter itself, so a test
does not have to program them.

**Returns** the programmed response.

```lua
local memory = require "akkar.db.memory"
local sql    = require "akkar.sql"

local fake = memory.new():on("select id from ref_db_tasks", { id = 7 })

print(fake:one(sql.select("id"):from("ref_db_tasks"):where("id = ?", 7)).id)
print(fake.log[1].sql)
print(fake.log[1].args[1])
```

#### fake:received(pattern)

Whether a query matching `pattern` was received.

**Returns** `false`, or `true` plus the log entry, which is
`{ sql = ..., args = table.pack(...) }`.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():on("^update", { id = 1 })
fake:exec("update ref_db_tasks set done = true where id = $1", 3)

local seen, call = fake:received "^update"
print(seen, call.sql, call.args[1])
print(fake:received "^delete")
```

#### fake:release()

Does nothing. Present so akkar can release it like any other connection.

#### fake:reset()

Clears the query log, the `committed` and `rolled_back` marks, and any dropped
state. Programmed responses stay.

**Returns** the instance.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():on("^select", { n = 1 })
fake:one "select 1"
print(fake:count())
print(fake:reset():count())
```

#### fake:scope(column, value)

The same scoping as the real adapter, through the same module, so a fake cannot
have a weaker safety property than the connection it stands in for.

**Returns** a [Scoped](scope.md#scoped) handle.

#### fake:transaction(fn)

Same shape as the real one: `commit` at the end, `rollback` on a raise, and the
error re-raised so a thrown response still works.

Afterwards `fake.committed` or `fake.rolled_back` is `true`, and `fake.depth`
counts the nesting while it runs.

**Returns** whatever `fn` returned.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():on("^insert", { id = 1 })

fake:transaction(function(tx) tx:exec "insert into ref_db_tasks (title) values ($1)" end)
print("committed", fake.committed)

print(pcall(function()
  fake:transaction(function() error "no" end)
end))
print("rolled back", fake.rolled_back)
```

#### fake:unscoped()

Returns the instance. As on a real connection, it is there to be grepped for.

## Not here

`db.escape` does not exist, and neither does any quoting helper. Values travel
as parameters over the extended protocol, so there is nothing to escape. A
column name is not a value, and that is
[`sql.identifier`](sql.md#sqlidentifiername-allowed-what)'s job.

There is no `db.transaction(conn, fn)`. A transaction is closure scoped on the
connection, so there is no way to leave a `begin` open by forgetting a line.

There is no prepared statement cache. Parameters are bound over the extended
protocol on an unnamed statement, which is safe binding and is not the same
thing as a server-side plan cached between calls.

There is no reconnect. A connection that broke is discarded and the next call
to the factory opens a new one.

## See also
- [akkar](akkar.md) for `app:run { db = open }` and for `req.db`
- [akkar.sql](sql.md) builds the statements this module runs
- [akkar.scope](scope.md) is the handle `conn:scope` returns
- [akkar.pool](pool.md) is what `pool_size` creates
- [akkar.migrate](migrate.md) takes one of these connections and keeps it for a whole run
- the module source, `akkar/db.lua`, for the parameter types, the buffered reads and why the transaction commits a returned 4xx
