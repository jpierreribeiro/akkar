# akkar.pool

> **Português (Brasil)** | [Original em inglês](../../reference/pool.md)

Um pool limitado de recursos. Ele não sabe nada sobre o que guarda: abrir um é uma função que você passa, e se um recurso devolvido está apto para reutilização é um predicado que você passa.

**Quando você precisa dele.** Raramente, de forma direta. `db.connect { pool_size = 10 }` constrói um e entrega para você como `open.pool`. Recorra a este módulo quando estiver escrevendo um adaptador próprio que mantém uma conexão, um cliente ou um handle cujo custo de criação é real.

```lua no-run
local Pool = require "akkar.pool"
```

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`pool:close`](#poolclose) | método |
| [`pool:get`](#poolget) | método |
| [`pool:put`](#poolputresource) | método |
| [`pool:reap`](#poolreap) | método |
| [`pool:reserved`](#poolreserved) | método |
| [`pool:stats`](#poolstats) | método |
| [`Pool.new`](#poolnewopen-size-reusable) | função |

Também nesta página:
[O que o pool grava em um recurso](#o-que-o-pool-grava-em-um-recurso) e
[O que não está aqui](#o-que-não-está-aqui).

## Pool.new(open, size, reusable)

Cria um pool. Nada é aberto ainda.

| argumento | tipo | significado |
|---|---|---|
| `open` | função | retorna um recurso novo, ou lança erro. Pode fazer yield |
| `size` | número | o máximo de recursos que podem existir ao mesmo tempo |
| `reusable` | função ou nil | dado um recurso devolvido, responde se deve mantê-lo |

Um recurso é uma tabela. Ele precisa ter um método `close`, que o pool chama quando `reusable` o rejeita e quando o próprio pool é fechado.

`reusable` é onde "apto para reutilização" é definido, porque a resposta muda de acordo com o backend: `akkar.db` rejeita uma conexão que está dentro de uma transação, marcada como quebrada, segurando uma query que ninguém leu, ou já desconectada. Um predicado que lança erro conta como rejeição.

**Retorna** um [Pool](#pool).

```lua
local Pool = require "akkar.pool"

local opened = 0
local pool = Pool.new(function()
  opened = opened + 1
  return { id = opened, close = function(self) self.closed = true end }
end, 2, function(resource) return not resource.broken end)

local first = pool:get()
print(first.id, opened)
pool:put(first)
print("reused:", pool:get().id == first.id)
```

## Pool

### pool:close()

Fecha todo recurso ocioso e esquece as reservas. `live` vai a zero.

Recursos que estão em uso não são tocados: o pool não os mantém e não consegue alcançá-los. O `akkar` chama isso depois do dreno no desligamento, quando não há mais nada em uso.

**Retorna** nada.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function()
  return { close = function(self) self.closed = true end }
end, 2)

local one = pool:get()
pool:put(one)
pool:close()

print(one.closed, pool:stats().live, pool:stats().idle)
```

### pool:get()

Pega um recurso: um ocioso se houver um, um novo de `open` se houver espaço, e caso contrário espera.

Esperar faz **yield** na corrotina. Isso não bloqueia o processo e não fica girando, então toda outra requisição (request) no processo continua rodando. Quando um recurso volta, todo aguardante é acordado, não apenas um: um aguardante cujo prazo já expirou nunca pega seu despertar, e entregar o despertar a ele deixaria um aguardante vivo dormindo ao lado de um recurso ocioso.

Enquanto `open` roda, o slot fica reservado em vez de gasto. `open` faz yield, então um prazo pode expirar dentro dele, e um slot contado como vivo ficaria perdido pelo resto da vida do processo. Veja [`reap`](#poolreap).

**Retorna** um recurso, com `pool` definido nele.

**Lança erro** com o que `open` lançou, depois de liberar o slot que havia reservado e acordar um aguardante.

```lua
local cqueues = require "cqueues"
local Pool    = require "akkar.pool"

local opened = 0
local pool = Pool.new(function()
  opened = opened + 1
  return { id = opened, close = function() end }
end, 1)

local cq = cqueues.new()
cq:wrap(function()
  local held = pool:get()
  cqueues.sleep(0.05)
  pool:put(held)
end)
cq:wrap(function()
  cqueues.sleep(0.01)
  local held = pool:get()          -- o pool está cheio, então isso espera
  print("got id", held.id, "after", pool:stats().waits, "wait(s)")
  pool:put(held)
end)
assert(cq:loop())

print("opened in total:", opened)
```

### pool:put(resource)

Devolve um recurso. Executa `reusable` nele: os mantidos vão para o conjunto de ociosos, e os rejeitados são fechados e seu slot liberado. De qualquer forma, todo aguardante é acordado.

Devolver o mesmo recurso duas vezes não faz nada na segunda vez. Essa proteção é essencial: sem ela, o conjunto de ociosos guardava um objeto duas vezes e dois chamadores de `get` recebiam a mesma tabela, e um recurso rejeitado devolvido duas vezes fazia `live` ficar negativo, o que fazia o pool abrir mais recursos do que seu tamanho.

**Retorna** nada.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function()
  return { close = function(self) self.closed = true end }
end, 2, function(resource) return not resource.broken end)

local good, bad = pool:get(), pool:get()

pool:put(good)
print("idle", pool:stats().idle, "live", pool:stats().live)

bad.broken = true
pool:put(bad)
print("closed", bad.closed, "idle", pool:stats().idle, "live", pool:stats().live)

pool:put(bad)                      -- o segundo put é ignorado
print("live still", pool:stats().live)
```

### pool:reap()

Recupera slots reservados por corrotinas que ninguém jamais vai retomar, rodando o coletor de lixo duas vezes e contando o que a tabela fraca perdeu.

Uma corrotina abandonada está suspensa, não morta, então `coroutine.status` não diz nada útil sobre ela. O que a distingue é que nada mais faz referência a ela. Duas vezes em vez de uma porque o handler abandonado é mantido pelo seu controlador `cqueues`, e é preciso uma coleta para rodar o finalizador desse controlador e uma segunda para coletar o que o finalizador descartou.

[`get`](#poolget) chama isso sozinho quando o pool parece cheio, antes de parar, então normalmente você não precisa.

**Retorna** quantos slots foram liberados, e `0` imediatamente quando nada está reservado.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function() return { close = function() end } end, 2)
print(pool:reserved(), pool:reap())
```

### pool:reserved()

Quantos slots estão retidos por um `open` ainda em andamento.

**Retorna** um número.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function() return { close = function() end } end, 2)
pool:get()
print(pool:reserved())
```

### pool:stats()

Uma fotografia, para um endpoint de saúde ou uma linha de log.

| campo | significado |
|---|---|
| `size` | o máximo |
| `live` | recursos que existem neste momento, em uso ou ociosos |
| `idle` | recursos parados no pool |
| `reserved` | slots retidos por um `open` ainda em execução |
| `reaped` | slots recuperados de corrotinas abandonadas desde que o pool foi criado |
| `waits` | quantas vezes um chamador teve que entrar na fila |
| `waited` | total de segundos gastos na fila |
| `waited_max` | a maior espera individual, em segundos |

`live` e `reserved` são dois números de propósito. Um pool que relata apenas um total não consegue dizer se está ocupado ou travado. `waits` e `waited` são os números que decidem o tamanho do pool: um p99 formado por espera na fila é um problema diferente de um p99 formado por trabalho, e de fora eles parecem a mesma coisa.

**Retorna** uma tabela.

```lua
local Pool = require "akkar.pool"

local pool = Pool.new(function() return { close = function() end } end, 4)
local held = pool:get()

local stats = pool:stats()
print(stats.size, stats.live, stats.idle, stats.reserved, stats.reaped)
print(stats.waits, stats.waited, stats.waited_max)

pool:put(held)
print(pool:stats().idle)
```

## O que o pool grava em um recurso

Três campos, na tabela que você retornou de `open`. Eles são legíveis, e o predicado `reusable` de `akkar.db` lê suas próprias flags separadas em vez destes.

| campo | quando |
|---|---|
| `pool` | definido em `get`, limpo em `put`. É isso que `conn:release()` segue |
| `pooled` | `true` enquanto o recurso está no conjunto de ociosos |
| `discarded` | `true` assim que `reusable` o rejeita e ele é fechado |

`pooled` e `discarded` juntos são o que faz um segundo `put` não fazer nada.

## O que não está aqui

Não há timeout em `get`. Um chamador que deveria desistir de esperar define um prazo acima do pool, o que abandona a corrotina, e `reap` é o que recupera o slot depois disso.

Não há tamanho mínimo nem pré-aquecimento. As primeiras `size` chamadas a `get` abrem cada uma um recurso, e depois disso o pool está cheio.

Não há verificação de saúde em um recurso ocioso. O predicado roda quando um recurso volta, não enquanto ele está parado, então uma conexão que um banco de dados fechou enquanto estava ociosa é descoberta pela requisição que a toma emprestada.

Não há `Pool:size(n)`. O tamanho é fixado quando o pool é criado.

## Veja também
- [akkar.db](db.md) constrói um destes a partir de `pool_size` e define o que "reutilizável" significa para uma conexão
- o código-fonte do módulo, `akkar/pool.lua`, para as razões medidas por trás de acordar todo aguardante e coletar duas vezes
