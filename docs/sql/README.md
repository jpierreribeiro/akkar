# SQL and migrations, taught slowly

This is a tutorial. It teaches you every part of `akkar.sql` and
`akkar.migrate`, one idea at a time, with the SQL that comes out shown next to
the Lua that made it.

It is not the reference. [`docs/reference/sql.md`](../reference/sql.md) and
[`docs/reference/migrate.md`](../reference/migrate.md) list every function with
its arguments and its return value, in alphabetical order, for somebody who
already knows what they are looking for. This track is for somebody who does
not know yet.

## Before you start

You should have done [page 5](../guide/05-a-database.md) and
[page 6](../guide/06-storing-and-reading.md) of the beginner guide. They give
you a Postgres container, a `tasks` table, and the two ideas everything here
builds on: a value never goes into the text of a statement, and a migration is
a numbered file that runs once.

This track starts where those pages stop. It does not repeat them.

You need the same container running:

```sh
docker start akkar-pg
```

Every example on every page is a complete file. Copy it, run it with
`lua5.4 whatever.lua`, and it works. The examples that need a table make their
own, named with a `sqlguide_` prefix, and drop it again at the end, so nothing
you already have is touched.

## The pages

### Building a query

1. [The query object](01-the-query-object.md), and the three ways to look at it
2. [select and from](02-select-and-from.md)
3. [where, and the question mark](03-where.md)
4. [where_in, for a list](04-where-in.md)
5. [order_by, limit and offset](05-order-limit-offset.md)
6. [join](06-join.md)
7. [group_by](07-group-by.md)

### Changing rows

8. [insert_into](08-insert.md)
9. [update and set](09-update.md)
10. [delete_from](10-delete.md)
11. [Identifiers and allow-lists](11-identifiers-and-allow-lists.md), the
    security page

### Running what you built

12. [one, many and exec](12-running-a-query.md)
13. [transaction, and the trap in it](13-transactions.md)
14. [scope, so a query cannot cross tenants](14-scope.md)

### Migrations

15. [What a migration is](15-what-a-migration-is.md)
16. [Names, numbers and order](16-names-and-order.md)
17. [The ledger and the checksum](17-the-ledger-and-the-checksum.md)
18. [The lock](18-the-lock.md)
19. [Migrations as data](19-migrations-as-data.md)
20. [Running them on deploy](20-on-deploy.md)

## The short version, if you only read one screen

Values are bound. Identifiers are checked against a list you wrote. There is no
third option, and there is no escape hatch:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where("done = ?", false)            -- a value: bound
q:order_by("title", { "id", "title" }) -- an identifier: checked
q:limit(20)                            -- a value: bound

print(q:to_string())
```

```
select id, title from sqlguide_tasks where done = $1 order by title asc limit $2
```

Everything else on these pages is that sentence, in detail.
