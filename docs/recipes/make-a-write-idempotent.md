# Make a write idempotent

The same POST sent twice charges once, and the second call gets the first
call's answer back.

You need Redis:

```sh
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine
```

## The whole file

```lua
local akkar = require "akkar"
local redis = require "akkar.redis"

local app = akkar.new()

app:use(akkar.idempotency { ttl = 86400, required = true,
                            namespace = false })

app:post("/charges", { body = { amount = "integer" } }, function(req)
  -- Stands in for the charge. It must run once however many times the client
  -- sends the request.
  req.log:info("charged", { amount = req.body.amount })
  return akkar.created { charged = req.body.amount }
end)

app:run {
  port = 3000,
  cache = redis.connect { host = "127.0.0.1", port = 6379 },
}
```

The middleware only touches POST and PATCH. GET, HEAD, PUT and DELETE are
already idempotent by HTTP's own definition, so they go straight through.
`required = true` refuses a write that arrives without a key. Leave it out and
a request with no key is simply not protected.

## Try it

```sh
lua5.4 app.lua
```

In a second terminal, send the same request twice with the same key:

```sh
curl -i -X POST http://127.0.0.1:3000/charges \
  -H "content-type: application/json" \
  -H "idempotency-key: charge-7f31" \
  -d '{"amount":2500}'
```

```
HTTP/1.1 201 Created
x-request-id: be35ef0a000001
content-type: application/json
content-length: 16

{"charged":2500}
```

```
HTTP/1.1 201 Created
idempotent-replay: true
x-request-id: be35ef0a000002
content-type: application/json
content-length: 16

{"charged":2500}
```

Same status, same body, plus `idempotent-replay: true`. The first terminal
shows the handler ran once:

```
INFO  charged amount=2500 request_id=be35ef0a000001
```

The same key with a different body is a mistake, not a retry, so it is
refused:

```
{"error":"this idempotency-key was already used for a different request"}
```

And with `required = true`, a write with no key at all:

```
{"error":"this endpoint requires an idempotency-key header"}
```

## Why the client picks the key

Only the client knows whether this is a new charge or a retry of the one
whose answer got lost on the way back. A key the server derives from the body
cannot tell two genuine identical charges apart from one charge sent twice,
and a network timeout is exactly the case where the client has no idea which
happened. So the client generates one key per intent, keeps it across
retries, and akkar remembers the answer for `ttl` seconds. The guarantee is
only as strong as the store: with Redis it holds across every process, and a
second request that arrives while the first is still running gets a 409 with
`retry-after` rather than a second charge.
