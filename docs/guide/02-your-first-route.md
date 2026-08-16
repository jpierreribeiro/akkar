# 2. Your first route

By the end of this page you will have a server running on your machine that
answers `GET /tasks` with a list of tasks in JSON.

You need akkar installed. If you have not done that yet, do steps 1 to 3 of the
[Quickstart](00-quickstart.md) first, then come back.

## The whole file

Create `app.lua` inside the `akkar` folder. This is the complete file. Nothing
is missing and nothing is abbreviated.

```lua
local akkar = require "akkar"

local app = akkar.new()

app:get("/tasks", function()
  return {
    tasks = {
      { id = 1, title = "buy milk",       done = false },
      { id = 2, title = "read the guide", done = true  },
    },
  }
end)

app:run { port = 3000 }
```

Run it:

```sh
lua5.4 app.lua
```

```
INFO  listening url=http://127.0.0.1:3000
```

Leave it running. In a **second terminal**:

```sh
curl http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"id":1,"title":"buy milk","done":false},{"id":2,"title":"read the guide","done":true}]}
```

That is a working backend. Six lines of it are yours.

## What each line does

**`local akkar = require "akkar"`**

Loads akkar and puts it in a variable called `akkar`. Every Lua file that uses
akkar starts with this line.

**`local app = akkar.new()`**

Creates one empty application. It has no routes yet, so right now it would
answer nothing.

**`app:get("/tasks", function() ... end)`**

Adds a route. Read it as a sentence: when a `GET` request arrives for the path
`/tasks`, run this function.

The function is written inline, between `function()` and `end`. It is not
called now. akkar stores it and calls it later, once per request that matches.

There is one of these for each method: `app:get`, `app:post`, `app:put`,
`app:patch`, `app:delete`.

**`return { ... }`**

The handler returns a Lua table. akkar turns that table into JSON and sends it
back with status `200 OK`.

This is the part that is different from most frameworks, and it is worth
noticing now. Your function does not write the response. It does not get handed
a connection. It returns a value, and akkar does the rest. That means you can
never accidentally answer the same request twice, because there is nothing to
call twice.

**`app:run { port = 3000 }`**

Opens the door and waits. This line never returns. Everything after it in the
file would never run.

## A little Lua, if you are new to it

A handful of Lua details show up all through this guide. Here they are once, so
no later page has to stop and explain them.

**`local x = ...`** declares a variable. Always write `local`. Without it the
variable is global, which on a server means it is shared between requests, and
one caller can see another caller's data.

**Tables are the only container Lua has.** `{ id = 1 }` is a table with a name
in it. `{ "a", "b" }` is a table with two values in order. They are the same
kind of thing, which is why one syntax covers both.

**`t[1]` is the first item, not `t[0]`.** Lua counts from 1.

**`#t` is how many items are in a list**, so `t[#t + 1] = x` adds one to the
end.

**`for _, item in ipairs(t) do ... end`** walks a list in order. `ipairs` gives
you the position and the value, and `_` is the ordinary name for "I do not need
this one".

**`app:get(...)` has a colon, `akkar.new()` has a dot.** The colon passes the
thing on the left into the function as a hidden first argument. You do not need
to think about it, only to type the right one, and this guide always shows
which.

**`nil` means "no value".** A name that was never set is `nil`, and using
`nil` as if it were a table is the most common Lua error you will see:
`attempt to index a nil value`.

## How the table became JSON

Lua tables come in two shapes, and JSON has a matching shape for each. The two
Lua blocks below are marked `no-run`, because they are values on their own and
not whole files. Every block in this guide marked `lua` and nothing else is a
complete file you can run.

A table with **names** becomes a JSON object with `{ }`:

```lua no-run
{ id = 1, title = "buy milk" }
```

```
{"id":1,"title":"buy milk"}
```

A table with **no names**, just values in order, becomes a JSON list with
`[ ]`:

```lua no-run
{ "buy milk", "walk the dog" }
```

```
["buy milk","walk the dog"]
```

The file above nests one inside the other. `tasks` is a name, and its value is
a list, and each item in the list is an object. That is why the output has
`{"tasks":[{...},{...}]}`.

**One thing that will confuse you if nobody says it:** the order of the fields
in the JSON is not fixed. You may get `{"id":1,"title":"buy milk"}` on one run
and `{"title":"buy milk","id":1}` on the next. Lua does not remember the order
you typed names in, so neither does the output. This is fine. JSON objects have
no order, and every JSON reader in the world treats those two as identical.
Never write code that depends on field order.

## The first two errors you will hit

Leave the server running and try these. They are worth seeing on purpose,
because you will hit them by accident later.

### Asking for a path that has no route

```sh
curl -i http://127.0.0.1:3000/task
```

`curl -i` shows the response headers as well as the body, which is how you see
the status code.

```
HTTP/1.1 404 Not Found
x-request-id: eaee221f000004
content-type: application/json
content-length: 35

{"error":"no route for GET \/task"}
```

`404` means the path does not exist here. Note the typo: the route is `/tasks`
and the request asked for `/task`. akkar tells you exactly which method and
path it could not match, which is usually enough to spot it.

(The `\/` is just JSON's way of writing `/`. It means the same thing.
`x-request-id` is an id akkar puts on every response so you can find that one
request in the logs later.)

### Using the wrong method

```sh
curl -i -X POST http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 405 Method Not Allowed
allow: GET
x-request-id: eaee221f000005
content-type: application/json
content-length: 48

{"allowed":["GET"],"error":"method not allowed"}
```

`405` is different from `404` and the difference is useful. `404` means the
path does not exist. `405` means the path exists but not with that method. The
`allow` header says which methods would have worked, so you can see that
`/tasks` accepts `GET` and nothing else. You wrote no code to produce this.
akkar knows what routes exist, so it can answer this itself.

### One more, because it is a real mistake

Change the handler to return a string instead of a table:

```lua
local akkar = require "akkar"

local app = akkar.new()

app:get("/tasks", function()
  return "buy milk"
end)

app:run { port = 3000 }
```

Stop the server with `Ctrl-C`, start it again, and call it:

```sh
curl -i http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 500 Internal Server Error
x-request-id: 80a40ab1000002
content-type: application/json
content-length: 33

{"error":"internal server error"}
```

The caller gets nothing useful, on purpose. Look at the terminal running the
server:

```
ERROR handler raised at=app.lua:5 detail=handler returned string; return a table, nil, or akkar.*() request_id=80a40ab1000002
```

There is the real message, with the line number of your route. A handler must
return a table, or `nil`, or one of akkar's response helpers. Page 4 covers
those helpers and explains why the detail stays in your log instead of going to
the caller.

Put the table version back before moving on.

## Checkpoint

You have this if:

- `lua5.4 app.lua` prints `listening url=http://127.0.0.1:3000` and stays
  running
- `curl http://127.0.0.1:3000/tasks` prints your two tasks as JSON
- `curl -i http://127.0.0.1:3000/task` gives you a `404`, and you know why

Right now the list is fixed. Every caller gets the same two tasks and there is
no way to ask for one of them. That is next:
[3. Reading input](03-reading-input.md).
