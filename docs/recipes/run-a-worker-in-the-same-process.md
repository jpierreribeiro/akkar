# Run a worker in the same process

Answers the request straight away and does the slow part afterwards, in the
same process, with no Redis and no second terminal.

## The whole file

```lua
local akkar   = require "akkar"
local cqueues = require "cqueues"
local logging = require "akkar.log"
local memory  = require "akkar.jobs.memory"

local log   = logging.new()
local queue = memory.new "emails"

local app = akkar.new()

app:post("/signup", { body = { email = "string" } }, function(req)
  queue:push("welcome", { to = req.body.email })
  return akkar.created { queued = true }
end)

app:get("/queue", function() return { depth = queue:depth() } end)

app:task("emails", function(task)
  while not task.stopping() do
    -- Drains whatever is waiting, then returns. `consume` does not sleep, so
    -- the poll below is what gives the server its turn.
    queue:consume({
      welcome = function(payload)
        log:info("welcome email sent", { to = payload.to })
      end,
    }, {
      timeout = 0,
      should_stop = function() return task.stopping() or queue:depth() == 0 end,
      log = log,
    })

    cqueues.poll(0.05)
  end
end)

app:run { port = 3000, log = log }
```

`app:task(name, fn)` runs a function in the server's own event loop for the
life of the process. akkar supervises it: a task that raises is logged and
restarted with a backoff, and a task is asked to finish after the server has
drained, so work queued by the last request still gets consumed.

## Try it

```sh
lua5.4 app.lua
```

In a second terminal:

```sh
curl -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com"}'
curl http://127.0.0.1:3000/queue
```

```
{"queued":true}
{"depth":0}
```

The signup answered immediately, and the first terminal shows the work being
done after it:

```
INFO  listening url=http://127.0.0.1:3000
INFO  task started task=emails
INFO  welcome email sent to=grace@example.com
```

## Why the loop and the poll, rather than `consume` on its own

One Lua state runs one coroutine at a time and switches only when something
yields. The in-memory store never blocks, so `queue:consume` with no work to
do is a loop that never yields: the process goes to 100% of a core and the
server stops answering entirely, which is the failure this shape avoids. The
poll is what hands control back. That also says what a task is for. It is for
work that waits, such as a queue, a timer or a poll. Work that burns CPU
still belongs in another process, because while it runs nothing else in this
one does. Once there is more than one process, swap the in-memory queue for
`akkar.jobs.redis` so the work is shared instead of duplicated:
[page 10](../guide/10-background-work.md) of the guide covers that queue.
