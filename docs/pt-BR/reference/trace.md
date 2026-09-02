# akkar.trace

> **Português (Brasil)** | [Original em inglês](../../reference/trace.md)

Spans do W3C Trace Context, exportados como JSON OTLP/HTTP por meio de uma capability `akkar.http`. Registrar um span acrescenta uma linha a uma tabela; a exportação acontece em um loop em segundo plano, nunca durante a requisição.

**Quando você precisa disso.** Uma requisição atravessa três serviços e você quer uma única linha do tempo para ela no Jaeger, no Tempo ou em um OpenTelemetry Collector, incluindo as requisições que falharam.

```lua no-run
local trace = require "akkar.trace"
```

## Sumário

- [trace.attributes_of(map)](#traceattributes_ofmap)
- [trace.DEFAULTS](#tracedefaults)
- [trace.Exporter](#traceexporter)
- [trace.KIND](#tracekind)
- [trace.nanoseconds(seconds)](#tracenanosecondsseconds)
- [trace.new(options)](#tracenewoptions)
- [trace.otlp(spans, resource)](#traceotlpspans-resource)
- [trace.Span](#tracespan)
- [trace.span_id()](#tracespan_id)
- [trace.STATUS](#tracestatus)
- [trace.trace_id()](#tracetrace_id)
- [trace.traceparent(trace_id, span_id, sampled)](#tracetraceparenttrace_id-span_id-sampled)
- [Exporter](#exporter)
  - [exporter:client()](#exporterclient)
  - [exporter:due()](#exporterdue)
  - [exporter:flush()](#exporterflush)
  - [exporter:middleware(options)](#exportermiddlewareoptions)
  - [exporter:record(span)](#exporterrecordspan)
  - [exporter:run(controller)](#exporterruncontroller)
  - [exporter:start_span(options)](#exporterstart_spanoptions)
  - [exporter:stats()](#exporterstats)
  - [exporter:stop()](#exporterstop)
  - [exporter:tick()](#exportertick)
- [Span](#span)
  - [span:finish(options)](#spanfinishoptions)
  - [span:set(key, value)](#spansetkey-value)
  - [span:traceparent()](#spantraceparent)
- [Timestamps](#timestamps)
- [O que não está aqui](#o-que-não-está-aqui)

## trace.attributes_of(map)

Transforma uma tabela de chave para valor na lista de atributos do OTLP, ordenada por chave para que duas execuções sejam serializadas de forma idêntica.

Uma string vira `stringValue`, um booleano vira `boolValue`, um inteiro Lua vira `intValue` (como **string**, que é o que o mapeamento JSON do OTLP exige para um int64), um float vira `doubleValue`. Qualquer outra coisa é convertida para string.

**Retorna** uma lista, ou `nil` para um mapa `nil` ou vazio.

## trace.DEFAULTS

Os valores padrão que `trace.new` aplica.

| chave | valor |
|---|---|
| `endpoint` | `"http://localhost:4318/v1/traces"` |
| `service` | `"akkar"` |
| `max_batch` | `256` |
| `max_queue` | `2048` |
| `interval` | `5` |
| `timeout` | `2` |

## trace.Exporter

A metatable que todo exportador compartilha.

## trace.KIND

Os tipos de span do OTLP: `INTERNAL = 1`, `SERVER = 2`, `CLIENT = 3`, `PRODUCER = 4`, `CONSUMER = 5`.

## trace.nanoseconds(seconds)

Segundos desde a epoch como uma string de nanossegundos, calculada em aritmética de inteiros de 64 bits para que os dígitos não sejam inventados por um double.

**Retorna** uma string.

## trace.new(options)

Constrói um exportador. Tudo é opcional, mas um exportador sem capability `http` descarta todo lote.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `http` | client ou function | nenhum | uma capability `akkar.http`, ou uma factory que retorna uma. Qualquer coisa com um método `post(url, options)` funciona. |
| `endpoint` | string | `"http://localhost:4318/v1/traces"` | para onde um lote é enviado |
| `headers` | table | nenhum | cabeçalhos extras na requisição de exportação, para uma chave de API |
| `service` | string | `"akkar"` | vira o atributo de recurso `service.name` |
| `resource` | table | `{}` | atributos de recurso adicionais, mesclados sobre `service.name` |
| `max_batch` | number | `256` | quantidade de spans que torna uma exportação devida por tamanho |
| `max_queue` | number | `2048` | quantidade de spans mantidos antes de novos serem descartados |
| `interval` | number | `5` | segundos que tornam uma exportação devida por tempo |
| `timeout` | number | `2` | segundos que uma exportação pode levar |
| `sampler` | function | nenhum | chamada com a requisição; uma resposta falsa significa nenhum span |

**Retorna** um exportador.

**Não gera** nada. Uma opção desconhecida é ignorada.

```lua
local trace = require "akkar.trace"

-- Uma capability `akkar.http` é qualquer coisa com um método `post`. Uma real
-- vem de `akkar.http.connect {}`.
local sent = {}
local collector = {
  post = function(_, _, options) sent[#sent + 1] = options.body return { status = 200 } end,
}

local exporter = trace.new { http = collector, service = "tasks" }

local span = exporter:start_span { name = "charge card", kind = trace.KIND.CLIENT }
span:set("payment.provider", "stripe")
span:finish { status = "ok" }

print(exporter:stats().recorded)   --> 1
print(exporter:stats().queued)     --> 1
print(exporter:flush())            --> true
print(exporter:stats().exported)   --> 1
print(sent[1].resourceSpans[1].scopeSpans[1].spans[1].name)   --> charge card
```

## trace.otlp(spans, resource)

Constrói o payload JSON OTLP/HTTP para uma lista de spans. `resource` é uma tabela de atributos de recurso.

Exportada para que um teste possa verificar exatamente o formato que seria enviado pela rede, sem um collector.

Um span na lista é uma tabela simples com `trace_id`, `span_id`, `name`, `kind`, `start_time`, `duration`, `attributes` e, opcionalmente, `parent_span_id`, `status` e `status_message`. `parentSpanId` é omitido em vez de enviado vazio, e `status` é omitido quando é `UNSET`.

**Retorna** uma tabela pronta para `akkar.json.encode`.

```lua
local trace = require "akkar.trace"
local json  = require "akkar.json"

local payload = trace.otlp({
  {
    trace_id   = "4bf92f3577b34da6a3ce929d0e0e4736",
    span_id    = "00f067aa0ba902b7",
    name       = "GET /tasks/:id",
    kind       = trace.KIND.SERVER,
    start_time = 1755000000,
    duration   = 0.0125,
    attributes = { ["http.response.status_code"] = 200 },
  },
}, { ["service.name"] = "tasks" })

print(json.encode(payload.resourceSpans[1].scopeSpans[1].spans[1]))
```

## trace.Span

A metatable que todo span compartilha.

## trace.span_id()

Um id de span de 8 bytes como 16 caracteres hexadecimais, gerado pelo CSPRNG do sistema operacional.

**Retorna** uma string.

## trace.STATUS

Os códigos de status do OTLP: `UNSET = 0`, `OK = 1`, `ERROR = 2`. `UNSET` não significa "desconhecido", significa "ninguém declarou que esse span teve sucesso ou falhou", que é a resposta certa para a maioria dos spans.

## trace.trace_id()

Um id de trace de 16 bytes como 32 caracteres hexadecimais, gerado pelo CSPRNG do sistema operacional em vez de `math.random`, de modo que dois processos iniciados no mesmo instante não gerem os mesmos ids.

**Retorna** uma string.

## trace.traceparent(trace_id, span_id, sampled)

Renderiza o valor do cabeçalho `traceparent`. A versão é `00` e `sampled` define o bit menos significativo do byte de flags.

**Retorna** uma string, `00-<32 hex>-<16 hex>-<2 hex>`.

```lua
local trace = require "akkar.trace"

local trace_id = trace.trace_id()
local span_id  = trace.span_id()

print(#trace_id, #span_id)                              --> 32  16
print(trace.traceparent(trace_id, span_id, true))       --> 00-<32>-<16>-01
print(trace.traceparent(trace_id, span_id, false))      --> 00-<32>-<16>-00
print(trace.nanoseconds(1755000000.25))                 --> 1755000000250000000
```

## Exporter

### exporter:client()

Resolve a capability `http` uma única vez e a mantém guardada. Uma factory é chamada no primeiro uso, não em todo flush.

**Retorna** o client, ou `nil` quando nenhum foi configurado ou a factory gerou um erro.

### exporter:due()

Se uma exportação está devida: a fila não está vazia, e ou ela atingiu `max_batch` ou `interval` segundos se passaram desde o último flush.

**Retorna** `true` ou `false`.

### exporter:flush()

Exporta o que está na fila, agora.

A fila é trocada por uma vazia **antes** da chamada de rede, então spans registrados enquanto a exportação está em trânsito são mantidos para o próximo lote.

Uma exportação com falha descarta seu lote. Ela não é tentada novamente: as requisições que esses spans descrevem foram respondidas de um jeito ou de outro, e um buffer de novas tentativas cresceria por todo o tempo em que o collector estivesse fora do ar. Falhas são contabilizadas, não geram erro.

**Não deve ser chamada de dentro de um handler ou de um middleware.** Tudo dentro dela pode esperar por uma chamada de rede.

**Retorna** `true`, ou `nil` e uma string com o motivo:

| motivo | quando |
|---|---|
| `akkar.trace has no http capability` | `http` não foi configurada, ou a factory gerou um erro |
| `status <n>` | o collector respondeu 400 ou mais |
| o texto do erro | o transporte gerou um erro, uma falha de DNS por exemplo |

### exporter:middleware(options)

Middleware de span de servidor, para `app:use`.

Ele continua o trace do chamador quando `req.trace` está presente, usando aquele id de trace e o id de span do chamador como pai. O akkar já validou o cabeçalho de entrada, então um cabeçalho malformado inicia um trace novo em vez de se juntar a um corrompido. Quando a decisão do chamador foi não amostrar, nenhum span é criado.

O span é exposto ao handler como `req.span`. Nada é escrito na resposta: o valor do handler volta exatamente como foi retornado.

| opção | tipo | padrão | significado |
|---|---|---|---|
| `name` | function | `req.method .. " " .. req.route` | nomeia o span, chamada depois que o handler roda, para que `req.route` já exista |
| `sampler` | function | nenhum | chamada com a requisição; uma resposta falsa significa nenhum span |

O nome do span usa o padrão da rota, não o caminho, então `/tasks/7` e `/tasks/8` são uma única operação. Atributos definidos: `http.request.method`, `url.path`, `http.response.status_code` e `akkar.request_id`, que é o `req.id` -- o mesmo valor que `req.log` escreve como `request_id` e que a resposta carrega como `x-request-id`. Fica sob o namespace do próprio akkar porque as convenções semânticas não definem atributo de request id, e o único atributo delas em forma de header registra o que o cliente mandou, que o `req.id` não é. O status é `ERROR` para um erro gerado ou um 5xx, e permanece `UNSET` para um 4xx, que é a própria regra do OpenTelemetry para um span de servidor.

**Retorna** uma função middleware.

```lua
local akkar = require "akkar"
local trace = require "akkar.trace"

local sent = {}
local collector = {
  post = function(_, _, options) sent[#sent + 1] = options.body return { status = 200 } end,
}
local exporter = trace.new { http = collector, service = "tasks" }

local app = akkar.new()
app:use(exporter:middleware())
app:get("/tasks/:id", function(req) return { id = req.params.id } end)

local client = app:test {}
print(client:get("/tasks/7").status)     --> 200
print(client:get("/tasks/8").status)     --> 200

exporter:flush()
local spans = sent[1].resourceSpans[1].scopeSpans[1].spans
print(#spans)                            --> 2
print(spans[1].name)                     --> GET /tasks/:id
print(spans[1].kind)                     --> 2
```

### exporter:record(span)

Enfileira um span finalizado. `span:finish` chama esse método; chame você mesmo apenas para um span que você construiu manualmente.

A função inteira é um append. Ela não codifica nada e não abre nenhum socket, porque roda na coroutine da requisição. Quando a fila já contém `max_queue` spans, o mais novo é recusado em vez de o mais antigo ser removido, e `dropped` é incrementado.

**Retorna** `true` quando o span foi mantido, `false` quando foi descartado.

### exporter:run(controller)

Inicia o loop de flush em um controller do cqueues. Chame uma única vez, na inicialização, de dentro do loop que o akkar executa.

O loop acorda a cada `min(interval / 4, 1)` segundos e chama `tick`, que faz o flush quando `due()`. Um tick ruim não encerra o loop.

**Retorna** o exportador.

**Gera** `akkar.trace: run() needs a cqueues controller; call it from inside the loop akkar runs on, or pass one` quando não há um controller em execução e nenhum foi passado.

### exporter:start_span(options)

Inicia um span.

| opção | tipo | padrão | significado |
|---|---|---|---|
| `name` | string | `"span"` | o nome do span |
| `kind` | number | `KIND.INTERNAL` | um dos valores de `trace.KIND` |
| `trace_id` | string | um novo | o trace ao qual se juntar |
| `parent_span_id` | string | nenhum | o pai dentro daquele trace |
| `sampled` | boolean | `true` | levado para `span:traceparent()` |
| `attributes` | table | `{}` | os atributos do span, usados como fornecidos |

**Retorna** um span. Apesar do que a docstring do código-fonte diz, ele nunca retorna `nil`: a decisão de amostragem é tomada no middleware, que não chama esta função quando um trace não é amostrado.

### exporter:stats()

Os contadores. Coloque `dropped` e `failed` em um dashboard: um trace com buracos e sem um contador é um trace que ninguém consegue explicar.

**Retorna** uma tabela.

| campo | significado |
|---|---|
| `queued` | spans esperando agora mesmo |
| `recorded` | spans entregues a `record`, mantidos ou não |
| `dropped` | spans recusados por uma fila cheia, mais todo span de um lote que falhou ao exportar |
| `exported` | spans que um collector aceitou |
| `failed` | lotes que falharam |
| `batches` | lotes tentados |

```lua
local trace = require "akkar.trace"

local exporter = trace.new { max_queue = 2 }      -- e nenhuma capability http

for i = 1, 3 do exporter:start_span { name = "n" .. i }:finish() end

print(exporter:stats().recorded)   --> 3
print(exporter:stats().queued)     --> 2
print(exporter:stats().dropped)    --> 1, o terceiro foi recusado
print(exporter:flush())            --> nil, akkar.trace has no http capability
print(exporter:stats().dropped)    --> 3, o lote também foi
```

### exporter:stop()

Para o loop e exporta mais uma vez.

**Retorna** o que `flush` retorna.

### exporter:tick()

Faz o flush se algum dos dois limites foi atingido, e não faz nada caso contrário. É isso que o loop chama, e o que um teste aciona em vez de esperar.

**Retorna** `true` quando fez o flush, `false` quando nada estava devido.

## Span

### span:finish(options)

Encerra o span, mede sua duração em relação ao relógio monotônico, e o entrega ao exportador. Finalizar um span duas vezes não faz nada na segunda vez.

| opção | tipo | significado |
|---|---|---|
| `status` | number ou string | um valor de `trace.STATUS`, ou `"ok"` ou `"error"` |
| `message` | string | a mensagem de status |
| `attributes` | table | mesclada sobre os atributos já definidos |

**Retorna** o span.

### span:set(key, value)

Define um atributo.

**Retorna** o span, para que as chamadas sejam encadeadas.

### span:traceparent()

O cabeçalho `traceparent` a enviar em uma chamada de saída feita dentro deste span, para que o próximo serviço se junte a este trace.

```lua no-run
local res = req.http:get(url, { traceparent = req.span:traceparent() })
```

**Retorna** uma string.

## Timestamps

Um span carrega um início em wall-clock para que um humano consiga encontrá-lo, e uma duração medida no relógio monotônico para que um ajuste de NTP não a torne negativa.

O início vem de `akkar.time.now()`, que é `os.time` e tem **resolução de um segundo**. Dois spans iniciados no mesmo segundo são ordenados de forma arbitrária entre si pelo horário de início, enquanto suas durações são precisas até microssegundos.

`endTimeUnixNano` é calculado como `start_time + duration` em ponto flutuante antes de ser dividido em nanossegundos, então seus últimos dígitos variam em dezenas de nanossegundos. `startTimeUnixNano` não: ele passa pelo caminho de inteiros.

## O que não está aqui

- **Spans de cliente em torno de HTTP de saída.** `akkar.http` envia um `traceparent`, e `span:traceparent()` o fornece, mas nada envolve uma chamada de saída em um span automaticamente para você.
- **Spans de banco de dados ou cache.** Só existe o span de servidor, de `exporter:middleware()`.
- **Nova tentativa de uma exportação com falha.** De propósito. O lote é descartado e contabilizado.
- **Métricas ou logs via OTLP.** Somente spans. Métricas são [akkar.metrics](metrics.md), um scrape do Prometheus.
- **Protobuf.** O payload é JSON OTLP/HTTP, gerado aqui.
- **Amostragem por cabeça (head sampling) por proporção.** `sampler` é uma função que você escreve. Não existe `ratio = 0.1`.

## Correlação com logs

Um span e uma linha de log da mesma requisição compartilham duas chaves, uma em cada direção. `req.log` carrega `trace_id` e `span_id` assim que o middleware iniciou um span (e os ids do trace de entrada mesmo quando não iniciou); o span de servidor carrega `akkar.request_id`. Qualquer um leva ao outro, e uma linha de log de uma requisição sem trace não carrega chave nenhuma, em vez de uma vazia. Veja [akkar.log](log.md#loggerwithfields).

```lua
local akkar = require "akkar"
local trace = require "akkar.trace"
local log   = require "akkar.log"
local json  = require "akkar.json"

local lines = {}
local logger = log.new { format = "json", sink = function(line) lines[#lines + 1] = line end }
local exporter = trace.new {}

local app = akkar.new()
app:use(exporter:middleware())
app:get("/tasks/:id", function(req) req.log:info("looked up") return { id = req.params.id } end)

local res = app:test({ log = logger }):get "/tasks/7"
local span = exporter.queue[1]
local line = json.decode(lines[1])

print(line.trace_id == span.trace_id)                              --> true
print(line.span_id == span.span_id)                                --> true
print(span.attributes["akkar.request_id"] == res.headers["x-request-id"])   --> true
```

## Veja também

- [akkar](akkar.md) para `req.trace`, o `traceparent` de entrada validado, e para `app:use`
- [akkar.metrics](metrics.md) para a visão agregada das mesmas requisições
- o código-fonte do módulo, `akkar/trace.lua`, para entender por que uma requisição nunca fica bloqueada esperando uma exportação
