# akkar.otlp

> **Português (Brasil)** | [Original em inglês](../../reference/otlp.md)

Um único pipeline de telemetria: traces, métricas e logs exportados como JSON OTLP/HTTP para um único collector, configurados com uma única opção, descarregados por um único loop em segundo plano. Nada aqui roda durante uma requisição; cada sinal acrescenta a uma fila limitada e é enviado depois.

**Quando você precisa disso.** Você roda um OpenTelemetry Collector, ou um endpoint de fornecedor que fala OTLP, e quer que as métricas que o `akkar.metrics` já mantém e as linhas que o `akkar.log` já escreve cheguem lá ao lado dos spans que o `akkar.trace` já exporta -- sem um segundo agente, um segundo endpoint ou um segundo conjunto de credenciais.

```lua no-run
local otlp = require "akkar.otlp"
```

## Sumário

- [otlp.DEFAULTS](#otlpdefaults)
- [otlp.endpoint_for(base, signal)](#otlpendpoint_forbase-signal)
- [otlp.new(options)](#otlpnewoptions)
- [otlp.PATHS](#otlppaths)
- [otlp.SIGNALS](#otlpsignals)
- [Pipeline](#pipeline)
  - [pipeline:flush()](#pipelineflush)
  - [pipeline:logger(options)](#pipelineloggeroptions)
  - [pipeline:middleware(options)](#pipelinemiddlewareoptions)
  - [pipeline:run(controller)](#pipelineruncontroller)
  - [pipeline:stats()](#pipelinestats)
  - [pipeline:stop()](#pipelinestop)
  - [pipeline:tick()](#pipelinetick)
- [No que cada sinal se transforma](#no-que-cada-sinal-se-transforma)
- [As regras que todo sinal segue](#as-regras-que-todo-sinal-segue)
- [O que não está aqui](#o-que-não-está-aqui)

## otlp.DEFAULTS

| chave | valor | significado |
|---|---|---|
| `endpoint` | `"http://localhost:4318"` | a URL base do collector; o caminho do sinal é acrescentado |
| `metrics_interval` | `60` | segundos entre pushes de métricas, o padrão do próprio SDK do OpenTelemetry |
| `metrics_queue` | `8` | snapshots mantidos antes de novos serem descartados |

Traces e logs pegam `max_batch`, `max_queue`, `interval` e `timeout` de [trace.DEFAULTS](trace.md#tracedefaults): 256, 2048, 5 e 2.

## otlp.endpoint_for(base, signal)

A URL para onde um sinal é enviado: `base` sem barra final, sem qualquer caminho de sinal em que já termine, e com o caminho de `signal` acrescentado. É isso que a especificação OTLP diz que um endpoint base significa.

**Retorna** uma string.

```lua
local otlp = require "akkar.otlp"

print(otlp.endpoint_for("http://collector:4318", "metrics"))
--> http://collector:4318/v1/metrics

-- O padrão de traces do akkar.trace pode ser colado sem prejuízo.
print(otlp.endpoint_for("http://localhost:4318/v1/traces", "logs"))
--> http://localhost:4318/v1/logs
```

## otlp.new(options)

Constrói o pipeline. Todo campo é opcional. Um pipeline sem capability `http` descarta todo lote e conta os descartes.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `http` | client ou function | nenhum | uma capability `akkar.http`, ou uma factory que retorna uma. Resolvida **uma vez** e compartilhada pelos três exportadores. |
| `endpoint` | string | `otlp.DEFAULTS.endpoint` | a URL base do collector |
| `headers` | table | nenhum | cabeçalhos em toda exportação, para uma chave de API |
| `service` | string | `"akkar"` | o atributo de recurso `service.name` |
| `resource` | table | `{}` | atributos de recurso adicionais |
| `registry` | registry | nenhum | um registro de `akkar.metrics.new()`. **Métricas só são enviadas quando um é dado.** |
| `sampler` | function | nenhum | o sampler de cabeça para spans, como `akkar.trace.new` o recebe |
| `timeout` | number | `2` | segundos que uma exportação pode levar, todos os sinais |
| `interval` | number | `5` | segundos que tornam uma exportação de spans ou logs devida por tempo |
| `max_batch` | number | `256` | spans ou linhas que tornam uma exportação devida por tamanho |
| `max_queue` | number | `2048` | spans ou linhas mantidos antes de novos serem descartados |
| `traces` | `false` ou table | ligado | `false` desliga os spans; uma table é mesclada sobre os campos compartilhados só para este sinal |
| `metrics` | `false`, table ou registry | ligado com um registro | `false` desliga o push; uma table pode trazer `registry`, `interval`, `max_queue`, `endpoint`, `headers`; um registro liga o push com os padrões |
| `logs` | `false` ou table | ligado | `false` desliga as linhas; uma table é mesclada sobre os campos compartilhados só para este sinal |

A table de um sinal pode trazer seu próprio `endpoint`, usado exatamente como dado, e seus próprios `headers`, mesclados sobre os compartilhados. O resto dos campos dela são os campos acima.

**Retorna** um pipeline com os campos `traces`, `metrics` e `logs`, cada um um [exportador](trace.md#exporter) ou `nil` quando o sinal está desligado. Acesse-os para `:stats()` de um único sinal ou para os testes que você escrever contra eles.

**Levanta** `akkar.otlp: metrics need a registry; pass registry = akkar.metrics.new() or metrics = false` quando `metrics = true` é pedido sem um registro, e `akkar.otlp: registry has no snapshot(); pass the registry from akkar.metrics.new()` quando o registro não é um. Uma opção desconhecida é ignorada.

```lua
local akkar   = require "akkar"
local otlp    = require "akkar.otlp"
local metrics = require "akkar.metrics"

-- Uma capability `akkar.http` é qualquer coisa com um método `post`. Uma real
-- vem de `akkar.http.connect {}`; esta lembra o que lhe foi enviado.
local sent = {}
local collector = {
  post = function(_, url, options)
    sent[#sent + 1] = { url = url, body = options.body }
    return { status = 200 }
  end,
}

local registry = metrics.new()
local pipeline = otlp.new {
  http     = collector,
  endpoint = "http://collector:4318",
  headers  = { authorization = "Bearer k" },
  service  = "tasks",
  registry = registry,
}

local app = akkar.new()
app:use(pipeline:middleware())          -- um span de servidor por requisição
app:use(registry:middleware())          -- o contador de requisições e o histograma
app:get("/tasks/:id", function(req)
  req.log:info("fetched", { id = req.params.id })   -- um LogRecord
  return { id = req.params.id }
end)

local client = app:test { log = pipeline:logger { level = "info" } }
client:get "/tasks/1"
client:get "/tasks/2"

-- Nada saiu ainda: nenhuma requisição tocou o collector.
print(#sent)                                   --> 0

-- `stop` descarrega todo sinal, métricas com um snapshot final.
print(pipeline:stop())                         --> true
for _, call in ipairs(sent) do print(call.url) end
--> http://collector:4318/v1/traces
--> http://collector:4318/v1/metrics
--> http://collector:4318/v1/logs

local requests
for _, metric in ipairs(sent[2].body.resourceMetrics[1].scopeMetrics[1].metrics) do
  if metric.name == "akkar_requests_total" then requests = metric end
end
print(requests.sum.isMonotonic, requests.sum.dataPoints[1].asInt)   --> true 2
```

O logger do próprio pipeline, `pipeline:logger`, escreve em stderr como qualquer logger; a exportação é em adição a isso, nunca no lugar. O cliente de teste acima o passa como a capability `log`, que é o que `app:run { log = ... }` faz em um processo real.

## otlp.PATHS

`{ traces = "/v1/traces", metrics = "/v1/metrics", logs = "/v1/logs" }`, da especificação OTLP.

## otlp.SIGNALS

`{ "traces", "metrics", "logs" }`, a ordem em que o pipeline os tica, descarrega e reporta.

## Pipeline

### pipeline:flush()

Exporta toda fila agora, na ordem de `otlp.SIGNALS`. Não deve ser chamado de um handler: tudo nele pode esperar por uma rede.

**Retorna** `true`, ou `nil` e os motivos unidos com `; `.

### pipeline:logger(options)

Um logger cujas linhas também chegam ao collector. `options` é o que [log.new](log.md#lognewoptions) recebe; `exporter` é definido como o exportador de logs, e `req.log` o herda por meio de `:with`. Com logs desligados é um logger comum.

**Retorna** um logger.

```lua
local otlp = require "akkar.otlp"

local pipeline = otlp.new { logs = { max_queue = 4 } }
local logger = pipeline:logger { level = "warn", sink = function() end }

for i = 1, 10 do logger:warn("line " .. i) end
logger:info "below the level: neither written nor queued"

local stats = pipeline:stats().logs
print(stats.recorded, stats.queued, stats.dropped)   --> 10 4 6
```

### pipeline:middleware(options)

O middleware de span de servidor do exportador de traces, com as `options` que [exporter:middleware](trace.md#exportermiddlewareoptions) recebe. Com traces desligados é um middleware que não faz nada, então o ponto de chamada não precisa saber quais sinais estão ligados.

**Retorna** um middleware.

### pipeline:run(controller)

Roda um único loop para todo sinal em um controller cqueues. Chame uma vez, na inicialização, de dentro do loop em que o akkar roda ou com o controller passado. O loop cochila um quarto do menor intervalo, no máximo um segundo, e tica todo sinal.

**Retorna** o pipeline.

**Levanta** `akkar.otlp: run() needs a cqueues controller; ...` quando chamado fora de um sem nenhum ser dado.

### pipeline:stats()

Os contadores por sinal: `{ traces = {...}, metrics = {...}, logs = {...} }`, cada um a table que [exporter:stats](trace.md#exporterstats) retorna. Um sinal desligado está ausente. Coloque todo `dropped` e `failed` em um dashboard.

**Retorna** uma table.

### pipeline:stop()

Para o loop depois de uma última exportação de todo sinal. As métricas tiram um snapshot final antes, para que os totais no desligamento cheguem ao collector.

**Retorna** `true`, ou `nil` e os motivos unidos.

### pipeline:tick()

Tica todo sinal uma vez: uma exportação de spans ou logs quando seu limite de tamanho ou tempo é atingido, um snapshot e push de métricas quando o intervalo de métricas passou. É isso que o loop chama, e o que um teste chama sob um relógio manual.

**Retorna** `true` quando qualquer coisa foi exportada.

```lua
local otlp    = require "akkar.otlp"
local metrics = require "akkar.metrics"
local time    = require "akkar.time"

local clock = time.manual { now = 1755000000 }
local restore = time.set(clock)

local pushes = 0
local collector = { post = function() pushes = pushes + 1 return { status = 200 } end }
local registry = metrics.new()
registry:counter "hits"

local pipeline = otlp.new { http = collector, registry = registry,
                            metrics = { interval = 60 } }

clock:advance(59)
print(pipeline:tick(), pushes)     --> false 0
clock:advance(1)
print(pipeline:tick(), pushes)     --> true 1

restore()
```

## No que cada sinal se transforma

**Spans** são o que [trace.otlp](trace.md#traceotlpspans-resource) constrói, em `/v1/traces`, sem alteração.

**Métricas** são o registro lido no momento do push por [registry:snapshot](metrics.md#registrysnapshotnow) -- a mesma leitura de um scrape, pools incluídos -- e codificadas por [metrics.otlp](metrics.md#metricsotlpsnapshots-resource) como um `ExportMetricsServiceRequest` em `/v1/metrics`. Seguindo o modelo de dados de métricas:

| no registro | em OTLP |
|---|---|
| `akkar_requests_total` e todo `registry:counter` | um `Sum`, `aggregationTemporality = 2` (cumulativo), `isMonotonic = true`; `startTimeUnixNano` é quando o registro foi construído |
| todo `registry:gauge`, os gauges de memória, `akkar_uptime_seconds` | um `Gauge` |
| `akkar_request_duration_seconds` | um `Histogram` com `explicitBounds` = os buckets do registro e uma entrada em `bucketCounts` por bucket mais uma para além do último, **por bucket** e não cumulativa como o Prometheus os renderiza |
| um pool de `registry:pool` | seus contadores como `Sum`, sua ocupação como `Gauge`, sob o atributo `pool` |
| rótulos | atributos, em ordem alfabética |

Cumulativo significa que todo push carrega o total desde que o registro foi construído, então um push descartado não perde nada: o próximo carrega o mesmo total e tudo o que veio depois.

**Linhas de log** viram `LogRecord`s em um `ExportLogsServiceRequest` em `/v1/logs`, construído por [log.otlp](log.md#logotlpentries-resource). Seguindo o modelo de dados de logs: `severityNumber` é 5 para `debug`, 9 para `info`, 13 para `warn` e 17 para `error` (o primeiro da faixa de quatro de cada nível), `severityText` é o nível em maiúsculas, `body` é a mensagem, e todo outro campo -- os vinculados com `:with`, os passados na chamada -- é um atributo. Um `trace_id` e um `span_id` na linha são elevados ao registro como `traceId` e `spanId` quando têm 32 e 16 caracteres hexadecimais; qualquer outra coisa permanece atributo em vez de virar um `traceId` pelo qual um collector rejeitaria o lote inteiro.

Todo inteiro de 64 bits -- um timestamp, uma contagem, um `asInt`, um `intValue` -- é uma **string**, que é o que a codificação JSON do OTLP exige de um.

## As regras que todo sinal segue

São as regras que `akkar/trace.lua` defende, e valem aqui porque os três exportadores são o exportador daquele módulo com três codificadores.

- **Uma requisição nunca é bloqueada por uma exportação.** Registrar um span, um snapshot ou uma linha acrescenta a uma table. A rede acontece no loop.
- **A fila é limitada e descarta além do limite**, recusando o mais novo e contando-o em `dropped`. Um collector que sumiu custa uma quantidade fixa de memória.
- **Um lote que falhou é descartado, não reenviado**, e contado em `failed`.
- **Parar exporta mais uma vez.** `pipeline:stop()` descarrega toda fila e envia um snapshot final de métricas.

Três filas em vez de uma, para que o sinal mais barulhento não consiga espremer os outros para fora do limite.

## O que não está aqui

- **Protobuf ou gRPC.** Somente JSON OTLP/HTTP.
- **Temporalidade delta.** Todo sum é cumulativo.
- **Amostragem de logs ou um segundo sink.** stderr é escrito primeiro, sempre; a exportação é em adição. O `sink` do `akkar.log` continua sendo o lugar para um arquivo.
- **Um push de métricas sem registro.** O push lê o registro do qual você já faz scrape, e nada mais.
- **Nova tentativa, backoff ou buffer persistente.** De propósito; os contadores são o que dizem que um collector está faltando.

## Veja também

- [akkar.trace](trace.md) para o exportador sobre o qual isto é construído, spans, e por que uma requisição nunca é bloqueada por uma exportação
- [akkar.metrics](metrics.md) para o registro, `registry:snapshot` e `metrics.otlp`
- [akkar.log](log.md) para `log.new { exporter = ... }`, `log.record` e `log.otlp`
- as especificações do OpenTelemetry que isto segue: o [modelo de dados de métricas](https://opentelemetry.io/docs/specs/otel/metrics/data-model/), o [modelo de dados de logs](https://opentelemetry.io/docs/specs/otel/logs/data-model/) e [OTLP/HTTP com sua codificação JSON](https://opentelemetry.io/docs/specs/otlp/)
- o código-fonte do módulo, `akkar/otlp.lua`, para entender por que há três filas e um único loop
