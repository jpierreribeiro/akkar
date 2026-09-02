# akkar.metrics

> **Português (Brasil)** | [Original em inglês](../../reference/metrics.md)

Um registro Prometheus sem dependência: um contador de requisições, um histograma de latência, gauges e um endpoint `GET /metrics` que os renderiza como texto. As requisições são rotuladas pelo padrão de rota, nunca pelo caminho da requisição.

**Quando você precisa disso.** Algo faz scrape deste processo em busca de uma taxa de requisições, uma taxa de erro e uma distribuição de latência, e você quer que os números venham de dentro do runtime, e não de um proxy na frente dele.

```lua no-run
local metrics = require "akkar.metrics"
```

## Conteúdo

- [metrics.DEFAULT_BUCKETS](#metricsdefault_buckets)
- [metrics.new(options)](#metricsnewoptions)
- [metrics.Registry](#metricsregistry)
- [Registry](#registry)
  - [registry:breaker(name, breaker)](#registrybreakername-breaker)
  - [registry:counter(name, delta, labels)](#registrycountername-delta-labels)
  - [registry:gauge(name, value, labels)](#registrygaugename-value-labels)
  - [registry:memory()](#registrymemory)
  - [registry:middleware()](#registrymiddleware)
  - [registry:observe(method, route, status, seconds)](#registryobservemethod-route-status-seconds)
  - [registry:pool(name, pool)](#registrypoolname-pool)
  - [registry:render()](#registryrender)
  - [registry:serve(app, path, sources)](#registryserveapp-path-sources)
- [O que é exportado](#o-que-é-exportado)
- [O que não está aqui](#o-que-não-está-aqui)

## metrics.DEFAULT_BUCKETS

As bordas dos buckets do histograma, em segundos:
`0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10`.

Escolhidas para uma API que conversa com um banco de dados. Abaixo de um milissegundo é ruído, e depois de 10 segundos uma requisição já bateu no deadline padrão.

## metrics.new(options)

Constrói um registro. Os contadores começam vazios e o relógio de uptime começa agora.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `buckets` | table | `metrics.DEFAULT_BUCKETS` | bordas do histograma em segundos, em ordem crescente |

**Retorna** um registro.

**Levanta** nada.

```lua
local metrics = require "akkar.metrics"

local registry = metrics.new()

registry:observe("GET", "/users/:id", 200, 0.012)
registry:observe("GET", "/users/:id", 404, 0.003)

io.write(registry:render())
```

## metrics.Registry

A metatable que todo registro compartilha. Exportada para um teste que queira identificar um.

## Registry

### registry:breaker(name, breaker)

Registra um [breaker](breaker.md) para ser LIDO a cada scrape, sob o rótulo `breaker="<name>"`. O mesmo contrato de `registry:pool`: o registro mantém uma referência e chama `breaker:stats()` de dentro de `render()`, e o caminho do próprio breaker nunca é tocado.

| argumento | tipo | significado |
|---|---|---|
| `name` | string | o valor do rótulo `breaker`, não vazio |
| `breaker` | breaker | qualquer coisa com um `stats()` que retorne os campos abaixo |

**Retorna** o breaker, para que a chamada encadeie a partir de `breaker.new{...}`.

**Levanta** erro quando `name` não é uma string não vazia, e quando `breaker` não tem um `stats()` para ler, pelo motivo que `registry:pool` levanta.

Cinco séries por breaker:

| métrica | tipo | origem |
|---|---|---|
| `akkar_breaker_state` | gauge | `0` fechado, `1` half-open, `2` aberto |
| `akkar_breaker_trips_total` | counter | vezes que ele abriu |
| `akkar_breaker_refused_total` | counter | chamadas recusadas sem rodar |
| `akkar_breaker_calls_total` | counter | chamadas que rodaram sob ele |
| `akkar_breaker_failures_total` | counter | chamadas que rodaram e falharam |

`state` é um número para que um alerta possa ser `akkar_breaker_state > 0`. Dois breakers registrados sob um mesmo nome somam seus contadores e reportam o PIOR estado em vez de uma soma que não significa nada; o rótulo é limitado a 64 nomes do jeito que `pool` é.

```lua
local metrics = require "akkar.metrics"
local breaker = require "akkar.breaker"

local registry = metrics.new()
local b = registry:breaker("payments", breaker.new { threshold = 1 })
b:call(function() return nil, "down" end)

local text = registry:render()
print((text:match "akkar_breaker_state{[^\n]*"))   --> akkar_breaker_state{breaker="payments"} 2
assert(text:find('akkar_breaker_trips_total{breaker="payments"} 1', 1, true))
```

### registry:counter(name, delta, labels)

Incrementa um contador da aplicação, criando-o em zero no primeiro uso. `delta` tem padrão `1` e pode ser fracionário; `labels` é uma lista de pares `{ name, value }`, na ordem em que devem ser renderizados.

`name` é usado literalmente como o nome da métrica no Prometheus, então já precisa ser um nome válido. Nada aqui prefixa com `akkar_`.

**Retorna** o novo valor.

**Levanta** erro quando `name` não é um nome de métrica Prometheus válido, quando `delta` não é um número não negativo, e quando um nome de rótulo não é um nome de rótulo Prometheus válido. Cada caso é um erro no ponto de chamada, corrigido de uma vez.

NÃO levanta erro quando um nome de contador acumula combinações demais de rótulos distintos. Depois de 64 combinações, toda combinação adicional se dobra em uma única série cujos valores de rótulo são `<other>` — a mesma resposta que `registry:middleware()` dá para um método que não reconhece, e pelo mesmo motivo. O total permanece correto e o detalhamento para de crescer.

Esse limite existe porque este é o único lugar do módulo em que os valores de rótulo são seus, e não do akkar. O rótulo `route` é limitado porque o akkar sabe o padrão que deu match; um contador rotulado com um id de pedido é uma série por pedido, que é como um backend de métricas quebra. Dobrar em vez de levantar erro é proposital: um contador não pode ter o poder de falhar a requisição que está medindo.

```lua
local metrics = require "akkar.metrics"

local registry = metrics.new()

registry:counter("commerce_checkouts_total", 1, { { "result", "created" } })
registry:counter("commerce_checkouts_total", 2, { { "result", "created" } })
registry:counter("commerce_checkouts_total", 1, { { "result", "declined" } })
registry:counter("commerce_retries_total")            -- sem rótulos, delta 1

local text = registry:render()
assert(text:find('commerce_checkouts_total{result="created"} 3', 1, true))
assert(text:find("\ncommerce_retries_total 1\n", 1, true))
```

### registry:gauge(name, value, labels)

Define um gauge, para um número que é lido em vez de contado: ocupação de pool, profundidade de fila, requisições em andamento. Definir o mesmo nome de novo substitui o valor.

`name` é usado literalmente como o nome da métrica no Prometheus, então já precisa ser um nome válido. Nada aqui prefixa com `akkar_`.

`labels` é uma lista de pares `{ name, value }`, na ordem em que devem ser renderizados, exatamente como `registry:counter` os recebe. Antes, levantava erro em toda chamada — a chave de armazenamento era construída concatenando os argumentos, e uma table não pode ser concatenada — então um ramo inteiro e documentado ficava inalcançável em um módulo testado. Agora funciona.

Nada limita os valores de rótulo de um gauge. `registry:counter` dobra depois de 64 combinações porque um contador é incrementado a partir de um handler; um gauge é definido a partir de um scrape, onde os valores são seus e poucos. Definir um por id de cliente ainda é o erro que sempre foi.

**Retorna** nada.

**Levanta** nada.

```lua
local metrics = require "akkar.metrics"

local registry = metrics.new()

registry:gauge("akkar_pool_in_use", 3)
registry:gauge("akkar_pool_in_use", 4)   -- mesmo nome, substituído
registry:gauge("queue_depth", 12, { { "queue", "emails" } })

local text = registry:render()
assert(text:find("\nakkar_pool_in_use 4\n", 1, true))
assert(text:find('queue_depth{queue="emails"} 12', 1, true))

local lua_bytes, rss_bytes = registry:memory()
print(lua_bytes > 0, rss_bytes >= 0)     --> true  true
```

### registry:memory()

Dois números de memória, porque respondem perguntas diferentes. O heap do próprio Lua diz se a aplicação está retendo tables; o resident set diz o que o sistema operacional acha que o processo custa, incluindo o lado C.

**Retorna** `lua_bytes, rss_bytes`, ambos números. `rss_bytes` é `0` quando `/proc/self/statm` não pode ser lido.

### registry:middleware()

Middleware que registra cada requisição neste registro.

O rótulo de rota é `req.route`, o padrão que deu match, então o conjunto de rótulos permanece limitado por mais caminhos distintos que sejam requisitados. Uma requisição que não deu match em nenhuma rota é registrada como `<unmatched>` em vez de pelo seu caminho.

O rótulo de método é limitado da mesma forma, e precisava ser: `req.method` é qualquer token que o cliente colocar na linha da requisição, então ia direto para um rótulo, e um chamador enviando um verbo novo a cada requisição cunhava uma série nova a cada requisição. Limitar só um dos dois rótulos não limita nada. Qualquer coisa fora dos nove métodos HTTP — `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`, `TRACE`, `CONNECT` — é registrada como `<other>`.

Ambos os desfechos são registrados. Um handler que retorna dá o status da sua resposta; um handler que lança (throw) uma resposta dá o status dessa resposta; um erro levantado é registrado como `500`, e então relançado sem alteração.

**Retorna** uma função middleware, para `app:use`.

### registry:observe(method, route, status, seconds)

Registra uma requisição manualmente. `registry:middleware()` chama isso; chame você mesmo para trabalho que não é uma requisição HTTP mas pertence ao mesmo histograma.

| argumento | tipo | significado |
|---|---|---|
| `method` | string | o rótulo `method` |
| `route` | string | o rótulo `route`. Um padrão, não um caminho. |
| `status` | number ou string | o rótulo `status`, convertido em string |
| `seconds` | number | duração, somada ao histograma e ao seu total |

**Retorna** nada.

### registry:pool(name, pool)

Registra um pool de conexões para ser LIDO a cada scrape, sob o rótulo `pool="<name>"`. O registro mantém uma referência e chama `pool:stats()` de dentro de `render()`.

| argumento | tipo | significado |
|---|---|---|
| `name` | string | o valor do rótulo `pool`, não vazio |
| `pool` | pool | qualquer coisa com um `stats()` que retorne os campos abaixo |

**Retorna** o pool, para que a chamada encadeie a partir de `db.connect{...}.pool`.

**Levanta** erro quando `name` não é uma string não vazia, e quando `pool` não tem um `stats()` para ler. Registrar um pool acontece uma vez no boot, então ambos são falhas de inicialização que o autor vê imediatamente, em vez de um 500 depois.

Nove séries por pool, cada uma um campo de `Pool:stats()`:

| métrica | tipo | origem |
|---|---|---|
| `akkar_pool_size` | gauge | slots que o pool pode preencher |
| `akkar_pool_connections` | gauge | conexões que existem agora |
| `akkar_pool_idle` | gauge | conexões no conjunto ocioso |
| `akkar_pool_reserved` | gauge | slots mantidos por um open ainda em andamento |
| `akkar_pool_waits_total` | counter | checkouts que precisaram entrar em fila |
| `akkar_pool_wait_seconds_total` | counter | segundos gastos em fila |
| `akkar_pool_wait_seconds_max` | gauge | maior espera única até agora |
| `akkar_pool_retired_total` | counter | conexões fechadas por idade |
| `akkar_pool_reaped_total` | counter | slots recuperados de um open abandonado |

Lido, não empurrado (pushed), e não amostrado. Empurrar significaria uma chamada de métrica em `Pool:get`, que é um caminho quente medido com um teto de alocação, e tornaria um pool não mensurável exceto por um processo segurando um registro. Amostrar em um timer seria pior: uma espera é uma medição do escalonador em execução, então um amostrador é mais uma coisa nesse escalonador lendo enquanto os números mudam, e continua lendo em um processo ocioso que ninguém está fazendo scrape.

O rótulo `pool` é limitado da mesma forma que os rótulos de um contador da aplicação: depois de 64 nomes distintos, todo pool adicional se dobra em `pool="<other>"`, e pools dobrados são somados ali em vez de se sobrescreverem. Dois pools registrados sob um mesmo nome se somam pelo mesmo motivo. Um pool cujo `stats()` levanta erro é ignorado e não falha o scrape.

Cada processo tem seu próprio pool e seu próprio registro, então um scrape é os números de um processo. Somar entre eles é trabalho do scraper, como é para toda outra métrica aqui.

```lua
local metrics = require "akkar.metrics"
local Pool    = require "akkar.pool"

local registry = metrics.new()
local pool     = Pool.new(function() return { open = true } end, 10)

registry:pool("db", pool)

local text = registry:render()
print((text:match "akkar_pool_size{[^\n]*"))         --> akkar_pool_size{pool="db"} 10
assert(text:find('akkar_pool_waits_total{pool="db"} 0', 1, true))
```

Com um pool de verdade é `registry:pool("db", db.connect({ ... }).pool)`, e o mesmo valor `db.connect` vai para `app:run { db = ... }`.

### registry:render()

O registro inteiro em formato texto Prometheus, terminando com uma quebra de linha. As séries são ordenadas, então dois scrapes de um estado inalterado produzem texto idêntico.

Sempre presente:

| métrica | tipo | rótulos |
|---|---|---|
| `akkar_requests_total` | counter | `method`, `route`, `status` |
| `akkar_request_duration_seconds_bucket` | histogram | `method`, `route`, `le` |
| `akkar_request_duration_seconds_sum` | histogram | `method`, `route` |
| `akkar_request_duration_seconds_count` | histogram | `method`, `route` |
| `akkar_uptime_seconds` | gauge | nenhum |

Contadores e gauges são renderizados só quando pelo menos um foi definido, cada um com uma linha `# TYPE` escrita uma vez por nome. Todo pool registrado com `registry:pool`, e todo breaker registrado com `registry:breaker`, é LIDO aqui, no momento do render, e contribui com as famílias listadas naquele método, agrupadas por nome de métrica — o formato de exposição exige que toda amostra de uma família fique contígua.

Um inteiro é renderizado puro; qualquer coisa fracionária é renderizada com seis casas decimais, para que uma espera abaixo de um milissegundo não saia no scrape em notação científica do Lua.

**Retorna** uma string.

### registry:serve(app, path, sources)

Registra `GET <path>` em `app`, respondendo com o registro renderizado como `text/plain; version=0.0.4`.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `app` | app | nenhum, obrigatório | o app no qual registrar |
| `path` | string | `"/metrics"` | onde o endpoint fica |
| `sources` | table | `{}` | nome de gauge para uma função que retorna um número, lida no momento do scrape |

Dois gauges são sempre definidos no momento do scrape: `akkar_lua_heap_bytes` e `akkar_process_resident_bytes`. Uma fonte que levanta erro, ou retorna algo que não é um número, é ignorada e não falha o scrape.

O endpoint é uma rota comum, então qualquer middleware instalado antes dele se aplica a ele. Isente-o de um limitador de taxa se você instalar um.

**Retorna** o app, para que a chamada encadeie.

```lua
local akkar   = require "akkar"
local metrics = require "akkar.metrics"

local app      = akkar.new()
local registry = metrics.new()

app:use(registry:middleware())
app:get("/users/:id", function(req) return { id = req.params.id } end)
registry:serve(app, "/metrics", { queue_depth = function() return 3 end })

local client = app:test {}
client:get "/users/42"
client:get "/users/43"

local scrape = client:get "/metrics"
print(scrape.status)                                       --> 200
print((scrape.raw:match "akkar_requests_total{[^\n]*"))
print((scrape.raw:match "\nqueue_depth (%S+)"))            --> 3
```

O corpo do scrape é `scrape.raw`, não `scrape.body`: o endpoint responde com uma string bruta em vez de uma table. O content type está no objeto de resposta e o cliente de teste em processo não o expõe em `headers`.

## O que é exportado

`metrics.new`, `metrics.Registry` e `metrics.DEFAULT_BUCKETS`, e os métodos acima. Não há contador em nível de módulo nem registro global: um registro é um valor que você mantém.

## O que não está aqui

- **Summaries e quantis.** Eles não podem ser agregados entre processos, e a resposta deste runtime para mais CPU é mais processos.
- **Um espaço de rótulos ilimitado.** `registry:counter` recebe rótulos com nomes seus, e para em 64 combinações por nome de contador. `registry:pool` para em 64 nomes de pool da mesma forma. Veja acima o motivo.
- **Push.** Nada é enviado a lugar nenhum. Algo faz scrape do endpoint.
- **Amostragem.** Nada lê um pool em um timer. `registry:pool` lê dentro de `render()`, então um processo sem scrape não paga nada e um scrape nunca lê um número que algum amostrador pegou em outro momento.
- **Agregação entre processos.** Cada processo tem seu próprio registro e seu próprio uptime. Somá-los é trabalho do scraper.

## Veja também

- [akkar](akkar.md) para `app:use`, `req.route` e `app:test{}`
- [akkar.trace](trace.md) para spans por requisição, que respondem "por que essa foi lenta" onde um histograma responde "quantas foram"
- o código-fonte do módulo, `akkar/metrics.lua`, para entender por que o padrão de rota é o rótulo e o caminho não é
