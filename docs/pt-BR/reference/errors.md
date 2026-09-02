# akkar.errors

> **Português (Brasil)** | [Original em inglês](../../reference/errors.md)

A falha por trás de um 500, capturada com o contexto da requisição e entregue a algo que a guarde. Capturar acrescenta uma linha a uma tabela; a entrega acontece em um loop em segundo plano, nunca durante a requisição.

**Quando você precisa disso.** Um handler levantou um erro em produção, o cliente recebeu `{"error": "internal server error"}` e o único registro do *porquê* é uma linha no stderr do contêiner que por acaso atendeu aquela requisição.

```lua no-run
local errors = require "akkar.errors"
```

`app:on_error` documenta esse gancho desde cedo e o akkar nunca entregou nada do outro lado dele. Esta é a outra ponta. Ela **não** implementa o protocolo de envelope do Sentry: faz um POST de um único documento JSON para uma única URL, então pode ser apontada para o Sentry através de um relay, para o receptor HTTP de um OpenTelemetry Collector, para o Loki, para uma Lambda, ou para quatro linhas suas que só escrevem em um arquivo.

## Sumário

- [errors.new(options)](#errorsnewoptions)
- [errors.DEFAULTS](#errorsdefaults)
- [errors.REDACTED](#errorsredacted)
- [errors.sanitise(value, limit)](#errorssanitisevalue-limit)
- [errors.Reporter](#errorsreporter)
- [Reporter](#reporter)
  - [reporter:capture(err, req, extra)](#reportercaptureerr-req-extra)
  - [reporter:due()](#reporterdue)
  - [reporter:encode(batch)](#reporterencodebatch)
  - [reporter:event(err, req, extra)](#reportereventerr-req-extra)
  - [reporter:flush()](#reporterflush)
  - [reporter:handler(inner)](#reporterhandlerinner)
  - [reporter:run(controller)](#reporterruncontroller)
  - [reporter:stats()](#reporterstats)
  - [reporter:stop()](#reporterstop)
  - [reporter:tick()](#reportertick)
- [O evento](#o-evento)
- [O documento que vai para a rede](#o-documento-que-vai-para-a-rede)
- [O que nunca chega ao cliente](#o-que-nunca-chega-ao-cliente)
- [O que nunca chega ao destino](#o-que-nunca-chega-ao-destino)
- [Correlação](#correlação)
- [O que não está aqui](#o-que-não-está-aqui)

## errors.new(options)

Constrói um reporter.

| chave | padrão | o que é |
|---|---|---|
| `sink` | — | `function(document, events)`, chamada com o que teria ido no POST |
| `http` | — | uma capability `akkar.http`: um cliente, ou uma fábrica que devolve um |
| `endpoint` | — | a URL do POST; obrigatória junto com `http` |
| `headers` | — | cabeçalhos enviados em todo POST, para um token de API |
| `service` | `"akkar"` | o nome do serviço, em cada evento e no documento |
| `environment` | — | em cada evento quando definido; ausente por completo quando não |
| `max_batch` | `32` | eventos por entrega |
| `max_queue` | `256` | eventos guardados antes que novos sejam recusados |
| `interval` | `5` | segundos entre entregas |
| `timeout` | `2` | segundos que um POST pode levar |
| `max_message` | `512` | bytes de mensagem mantidos |

**Levanta um erro** quando não recebe nem `sink` nem `http`, e quando recebe `http` sem `endpoint`. Isso é deliberado e é o único lugar em que este módulo levanta erro: a construção acontece uma vez, na inicialização, onde um reporter mal configurado ainda é um erro de digitação que alguém pode corrigir. Tudo depois da inicialização conta em vez de levantar, porque a essa altura uma requisição já falhou e o reporter não pode piorar as coisas.

```lua
local akkar  = require "akkar"
local errors = require "akkar.errors"

local kept = {}
local reporter = errors.new {
  service = "checkout",
  sink    = function(document)
    for _, event in ipairs(document.events) do kept[#kept + 1] = event end
  end,
}

local app = akkar.new()
app:on_error(reporter:handler())
app:get("/orders/:id", function() error("no such tenant", 0) end)

local res = app:test():get "/orders/9f2b"

-- O cliente não aprende nada que já não soubesse.
print(res.status, res.body.error)          --> 500  internal server error

-- Nada foi entregue durante a requisição; quem faz isso é o loop.
print(reporter:stats().queued)             --> 1
reporter:flush()

print(kept[1].message)                     --> no such tenant
print(kept[1].method, kept[1].route)       --> GET  /orders/:id
print(kept[1].request_id == res.headers["x-request-id"])   --> true
```

## errors.DEFAULTS

Os padrões que `errors.new` aplica.

| chave | valor |
|---|---|
| `service` | `"akkar"` |
| `max_batch` | `32` |
| `max_queue` | `256` |
| `interval` | `5` |
| `timeout` | `2` |
| `max_message` | `512` |

Os dois limites são menores que os 256 e 2048 do `akkar.trace`, e a razão é o argumento: um span é emitido por requisição e um erro não, então uma fila com 256 erros dentro é um serviço em incidente — e 256 deles descrevem esse incidente exatamente tão bem quanto 2048 descreveriam, enquanto o lote menor faz os primeiros chegarem antes, que é quando alguém está olhando.

## errors.REDACTED

A string `"[redacted]"`, que é como o `akkar.config` também renderiza um segredo. Uma grafia só, tenha o segredo sido pego por construção lá ou por padrão aqui.

## errors.sanitise(value, limit)

A mensagem que vai no evento: uma linha, limitada, sem as credenciais óbvias.

- Tudo a partir de `stack traceback:` é cortado.
- Caracteres de controle e sequências de espaço viram um espaço.
- Uma URL com credenciais perde a senha.
- `chave = valor` e `chave: valor` perdem o valor, para os nomes de chave usuais, em qualquer caixa.
- `Bearer <token>` perde o token.
- O resultado é truncado em `limit` bytes (padrão `512`) sem partir uma sequência UTF-8, e ganha ` [truncated]` quando foi truncado.

Uma tabela é lida em busca de uma string `message`, `error` ou `detail` antes de ser convertida com `tostring`, para que uma tabela levantada não chegue como `table: 0x55f3...` — um endereço que muda a cada execução e que, portanto, agruparia separadamente em qualquer coisa que leia isso.

**A remoção é um piso, não uma garantia.** Ela pega o que um driver ou um cliente HTTP de fato levanta. Não pega um segredo que não parece um segredo; a defesa que não depende de casamento de padrões é o `akkar.config`, cujos segredos se renderizam como `[redacted]` por `__tostring` e `__concat` e por isso nunca chegam a uma mensagem.

```lua
local errors = require "akkar.errors"

print(errors.sanitise "could not connect to postgres://app:hunter2@db:5432/x")
--> could not connect to postgres://app:[redacted]@db:5432/x

print(errors.sanitise 'refused: api_key: k-abc123')
--> refused: api_key: [redacted]

print(errors.sanitise "boom\nstack traceback:\n\t/srv/app/handlers.lua:19")
--> boom

print(errors.sanitise { message = "no such tenant" })
--> no such tenant
```

## errors.Reporter

A metatabela do reporter, exportada para que uma spec possa estendê-la. Ela herda `trace.Batch` — a fila, os dois limites e o loop em segundo plano são uma implementação só, compartilhada com o `akkar.trace`, porque o argumento para cada uma dessas escolhas é o mesmo argumento e escrevê-lo duas vezes é como a segunda cópia sai sutilmente errada.

## Reporter

### reporter:capture(err, req, extra)

Monta o evento e o enfileira. **Devolve** `true` quando foi guardado, `false` quando a fila estava cheia.

É um append. Nenhum socket, nenhuma codificação além do próprio evento, nenhuma decisão que possa demorar — isso roda na corotina da requisição que falhou, e tudo o que faz é tempo que um usuário já está esperando.

`req` pode ser nil: um executor de jobs não tem nenhuma, e o `app:on_error` documenta que a requisição "pode estar ausente para uma falha que aconteceu antes de existir uma". Cada campo de requisição fica então simplesmente ausente, em vez de presente e vazio.

`extra` é mesclado por último e **não pode sobrescrever** um campo que o reporter definiu, para que um `route` passado não vire silenciosamente um caminho cru e um `message` passado não escape do sanitizador.

```lua
local errors = require "akkar.errors"

local seen
local reporter = errors.new { sink = function(d) seen = d.events end }

reporter:capture("the nightly rollup fell over", nil, { job = "rollup" })
reporter:flush()

print(seen[1].message, seen[1].job)   --> the nightly rollup fell over  rollup
print(seen[1].route)                  --> nil
```

### reporter:due()

Se uma entrega está devida, por qualquer um dos limites: `max_batch` eventos na fila, ou `interval` segundos desde a última. **Devolve** `false` para uma fila vazia.

### reporter:encode(batch)

O documento em que um lote se transforma. **Devolve** uma tabela; o `akkar.http` a codifica como JSON.

### reporter:event(err, req, extra)

Monta um evento sem enfileirá-lo. **Devolve** uma tabela simples. Útil para um destino de que este módulo não fala, e para asserções sobre o formato.

### reporter:flush()

Entrega o que está na fila, agora. **Devolve** `true`, ou `nil` e um motivo.

**Não deve ser chamado de um handler nem de um middleware.** Tudo aqui dentro pode esperar por uma rede. Existe para ser chamado por `run`, e por um teste.

Uma entrega que falha **descarta o lote** em vez de tentar de novo. Repetir move o crescimento desta fila para um buffer de retentativas e não compra nada: a requisição que cada evento descreve já foi respondida de um jeito ou de outro.

### reporter:handler(inner)

**Devolve** uma `function(err, req)` para o `app:on_error`.

Ela captura e então devolve `nil` — que o akkar lê como "o gancho recusou", de modo que o cliente recebe o 500 nu embutido, inalterado. Passe `inner` para responder com um corpo seu; ele roda *depois* da captura, e fora de qualquer `pcall` nosso, para que um defeito nele não possa perder o evento e o `internal_error` ainda registre "the error handler itself raised".

```lua
local akkar  = require "akkar"
local errors = require "akkar.errors"

local reporter = errors.new { sink = function() end }

local app = akkar.new()
app:on_error(reporter:handler(function(_, req)
  return akkar.response(500, { instance = req.id })
end))
app:get("/boom", function() error("x", 0) end)

local res = app:test():get "/boom"
print(res.status, res.body.instance == res.headers["x-request-id"])
--> 500  true
```

### reporter:run(controller)

Inicia o loop de entrega em um controlador do cqueues. Chame uma vez, na inicialização, de dentro do loop em que o akkar roda. **Devolve** o reporter.

```lua no-run
app:run {
  port = 3000,
  on_start = function() reporter:run() end,
}
```

**Levanta um erro** quando não há controlador e nenhum foi passado, em vez de silenciosamente nunca entregar nada.

### reporter:stats()

Os contadores. **Devolve** uma tabela.

| chave | o que conta |
|---|---|
| `queued` | eventos esperando agora |
| `recorded` | eventos capturados, incluindo os recusados |
| `dropped` | eventos recusados pelo limite, mais todo evento de um lote que falhou |
| `exported` | eventos entregues |
| `failed` | lotes que não chegaram |
| `batches` | entregas tentadas |

Coloque `dropped` e `failed` em um painel. Descartar é o comportamento correto; descartar *em silêncio* não é, e um operador vendo `dropped` subir sabe que seu tracker está inalcançável, em vez de ter um tracker com buracos e nenhuma ideia do porquê.

### reporter:stop()

Para o loop, depois de uma última entrega.

### reporter:tick()

Entrega se qualquer um dos limites foi atingido. **Devolve** `true` quando entregou. É isso que o loop chama.

## O evento

| chave | presente quando | o que é |
|---|---|---|
| `timestamp` | sempre | segundos desde a epoch, vindos do `akkar.time` |
| `level` | sempre | `"error"` |
| `service` | sempre | o `service` dado ao `errors.new` |
| `message` | sempre | a mensagem sanitizada |
| `status` | sempre | `500`, o status que o akkar está prestes a responder |
| `environment` | quando configurado | o `environment` dado ao `errors.new` |
| `request_id` | com uma requisição | o mesmo id que o cliente recebeu em `x-request-id` |
| `method` | com uma requisição | `"GET"` |
| `route` | uma rota casou | o **padrão**, `/orders/:id` |
| `trace_id` | a requisição carrega um trace | junta com o span e com a linha de log |
| `span_id` | a requisição carrega um trace | o span local, ou o do chamador |

`route` é o padrão e não o caminho, e deliberadamente não há fallback para `req.path` quando nenhuma rota casou. `/orders/9f2b` e `/orders/7c41` são uma operação só; um tracker que agrupa por caminho cru produz um grupo por id de pedido, o que é um tracker que parou de agrupar qualquer coisa. Um fallback traria isso de volta exatamente nos erros mais difíceis de ler.

## O documento que vai para a rede

```lua
local errors = require "akkar.errors"
local json   = require "akkar.json"

local posted
local reporter = errors.new {
  service  = "checkout",
  endpoint = "https://errors.internal/ingest",
  headers  = { authorization = "Token abc" },
  http     = { post = function(_, url, options)
    posted = { url = url, body = options.body }
    return { status = 202 }
  end },
}

reporter:capture "the queue worker gave up"
reporter:flush()

print(posted.url)                       --> https://errors.internal/ingest
print(json.encode(posted.body.service)) --> "checkout"
print(#posted.body.events)              --> 1
```

Um objeto com os eventos em uma lista, em vez de um array cru no topo: `service` pertence ao lote em vez de ser repetido em cada evento, e um documento que já é um objeto pode ganhar um campo depois sem mudar de tipo.

`http` é uma capability `akkar.http` — um cliente ou uma fábrica, o mesmo formato que `app:run { http = ... }` aceita, e não uma URL mais uma biblioteca de sockets. É isso que faz da tabela com um método `post` acima uma dublê legítima da coisa real.

## O que nunca chega ao cliente

O 500 não muda por instalar isto. O `akkar/init.lua` mantém aquele corpo deliberadamente nu — um erro de Lua carrega caminhos de arquivo, números de linha e às vezes SQL — e `reporter:handler()` devolve nil em vez de um corpo precisamente para que continue assim. O id da requisição em `x-request-id` é a junção: o cliente cita, você acha o evento.

## O que nunca chega ao destino

O traceback, nunca. E a mensagem crua: o destino em geral é um terceiro, o texto de uma falha é frequentemente influenciado por quem a causou, e um campo sem limite é ao mesmo tempo um vazamento e uma conta a pagar. Daí o `errors.sanitise`, e daí o `max_message`.

## Correlação

Três cantos da mesma junção, e cada um está em um arquivo diferente:

- `akkar/execution.lua` liga `trace_id` e `span_id` ao `req.log`;
- `akkar/trace.lua` põe `akkar.request_id` no span do servidor;
- este módulo põe `request_id`, `trace_id` e `span_id` no evento.

Assim um evento no tracker leva ao span no Jaeger e às linhas no stderr, em qualquer direção, sem busca por timestamp.

```lua
local akkar  = require "akkar"
local errors = require "akkar.errors"
local trace  = require "akkar.trace"

local event
local reporter = errors.new { sink = function(d) event = d.events[1] end }
local exporter = trace.new { http = { post = function() return { status = 200 } end } }

local app = akkar.new()
app:on_error(reporter:handler())
app:use(exporter:middleware())
app:get("/orders/:id", function() error("boom", 0) end)

app:test():get("/orders/1", {
  headers = { traceparent =
    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" },
})
reporter:flush()

print(event.trace_id)   --> 4bf92f3577b34da6a3ce929d0e0e4736
print(event.route)      --> /orders/:id
```

## O que não está aqui

**O protocolo de envelope do Sentry.** Um envelope delimitado por quebras de linha, tipos de item, uma DSN carregando um id de projeto e uma chave pública, um handshake de cliente — o formato de um fornecedor, no cronograma de lançamento dele, impossível de testar aqui sem uma conta. Um POST JSON genérico chega ao mesmo lugar por um relay e chega a todo o resto diretamente.

**Agrupamento, fingerprinting e deduplicação.** Isso é trabalho do tracker e é a razão de ter um. Isto entrega eventos; não decide quais deles são o mesmo evento.

**Retentativas.** Veja `reporter:flush()`.

**Breadcrumbs e variáveis locais.** Os dois significam carregar estado por uma requisição em benefício de uma falha que em geral não acontece. O `req.log` já anota as interessantes, com o mesmo `trace_id` nelas.
