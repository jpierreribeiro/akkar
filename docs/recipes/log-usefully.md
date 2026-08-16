# Log usefully

One line per request with fields a log search can filter on, and every line
carrying the request id that ties it to the others.

## The whole file

```lua
local akkar   = require "akkar"
local logging = require "akkar.log"
local time    = require "akkar.time"

local log = logging.new { level = "info", format = "json" }

local app = akkar.new()

-- One line per request, with the fields something can search on later.
app:use(function(req, next)
  local started = time.monotime()
  local res = next(req)
  req.log:info("request", {
    method = req.method,
    path   = req.path,
    status = res.status,
    ms     = math.floor((time.monotime() - started) * 1000),
  })
  return res
end)

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  if req.params.id ~= 1 then
    -- req.log already carries the request id, so this line and the one above
    -- can be found together.
    req.log:warn("task not found", { task_id = req.params.id })
    return akkar.not_found "no task with that id"
  end
  return { id = 1, title = "buy milk", done = false }
end)

app:run { port = 3000, log = log }
```

Passing `log` to `app:run{}` replaces akkar's own voice as well, so the whole
process writes one stream in one format. Inside a handler use `req.log`, which
akkar has already bound to the request id.

## Try it

```sh
lua5.4 app.lua
```

```sh
curl http://127.0.0.1:3000/tasks/1
curl http://127.0.0.1:3000/tasks/7
```

```
{"id":1,"done":false,"title":"buy milk"}
{"error":"no task with that id"}
```

The first terminal:

```
{"url":"http:\/\/127.0.0.1:3000","message":"listening","time":1786892056,"level":"info"}
{"request_id":"fb09c5ac000001","status":200,"method":"GET","ms":0,"path":"\/tasks\/1","message":"request","time":1786892058,"level":"info"}
{"request_id":"fb09c5ac000002","task_id":7,"message":"task not found","time":1786892058,"level":"warn"}
{"request_id":"fb09c5ac000002","status":404,"method":"GET","ms":0,"path":"\/tasks\/7","message":"request","time":1786892058,"level":"info"}
```

Two lines share `fb09c5ac000002`. That is one request, and the same id went
back to the caller in the `x-request-id` header, so a support message quoting
it finds both.

Drop `format = "json"` while developing and the same lines read as
`INFO  request method=GET ms=0 path=/tasks/1 request_id=... status=200`.

## Why fields and not sentences

`log:warn("task not found", { task_id = 7 })` and
`log:warn("task 7 not found")` read the same to a person and are completely
different to a machine. The first has a message that is identical for every
occurrence, so it can be counted, and a field that can be filtered, so one
customer's requests can be pulled out. The second is a string that has to be
matched with a pattern by whoever is on call. Log the identifiers you would
want to search by, never the values you would not want to read in a leaked
log file: a password, a token, a session cookie, a whole request body. If a
value is worth hiding, keep it out rather than trusting a redactor.
