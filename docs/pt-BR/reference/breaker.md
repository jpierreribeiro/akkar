# akkar.breaker

> **Português (Brasil)** | [Original em inglês](../../reference/breaker.md)

Um circuit breaker: depois de falhas suficientes contra uma dependência, as chamadas a ela são recusadas na hora em vez de feitas, até que um cooldown tenha passado e uma sonda (probe) tenha mostrado que ela voltou.

**Quando você precisa disso.** Quando um serviço que você chama está fora do ar e cada requisição que chega a você ainda o disca. O deadline limita o que *uma* chamada dessas custa; ele não impede que as próximas mil paguem esse custo cada uma. Um breaker impede.

```lua no-run
local breaker = require "akkar.breaker"
```

Só essa grafia. `akkar.breaker` não é reexportado a partir do módulo de topo.

## Sumário

- [breaker.new(options)](#breakernewoptions)
- [breaker.is(value)](#breakerisvalue)
- [breaker.OPEN](#breakeropen)
- [breaker.STATE_CODE](#breakerstate_code)
- [Breaker](#breaker)
- [Com akkar.http](#com-akkarhttp)
- [Com akkar.metrics](#com-akkarmetrics)

## breaker.new(options)

Constrói um breaker no estado `closed`.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `threshold` | number | obrigatório | sem `window`: falhas consecutivas que o abrem; com `window`: a razão de falhas em `(0, 1]` que o abre |
| `window` | number | nenhum | segundos sobre os quais a razão é medida; sua presença seleciona a política de amostragem |
| `minimum` | number | `10` | só na amostragem: chamadas que precisam estar na janela antes de a razão ser julgada |
| `cooldown` | number | `30` | segundos passados em `open` antes de sondas serem permitidas |
| `half_open_max` | number | `1` | sondas emitidas por período half-open; todas precisam ter sucesso para fechar |
| `is_failure` | function | `first == nil` | chamada com os resultados de uma chamada; `true` significa que ela falhou |
| `on_change` | function | nenhum | `on_change(breaker, from, to)` a cada transição; um erro dentro dela é engolido |
| `buckets` | number | `10` | só na amostragem: fatias fixas em que a janela é dividida |

Duas políticas, selecionadas por `window` ter sido dado ou não. **Consecutiva** abre em `threshold` falhas seguidas; um sucesso zera a sequência. **Amostragem** abre quando `failures / calls` nos últimos `window` segundos alcança `threshold`, uma vez que pelo menos `minimum` chamadas foram vistas — então uma dependência que responde uma chamada em três ainda dispara, onde uma contagem consecutiva seria zerada por cada sucesso.

Uma chamada **falha** quando levanta erro, ou quando `is_failure` diz que sim. O padrão é a convenção dos adapters: um primeiro resultado `nil` é uma falha. Substitua-o quando `nil` significar algo que a dependência fez de propósito — uma consulta que responde `nil, "not found"` é a dependência funcionando, e uma sequência de ausências não pode abrir o breaker contra ela.

**Retorna** um [Breaker](#breaker).

**Levanta** erro com um `threshold` ausente ou não positivo, um `threshold` fracionário sem `window`, um `threshold` acima de `1` com um, um `cooldown` ou `window` não positivo, um `half_open_max` abaixo de `1`, ou um `is_failure` que não é uma função.

```lua
local breaker = require "akkar.breaker"
local time    = require "akkar.time"

local clock = time.manual()
local restore = time.set(clock)

local b = breaker.new { threshold = 3, cooldown = 30 }

local function down() return nil, "connection refused" end
for _ = 1, 3 do b:call(down) end
print(b:current())                           --> open

print(b:call(down))                          --> nil   breaker open

clock:advance(30)                            -- o cooldown, sem esperar
print(b:current())                           --> half_open

print(b:call(function() return "hello" end)) --> hello
print(b:current())                           --> closed

restore()
```

A política de amostragem:

```lua
local breaker = require "akkar.breaker"

-- Abre quando metade das chamadas do último minuto falhou, julgado só depois
-- que dez chamadas foram vistas.
local b = breaker.new { threshold = 0.5, window = 60, minimum = 10 }

for _ = 1, 10 do
  b:call(function() return nil, "timed out" end)
  b:call(function() return "ok" end)
end
print(b:current())                           --> open
```

## breaker.is(value)

**Retorna** `true` quando `value` veio de `breaker.new`. `akkar.http` usa isso para distinguir uma instância que deve compartilhar de uma tabela de opções a partir da qual deve construir um breaker por origem.

```lua
local breaker = require "akkar.breaker"
print(breaker.is(breaker.new { threshold = 1 }))   --> true
print(breaker.is({ threshold = 1 }))               --> false
```

## breaker.OPEN

A string `"breaker open"`, que toda chamada recusada retorna como motivo. Compare com a constante em vez de com a grafia.

```lua
local breaker = require "akkar.breaker"
local b = breaker.new { threshold = 1 }
b:call(function() return nil, "x" end)
local res, why = b:call(function() return "never" end)
print(res, why == breaker.OPEN)              --> nil   true
```

## breaker.STATE_CODE

`{ closed = 0, half_open = 1, open = 2 }`, os números que `stats().state` e o gauge `akkar_breaker_state` carregam. Um alerta é `akkar_breaker_state > 0`.

## Breaker

O que `breaker.new` retorna. Todo método é chamado com dois-pontos.

### b:allow()

Se uma chamada pode rodar agora, aplicando qualquer transição que o relógio tenha causado. Em `half_open` isso **reserva** uma sonda.

**Retorna** `true`, ou `nil, "breaker open"`.

**Levanta** nada.

Use isto com `b:success()` e `b:failure()` quando a coisa sob o breaker não cabe em uma função — `akkar.http` faz isso, porque decide que um `5xx` é uma falha depois da troca. Caso contrário use `b:call`.

### b:call(fn, ...)

Roda `fn(...)` se o breaker permitir e reporta o resultado.

**Retorna** tudo o que `fn` retornou, ou `nil, "breaker open"` sem chamar `fn`.

**Levanta** o que quer que `fn` tenha levantado, depois de contar como falha. O breaker observa erros; ele não os engole.

### b:current()

**Retorna** `"closed"`, `"open"` ou `"half_open"`, depois de aplicar qualquer transição que o relógio tenha causado. Leia isto, não leia `b.state`.

### b:failure()

Reporta que uma chamada que `b:allow()` deixou passar falhou. Em `half_open` isso abre o breaker de novo e rearma o cooldown.

### b:reset()

Fecha o breaker e esquece as falhas por trás do disparo.

### b:stats()

**Retorna** `{ state = code, trips = n, refused = n, calls = n, failures = n, successes = n }`. `state` é um [STATE_CODE](#breakerstate_code); `trips` conta cada entrada em `open`; `refused` conta chamadas que nunca rodaram; o resto conta chamadas que rodaram.

### b:success()

Reporta que uma chamada que `b:allow()` deixou passar teve sucesso. Em `half_open` o breaker fecha quando `half_open_max` sondas tiveram sucesso.

### b:trip()

Mantém o breaker `open` até `b:reset()`, faça o relógio o que fizer. Para uma dependência que um operador sabe que está fora do ar ou que está prestes a derrubar.

```lua
local breaker = require "akkar.breaker"
local time    = require "akkar.time"
local clock = time.manual()
local restore = time.set(clock)

local b = breaker.new { threshold = 1, cooldown = 10 }
b:trip()
clock:advance(3600)
print(b:current())                           --> open
b:reset()
print(b:current())                           --> closed
restore()
```

## Uma sonda que nunca reporta

Uma sonda é uma chamada deixada passar em `half_open`. Se a corrotina que a roda for abandonada — o deadline da execução disparou enquanto ela esperava no socket — o veredito nunca chega. O breaker não espera por ele: depois de mais um `cooldown` sem veredito, as sondas são emitidas de novo.

## Com akkar.http

`http.connect { breaker = ... }` consulta o breaker **antes de discar**. Uma recusa não abre conexão, não ocupa slot do pool e não gasta nada do orçamento da execução. Um `5xx` ou um erro de transporte é uma falha; um `4xx` é a dependência funcionando.

| valor de `breaker` | o que faz |
|---|---|
| uma tabela de opções de `breaker.new` | um breaker **por origem**, construído no primeiro uso, chaveado como os pools são (`scheme://host:port`) |
| uma instância de breaker | um breaker compartilhado por toda origem com que o client conversa |

Uma requisição recusada retorna `nil, "breaker open"` imediatamente: não há retentativa nem backoff dormido, porque o cooldown é medido em segundos e o orçamento da requisição não é. Os breakers aparecem em `client:stats().breakers`, por origem, ou sob `"*"` para uma instância compartilhada.

```lua
local http    = require "akkar.http"
local breaker = require "akkar.breaker"

local per_origin = http.connect {
  timeout = 2,
  breaker = { threshold = 5, cooldown = 30 },
}
local shared = http.connect {
  timeout = 2,
  breaker = breaker.new { threshold = 0.5, window = 60 },
}
print(per_origin ~= shared)                  --> true
```

## Com akkar.metrics

`registry:breaker(name, b)` lê `b:stats()` a cada scrape, do jeito que `registry:pool` lê um pool. Nada é empurrado a partir do caminho do próprio breaker.

```lua
local breaker = require "akkar.breaker"
local metrics = require "akkar.metrics"

local registry = metrics.new()
local b = registry:breaker("payments", breaker.new { threshold = 1 })
b:call(function() return nil, "down" end)
b:call(function() return "never runs" end)

local text = registry:render()
print(text:match 'akkar_breaker_state{breaker="payments"} %d')
--> akkar_breaker_state{breaker="payments"} 2
print(text:match 'akkar_breaker_refused_total{breaker="payments"} %d')
--> akkar_breaker_refused_total{breaker="payments"} 1
```

As séries são `akkar_breaker_state` (gauge), `akkar_breaker_trips_total`, `akkar_breaker_refused_total`, `akkar_breaker_calls_total` e `akkar_breaker_failures_total` (counters), rotuladas `breaker="<name>"`. Dois breakers sob um mesmo nome somam seus contadores e reportam o pior estado.

## O que não está aqui

- **Um timeout.** O deadline já é um, e ele se propaga: `execution.bounded` dá a uma chamada de saída o que quer que a execução ainda tenha. Uma chamada que o breaker deixa passar é limitada como sempre; o breaker não acrescenta nada a isso e não tira nada disso.
- **Um bulkhead.** `akkar.limit.concurrent` limita chamadas em andamento.
- **Um retry genérico.** `akkar.http` retenta o que é seguro retentar, e `akkar.jobs` retenta com backoff. Componha-os do jeito que `akkar.http` faz: retries por fora, o breaker por dentro, para que uma retentativa depois do disparo seja recusada sem discar.
- **Um breaker compartilhado entre processos.** O estado é por processo. Cada worker descobre uma dependência morta por conta própria, `threshold` chamadas de cada vez; é a mesma escolha que `akkar.limit.shed` faz pelo mesmo motivo.
- **Um timer de `closed`/`open`.** Nada roda em agenda. O estado é resolvido quando a próxima chamada pergunta, lendo `akkar.time`.

## Veja também

- [http](http.md) para o campo `breaker` de `http.connect`
- [metrics](metrics.md) para `registry:breaker`
- [time](time.md), cujo relógio manual é o que torna o cooldown provável
- o código-fonte do módulo, `akkar/breaker.lua`, para o motivo de o teste de falha ser configurável e de uma sonda abandonada não conseguir travar o breaker
