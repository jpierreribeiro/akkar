# Chame outra API e trate a falha

> **Português (Brasil)** | [Original em inglês](../../recipes/call-another-api.md)

Chama um serviço que você não controla, com um timeout, e transforma toda forma pela qual ele pode te decepcionar em uma resposta sua.

## O arquivo inteiro

```lua
local akkar = require "akkar"
local http  = require "akkar.http"

local UPSTREAM = "https://api.github.com/zen"

local app = akkar.new()

app:get("/zen", function(req)
  local res, why = req.http:get(UPSTREAM, { timeout = 2 })

  -- Nenhuma resposta: recusada, timeout, DNS, TLS. `why` diz qual foi.
  if not res then
    req.log:warn("upstream did not answer", { detail = why })
    return akkar.unavailable "the quote service is not answering"
  end

  -- Uma resposta, mas não uma que esta rota consiga usar. O 500 deles não é o nosso 500.
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

`http` é uma capability, assim como `db` e `cache`, então é configurada uma única vez em `app:run{}` e acessada como `req.http` dentro de um handler. O cliente nunca dispara exceção por causa de uma falha de rede: ele retorna `nil` e uma razão, e é por isso que toda chamada tem dois valores de retorno.

## Experimente

```sh
lua5.4 app.lua
```

Em um segundo terminal:

```sh
curl http://127.0.0.1:3000/zen
```

```
{"zen":"Avoid administrative distraction."}
```

Agora aponte `UPSTREAM` para uma porta sem nada por trás, como `http://127.0.0.1:9/zen`, e pergunte de novo:

```
HTTP/1.1 503 Service Unavailable
x-request-id: 258816c6000001
content-type: application/json
content-length: 46

{"error":"the quote service is not answering"}
```

O primeiro terminal diz qual foi a falha:

```
WARN  upstream did not answer detail=flush: Connection refused request_id=258816c6000001
```

## Por que um timeout menor que o seu próprio prazo

Uma requisição (request) que espera pelo servidor de outra pessoa mantém um dos seus abertos por exatamente o mesmo tempo, e o prazo padrão de uma requisição é 30 segundos. Dois segundos aqui significam que um upstream lento custa ao chamador dois segundos e um 503, em vez de segurar uma conexão, uma vaga no pool e uma vaga in-flight por meio minuto cada, enquanto a fila atrás dela cresce. Escolha o número a partir do que o chamador consegue suportar, não a partir do que o upstream costuma levar. Se o trabalho não precisa acontecer antes de a resposta (response) sair, não faça o chamador esperar: coloque-o numa fila, que é a [página 10](../guide/10-background-work.md) do guia.
