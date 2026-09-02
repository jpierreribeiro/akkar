# akkar.limit

> **Português (Brasil)** | [Original em inglês](../../reference/limit.md)

Três middlewares que recusam trabalho em vez de enfileirá-lo: um token bucket em requisições por segundo, um teto de requisições simultâneas em andamento e um shedder que descarta trabalho de baixa prioridade quando o processo está sobrecarregado.

**Quando você precisa disso.** Quando um chamador pode enviar mais do que o serviço consegue atender, e a resposta deveria ser um `429` imediato em vez de um `200` lento para todo mundo.

```lua no-run
local limit = require "akkar.limit"
```

`akkar.limit` é essa mesma tabela do módulo, então `akkar.limit.rate` e `require("akkar.limit").rate` são a mesma função.

## Sumário

- [limit.concurrent(options)](#limitconcurrentoptions)
- [limit.CONCURRENT_SCRIPT](#limitconcurrent_script)
- [limit.rate(options)](#limitrateoptions)
- [limit.RATE_SCRIPT](#limitrate_script)
- [limit.scriptable(cache)](#limitscriptablecache)
- [limit.shared(cache)](#limitsharedcache)
- [limit.shed(options)](#limitshedoptions)
- [limit.store_failures](#limitstore_failures)
- [Qual chamador é contado](#qual-chamador-é-contado)
- [Quando o store falha](#quando-o-store-falha)
- [Cabeçalhos de resposta](#cabeçalhos-de-resposta)

## limit.concurrent(options)

Middleware que limita quantas requisições (request) um chamador pode ter **em andamento** ao mesmo tempo. Um slot é ocupado antes de o handler rodar e devolvido em toda saída, inclusive um erro lançado. Numa resposta (response) em streaming, o slot fica retido até o último byte ser produzido.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `limit` | number | `10` | slots que um chamador pode manter ao mesmo tempo |
| `ttl` | number | `30` | segundos que um slot pode ficar retido antes de ser varrido |
| `prefix` | string | `"akkar:concurrent:"` | prefixado à chave |
| `name` | string | suas próprias configurações | identifica o bucket deste limitador; dois limitadores configurados da mesma forma precisam de um |
| `namespace` | string ou function | nenhum | `namespace(req)` retorna o tenant ao qual essa chave pertence |
| `key` | function | veja abaixo | `key(req)` retorna a string a ser contada |
| `cache` | cache | `req.cache` | o store onde contar |
| `on_error` | `"open"` ou `"closed"` | `"open"` | o que fazer quando o store não consegue responder |
| `retry_after_ms` | number | `1000` | o valor de `retry-after` numa recusa |
| `on_store_error` | function | nenhum | `on_store_error(err, req)` numa chamada ao store que falhou |

Uma recusa é `429` com corpo `{ error = "too many requests", retry_after = 1 }` e um cabeçalho `retry-after`. Sem cabeçalhos `ratelimit-*`: um slot de concorrência volta quando uma das próprias requisições desse chamador termina, o que não é um número que esse middleware consiga prever.

`ttl` é o backstop para um slot que nunca é liberado, que é o que uma requisição abandonada deixa para trás. Entradas mais velhas que `ttl` são descartadas a cada aquisição, então uma liberação perdida custa um slot por um `ttl`, e não pela vida inteira do processo.

**Retorna** middleware.

**Levanta erro** em tempo de requisição, não na construção, quando não há store nenhum:

```
akkar.limit.concurrent has no cache to count in: pass `cache = ...` to
app:run{} (or `cache = ...` in the limiter's own options). A limiter with no
store cannot limit anything, and quietly allowing every request would hide that.
```

```lua
local akkar  = require "akkar"
local limit  = require "akkar.limit"
local memory = require "akkar.cache.memory"

local app = akkar.new()
app:use(limit.concurrent { limit = 1, key = function() return "one" end })

local client
app:get("/outer", function()
  -- Still inside /outer's handler, so this second request is the same
  -- caller's second slot.
  return { inner = client:get("/inner").status }
end)
app:get("/inner", function() return { ok = true } end)

client = app:test { cache = memory.new() }

local res = client:get "/outer"
assert(res.status == 200)
assert(res.body.inner == 429)          -- the slot was already held

-- The slot came back, so a later request is served.
assert(client:get("/inner").status == 200)
```

## limit.CONCURRENT_SCRIPT

O script Lua do Redis que `limit.concurrent` executa, como string. Exportado para que um teste possa fazer asserções sobre ele. Lê-lo não faz parte do uso normal do módulo.

```lua
local limit = require "akkar.limit"
assert(type(limit.CONCURRENT_SCRIPT) == "string")
```

## limit.rate(options)

Middleware que mede requisições por segundo com um token bucket. Um chamador pode fazer uma sequência de `burst` requisições e, depois disso, recebe `per_second` por segundo, pelo tempo que quiser.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `per_second` | number | `10` | tokens adicionados ao bucket a cada segundo |
| `burst` | number | `per_second` | capacidade do bucket, a maior sequência permitida |
| `cost` | number | `1` | tokens que uma requisição consome |
| `prefix` | string | `"akkar:rate:"` | prefixado à chave |
| `name` | string | suas próprias configurações | identifica o bucket deste limitador; dois limitadores configurados da mesma forma precisam de um |
| `namespace` | string ou function | nenhum | `namespace(req)` retorna o tenant ao qual essa chave pertence |
| `key` | function | veja abaixo | `key(req)` retorna a string a ser contada |
| `cache` | cache | `req.cache` | o store onde contar |
| `on_error` | `"open"` ou `"closed"` | `"open"` | o que fazer quando o store não consegue responder |
| `headers` | boolean | `true` | envia os cabeçalhos `ratelimit-*`; `false` os suprime |
| `exempt` | lista ou `false` | `{ "/health", "/healthz", "/livez", "/readyz" }` | prefixos de caminho que pulam o limitador completamente |
| `on_store_error` | function | nenhum | `on_store_error(err, req)` numa chamada ao store que falhou |

`exempt` é uma comparação por prefixo, verificada antes de o store ser tocado, então um caminho isento não custa uma ida e volta. `exempt = false` desliga a isenção e conta as sondas de saúde como qualquer outra coisa. Uma lista substitui o padrão em vez de somar a ele.

Uma recusa é `429` com corpo `{ error = "too many requests", retry_after = N }`, um cabeçalho `retry-after` e os cabeçalhos de cota, a menos que `headers = false`.

**Retorna** middleware.

**Levanta erro** em tempo de requisição, não na construção, quando não há store nenhum:

```
akkar.limit.rate has no cache to count in: pass `cache = ...` to app:run{}
(or `cache = ...` in the limiter's own options). A limiter with no store cannot
limit anything, and quietly allowing every request would hide that.
```

```lua
local akkar  = require "akkar"
local limit  = require "akkar.limit"
local memory = require "akkar.cache.memory"

local app = akkar.new()
app:use(limit.rate {
  per_second = 1,
  burst      = 2,
  key        = function() return "one-caller" end,
})
app:get("/tasks", function() return { ok = true } end)
app:get("/health/live", function() return { ok = true } end)

local client = app:test { cache = memory.new() }

local first = client:get "/tasks"
assert(first.status == 200)
assert(first.headers["ratelimit-limit"] == "2")
assert(first.headers["ratelimit-remaining"] == "1")

assert(client:get("/tasks").status == 200)    -- the burst is spent

local refused = client:get "/tasks"
assert(refused.status == 429)
assert(refused.body.error == "too many requests")
assert(refused.headers["retry-after"] == "1")

-- Health probes are exempt by default, so an orchestrator is never refused.
for _ = 1, 5 do
  assert(client:get("/health/live").status == 200)
end
```

## limit.RATE_SCRIPT

O script Lua do Redis que `limit.rate` executa, como string. Exportado para que um teste possa fazer asserções sobre ele. Lê-lo não faz parte do uso normal do módulo.

Os timestamps dentro dele vêm do `TIME` do Redis, não do chamador, então um cliente com o relógio errado não consegue mover a janela.

```lua
local limit = require "akkar.limit"
assert(type(limit.RATE_SCRIPT) == "string")
```

## limit.scriptable(cache)

Se o store consegue executar um script Lua. Implementado enviando `EVAL "return 1" 0` dentro de um `pcall`.

**Retorna** `true` ou `false`.

**Levanta erro** nunca. Um argumento `nil` retorna `false`.

Essa **não** é a pergunta a fazer antes de acreditar que um limite é de fato um limite. `akkar.cache.memory` responde `true` aqui e ainda assim é por processo. Use `limit.shared`.

```lua
local limit  = require "akkar.limit"
local memory = require "akkar.cache.memory"

assert(limit.scriptable(memory.new()) == true)
assert(limit.scriptable(nil) == false)
```

## limit.shared(cache)

Se o store é compartilhado por todo processo que fala com ele. `false` para `nil`, `false` para qualquer store que declare `per_process`, e caso contrário o que `limit.scriptable` disser.

**Retorna** `true` ou `false`.

**Levanta erro** nunca.

Com um store por processo, uma frota de seis processos aplica seis vezes o limite configurado. Isso é um padrão de desenvolvimento útil e não é limitação de taxa.

```lua
local limit  = require "akkar.limit"
local memory = require "akkar.cache.memory"
local redis  = require "akkar.redis"

assert(limit.shared(nil) == false)
assert(limit.shared(memory.new()) == false)   -- counts inside one process

local cache = redis.connect { host = "127.0.0.1", port = 6379 } ()
assert(limit.shared(cache) == true)           -- counts in one place for everybody
cache:close()
```

Contra um Redis de verdade, o mesmo limitador é um limite de verdade. Note o `prefix`, que é como as chaves são nomeadas:

```lua
local akkar = require "akkar"
local limit = require "akkar.limit"
local redis = require "akkar.redis"

local cache = redis.connect { host = "127.0.0.1", port = 6379 } ()

local app = akkar.new()
app:use(limit.rate {
  per_second = 1,
  burst      = 2,
  prefix     = "ref_limit_",
  key        = function() return "demo" end,
})
app:get("/tasks", function() return { ok = true } end)

local client = app:test { cache = cache }
assert(client:get("/tasks").status == 200)
assert(client:get("/tasks").status == 200)
assert(client:get("/tasks").status == 429)

cache:del "ref_limit_demo"
assert(cache:get "ref_limit_demo" == nil)
cache:close()
```

## limit.shed(options)

Middleware que recusa requisições não críticas quando o processo está mais ocupado do que uma fração de sua capacidade. Ele lê `app.in_flight` e nunca toca no store.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `app` | application | obrigatório a menos que `capacity` seja informado | lido para obter `in_flight` e `max_concurrent` |
| `capacity` | number | de `app.max_concurrent` | o número do qual `ceiling` é uma fração |
| `ceiling` | number | `0.8` | descarta acima dessa fração de `capacity` |
| `critical` | function | sempre false | `critical(req)` retorna true para trabalho que nunca é descartado |
| `retry_after_ms` | number | `1000` | o valor de `retry-after` numa recusa |

Uma recusa é `429` com corpo `{ error = "too many requests", retry_after = 1 }` e um cabeçalho `retry-after`. A condição é `in_flight > capacity * ceiling and not critical(req)`.

`app.in_flight` é mantido por `app:run`. Sob `app:test{}` ele nunca é definido, então um shedder que recebe uma app de verdade não descarta nada num teste.

**Retorna** middleware.

**Levanta erro** na construção, quando nem `app` nem `capacity` são informados:

```
akkar.limit.shed needs `app = app`, so it can read the in-flight count and the
concurrency ceiling, or an explicit `capacity`. With neither it can never shed.
```

Quando uma capacidade não pode ser deduzida em tempo de requisição, ele registra um aviso pelo `req.log` e deixa toda requisição passar.

```lua
local akkar = require "akkar"
local limit = require "akkar.limit"

local app = akkar.new()
app:use(limit.shed {
  -- A real application passes `app = app`; this stand-in fixes the
  -- in-flight count so the threshold can be shown.
  app      = { in_flight = 9 },
  capacity = 4,                                  -- 9 > 4 * 0.8
  critical = function(req) return req.path:match "^/payments" ~= nil end,
})
app:get("/reports", function() return { ok = true } end)
app:get("/payments", function() return { ok = true } end)

local client = app:test {}
assert(client:get("/reports").status == 429)     -- shed
assert(client:get("/payments").status == 200)    -- critical, never shed
```

O shedder de utilização de workers em toda a frota está deliberadamente ausente. Veja [Não está aqui](#não-está-aqui).

## limit.store_failures

Um campo numérico simples contando quantas chamadas ao store falharam, em todo o processo, desde que o processo começou. Todo limitador no processo soma nesse mesmo contador. Ele nunca é reiniciado.

Leia esse valor num gauge se quiser tê-lo no `/metrics`. Um valor crescente significa que os limites configurados não estão sendo aplicados.

```lua
local limit = require "akkar.limit"
assert(type(limit.store_failures) == "number")
```

## Qual chamador é contado

`rate` e `concurrent` compartilham uma `key` padrão:

1. `"user:" .. req.user.id` quando há um usuário autenticado
2. `"ip:" .. req.ip` caso contrário, ou `"ip:unknown"` quando `req.ip` é nil

`req.ip` é o peer do socket, e só respeita `X-Forwarded-For` quando a conexão vem de um proxy nomeado em `app:run { trusted_proxies = ... }`. Um chamador não consegue criar um bucket novo enviando um cabeçalho.

Nunca por caminho. Um chamador limitado por caminho passa pelos caminhos em sequência.

Passe `key` para sobrescrever. A chave completa enviada ao store é `prefix .. key(req)`.

## Quando o store falha

Toda decisão é uma ida e volta, e toda ida e volta pode falhar. Quando o store não consegue responder, **a requisição é permitida**. Uma resposta que não é uma tabela também conta como falha.

A cada falha:

- `limit.store_failures` sobe em um
- a primeira falha de uma interrupção é registrada em nível warn pelo `req.log`, e novamente cada vez que o store se recupera e falha de novo
- `on_store_error(err, req)` é chamado se informado, dentro de um `pcall`

Nenhum cabeçalho de cota sai numa requisição servida dessa forma: os números são desconhecidos, e inventá-los seria uma mentira contra a qual um cliente se pautaria.

Um store que nunca foi configurado é uma falha diferente e **levanta erro** em vez disso. Um limitador sem store não consegue limitar nada, e permitir toda requisição silenciosamente esconderia isso.

## Cabeçalhos de resposta

`limit.rate` envia três cabeçalhos em toda resposta sobre a qual toma uma decisão, a menos que `headers = false`:

| cabeçalho | significa |
|---|---|
| `ratelimit-limit` | a capacidade do bucket, que é `burst` |
| `ratelimit-remaining` | tokens restantes depois desta requisição |
| `ratelimit-reset` | segundos até o bucket ficar cheio de novo |

`retry-after` é enviado apenas num `429`, e é a espera para o único token que essa requisição queria. É um número menor que `ratelimit-reset`.

Os nomes são os do draft do IETF, não a grafia `X-RateLimit-`.

Um cabeçalho que a resposta já carrega prevalece. O limitador copia a resposta em vez de escrever sobre ela, então um handler que retorna uma tabela hoisted ou memoizada não tem a cota de uma requisição lida por outra.

## Não está aqui

- **Um shedder de utilização de workers em toda a frota.** Ele precisa saber quantos workers estão ocupados na frota inteira, e o akkar não tem esse número. Uma aproximação sob o mesmo nome seria pior, porque seria confiável (trusted).
- **Limites por rota.** Instale o middleware numa sub-app, ou desvie dentro de um middleware seu com base em `req.path`.
- **Um store.** `limit` conta em qualquer coisa que `req.cache` seja. Veja `akkar.cache.memory` e `akkar.redis`.

## Veja também

- [akkar](akkar.md) para `app:use`, que instala o middleware que este módulo retorna, e para `app:run { cache = ... }`, que fornece o store
- [akkar.idempotency](idempotency.md), que usa o mesmo store e a mesma disciplina de avaliação de scripts
- o código-fonte do módulo, `akkar/limit.lua`, para as medições que justificaram um limite de concorrência e o porquê de o modo de falha ser permitir
