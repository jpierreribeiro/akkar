# Torne uma escrita idempotente

> **Português (Brasil)** | [Original em inglês](../../recipes/make-a-write-idempotent.md)

O mesmo POST enviado duas vezes cobra uma vez, e a segunda chamada recebe de volta a resposta da primeira chamada.

Você precisa do Redis:

```sh
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine
```

## O arquivo completo

```lua
local akkar = require "akkar"
local redis = require "akkar.redis"

local app = akkar.new()

app:use(akkar.idempotency { ttl = 86400, required = true,
                            namespace = false })

app:post("/charges", { body = { amount = "integer" } }, function(req)
  -- Representa a cobrança. Ela precisa rodar uma vez, não importa quantas
  -- vezes o cliente envie a requisição.
  req.log:info("charged", { amount = req.body.amount })
  return akkar.created { charged = req.body.amount }
end)

app:run {
  port = 3000,
  cache = redis.connect { host = "127.0.0.1", port = 6379 },
}
```

O middleware só afeta POST e PATCH. GET, HEAD, PUT e DELETE já são idempotentes pela própria definição do HTTP, então passam direto. `required = true` recusa uma escrita que chega sem uma chave. Se você omitir isso, uma requisição sem chave simplesmente não fica protegida.

## Experimente

```sh
lua5.4 app.lua
```

Em um segundo terminal, envie a mesma requisição duas vezes com a mesma chave:

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

Mesmo status, mesmo corpo, além de `idempotent-replay: true`. O primeiro terminal mostra que o handler rodou uma única vez:

```
INFO  charged amount=2500 request_id=be35ef0a000001
```

A mesma chave com um corpo diferente é um erro, não uma nova tentativa, então é recusada:

```
{"error":"this idempotency-key was already used for a different request"}
```

E com `required = true`, uma escrita sem nenhuma chave:

```
{"error":"this endpoint requires an idempotency-key header"}
```

## Por que o cliente escolhe a chave

Só o cliente sabe se isso é uma cobrança nova ou uma nova tentativa daquela cuja resposta se perdeu no caminho de volta. Uma chave que o servidor deriva do corpo não consegue distinguir duas cobranças genuinamente idênticas de uma única cobrança enviada duas vezes, e um timeout de rede é exatamente o caso em que o cliente não tem ideia do que aconteceu. Por isso o cliente gera uma chave por intenção, mantém ela ao longo das novas tentativas, e o akkar guarda a resposta por `ttl` segundos. A garantia só é tão forte quanto o armazenamento: com Redis ela se mantém entre todos os processos, e uma segunda requisição que chega enquanto a primeira ainda está em execução recebe um 409 com `retry-after` em vez de uma segunda cobrança.
