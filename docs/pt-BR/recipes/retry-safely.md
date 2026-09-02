# Envie novamente com segurança

> **Português (Brasil)** | [Original em inglês](../../recipes/retry-safely.md)

Repete uma chamada de saída que falhou, sem transformar um pedido em três.

## O arquivo inteiro

```lua
local akkar  = require "akkar"
local http   = require "akkar.http"
local crypto = require "akkar.crypto"

local UPSTREAM = "http://127.0.0.1:4000"

local app = akkar.new()

-- GET é seguro de enviar de novo, então `retries` já basta.
app:get("/rates", function(req)
  local res, why = req.http:get(UPSTREAM .. "/rates", { retries = 3 })
  if not res then
    req.log:warn("rates gave up", { detail = why })
    return akkar.unavailable "rates are not available"
  end
  return { rates = res.body }
end)

-- POST não é repetido a menos que você peça, e pedir só é seguro com uma
-- chave que o outro lado usa para reconhecer a repetição. A chave é criada
-- uma única vez, então toda tentativa desse mesmo pedido carrega a mesma chave.
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

`retries` conta as tentativas depois da primeira. Uma resposta 5xx é repetida;
uma 4xx não é, porque enviar a mesma requisição (request) inválida de novo vai
receber a mesma resposta. As esperas dobram a partir de 100 ms: 0,1 s, depois
0,2 s, depois 0,4 s.

## Experimente

Não há nada escutando na porta 4000, então toda tentativa é recusada na hora
e a única coisa que consome tempo é a espera entre elas.

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

Quatro tentativas, três esperas, 0,7 segundos. Tire `retries = 3` e a mesma
requisição responde imediatamente:

```
{"error":"rates are not available"}

real	0m0,012s
```

## Por que o POST não é repetido a menos que você peça

O akkar repete GET, HEAD, PUT, DELETE, OPTIONS e TRACE, e deixa POST e PATCH
de fora. O motivo é que uma falha não dá nenhuma forma de distinguir "a
requisição nunca chegou" de "a requisição chegou, foi processada, e a
resposta se perdeu", e para um POST essas duas situações diferem em uma
cobrança ou um pedido a mais. Por isso repetir um POST é algo que você ativa
conscientemente com `retry_unsafe = true`, e isso só é correto quando o outro
lado consegue reconhecer a repetição, que é exatamente para o que serve a
chave de idempotência. Gere essa chave uma única vez por intenção, fora do
mecanismo de repetição, ou você mesmo acaba de escrever a duplicata. A mesma
ideia vista do outro lado está em [Torne uma escrita
idempotente](make-a-write-idempotent.md).
