# Retry safely

Retries an outbound call that failed, without turning one order into three.

## The whole file

```lua
local akkar  = require "akkar"
local http   = require "akkar.http"
local crypto = require "akkar.crypto"

local UPSTREAM = "http://127.0.0.1:4000"

local app = akkar.new()

-- GET is safe to send again, so `retries` is enough.
app:get("/rates", function(req)
  local res, why = req.http:get(UPSTREAM .. "/rates", { retries = 3 })
  if not res then
    req.log:warn("rates gave up", { detail = why })
    return akkar.unavailable "rates are not available"
  end
  return { rates = res.body }
end)

-- POST is not retried unless you say so, and saying so is only safe with a
-- key the other side uses to recognise the repeat. The key is made once, so
-- every attempt of this one order carries the same one.
app:post("/orders", { body = { sku = "string" } }, function(req)
  local res, why = req.http:post(UPSTREAM .. "/orders", {
    body = { sku = req.body.sku },
    headers = { ["idempotency-key"] = crypto.token(16) },
    retries = 2,
    retry_unsafe = true,
  })
  if not res then
    req.log:warn("order gave up", { detail = why })
    return akkar.unavailable "the order service is not available"
  end
  return akkar.created { upstream_status = res.status }
end)

app:run { port = 3000, http = http.connect { timeout = 2 } }
```

`retries` counts attempts after the first. A 5xx answer is retried; a 4xx is
not, because sending the same bad request again will get the same answer.
Waits double from 100 ms: 0.1 s, then 0.2 s, then 0.4 s.

## Try it

Nothing is listening on port 4000, so every attempt is refused at once and
the only thing left on the clock is the waiting between them.

```sh
lua5.4 app.lua
```

```sh
time curl http://127.0.0.1:3000/rates
```

```
{"error":"rates are not available"}

real	0m0,738s
```

Four attempts, three waits, 0.7 seconds. Take `retries = 3` out and the same
request answers immediately:

```
{"error":"rates are not available"}

real	0m0,012s
```

## Why POST is not retried unless you ask

akkar retries GET, HEAD, PUT, DELETE, OPTIONS and TRACE, and leaves POST and
PATCH alone. The reason is that a failure gives you no way to tell "the
request never arrived" from "the request arrived, was acted on, and the
answer got lost", and for a POST those two differ by one charge or one order.
So retrying a POST is something you opt into with `retry_unsafe = true`, and
it is only correct when the other side can recognise the repeat, which is
what the idempotency key is for. Generate that key once per intent, outside
the retry, or you have simply written the duplicate yourself. The same idea
seen from the other side is [Make a write
idempotent](make-a-write-idempotent.md).
