# See what is slow

Puts a duration on every route, and tells you when a handler is not slow but
stuck.

## The whole file

```lua
local akkar   = require "akkar"
local metrics = require "akkar.metrics"
local time    = require "akkar.time"

local registry = metrics.new()

local app = akkar.new()

app:use(registry:middleware())

app:get("/fast", function() return { ok = true } end)

app:get("/slow", function()
  time.sleep(0.3)                 -- waiting, the way a query or an API call waits
  return { ok = true }
end)

app:get("/blocking", function()
  local total = 0
  for i = 1, 20000000 do total = total + i end    -- computing, never yielding
  return { total = total }
end)

-- Adds GET /metrics, in the text format Prometheus scrapes.
registry:serve(app, "/metrics")

app:run { port = 3000 }
```

## Try it

```sh
lua5.4 app.lua
```

```sh
curl http://127.0.0.1:3000/fast
curl http://127.0.0.1:3000/slow
curl http://127.0.0.1:3000/blocking
curl http://127.0.0.1:3000/metrics
```

The counts and the total time, per route:

```
# HELP akkar_requests_total Requests handled, by method, route and status.
# TYPE akkar_requests_total counter
akkar_requests_total{method="GET",route="/blocking",status="200"} 1
akkar_requests_total{method="GET",route="/fast",status="200"} 1
akkar_requests_total{method="GET",route="/slow",status="200"} 1
akkar_request_duration_seconds_sum{method="GET",route="/blocking"} 0.834737
akkar_request_duration_seconds_count{method="GET",route="/blocking"} 1
akkar_request_duration_seconds_sum{method="GET",route="/fast"} 0.000032
akkar_request_duration_seconds_count{method="GET",route="/fast"} 1
akkar_request_duration_seconds_sum{method="GET",route="/slow"} 0.301739
akkar_request_duration_seconds_count{method="GET",route="/slow"} 1
```

The route label is the pattern, `/tasks/:id`, not the path, so a million ids
are one series and not a million.

`/metrics` also carries `akkar_request_duration_seconds_bucket`, which is
what a percentile is computed from, plus heap and resident memory and uptime.

While `/blocking` was running, the first terminal said this on its own:

```
WARN  handler blocked the event loop without yielding at=app.lua:18 blocked_ms=101 hint=this stalls every request in this process traceback=
```

followed by a traceback naming the loop.

## Why two different signals

The histogram says a route is slow. The watchdog says something worse: that
a handler spent 100 ms of uninterrupted CPU without yielding, which in one
Lua process means every other request waited exactly that long too. Those
have different fixes. A slow route that waits is usually a query without an
index or a call to somebody else's service, and it hurts one caller at a
time. A blocked loop is arithmetic, parsing, hashing or compression in the
handler, and it hurts everyone at once, so it moves to another process or
gets broken up with `akkar.work.yielding`. The watchdog costs about 2%, and
it is the only one of the two that finds the problem you were not looking
for.
