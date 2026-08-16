# Why all I/O goes through an adapter akkar owns

A handler never calls `require "pgmoon"`. It receives `req.db` and calls four
methods on it.

```lua no-run
db:one(sql, ...)                  -- first row, or nil
db:many(sql, ...)                 -- array of rows, possibly empty
db:exec(sql, ...)                 -- no rows expected
db:transaction(function(tx) end)  -- commit at the end, rollback on any error
```

That is the whole database contract. It is four functions, and the size is the
argument: a contract small enough to implement by hand is a contract a test can
implement by hand.

For most of this project's life that was a principle. It stopped being one, and
the rest of this page is about what replaced it.

## The claim, and the day it became a measurement

`docs/PLAN.md` has always said that swapping the driver rewrites
`akkar/db.lua` and nothing else. `akkar/db.lua` says the same thing in its
first ten lines:

> This file exists to enforce the framework's one architectural rule:
> a handler never calls `require "pgmoon"`.

An assertion like that is easy to make and hard to believe, because nobody had
ever done the swap.

Then a second driver arrived. `akkar/pq.lua` is libpq with the waiting done in
Lua: `src/akkar_pq.c` speaks the protocol and never waits, `akkar/pq.lua` waits
with `cqueues.poll` and never speaks to libpq. And `spec/db_spec.lua` now runs
**one contract against both drivers**:

```lua no-run
local DRIVERS = { "pgmoon" }
if pcall(require, "akkar.pq_native") and reachable "pq" then
  DRIVERS[#DRIVERS + 1] = "pq"
end

for _, DRIVER in ipairs(DRIVERS) do
  -- the entire suite, unchanged, for each one
end
```

Twenty-two tests over parameter binding, parameter typing, buffered reads,
`statement_timeout` and the boot-time warning, run once per driver present. The
spec says why in its own comment:

> Until there were two drivers that was an assertion; running one suite against
> both is what turns it into a check.

Choosing a driver is now one key in one table:

```lua no-run
local pool = db.connect { host = "127.0.0.1", port = 5432, driver = "pq" }
```

pgmoon stays the default. A driver earns promotion by answering the contract,
not by being newer.

## What the boundary bought, in microseconds

The second driver is also the first chance to say what the boundary is worth,
and the honest answer is "it depends entirely on the query".

`bench/driver/RESULTS.md` measures both drivers against a floor:
`bench/driver/floor.c` is the same query through blocking `PQexecParams` in a
tight C loop, no Lua at all. Whatever that costs is Postgres plus libpq, and
everything above it belongs to akkar.

```
                        1 row        1000 rows
floor (libpq in C)     165.99 us       996.70 us
akkar.pq               200.96 us      1639.70 us
pgmoon                 219.63 us      4931.94 us
```

Subtract the floor and you get the only figure that measures a driver:

| | driver cost, 1 row | driver cost, 1000 rows |
|---|---:|---:|
| pgmoon | 53.6 us | 3,935 us |
| akkar.pq | 35.0 us | 643 us |
| reduction | 1.53x | **6.1x** |

That is a laptop with Postgres in a container, not the benchmark machine, and
the page says so at the top. What travels is the shape.

**The uncomfortable part, which the benchmark page states before its own
headline.** At one row the difference does not clear the noise gate, and
`/users/:id` is a one row query. It is the route in the comparison study, in
the saturation sweep and in the soak. So the C driver **will not move the
headline throughput**, and anyone expecting that route to approach Gin because
the driver changed is going to be disappointed. What moves is list endpoints,
and tail latency under load, and the second of those is not yet measured.

Read that page's own version of this sentence with care: it is written against
akkar at 2,744 req/s and Gin at 26,212, which are figures from
`bench/compare/RESULTS.md`, a page since retracted. The current measurement of
the same route is in `bench/study/RESULTS.md`: akkar 7,321.95 req/s against
Gin's 26,358.92. The conclusion is unchanged, because it rests on the crossover
between 1 and 10 rows and not on the ratio.

### The correction that came with it

The first run of that benchmark was taken on a machine with **twenty two
spinning processes on it**, left behind by a test that deliberately wedges a
lua-http server and cleaned up on its last line, so a failing assertion skipped
the cleanup. Load average 23. Nothing in the benchmark could detect it: it ran,
it produced a consistent curve, and every figure was wrong.

Re-measured quiet, the speedup at 1000 rows fell from 3.91x to **3.01x** and
the driver cost reduction from 7.3x to 6.1x. The contamination **inflated** the
advantage, because pgmoon does its work in the interpreter and loses more to
CPU contention than a driver that spends its time in libpq and the kernel.

A noisy machine flatters the thing being sold, which is the worst way for a
benchmark to be wrong. The numbers in the table above are the quiet ones.

## What else the boundary paid for

The driver swap is the newest evidence, not the only evidence.

**A wrong parameter type, fixed in one file, worth 43x on a query.** pgmoon
declares every Lua number as `numeric`. Comparing an `integer` column to a
`numeric` parameter is a cross-type comparison Postgres cannot answer from the
index, so it casts the column on every row. Measured on a 10,000 row table
(`akkar/db.lua`):

```
$1 numeric   Seq Scan,   Rows Removed by Filter: 10001,  3.287 ms
$1 bigint    Index Scan, Index Cond: (id = '42'::bigint), 0.153 ms
```

End to end, `docs/PERFORMANCE-STUDY.md` certifies that fix at **3.91x** on the
database route. Every handler in every application got it without changing a
line, because no handler names a type.

**Reaching into a dependency, in the one place that is allowed to.** pgmoon
asks the socket for five bytes and then a body, once per protocol message, and
Postgres sends one message per row: 2,006 Lua level calls for a thousand rows.
Serving those from one large read is certified at **1.05x throughput and p99
down 20%**, 106.16 ms to 84.91 ms on a 200 row query. `docs/PERFORMANCE-STUDY.md`
notes that this "is the only place akkar reaches into a dependency's internals,
so it lives in the file whose whole job is isolating pgmoon", with an off
switch that needs no fork.

**Surviving a defect in the substrate.** `docs/substrate/lua-http-wedge.md`
documents a request with `Content-Length: banana` that leaves lua-http alive,
listening, spinning, and answering nobody, for ever. Every port based liveness
check calls that server healthy. The page originally ended "it is not akkar's
to fix"; that has been corrected, because it was true of *reporting* the bug
and false of *surviving* it. `akkar/substrate.lua` carries the repair and
`spec/substrate_repair_spec.lua` proves it by starting a server without it and
requiring that one to die.

You can only repair a dependency you have wrapped.

## Writing your own adapter

There is no registry and no base class. If it has the four methods, it is a
database.

```lua
local akkar = require "akkar"

-- The whole database contract, by hand.
local my_own_adapter = {
  one = function(_, _, id) return { id = tonumber(id), name = "ada" } end,
  many = function() return {} end,
  exec = function() return 0 end,
  transaction = function(self, fn) return fn(self) end,
}

local app = akkar.new()
app:get("/users/:id", function(req)
  return req.db:one("select id, name from users where id = $1", req.params.id)
end)

print(app:test { db = my_own_adapter }:get("/users/1").status)   --> 200
```

akkar checks the contract once at startup, so a misconfigured adapter fails at
boot rather than on the first request that happens to touch it.

## The rule is narrower than it used to be

The README once said "all I/O goes through adapters the framework owns", and
`docs/DECISIONS.md` section 8 records why that was walked back. Owning
implementations for Postgres, Redis, S3, SMTP and queues "would make akkar the
ecosystem's bottleneck, and there is no version of that this project can
staff". The rule that survived is:

> **akkar owns the contract. Libraries implement it.**

`akkar.db` is the reference implementation for Postgres, not the only permitted
one.

Sometimes writing it is still the right call, and that needs a reason rather
than a preference. `akkar.redis` exists because **no non-blocking Redis client
exists for Lua 5.4 on cqueues**: every `lua-resty-*` needs OpenResty cosockets,
`lua-hiredis` blocks, and `lredis` is not packaged for 5.4. A blocking client
passes every functional test and stalls the event loop on every command. RESP2
was small enough that writing it cost less than the risk, and the proof it
works is not that `GET` returns a value, it is that eight concurrent one second
`BLPOP` calls through a pool of four finish in 2.07 s.

## What it costs

### The capability set has to stay closed, and it has moved

`req` carries request data and capabilities in one flat table. The known hazard
is that `req` becomes a service locator, accumulating `req.mailer`,
`req.payments`, `req.storage`, until it is a global by another name. What
prevents that is an admission rule, enforced in code:

> A capability is infrastructure the framework knows how to inject, guard and
> fake. Anything belonging to the application does not qualify.

`app:run{}` rejects unknown keys and names the nearest match, so `timout = 5`
is an error rather than a server running with a 30 second deadline its author
believed was 5.

The honest note: the set is described as `db`, `cache`, `log`, `clock` in both
`README.md` and `docs/DECISIONS.md`, and `akkar/init.lua` now reads
`db, cache, log, clock, http`. The set was widened deliberately for the
outbound path and the older pages have not caught up. A closed set that grows
is still closed if each addition is argued; it is not closed if the
documentation stops tracking it.

### The fake must not become a second implementation

`akkar.db.memory` matches programmed queries and **does not parse SQL**,
because a fake SQL engine would be a second database whose disagreements show
up as tests that pass and production that does not. The cache fake is different:
it is a real implementation with expiry, and small deployments can ship it.
Knowing which kind you have is on you.

### Boot time coupling

Because contracts are checked at startup, **the server refuses to start when
the database is unreachable**. That is right for a service whose every route
needs it and wrong for one that should come up degraded, so
`app:run { check_capabilities = false }` opts out.

### One more indirection between you and the driver

Every feature of pgmoon that is not in the four methods is not reachable from a
handler. That is the point, and it is also occasionally annoying. The cache
contract keeps an explicit escape hatch, `cache:command(name, ...)`; the
database contract does not have one, and raw SQL through `:one` is as close as
it gets.

## What to read next

- `bench/driver/RESULTS.md` for the driver numbers and the contamination story.
- `docs/PERFORMANCE-STUDY.md` for the parameter typing and buffered read
  certifications.
- `docs/DECISIONS.md` sections 5, 7 and 8.
