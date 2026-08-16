# 4. Errors that are not crashes

By the end of this page your task list will answer correctly when something
goes wrong: `404` for a task that does not exist, `400` for a request that
breaks a rule, and `500` only when the fault is genuinely yours.

Same setup as before: `app.lua` in the `akkar` folder, one terminal running the
server, one for `curl`. See [page 2](02-your-first-route.md) if you need it.

## One question decides the status code

Whose fault is it?

- **The caller's fault** gets a status starting with `4`. The message is aimed
  at the caller, and it should be specific, because they can fix it.
- **Your fault** gets a status starting with `5`. The message is aimed at you,
  and the caller gets almost nothing, because there is nothing they can do.

That is the entire idea. Every status below is one of those two.

Getting it wrong is not cosmetic. A `5` means "I am broken", and a server that
reports `500` for normal bad input will page somebody at 3am for a caller who
typed a word wrong. A `4` means "you are wrong", and a server that reports
`400` for its own bug hides that bug forever, because nobody investigates a
client mistake.

## The ones akkar handles without you

You have already seen some of these. Here they are together. Unless a section
shows its own file, the output came from the finished application at the bottom
of this page, so you can run every one of these once you have that file.

**No route matches the path.** `404`.

```sh
curl -i http://127.0.0.1:3000/nope
```

```
HTTP/1.1 404 Not Found
x-request-id: fe230c25000005
content-type: application/json
content-length: 35

{"error":"no route for GET \/nope"}
```

**The path exists, the method does not.** `405`, and it says what would work.

```sh
curl -i -X PUT http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 405 Method Not Allowed
allow: DELETE, GET
x-request-id: fe230c25000004
content-type: application/json
content-length: 57

{"allowed":["DELETE","GET"],"error":"method not allowed"}
```

**The body is not valid JSON.** `400`.

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{oops}'
```

```
HTTP/1.1 400 Bad Request
x-request-id: fe230c25000001
content-type: application/json
content-length: 29

{"error":"invalid JSON body"}
```

**The body is a type the server does not read.** `415`, not `400`. The body may
be perfectly well formed and simply be something this server does not speak,
and `400` would blame the caller for the wrong thing.

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: text/plain" -d 'hello'
```

```
HTTP/1.1 415 Unsupported Media Type
x-request-id: fe230c25000002
content-type: application/json
content-length: 149

{"error":"unsupported content type 'text\/plain'; this endpoint reads application\/json, application\/x-www-form-urlencoded or multipart\/form-data"}
```

**The body is enormous.** `413`. akkar refuses it before reading it into
memory, so a caller cannot use a large upload to exhaust your server. The
default limit is 1 MB.

```sh
head -c 2000000 /dev/zero | tr '\0' 'a' > big.txt
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" --data-binary @big.txt
```

```
HTTP/1.1 413 Request Entity Too Large
x-request-id: fe230c25000003
content-type: application/json
content-length: 46

{"error":"request body exceeds 1048576 bytes"}
```

**Input does not match the schema.** `422`, with the failing fields named. That
was all of [page 3](03-reading-input.md).

**The request took too long.** `503`. Every request has a deadline, 30 seconds
by default. Here is one with the deadline set to 1 second and a handler that
takes 3:

```lua
local akkar   = require "akkar"
local cqueues = require "cqueues"

local app = akkar.new()

app:get("/slow", function()
  cqueues.sleep(3)
  return { done = true }
end)

app:run { port = 3000, timeout = 1 }
```

```sh
curl -i http://127.0.0.1:3000/slow
```

```
HTTP/1.1 503 Service Unavailable
x-request-id: 30e8581a000001
content-type: application/json
content-length: 37

{"error":"request deadline exceeded"}
```

And in the server's terminal:

```
WARN  request deadline exceeded method=GET path=/slow request_id=30e8581a000001 timeout_s=1
```

Seven behaviours, no code. You get them by using akkar.

## The 500 you cause, and what the caller is told

Here is a handler with a bug in it. It looks up a task and uses it without
checking that it was found.

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
  local task = find_task(req.params.id)
  return { id = task.id, title = task.title }
end)

app:run { port = 3000 }
```

Task 1 works:

```sh
curl -i http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 200 OK
x-request-id: 193d86bb000002
content-type: application/json
content-length: 27

{"id":1,"title":"buy milk"}
```

Task 99 does not:

```sh
curl -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 500 Internal Server Error
x-request-id: 193d86bb000003
content-type: application/json
content-length: 33

{"error":"internal server error"}
```

`find_task` returned nothing, so `task` was `nil`, so `task.id` crashed.

**Two things happened here and both are worth understanding.**

**First, the server did not die.** One handler raised an error and akkar
answered `500` for that one request. The process kept running and the next
request was served normally. A crash inside a handler is contained.

**Second, the caller was told nothing useful.** That is deliberate. Look at
what the server printed instead:

```
ERROR handler raised at=app.lua:16 detail=app.lua:18: attempt to index a nil value (local 'task') request_id=193d86bb000003
```

The real message, the file, and both line numbers: `app.lua:16` is where the
route is declared, `app.lua:18` is where it broke. None of that went to the
caller, because a Lua error message can contain file paths, internal variable
names, and sometimes fragments of SQL. Handing that to whoever sent the request
tells an attacker how your server is built.

The `request_id` is in both places. The caller has it in the
`x-request-id` header, you have it in the log. Someone can report "I got an
error, the id was 193d86bb000003" and you can find that exact request.

## Saying "not found" on purpose

The `500` above is not really about a missing nil check. **Asking for a task
that does not exist is a normal thing for a caller to do, and the right answer
is `404`.** The bug was answering it as a server failure.

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
  local task = find_task(req.params.id)
  if not task then
    return akkar.not_found "no task with that id"
  end
  return { id = task.id, title = task.title }
end)

app:run { port = 3000 }
```

```sh
curl -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 404 Not Found
x-request-id: 27532103000002
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

`akkar.not_found "..."` builds a response with status `404` and a body of
`{"error": "..."}`. You return it exactly the way you return a table, because
it is just another value. There is no separate "error path" to learn.

## The helpers, all of them

Each one takes an optional message and returns a response you can `return`.

| Helper | Status | Use it when |
|---|---|---|
| `akkar.ok(body)` | 200 | you want `200` with an explicit body |
| `akkar.created(body)` | 201 | you just created something |
| `akkar.no_content()` | 204 | it worked and there is nothing to send |
| `akkar.bad_request(msg)` | 400 | the request breaks a rule a schema cannot express |
| `akkar.unauthorized(msg)` | 401 | the caller has not proved who they are |
| `akkar.forbidden(msg)` | 403 | you know who they are and they may not do this |
| `akkar.not_found(msg)` | 404 | the thing they asked for does not exist |
| `akkar.conflict(msg)` | 409 | it clashes with something that already exists |
| `akkar.too_large(msg)` | 413 | what they sent is too big |
| `akkar.unavailable(msg)` | 503 | you cannot serve this right now |

For anything else, `akkar.response(status, body)` takes any status and any
body.

Returning `nil` from a handler is the same as `akkar.no_content()`. You saw
that on page 3, when `find_task` found nothing and the caller got `204`.

## 400 or 422?

They are close and the line is worth stating once.

**`422` is what akkar sends when the input does not match the schema.** Wrong
type, missing field, string too long. You never write it yourself.

**`400` is what you send when the input matches the schema and is still
wrong.** The rule is one a schema cannot express.

```lua
local akkar = require "akkar"

local app = akkar.new()

app:post("/tasks", { body = { title = "string" } }, function(req)
  if req.body.title:match "^%s*$" then
    return akkar.bad_request "title cannot be blank"
  end
  return akkar.created { id = 1, title = req.body.title, done = false }
end)

app:run { port = 3000 }
```

`"   "` is a string, so the schema is satisfied. akkar has no complaint. It is
still not a title, and only your code knows that:

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"   "}'
```

```
HTTP/1.1 400 Bad Request
x-request-id: da26a49f000001
content-type: application/json
content-length: 33

{"error":"title cannot be blank"}
```

Leave the title out entirely and the schema catches it first, so your `if`
never runs:

```sh
curl -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{}'
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: da26a49f000002
content-type: application/json
content-length: 64

{"error":"validation failed","fields":{"body.title":"required"}}
```

If you are unsure which to use, it barely matters. Both are `4`, both say "the
caller sent something wrong". What matters is that neither of them is `500`.

## Raising an error from deep in your code

Here is a problem you will hit as soon as your code has more than one layer.

`find_task` is the function that knows the task is missing. But `find_task` is
not a handler, so it cannot return a response. Today it returns `nil`, and
every single caller has to remember to check for `nil` and turn it into a
`404`. One that forgets produces the `500` from earlier.

akkar's answer: **a response works as a thrown error too.** The last line of
`find_task` is the only change in this file.

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
  error(akkar.not_found "no task with that id")
end

local app = akkar.new()

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  return find_task(req.params.id)
end)

app:run { port = 3000 }
```

`error(...)` is Lua's way of raising. Normally raising inside a handler gives
the caller a `500`, as you saw. But akkar checks what was raised first: if it
is one of its own responses, that response is sent as written.

```sh
curl -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 404 Not Found
x-request-id: 7c0c87ef000001
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

And the good case is untouched:

```sh
curl -i http://127.0.0.1:3000/tasks/1
```

```
HTTP/1.1 200 OK
x-request-id: 7c0c87ef000002
content-type: application/json
content-length: 40

{"done":false,"id":1,"title":"buy milk"}
```

The handler is one line and nothing in it checks for `nil`. Every handler that
calls `find_task` now gets the `404` for free, and forgetting to check is no
longer possible, because `find_task` never returns `nil`.

Use this sparingly. A returned response is easier to follow than a thrown one,
so throw only where returning would mean threading a value back through
functions that have no business knowing about HTTP.

## The whole application

Everything from pages 2, 3 and 4:

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
  error(akkar.not_found "no task with that id")
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
  if req.body.title:match "^%s*$" then
    return akkar.bad_request "title cannot be blank"
  end

  for _, task in ipairs(tasks) do
    if task.title == req.body.title then
      return akkar.conflict "a task with that title already exists"
    end
  end

  local task = { id = next_id, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  next_id = next_id + 1
  return akkar.created(task)
end)

app:delete("/tasks/:id", { params = { id = "integer" } }, function(req)
  local task = find_task(req.params.id)
  for i, candidate in ipairs(tasks) do
    if candidate.id == task.id then
      table.remove(tasks, i)
      break
    end
  end
  return nil
end)

app:run { port = 3000 }
```

Six answers from one server. Run them in this order.

**A task that does not exist:**

```sh
curl -s -i http://127.0.0.1:3000/tasks/99
```

```
HTTP/1.1 404 Not Found
x-request-id: 35851af7000001
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

**A title that is only spaces:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"   "}'
```

```
HTTP/1.1 400 Bad Request
x-request-id: 35851af7000002
content-type: application/json
content-length: 33

{"error":"title cannot be blank"}
```

**A title that already exists:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"buy milk"}'
```

```
HTTP/1.1 409 Conflict
x-request-id: 35851af7000003
content-type: application/json
content-length: 49

{"error":"a task with that title already exists"}
```

**A title that is fine:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"walk the dog"}'
```

```
HTTP/1.1 201 Created
x-request-id: 35851af7000004
content-type: application/json
content-length: 44

{"title":"walk the dog","id":3,"done":false}
```

**Deleting it:**

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/3
```

```
HTTP/1.1 204 No Content
x-request-id: 35851af7000005
content-length: 0

```

**Deleting it again:**

```sh
curl -s -i -X DELETE http://127.0.0.1:3000/tasks/3
```

```
HTTP/1.1 404 Not Found
x-request-id: 35851af7000006
content-type: application/json
content-length: 32

{"error":"no task with that id"}
```

Every one of those is a `4` or a `2`. Not one is a `500`, and that is the
measure of this page: **a `500` in your log should mean you have a bug to fix.**
If normal caller mistakes produce `500`, the log stops meaning anything and you
will stop reading it.

## Checkpoint

You have this if:

- `curl http://127.0.0.1:3000/tasks/99` returns `404`, not `204` and not `500`
- posting a blank title returns `400` with your message
- posting a duplicate title returns `409`
- you can say, for any status your server sends, whose fault it is

You now have a complete task list API that behaves correctly when things go
wrong. Everything it knows disappears when you stop the server, because the
tasks live in a Lua variable.

Next in the guide: a real database.
