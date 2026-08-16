# Cache an expensive query

Computes an answer once, keeps it for a minute, and serves every caller in
that minute from memory instead of from the database.

You need the `tasks` table from [page 5](../guide/05-a-database.md) of the
guide, and Redis:

```sh
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine
```

## The whole file

```lua
local akkar = require "akkar"
local db    = require "akkar.db"
local redis = require "akkar.redis"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

local KEY = "stats:tasks"
local TTL = 60

local app = akkar.new()

app:get("/stats", function(req)
  local cached = req.cache:get(KEY)
  if cached then return akkar.json.decode(cached) end

  local row = req.db:one [[
    select count(*)::int                          as total,
           count(*) filter (where done)::int      as done
    from tasks
  ]]

  req.cache:set(KEY, akkar.json.encode(row), TTL)
  req.log:info("stats computed", { ttl_s = TTL })
  return row
end)

app:run {
  port = 3000,
  db = open,
  cache = redis.connect { host = "127.0.0.1", port = 6379 },
}
```

The cache stores strings, so the row goes in as JSON and comes back out with
`akkar.json.decode`. The third argument to `set` is the time to live in
seconds. After it, the key is gone and the next caller pays for the query.

## Try it

```sh
lua5.4 app.lua
```

In a second terminal, ask twice:

```sh
curl http://127.0.0.1:3000/stats
curl http://127.0.0.1:3000/stats
```

```
{"total":5,"done":0}
{"total":5,"done":0}
```

Two identical answers, and in the first terminal one line:

```
INFO  listening url=http://127.0.0.1:3000
INFO  stats computed request_id=ab82d0de000001 ttl_s=60
```

The query ran once. The second request never reached the database.

## Why a time to live and not invalidation on write

Deleting the key whenever the underlying rows change is more exact and much
harder to keep right: every write anywhere in the application has to remember
every key it affects, and the one that forgets serves a wrong answer for ever.
A time to live is wrong for at most `TTL` seconds and then repairs itself
without anyone remembering anything, which is the correct trade for a
dashboard number and the wrong one for a bank balance. Add
`req.cache:del(KEY)` on the writes you do control if you want both. Use Redis
rather than `akkar.cache.memory` for this once there is more than one process:
memory caching is per process, so with four workers you get four copies and
four times the misses.
