# 3. Reading input

By the end of this page your task list will answer three routes: ask for one
task by its id, filter the list, and create a new task. You will also have seen
what goes wrong when input is not checked, which is the reason the checking
exists.

Everything on this page runs in the `akkar` folder, in the file `app.lua`, the
same way as [page 2](02-your-first-route.md). Keep two terminals open: one
running the server, one for `curl`.

## Input arrives in three places

A request can carry information in three different spots, and they are not
interchangeable.

| Where | Looks like | Used for |
|---|---|---|
| The path | `/tasks/7` | which thing you mean |
| The query string | `/tasks?done=true` | options and filters |
| The body | attached to `POST`, `PUT`, `PATCH` | the data being sent |

The rest of this page is one section per spot.

---

## Part 1: the path

### A piece of the path you do not know in advance

You cannot write one route per task id. You write a route with a hole in it,
like `"/tasks/:id"`.

`:id` means "any single piece of path goes here, and call it `id`". A request
for `/tasks/7` matches, and `7` is the value.

Two new things appear. The handler now takes an argument, usually called `req`,
which is the request. And the captured piece is on `req.params`, under the name
you chose.

### The version that looks right and is wrong

This is the complete file. Try it before reading further.

```lua
local akkar = require "akkar"

local tasks = {
  { id = 1, title = "buy milk",       done = false },
  { id = 2, title = "read the guide", done = true  },
}

local function find_task(id)
  for _, task in ipairs(tasks) do
    if task.id == id then return task end
  end
end

local app = akkar.new()

app:get("/tasks/:id", function(req)
  return find_task(req.params.id)
end)

app:run { port = 3000 }
```

```sh
curl -i http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 204 No Content
x-request-id: 970f4cb2000002
content-length: 0

```

Task 1 exists. You asked for task 1. You got nothing.

**`204 No Content` is what akkar sends when a handler returns nothing.** That
is a real, deliberate status, and it is correct here: `find_task` found nothing
and returned nothing, so there is no content to send. The bug is not in akkar.
The bug is that `find_task` did not find task 1.

### Why it failed

**Everything in a URL is text.** There are no numbers in a path, only
characters. So `req.params.id` is the string `"1"`, not the number `1`.

And in Lua, `1 == "1"` is `false`. The number one and the text "one" are
different values. So the loop compared `1 == "1"` twice, got `false` twice, and
returned nothing.

Nothing crashed. No error appeared anywhere. The route simply told every caller
that no task exists. This is the whole reason for the next section.

### The version that works

One change. The route now declares what it expects.

```lua
local akkar = require "akkar"

local tasks = {
  { id = 1, title = "buy milk",       done = false },
  { id = 2, title = "read the guide", done = true  },
}

local function find_task(id)
  for _, task in ipairs(tasks) do
    if task.id == id then return task end
  end
end

local app = akkar.new()

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  return find_task(req.params.id)
end)

app:run { port = 3000 }
```

The new part is `{ params = { id = "integer" } }`, sitting between the path and
the handler. It says: this route has one path parameter, it is called `id`, and
it must be a whole number.

```sh
curl -i http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 200 OK
x-request-id: aa5a8a75000002
content-type: application/json
content-length: 40

{"id":1,"title":"buy milk","done":false}
```

akkar checked that `"1"` is a whole number, converted it to the number `1`, and
put that on `req.params.id`. The comparison now works because both sides are
numbers.

### And nonsense gets a real answer

```sh
curl -i http://127.0.0.1:3000/tasks/abc
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: aa5a8a75000003
content-type: application/json
content-length: 71

{"fields":{"params.id":"expected integer"},"error":"validation failed"}
```

`422` means: I understood the request, but the data in it is not acceptable.
The body names the exact field and the exact problem. `params.id` says which of
the three places it came from, so a client sending both a bad path and a bad
body can tell them apart.

**Your handler never ran.** akkar checked first. That is the point: a handler
with a schema can assume its input is already the right shape, so it does not
have to start with five lines of checking.

### One more, and it is not an error

```sh
curl -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 204 No Content
x-request-id: aa5a8a75000004
content-length: 0

```

`99` is a perfectly good whole number, so validation passed. There is just no
task with that id, so `find_task` returned nothing, so akkar sent `204`.

That is not what you want. Asking for a task that does not exist should be a
`404`, not "here is nothing". Fixing that is [page 4](04-errors.md).

---

## Part 2: the query string

Everything after `?` in a URL is the query string. It is a list of
`name=value` pairs joined by `&`:

```
/tasks?done=true
/tasks?done=true&sort=title
```

Use it for options: filters, sorting, page numbers. Things that change how you
answer, rather than what you are asking about.

akkar puts them on `req.query`, and they get a schema exactly like path
parameters do.

```lua
local akkar = require "akkar"

local tasks = {
  { id = 1, title = "buy milk",       done = false },
  { id = 2, title = "read the guide", done = true  },
}

local app = akkar.new()

app:get("/tasks", { query = { done = "boolean?" } }, function(req)
  if req.query.done == nil then
    return { tasks = tasks }
  end

  local matching = {}
  for _, task in ipairs(tasks) do
    if task.done == req.query.done then
      matching[#matching + 1] = task
    end
  end
  return { tasks = matching }
end)

app:run { port = 3000 }
```

**The `?` at the end of `"boolean?"` means optional.** Without it the field
would be required, and `/tasks` with no filter would be rejected. With it,
`req.query.done` is either a real boolean or `nil`, and `nil` here means "the
caller did not filter".

```sh
curl "http://127.0.0.1:3000/tasks"
```

```
{"tasks":[{"title":"buy milk","id":1,"done":false},{"title":"read the guide","id":2,"done":true}]}
```

```sh
curl "http://127.0.0.1:3000/tasks?done=true"
```

```
{"tasks":[{"title":"read the guide","id":2,"done":true}]}
```

```sh
curl "http://127.0.0.1:3000/tasks?done=false"
```

```
{"tasks":[{"title":"buy milk","id":1,"done":false}]}
```

Quote the URL in your shell. Without the quotes, `&` tells the shell to run the
command in the background, which is confusing and not what you meant.

Same as before, the query string is text. akkar turned `"true"` into the
boolean `true` because the schema said `boolean`. Send something that is not a
boolean and you get the same shape of answer as before:

```sh
curl -i "http://127.0.0.1:3000/tasks?done=yes"
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 396ea19e000005
content-type: application/json
content-length: 72

{"error":"validation failed","fields":{"query.done":"expected boolean"}}
```

---

## Part 3: the body

To create a task, the caller has to send the task. That goes in the body.

Here is `curl` sending one:

```sh
curl -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{"title":"buy milk"}'
```

Three flags, and all three are needed:

- `-X POST` sets the method. Without it `curl` sends `GET`.
- `-H "content-type: application/json"` tells the server the body is JSON.
  Without it the server does not know how to read the bytes.
- `-d '...'` is the body itself.

### First, without checking anything

```lua
local akkar = require "akkar"

local tasks = {}
local next_id = 1

local app = akkar.new()

app:post("/tasks", function(req)
  local task = { id = next_id, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  next_id = next_id + 1
  return akkar.created(task)
end)

app:run { port = 3000 }
```

`akkar.created(...)` sends status `201 Created` instead of `200 OK`. `201` is
the right answer to "I made a new thing", and it is the only new idea in that
file.

The good case works:

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{"title":"buy milk"}'
```

```
HTTP/1.1 201 Created
x-request-id: e9429509000002
content-type: application/json
content-length: 40

{"done":false,"title":"buy milk","id":1}
```

Now the two bad cases. These are the point of the page.

**A caller who forgets the title:**

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{}'
```

```
HTTP/1.1 201 Created
x-request-id: e9429509000003
content-type: application/json
content-length: 21

{"done":false,"id":2}
```

`201 Created`. Your server said "done, made it". It stored a task with no
title. Nobody was told anything was wrong. That row is now in your list
forever, and every piece of code that reads a task and expects a title is now
one step from crashing on it. This is the worst outcome on this page, because
nothing looks broken.

**A caller who sends no body at all:**

```sh
curl -i -X POST http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 500 Internal Server Error
x-request-id: 6e579814000002
content-type: application/json
content-length: 33

{"error":"internal server error"}
```

And in the server's terminal:

```
ERROR handler raised at=app.lua:8 detail=app.lua:9: attempt to index a nil value (field 'body') request_id=6e579814000002
```

With no body sent, `req.body` is `nil`, so `req.body.title` crashes. `500`
means the server broke. But the server did not break. **The caller sent a bad
request and the server took the blame for it.** That is the wrong status, and
page 4 is about why it matters.

### Now with the schema

```lua
local akkar = require "akkar"

local tasks = {}
local next_id = 1

local app = akkar.new()

app:post("/tasks", { body = { title = "string" } }, function(req)
  local task = { id = next_id, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  next_id = next_id + 1
  return akkar.created(task)
end)

app:run { port = 3000 }
```

Same three requests. The good one is unchanged:

```
HTTP/1.1 201 Created
x-request-id: 04c9ad53000002
content-type: application/json
content-length: 40

{"done":false,"title":"buy milk","id":1}
```

Missing title:

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 04c9ad53000003
content-type: application/json
content-length: 64

{"fields":{"body.title":"required"},"error":"validation failed"}
```

No body at all:

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 04c9ad53000004
content-type: application/json
content-length: 64

{"fields":{"body.title":"required"},"error":"validation failed"}
```

Wrong type:

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{"title": 42}'
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 04c9ad53000005
content-type: application/json
content-length: 71

{"fields":{"body.title":"expected string"},"error":"validation failed"}
```

No `500`. No silently broken task. The handler did not run in any of the three
bad cases, and the caller was told exactly which field was wrong.

### A second thing the schema does

Send fields the schema does not mention:

```sh
curl -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" \
  -d '{"title":"buy milk","done":true,"id":999}'
```

The handler sees only this:

```
{"title":"buy milk"}
```

**Fields you did not declare are removed before your handler runs.** A caller
cannot set `id`, and cannot mark a task done at creation, because those never
reach your code. You did not write a line to prevent it. Declaring what you
accept is the same act as rejecting what you do not.

---

## The schema types you have now

A schema is a plain table. The name is the field, the value is the rule. (This
block is marked `no-run` because it is a value on its own, not a whole file.)

```lua no-run
{ title = "string", count = "integer", ratio = "number",
  done = "boolean", extra = "table" }
```

Five type names: `string`, `integer`, `number`, `boolean`, `table`. Add `?` to
the end of any of them to make the field optional: `"string?"`.

Rules can be stricter than a type. Instead of a name, use `akkar.v`:

```lua
local akkar = require "akkar"
local v = akkar.v

local app = akkar.new()

app:post("/tasks", {
  body = {
    title    = v.string { min = 1, max = 100 },
    priority = v.string { optional = true, one_of = { "low", "high" } },
  },
}, function(req)
  return akkar.created { title = req.body.title, priority = req.body.priority }
end)

app:run { port = 3000 }
```

`v.string { min = 1, max = 100 }` is a title between 1 and 100 characters.
`one_of` limits a string to a fixed list. `v.integer { min = 1 }` does the same
for numbers. `"string?"` is just shorthand for `v.string { optional = true }`.

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"x","priority":"urgent"}'
```

```
{"error":"validation failed","fields":{"body.priority":"must be one of: low, high"}}
```

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":""}'
```

```
{"error":"validation failed","fields":{"body.title":"min length 1"}}
```

The message says what the rule was, not just that a rule was broken. A caller
can act on that without reading your source.

---

## The whole application

Everything from this page in one file:

```lua
local akkar = require "akkar"

local tasks = {
  { id = 1, title = "buy milk",       done = false },
  { id = 2, title = "read the guide", done = true  },
}
local next_id = 3

local function find_task(id)
  for _, task in ipairs(tasks) do
    if task.id == id then return task end
  end
end

local app = akkar.new()

app:get("/tasks", { query = { done = "boolean?" } }, function(req)
  if req.query.done == nil then
    return { tasks = tasks }
  end

  local matching = {}
  for _, task in ipairs(tasks) do
    if task.done == req.query.done then
      matching[#matching + 1] = task
    end
  end
  return { tasks = matching }
end)

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  return find_task(req.params.id)
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  local task = { id = next_id, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  next_id = next_id + 1
  return akkar.created(task)
end)

app:run { port = 3000 }
```

Four commands against it, in order:

```sh
curl -s http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"done":false,"title":"buy milk"},{"id":2,"done":true,"title":"read the guide"}]}
```

```sh
curl -s -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"walk the dog"}'
```

```
{"id":3,"done":false,"title":"walk the dog"}
```

```sh
curl -s http://127.0.0.1:3000/tasks/3
```

```
{"id":3,"done":false,"title":"walk the dog"}
```

```sh
curl -s "http://127.0.0.1:3000/tasks?done=false"
```

```
{"tasks":[{"id":1,"done":false,"title":"buy milk"},{"id":3,"done":false,"title":"walk the dog"}]}
```

The new task disappears when you stop the server, because the list lives in a
Lua variable. A database comes later in the guide.

## Checkpoint

You have this if:

- `curl http://127.0.0.1:3000/tasks/1` returns task 1, not `204`
- `curl http://127.0.0.1:3000/tasks/abc` returns `422` naming `params.id`
- `curl -X POST .../tasks -H "content-type: application/json" -d '{}'` returns
  `422` naming `body.title`, and creates nothing

And you can say why validation is not optional in one sentence: without it,
bad input either crashes the handler as a `500` or gets stored as if it were
fine, and the second one is worse.

One thing on this page is still wrong and was promised a fix: asking for
`/tasks/99`, a task that does not exist, answers `204 No Content` instead of
`404 Not Found`. That, and the whole question of whose fault an error is, is
next: [4. Errors that are not crashes](04-errors.md).
