# Test a route

Sends requests through your whole application, including validation and
middleware, without opening a socket or binding a port.

You need busted:

```sh
luarocks install --local busted
```

## The application

`app.lua`, which starts a server when you run it and hands back the
application when a spec asks for it:

```lua
local akkar = require "akkar"
local v     = akkar.v

local app = akkar.new()

local tasks = { { id = 1, title = "buy milk", done = false } }

app:get("/tasks", function()
  return { tasks = akkar.array(tasks) }
end)

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  for _, task in ipairs(tasks) do
    if task.id == req.params.id then return task end
  end
  return akkar.not_found "no task with that id"
end)

app:post("/tasks", { body = { title = v.string { min = 1 } } }, function(req)
  local task = { id = #tasks + 1, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  return akkar.created(task)
end)

-- Only start a server when this file is run directly. When a spec requires
-- it, it hands back the app instead.
if ... == nil then app:run { port = 3000 } end

return app
```

## The spec

`spec/tasks_spec.lua`. This block is marked `no-run` because busted runs it,
not `lua5.4`: `describe`, `it` and `assert.equal` come from busted.

```lua no-run
local app = require "app"

describe("the tasks API", function()
  -- No socket, no port, no server. The test client travels the same chain a
  -- real request does.
  local client = app:test()

  it("lists the tasks", function()
    local res = client:get "/tasks"
    assert.equal(200, res.status)
    assert.equal("buy milk", res.body.tasks[1].title)
  end)

  it("answers 404 for an id that is not there", function()
    local res = client:get "/tasks/999"
    assert.equal(404, res.status)
    assert.equal("no task with that id", res.body.error)
  end)

  it("refuses a task with no title", function()
    local res = client:post("/tasks", { body = {} })
    assert.equal(422, res.status)
    assert.equal("required", res.body.fields["body.title"])
  end)

  it("creates one", function()
    local res = client:post("/tasks", { body = { title = "walk the dog" } })
    assert.equal(201, res.status)
    assert.equal("walk the dog", res.body.title)
    assert.is_number(res.body.id)
  end)
end)
```

## Try it

From the directory holding `app.lua`:

```sh
busted spec/tasks_spec.lua
```

```
++++
4 successes / 0 failures / 0 errors / 0 pending : 0.149255 seconds
```

`app:test()` gives a client with `get`, `post`, `put`, `patch`, `delete`,
`head` and `options`. Each takes a path and an options table of `body`,
`headers` and `timeout`, and answers `{ status, body, raw, headers }`. The
body is already decoded, so `res.body.tasks[1].title` works without parsing
anything.

## Why in process and not over HTTP

The test client calls the same function the server calls, so validation,
middleware, response schemas and error handling all run exactly as they do in
production, and nothing is left untested but the socket. What you get for
that is speed and determinism: no port to be busy, no server to start and
stop, no sleep before the first request, and four cases in a seventh of a
second. One thing does not survive the trip: the content type is written to
the wire, not to the response, so `res.headers["content-type"]` is nil in a
test even though a real client would see it. Assert on `res.raw` for a
non-JSON body instead. To point the same routes at a database, see
[Test something that hits the database](test-with-the-database.md).
