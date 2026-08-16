# Return a CSV

Answers with a spreadsheet file instead of JSON, and makes the browser save it
under a name you choose.

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

-- A field that contains a comma, a quote or a newline has to be quoted, and a
-- quote inside it has to be doubled. Everything else goes out as it is.
local function cell(value)
  local text = tostring(value)
  if text:find '["\n\r,]' then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

local function csv(header, rows, columns)
  local lines = { table.concat(header, ",") }
  for _, row in ipairs(rows) do
    local out = {}
    for i, column in ipairs(columns) do out[i] = cell(row[column]) end
    lines[#lines + 1] = table.concat(out, ",")
  end
  return table.concat(lines, "\r\n") .. "\r\n"
end

local app = akkar.new()

app:get("/tasks.csv", function(req)
  local rows = req.db:many "select id, title, done from tasks order by id"

  local body = csv({ "id", "title", "done" }, rows, { "id", "title", "done" })

  local res = akkar.raw(body, "text/csv; charset=utf-8")
  res.headers = { ["content-disposition"] = 'attachment; filename="tasks.csv"' }
  return res
end)

app:run { port = 3000, db = open }
```

`akkar.raw(body, content_type)` is the answer for a response that is not JSON.
The body goes out exactly as given.

## Try it

```sh
lua5.4 app.lua
```

In a second terminal:

```sh
curl -i http://127.0.0.1:3000/tasks.csv
```

```
HTTP/1.1 200 OK
content-disposition: attachment; filename="tasks.csv"
x-request-id: 8dbcaf87000001
content-type: text/csv; charset=utf-8
content-length: 141

id,title,done
8,buy milk,false
9,call the bank,false
10,read the guide,false
11,buy a birthday card,false
12,buy a birthday card,false
```

## Why the escaping is worth the six lines

A CSV export is the one endpoint whose output is read by a program nobody
here wrote, and a title containing a comma turns one column into two for
every row after it. The `cell` function above is the whole rule: quote when
the value contains a comma, a quote or a newline, and double any quote
inside. Line endings are `\r\n` because that is what the format says and what
Excel expects. If the export is large enough that holding it in memory is a
problem, produce it as it is written instead: see
[Stream a large response](stream-a-large-response.md).
