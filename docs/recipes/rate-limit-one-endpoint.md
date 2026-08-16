# Rate limit one endpoint

Puts a limit on one expensive path and leaves every other path alone.

You need Redis:

```sh
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine
```

## The whole file

```lua
local akkar = require "akkar"
local redis = require "akkar.redis"

local app = akkar.new()

-- The limiter is middleware, and middleware runs for every request. This gate
-- is what makes it apply to one path and nothing else.
local search_limit = akkar.limit.rate { per_second = 1, burst = 5 }

app:use(function(req, next)
  if req.path ~= "/search" then return next(req) end
  return search_limit(req, next)
end)

app:get("/search", function(req)
  return { query = req.query.q, results = akkar.empty_array }
end)

app:get("/health", function() return { ok = true } end)

app:run {
  port = 3000,
  cache = redis.connect { host = "127.0.0.1", port = 6379 },
}
```

`per_second` is how fast the allowance refills and `burst` is how much of it
one caller may spend at once. The limiter counts per caller: per account when
authentication middleware has set `req.user`, and per IP address otherwise.

## Try it

```sh
lua5.4 app.lua
```

In a second terminal, the first request:

```sh
curl -i "http://127.0.0.1:3000/search?q=milk"
```

```
HTTP/1.1 200 OK
ratelimit-limit: 5
ratelimit-remaining: 4
ratelimit-reset: 1
x-request-id: 90ed2034000001
content-type: application/json
content-length: 29

{"results":[],"query":"milk"}
```

Run it six times inside one second and the sixth is refused:

```
HTTP/1.1 429 Too Many Requests
ratelimit-reset: 5
ratelimit-limit: 5
ratelimit-remaining: 0
retry-after: 1
x-request-id: 90ed2034000007
content-type: application/json
content-length: 45

{"retry_after":1,"error":"too many requests"}
```

`/health` still answers however many times you ask, because the gate sent it
straight past the limiter.

## Why a gate and not the route's `before` list

A route can take its own middleware list, and `app:get("/search", { before =
{ search_limit } }, handler)` looks like the tidier spelling. It has one
sharp edge: middleware in a `before` list sees exactly what the handler
returned, and the limiter adds its headers by copying a response, so a
handler that returns a plain table gets copied into a response with no status
and the caller receives an empty 503. Route middleware there has to return
`akkar.ok { ... }` rather than `{ ... }`. The gate above has no such rule,
which is why it is the one written here. For the argument about limits in
general, and the difference between counting per second and counting in
flight, see [page 11](../guide/11-not-falling-over.md) of the guide.
