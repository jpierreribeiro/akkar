# Stream a large response

Writes the answer out as it is produced, so an export of any size costs the
same memory as an export of one row.

You need the `tasks` table from [page 5](../guide/05-a-database.md) of the
guide.

## The whole file

```lua
local akkar = require "akkar"
local db    = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

local BATCH = 500

local app = akkar.new()

app:get("/tasks.ndjson", function(req)
  return akkar.stream(function(write)
    local after = 0
    while true do
      local rows = req.db:many(
        "select id, title, done from tasks where id > $1 order by id limit $2",
        after, BATCH)
      if #rows == 0 then break end

      for _, row in ipairs(rows) do
        write(akkar.json.encode(row) .. "\n")
      end
      after = rows[#rows].id
    end
  end, { content_type = "application/x-ndjson" })
end)

app:run { port = 3000, db = open }
```

The handler still returns a value. `akkar.stream` describes a body that is
produced on demand, and the loop reads the table in batches of 500, so the
process holds 500 rows at a time and not the whole table.

## Try it

```sh
lua5.4 app.lua
```

In a second terminal:

```sh
curl -i http://127.0.0.1:3000/tasks.ndjson
```

```
HTTP/1.1 200 OK
x-request-id: 3638d95d000001
content-type: application/x-ndjson
transfer-encoding: chunked
connection: transfer-encoding

{"done":false,"id":8,"title":"buy milk"}
{"done":false,"id":9,"title":"call the bank"}
{"done":false,"id":10,"title":"read the guide"}
{"done":false,"id":11,"title":"buy a birthday card"}
{"done":false,"id":12,"title":"buy a birthday card"}
```

There is no `content-length`, because the length is not known when the
headers go out. The response is chunked instead, which is what streaming means
on HTTP/1.1.

## Three things that change once you stream

The status goes out with the first byte, so a producer that fails halfway
cannot become a 500. akkar logs it and drops the connection, and the caller
sees a truncated response rather than a complete looking lie. Do every check
that can refuse the request before the first `write`, where returning a 404 or
a 400 still works. The database connection stays checked out until the last
byte is written, so a slow reader holds a pool slot for as long as it reads.
And the request deadline covers the handler, not the body, so a large export
is allowed to outlive it. Format one row per line rather than as one JSON
array when you can: the reader can then start work on row one without waiting
for the closing bracket.
