# Paginate a list

One page of rows, plus a cursor the caller sends back to get the next page.

You need the `tasks` table from [page 5](../guide/05-a-database.md) of the
guide.

## The whole file

```lua
local akkar = require "akkar"
local db    = require "akkar.db"
local sql   = require "akkar.sql"
local v     = akkar.v

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

local app = akkar.new()

app:get("/tasks", {
  query = {
    after = "integer?",
    limit = v.integer { min = 1, max = 100, default = 20 },
  },
}, function(req)
  local size = math.tointeger(req.query.limit)

  -- One row more than the page, so the answer knows if there is a next one.
  local query = sql.select "id, title, done"
    :from("tasks", { "tasks" })
    :order_by("id", { "id" }, "asc")
    :limit(size + 1)

  if req.query.after then query:where("id > ?", req.query.after) end

  local rows = req.db:many(query)

  local next_after = nil
  if #rows > size then
    rows[size + 1] = nil
    next_after = rows[size].id
  end

  return { tasks = akkar.array(rows), next_after = next_after }
end)

app:run { port = 3000, db = open }
```

## Try it

```sh
lua5.4 app.lua
```

In a second terminal:

```sh
curl "http://127.0.0.1:3000/tasks?limit=2"
```

```
{"tasks":[{"title":"buy milk","id":8,"done":false},{"title":"call the bank","id":9,"done":false}],"next_after":9}
```

Your ids will be different numbers. Send `next_after` back as `after` to get
the page after that one:

```sh
curl "http://127.0.0.1:3000/tasks?limit=2&after=9"
```

```
{"tasks":[{"title":"read the guide","id":10,"done":false},{"title":"buy a birthday card","id":11,"done":false}],"next_after":11}
```

The last page has no `next_after` field at all. That is how the caller knows
to stop.

The cursor is the last id on the page, so it must be the column you order by.
Ordering by anything else needs that column in the cursor too, and a tiebreak
on `id` after it, or rows with equal values are skipped or repeated.

## Why a cursor and not an offset

`offset 10000` makes Postgres read and throw away ten thousand rows before it
returns anything, so page 500 is much slower than page 1 and gets slower as
the table grows. `where id > ?` reads the index straight to the position and
returns the same number of rows whatever page it is, so the cost stays flat.
A cursor also survives writes: a row inserted while a caller is paging shifts
every later offset by one, which shows the same row twice or skips one, and
a cursor never does. The trade is that a caller cannot jump to page 500
without walking there.
