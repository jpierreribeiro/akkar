# Serve a frontend from the same server

Serves the HTML, CSS and JavaScript from the same akkar process that answers
the API, so there is one origin, one port and no CORS.

Put your built frontend in a `web` directory next to `app.lua`. The smallest
one that proves it works:

```html
<!doctype html>
<meta charset="utf-8">
<title>Tasks</title>
<h1>Tasks</h1>
<ul id="tasks"></ul>
<script>
  fetch("/api/tasks")
    .then(function (r) { return r.json() })
    .then(function (data) {
      document.getElementById("tasks").innerHTML =
        data.tasks.map(function (t) { return "<li>" + t.title + "</li>" }).join("")
    })
</script>
```

## The whole file

```lua
local akkar  = require "akkar"
local static = require "akkar.static"

local ROOT = "web"

local function shell()
  local file = io.open(ROOT .. "/index.html", "rb")
  if not file then return akkar.not_found "no frontend was built" end
  local html = file:read "a"
  file:close()
  return akkar.raw(html, "text/html; charset=utf-8")
end

local app = akkar.new()

-- Last resort. A GET that matched no file and no route is the app shell, so
-- reloading a deep link such as /tasks/42 in the browser still works. Paths
-- under /api are left alone, because an unknown API path is a real 404.
app:use(function(req, next)
  local res = next(req)
  if res.status == 404 and req.method == "GET" and not req.path:find "^/api/" then
    return shell()
  end
  return res
end)

-- Serves web/ for any path it has a file for, and passes everything else on.
app:use(static.new {
  root = ROOT,
  index = "index.html",
  max_age = 3600,
  fallthrough = true,
})

app:get("/api/tasks", function()
  return { tasks = akkar.array { { id = 1, title = "buy milk", done = false } } }
end)

app:run { port = 3000 }
```

Middleware runs in the order it is registered and unwinds in reverse, so the
shell middleware is added first and sees the answer everything else produced.
`fallthrough = true` is what lets a path the file server has no file for reach
the router instead of getting a 404 there.

## Try it

```sh
lua5.4 app.lua
```

Then open `http://127.0.0.1:3000/` in a browser. From the command line:

```sh
curl -i http://127.0.0.1:3000/
```

```
HTTP/1.1 200 OK
accept-ranges: bytes
etag: "6a81ce45-15f"
x-content-type-options: nosniff
last-modified: Sun, 16 Aug 2026 14:50:45 GMT
cache-control: public, max-age=3600
x-request-id: f9f99982000001
content-type: text/html; charset=utf-8
content-length: 351
```

The API is on the same origin:

```sh
curl http://127.0.0.1:3000/api/tasks
```

```
{"tasks":[{"title":"buy milk","done":false,"id":1}]}
```

A deep link the frontend routes itself gets the shell:

```sh
curl -i http://127.0.0.1:3000/tasks/42
```

```
HTTP/1.1 200 OK
x-request-id: f9f99982000003
content-type: text/html; charset=utf-8
content-length: 351
```

An unknown API path is still a 404, which is what an API client needs:

```sh
curl http://127.0.0.1:3000/api/nope
```

```
{"error":"no route for GET \/api\/nope"}
```

## Why one origin is worth the middleware

Serving the frontend from somewhere else makes every call cross-origin, and
then cookies need `SameSite`, `credentials`, an `Access-Control-Allow-Origin`
that cannot be `*`, and a preflight on anything that is not a plain GET. One
origin removes all of it, and the cost is the two pieces of middleware above.
akkar sets `etag` and `last-modified` on every file, so a reload after the
first one costs a 304 and no body. Keep `max_age` low, or zero, for
`index.html` if your build puts hashes in asset filenames, or a browser will
hold on to the old shell. If the frontend does live somewhere else,
[page 9](../guide/09-a-frontend.md) of the guide covers the CORS side.
