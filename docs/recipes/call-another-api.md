# Call another API and handle failure

Calls a service you do not control, with a timeout, and turns every way it can
let you down into an answer of your own.

## The whole file

```lua
local akkar = require "akkar"
local http  = require "akkar.http"

local UPSTREAM = "https://api.github.com/zen"

local app = akkar.new()

app:get("/zen", function(req)
  local res, why = req.http:get(UPSTREAM, { timeout = 2 })

  -- No response at all: refused, timed out, DNS, TLS. `why` says which.
  if not res then
    req.log:warn("upstream did not answer", { detail = why })
    return akkar.unavailable "the quote service is not answering"
  end

  -- A response, but not one this route can use. Their 500 is not our 500.
  if res.status ~= 200 then
    req.log:warn("upstream answered badly", { status = res.status })
    return akkar.response(502, { error = "the quote service answered " .. res.status })
  end

  return { zen = res.body }
end)

app:run {
  port = 3000,
  http = http.connect {
    timeout = 2,
    headers = { ["user-agent"] = "akkar-recipe" },
  },
}
```

`http` is a capability, like `db` and `cache`, so it is configured once in
`app:run{}` and reached as `req.http` inside a handler. The client never
raises for a network failure: it returns `nil` and a reason, which is why
every call has two return values.

## Try it

```sh
lua5.4 app.lua
```

In a second terminal:

```sh
curl http://127.0.0.1:3000/zen
```

```
{"zen":"Avoid administrative distraction."}
```

Now point `UPSTREAM` at a port with nothing behind it, such as
`http://127.0.0.1:9/zen`, and ask again:

```
HTTP/1.1 503 Service Unavailable
x-request-id: 258816c6000001
content-type: application/json
content-length: 46

{"error":"the quote service is not answering"}
```

The first terminal says which failure it was:

```
WARN  upstream did not answer detail=flush: Connection refused request_id=258816c6000001
```

## Why a timeout smaller than your own deadline

A request that waits on somebody else's server holds one of yours open for
exactly as long, and the default request deadline is 30 seconds. Two seconds
here means a slow upstream costs a caller two seconds and one 503, instead of
holding a connection, a pool slot and an in-flight slot for half a minute
each while the queue behind it grows. Pick the number from what the caller
can stand, not from what the upstream usually does. If the work does not have
to happen before the answer goes out, do not make the caller wait at all: put
it on a queue instead, which is [page 10](../guide/10-background-work.md) of
the guide.
