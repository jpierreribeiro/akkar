# Veja o que está lento

> **Português (Brasil)** | [Original em inglês](../../recipes/see-what-is-slow.md)

Coloca uma duração em cada rota e avisa quando um handler não está lento, mas travado.

## O arquivo completo

```lua
local akkar   = require "akkar"
local metrics = require "akkar.metrics"
local time    = require "akkar.time"

local registry = metrics.new()

local app = akkar.new()

app:use(registry:middleware())

app:get("/fast", function() return { ok = true } end)

app:get("/slow", function()
  time.sleep(0.3)                 -- esperando, do jeito que uma query ou uma chamada de API espera
  return { ok = true }
end)

app:get("/blocking", function()
  local total = 0
  for i = 1, 20000000 do total = total + i end    -- computando, nunca cedendo o controle
  return { total = total }
end)

-- Adiciona GET /metrics, no formato texto que o Prometheus coleta.
registry:serve(app, "/metrics")

app:run { port = 3000 }
```

## Experimente

```sh
lua5.4 app.lua
```

```sh
curl http://127.0.0.1:3000/fast
curl http://127.0.0.1:3000/slow
curl http://127.0.0.1:3000/blocking
curl http://127.0.0.1:3000/metrics
```

As contagens e o tempo total, por rota:

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

O rótulo route é o padrão, `/tasks/:id`, não o caminho, então um milhão de ids vira uma série só, e não um milhão.

`/metrics` também traz `akkar_request_duration_seconds_bucket`, que é a partir do que um percentil é calculado, além de heap, memória residente e uptime.

Enquanto `/blocking` estava rodando, o primeiro terminal disse isto por conta própria:

```
WARN  handler blocked the event loop without yielding at=app.lua:18 blocked_ms=101 hint=this stalls every request in this process traceback=
```

seguido de um traceback nomeando o loop.

## Por que dois sinais diferentes

O histograma diz que uma rota está lenta. O watchdog diz algo pior: que um handler gastou 100 ms de CPU ininterrupta sem ceder o controle, o que em um único processo Lua significa que toda outra requisição esperou exatamente esse mesmo tempo. Isso tem consertos diferentes. Uma rota lenta que espera geralmente é uma query sem índice ou uma chamada para o serviço de outra pessoa, e prejudica um chamador de cada vez. Um loop travado é aritmética, parsing, hashing ou compressão no handler, e prejudica todo mundo ao mesmo tempo, então a solução é mover isso para outro processo ou quebrar o trabalho com `akkar.work.yielding`. O watchdog custa cerca de 2%, e é o único dos dois que encontra o problema que você não estava procurando.
