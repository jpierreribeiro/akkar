# Schedule a recurring job

Runs something every minute inside the server, and stops running it when the
server stops.

You need the `tasks` table from [page 5](../guide/05-a-database.md) of the
guide.

## The whole file

```lua
local akkar   = require "akkar"
local logging = require "akkar.log"
local db      = require "akkar.db"
local time    = require "akkar.time"

local log = logging.new()

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
  pool_size = 2,
}

local EVERY = 60

local app = akkar.new()

app:get("/health", function() return { ok = true } end)

app:task("task-report", function(task)
  while not task.stopping() do
    -- There is no `req` here, so the capability is taken and given back by
    -- hand. Not releasing it leaks a pool slot on every tick.
    local ok, why = pcall(function()
      local conn = open()
      local row = conn:one "select count(*)::int as total from tasks"
      conn:release()
      log:info("task report", { total = row.total })
    end)
    if not ok then log:error("task report failed", { detail = tostring(why) }) end

    -- Slept in slices, so a shutdown does not wait out the whole interval.
    local due = time.monotime() + EVERY
    while time.monotime() < due and not task.stopping() do
      time.sleep(0.5)
    end
  end
end)

app:handle_signals()
app:run { port = 3000, db = open, log = log }
```

The `pcall` matters. A tick that raises would end the task, and akkar would
restart it with a backoff, so a database that is down for a minute turns one
failing tick into a restart loop instead of one logged error.

## Try it

```sh
lua5.4 app.lua
```

The first tick runs at once and the next one a minute later:

```
INFO  listening url=http://127.0.0.1:3000
INFO  task started task=task-report
INFO  task report total=5
INFO  task report total=5
```

The server answers normally the whole time:

```sh
curl http://127.0.0.1:3000/health
```

```
{"ok":true}
```

Stop it with `Ctrl-C`, or send it a `SIGTERM` the way a container does, and
the timer is asked to finish rather than killed:

```
INFO  signal received
INFO  shutdown: no longer accepting connections
INFO  shutdown: asking tasks to finish tasks=1
INFO  shutdown: tasks finished
INFO  shutdown: stopped cleanly
```

## Why there is no cron in akkar

akkar has no scheduler, and the loop above is the whole of what one would
have been. That is a real decision rather than a gap: a timer inside the
server process runs once per process, so two processes means two runs a
minute and eight processes means eight, and any scheduler akkar shipped would
have to answer that question with a lock nobody asked for. Run this in one
process, or take the lock yourself, or leave the schedule to the thing that
already owns it, such as a cron entry or your platform's scheduler calling a
route. What akkar does give you is that the task lives and dies with the
server: it is asked to finish after the last request drains, and never
between one and the next.
