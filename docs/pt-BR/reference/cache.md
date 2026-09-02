# akkar.cache.memory

> **Português (Brasil)** | [Original em inglês](../../reference/cache.md)

Um adaptador de cache in-process. É uma implementação real, não um substituto:
um TTL realmente expira, `incr` realmente conta, e `eval` realmente executa um
script Redis.

**Quando você precisa dele.** Um teste que precisa de um cache sem um Redis
rodando, e uma implantação de processo único que quer cache e não quer um
segundo serviço. É por processo, então dois processos worker mantêm dois
caches que não concordam entre si.

```lua no-run
local memory = require "akkar.cache.memory"
```

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`cache.per_process`](#cache) | campo |
| [`cache:close`](#cacheclose) | método |
| [`cache:command`](#cachecommandname-) | método |
| [`cache:del`](#cachedel) | método |
| [`cache:drop`](#cachedropmatch) | método |
| [`cache:eval`](#cacheevalscript-numkeys-) | método |
| [`cache:expire`](#cacheexpirekey-seconds) | método |
| [`cache:fail`](#cachefailmatch-message) | método |
| [`cache:get`](#cachegetkey) | método |
| [`cache:hang`](#cachehangmatch-seconds) | método |
| [`cache:incr`](#cacheincrkey) | método |
| [`cache:on`](#cacheonmatch-effect) | método |
| [`cache:release`](#cacherelease) | método |
| [`cache:reset`](#cachereset) | método |
| [`cache:set`](#cachesetkey-value-ttl) | método |
| [`cache:size`](#cachesize) | método |
| [`cache:sweep`](#cachesweep) | método |
| [`cache:ttl`](#cachettlkey) | método |
| [`memory.factory`](#memoryfactoryoptions) | função |
| [`memory.Memory`](#memorymemory-metatable) | tabela |
| [`memory.new`](#memorynewoptions) | função |

## memory.factory(options)

Constrói um cache e retorna algo chamável que sempre devolve esse mesmo cache.
`options` é repassado para `memory.new`.

**Retorna** uma tabela. Chamá-la retorna o `Cache`. Seu campo `instance` é o
mesmo `Cache`.

```lua
local memory = require "akkar.cache.memory"

local cache = memory.factory()
assert(cache() == cache())
assert(cache() == cache.instance)

cache():set("ref_cache_hits", 1)
print(cache.instance:get "ref_cache_hits")
```

## memory.Memory (metatable)

A metatable que todo cache carrega. Exposta para que quem a use possa
estendê-la ou checar `getmetatable(cache) == memory.Memory`.

## memory.new(options)

Constrói um cache. `options` pode ser omitido.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `now` | function | `akkar.time.now` | lê a hora atual em segundos. Injetado para que um teste possa mover o tempo em vez de dormir. |
| `max_qps` | number | nenhum | quantos comandos o armazenamento atende por segundo. Veja [Capacidade](#capacidade-max_qps-e-latency_ms). |
| `latency_ms` | number | nenhum | quanto tempo cada comando leva. |

**Retorna** um `Cache`. Seu campo `per_process` é `true`, e é assim que quem
precisa de um valor compartilhado entre processos descobre que não vai
conseguir um aqui.

**Levanta um erro** quando `max_qps` não é maior que zero, ou `latency_ms` é
negativo.

```lua
local memory = require "akkar.cache.memory"

local clock = 1000
local cache = memory.new { now = function() return clock end }

cache:set("ref_cache_token", "abc", 30)
print(cache:get "ref_cache_token")   --> abc

clock = clock + 31
print(cache:get "ref_cache_token")   --> nil
print(cache.per_process)             --> true
```

### Capacidade: max_qps e latency_ms

Os dois juntos formam um armazenamento que é lento, ou está saturado, ou as
duas coisas, sem que exista um Redis, para que um handler possa ser testado
contra a dependência que um diagrama de capacidade descreve, em vez de ser
testado contra um que sempre responde instantaneamente.

Eles são **uma fila só, não duas latências somadas**. Um comando ocupa o
armazenamento por `latency_ms`, e `max_qps` diz com que frequência um novo pode
começar; o que for a restrição mais apertada é o que quem chama sente. A
1500/s e 8 ms, o tempo de serviço domina, porque 8 ms de trabalho não podem ser
emitidos 1500 vezes por segundo. A 50/s e 8 ms, a taxa domina.

Um comando é uma ida e volta, e um script é uma ida e volta não importa quantos
`redis.call` ele faça, porque é isso que custa num servidor real.

**A espera passa pelo [akkar.time](time.md), nunca por um relógio de parede
próprio.** Sob `akkar.time.manual` um segundo modelado passa instantaneamente,
então um teste permanece determinístico e rápido; sob o relógio real, os
mesmos números custam segundos reais. Uma única configuração, e qual
comportamento você obtém é decidido por qual relógio está instalado.
([`cache:hang`](#cachehangmatch-seconds) é deliberadamente a exceção.)

É um modelo, e ele o diz. O tempo de serviço de um servidor real varia com o
comando, o tamanho do valor e o descarte que ele está fazendo. Isto reproduz
uma fila com uma taxa de serviço fixa, que é o que um diagrama de capacidade
representa, e o objetivo de um único número configurar os dois é que a
previsão e a medição possam então ser comparadas e constatadas em desacordo.

```lua
local memory = require "akkar.cache.memory"
local time   = require "akkar.time"

local clock   = time.manual { monotime = 0 }
local restore = time.set(clock)

local cache = memory.new { max_qps = 1500, latency_ms = 8 }
for i = 1, 10 do cache:get("ref_cache_k" .. i) end

print(("%.3f"):format(clock.monotime()))   --> 0.080, e nada esperou
restore()
```

### Falhas

Um cache que sempre responde não é o cache que alguém roda de verdade, então
este pode ser feito para quebrar. [`cache:fail`](#cachefailmatch-message),
[`cache:hang`](#cachehangmatch-seconds) e [`cache:drop`](#cachedropmatch) são
os mesmos três que [akkar.db.memory](db.md#memory) tem, batizados conforme o
que o [akkar.redis](redis.md) realmente faz, porque um simulacro cujas falhas
não são falhas que o adaptador real pode produzir é como um teste prova a
coisa errada.

| método | o que realmente produz isso | o que isso deixa para trás |
|---|---|---|
| `fail` | uma resposta de erro: `WRONGTYPE`, `NOSCRIPT`, `READONLY`, `OOM`, `NOAUTH` | uma conexão **saudável**, o stream RESP continua em sincronia |
| `hang` | um comando enviado e nunca respondido, encerrado pelo timeout do socket | `broken`, porque uma leitura que expirou por timeout deixa o stream fora de sincronia |
| `drop` | uma escrita que falhou, uma resposta truncada, um cabeçalho que não parseou | `broken` **e** `in_flight`, e todo comando posterior falha |

`fail` contra `drop` é a distinção que importa, e importa mais num cache do
que num banco de dados. RESP casa respostas com comandos pela ordem e por mais
nada, então uma conexão devolvida ao pool com uma resposta ainda não lida
entrega ao próximo pedido a resposta de outra pessoa, um cache miss que nunca
aconteceu, e depois o valor de um estranho, sem nenhum erro levantado em lugar
nenhum. O Postgres recusa isso com "connection is busy"; o Redis não tem nada
com que recusar.

**Com o que uma falha é comparada** é o verbo, e a chave quando o verbo tem
uma. Então `"DEL"` é todo delete, `"session:7"` é todo comando que toca aquela
chave, e `"GET session:7"` é exatamente um. Um script casa com `"EVAL"`
sozinho.

A agulha é tentada primeiro como **texto puro, e como padrão Lua somente se
isso não encontrar nada**, porque chaves são cheias de mágica de padrão:
`rate-limit:user-7` lido como padrão não casa com nada que ninguém quis dizer.
`^GET session:` ainda ancora normalmente.

A primeira falha que casa vence, na ordem em que foram adicionadas.
[`cache:reset`](#cachereset) não as desprograma.

```lua
local memory = require "akkar.cache.memory"

local cache = memory.new():fail("GET ref_cache_hot", "WRONGTYPE")

-- O comando falha; a conexão não.
print(pcall(function() return cache:get "ref_cache_hot" end))
print(cache.broken)                       --> nil
print(cache:set("ref_cache_cold", "1"))   --> OK
```

## Cache

O objeto que `memory.new` retorna. Ele satisfaz o contrato da capability
`cache` que `app:run{}` e `app:test{}` verificam, que é `get`, `set` e `del`.

A expiração é ativa, como acontece num servidor real. Uma entrada é
descartada quando seu TTL termina, mesmo que nada a leia: cada ida e volta paga
por uma parte do mesmo ciclo de amostragem que o Redis executa no próprio
tempo. Assim, um armazenamento cujas chaves ficaram todas obsoletas se esvazia
ao longo dos próximos comandos, enquanto um armazenamento ocioso não custa
nada. Não há uma tarefa em background aqui; o trabalho pega carona nos comandos
que você já enviaria. `cache:sweep()` ainda recupera tudo de uma vez para quem
precisa fazer isso imediatamente.

Antes a expiração era preguiçosa: a chave era descartada na próxima leitura e
por nada mais. Isso era um vazamento com um nome respeitável. `akkar.limit`
identifica um bucket por (limitador, tenant, chamador), portanto um processo
que tivesse atendido N chamadores guardava N hashes mortos para sempre, e
`cache:size()` informava 5.000 chaves que tinham expirado uma hora antes.

Não existe `maxmemory` aqui. A `maxmemory-policy` padrão do Redis é
`noeviction`, que recusa a escrita em vez de descartar chaves vivas. Essa
recusa é uma falha que você pode programar: `cache:fail("SET", "OOM command not
allowed when used memory > 'maxmemory'")`.

```lua
local akkar  = require "akkar"
local memory = require "akkar.cache.memory"

local app = akkar.new()

app:get("/count", function(req)
  return { seen = req.cache:incr "ref_cache_visits" }
end)

local client = app:test { cache = memory.new() }
print(client:get("/count").body.seen)   --> 1
print(client:get("/count").body.seen)   --> 2
```

### cache:close()

Não faz nada e não retorna nada. Existe para que quem chama possa tratar isto
e uma conexão Redis da mesma forma.

### cache:command(name, ...)

Executa um comando Redis pelo nome. `name` é comparado sem diferenciar
maiúsculas de minúsculas. A resposta segue o Redis: uma chave ausente é `nil`,
uma contagem é um número, `SET` responde com a string `OK`.

Os comandos implementados:

| grupo | verbos |
|---|---|
| strings | `GET`, `SET` (com `NX`, `EX`, `PX`), `DEL`, `INCR`, `EXPIRE`, `TTL` |
| listas | `LPUSH`, `RPOP`, `BRPOP`, `LLEN`, `LRANGE`, `LTRIM` |
| hashes | `HSET`, `HMSET`, `HGET`, `HMGET`, `HINCRBY` |
| conjuntos ordenados | `ZADD`, `ZREM`, `ZCARD`, `ZRANGEBYSCORE`, `ZREMRANGEBYSCORE` |
| scripting | `EVAL`, `EVALSHA`, `SCRIPT LOAD` |
| outros | `PING`, `TIME` |

`BRPOP` não bloqueia. Ele desempilha se houver algo lá e retorna `nil` caso
contrário, porque nada neste processo poderia empilhar enquanto ele esperava.

**Levanta um erro** `akkar.cache.memory: unsupported command 'X'; this
adapter implements the contract, not all of Redis` para qualquer outro verbo.
`EVALSHA` para um script que nunca passou por `SCRIPT LOAD` levanta `NOSCRIPT
No matching script`, a mesma resposta que um servidor real envia.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

-- SET NX é uma reivindicação, não uma escrita: a segunda responde nil.
print(cache:command("SET", "ref_cache_lock", "1", "NX", "EX", 60))
print(tostring(cache:command("SET", "ref_cache_lock", "1", "NX", "EX", 60)))

local ok, err = pcall(cache.command, cache, "SINTERCARD", "a", "b")
print(ok, err)
```

### cache:del(...)

Apaga cada chave informada.

**Retorna** quantas delas estavam ativas naquele momento. Uma chave expirada
conta como ausente.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_a", "1")
cache:set("ref_cache_b", "2")
print(cache:del("ref_cache_a", "ref_cache_b", "ref_cache_never"))   --> 2
```

### cache:drop(match)

Programa um comando que dá match para matar a CONEXÃO, não apenas falhá-la.
Levanta `redis: write failed: connection reset by peer`, e **todo** comando
depois disso levanta a mesma coisa, que é o que um transporte morto faz.
Somente [`cache:reset`](#cachereset) desfaz isso.

Deixa `broken` e `in_flight` ambos definidos, o par que o pool do
[akkar.redis](redis.md) lê para decidir que uma conexão não é adequada para
reutilização. Os dois, porque o comando estava em trânsito quando o transporte
morreu, e uma conexão devolvida com uma resposta ainda não lida entrega essa
resposta ao próximo solicitante como se fosse dele.

**Retorna** o cache, para permitir encadeamento.

```lua
local memory = require "akkar.cache.memory"

local cache = memory.new():drop "SET ref_cache_orders"

print(cache:get "ref_cache_anything")                                  --> nil
print(pcall(function() return cache:set("ref_cache_orders", "1") end))
print(pcall(function() return cache:get "ref_cache_anything" end))
print(cache.broken, cache.in_flight)

-- reset revive a conexão. NÃO desprograma a falha, então o comando que deu
-- match com ela volta a falhar; tudo o mais funciona.
cache:reset()
print(cache:get "ref_cache_anything")   --> nil, a conexão está viva
```

### cache:eval(script, numkeys, ...)

Executa `script` do jeito que o `EVAL` do Redis faz. Os primeiros `numkeys`
argumentos extras viram `KEYS`, o resto vira `ARGV` como strings. Dentro do
script, `redis.call`, `redis.pcall`, `redis.status_reply`,
`redis.error_reply`, `redis.sha1hex` e `redis.log` estão disponíveis, e
`redis.call` passa de volta por `cache:command`.

As respostas são convertidas do jeito que um servidor real converte: um
número é truncado em direção a zero, `false` vira `nil`.

**O script roda numa sandbox Lua 5.1, porque é isso que o Redis incorpora.**
O ambiente é uma lista de permissões obtida de um servidor em execução, não
o `_G` deste processo: `table.unpack`, `table.move`, `string.pack`,
`math.tointeger`, `math.type` e `math.maxinteger` não existem porque o Redis
não os tem; `unpack`, `math.pow`, `math.log10`, `table.getn` e `table.maxn`
existem porque ele os tem; `_VERSION` retorna `Lua 5.1`; e ler ou escrever uma
global indefinida levanta um erro como no servidor. Código que o Lua 5.1 não
consegue analisar — `//`, `&`, `|`, `~` como operador, `<<`, `>>` e
`::labels::` — é recusado antes que o chunk seja compilado.

Os números atravessam a fronteira como num servidor real: dentro do script,
`tostring` formata por meio de um double, então `tostring(10/2)` é `"5"`, não
`"5.0"`. Um número entregue a `redis.call` é convertido para o decimal mais
curto que volta a ser lido como o mesmo double, portanto
`redis.call('SET', k, 10/2)` grava `"5"`.

Resta uma diferença que vale conhecer: `..` sobre um número não pode ser
interceptado, pois o Lua não consulta nenhum metamétodo ao concatenar um
número. Assim, `'k:' .. 10/2` é `"k:5.0"` aqui e `"k:5"` no servidor. Monte a
chave com `tostring` e este adaptador se comporta de forma fiel.

**Retorna** a resposta convertida.

**Levanta um erro** `akkar.cache.memory: script would not compile: ...`
quando `load` rejeita o script, e o que quer que `redis.call` levante quando o
script chama um comando que este adaptador não implementa.

**Isto executa o script. Não torna o script atômico.** Atomicidade é uma
propriedade de um servidor Redis real, e só um teste apoiado em Redis
comprova isso.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

local n = cache:eval([[
  local current = tonumber(redis.call('GET', KEYS[1]) or '0')
  redis.call('SET', KEYS[1], current + tonumber(ARGV[1]))
  return current + tonumber(ARGV[1])
]], 1, "ref_cache_score", 7)

print(n)                            --> 7
print(cache:get "ref_cache_score")  --> 7
```

### cache:expire(key, seconds)

Define uma nova expiração, contada a partir de agora, numa chave que já
existe.

**Retorna** `1` quando a chave estava lá, `0` quando não estava.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_session", "x")
print(cache:expire("ref_cache_session", 60))   --> 1
print(cache:expire("ref_cache_missing", 60))   --> 0
```

### cache:fail(match, message)

Programa um comando que dá match para voltar como uma **resposta de erro**: o
servidor respondeu, e respondeu mal. Levanta `redis: <message>`, com padrão
`redis: ERR command failed`.

A conexão permanece **utilizável**, e isso não é um descuido. `WRONGTYPE`,
`NOSCRIPT`, `READONLY` e `OOM` deixam o stream RESP perfeitamente em
sincronia, e o [akkar.redis](redis.md) deliberadamente não marca a conexão
como quebrada nesses casos, descartar uma conexão boa a cada `WRONGTYPE` é um
defeito que aquele módulo já corrigiu uma vez, medido como um pool indo de
`live=1 idle=1` para `live=0 idle=0`.

**Retorna** o cache, para permitir encadeamento.

```lua
local memory = require "akkar.cache.memory"

local cache = memory.new()
cache:fail("INCR ref_cache_quota",
           "OOM command not allowed when used memory > 'maxmemory'")

print(pcall(function() return cache:incr "ref_cache_quota" end))
print(cache:set("ref_cache_other", "still works"))   --> OK
```

### cache:get(key)

**Retorna** o valor armazenado como string, ou `nil` quando a chave está
ausente ou expirada. Os valores são armazenados via `tostring`, então um
número entra e uma string sai.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_n", 41)
print(type(cache:get "ref_cache_n"), cache:get "ref_cache_n")   --> string 41
print(tostring(cache:get "ref_cache_absent"))                   --> nil
```

### cache:hang(match, seconds)

Programa um comando que dá match para esperar `seconds` (60 por padrão) e
então levantar `redis: the command was sent and never answered`, um comando
que chegou ao servidor e nunca foi respondido, encerrado pelo próprio timeout
do socket. Deixa a conexão `broken`, porque uma leitura que expirou por
timeout deixou o stream RESP fora de sincronia.

A espera é real e ela cede (yield), e esse é o ponto: encena uma coroutine
abandonada no meio de um comando, o que levantar o erro imediatamente não
faz. Um deadline de requisição acima dela dispara, e o que se torna observável
então é se o framework liberou a capability, a classe de defeito que uma
auditoria deste projeto encontrou sete vezes.

**Ela espera pelo relógio real mesmo quando um relógio manual está
instalado**, o oposto do que `latency_ms` faz. Um relógio manual colapsaria a
espera para nada, e `hang` silenciosamente viraria `fail` com outro nome.

**Retorna** o cache, para permitir encadeamento.

```lua
local akkar   = require "akkar"
local cqueues = require "cqueues"
local memory  = require "akkar.cache.memory"

local cache = memory.new():hang("GET ref_cache_slow", 0.3)

local app = akkar.new()
app:get("/slow", function(req) return { v = req.cache:get "ref_cache_slow" } end)

local client = app:test { cache = function() return cache end, timeout = 0.1 }

-- Um deadline precisa de um controller para ceder (yield); fora de um, não arma nada.
local cq = cqueues.new()
cq:wrap(function()
  print(client:get("/slow").status)   --> 503, respondido no deadline
end)
assert(cq:loop(20))
```

### cache:incr(key)

Adiciona um, tratando uma chave ausente como zero. Qualquer expiração já
existente na chave é mantida, o que é o que a torna utilizável para um rate
limit e não apenas para um contador.

O valor precisa ser o que o Redis chama de inteiro, uma regra mais estrita que
`tonumber`: somente base dez, sem espaços ao redor, sem `+` inicial, sem zero
inicial (`"01"` e `"-0"` são recusados), sem ponto decimal ou expoente e dentro
do intervalo de 64 bits com sinal. `HINCRBY` aplica a mesma regra.

**Retorna** o novo valor, como número.

**Levanta um erro** `ERR value is not an integer or out of range` quando o
valor armazenado não é um inteiro, e `ERR increment or decrement would
overflow` no topo do intervalo: são as respostas enviadas por um servidor
real. Antes, aceitava qualquer coisa que `tonumber` aceitasse; por isso,
`"abc"` subia para `1`, destruindo silenciosamente o valor, e `"1.5"` subia
para `2.5`.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_calls", 0, 60)
print(cache:incr "ref_cache_calls")   --> 1
print(cache:ttl "ref_cache_calls")    --> 60, a expiração sobreviveu ao incr
```

### cache:on(match, effect)

Programa o que um comando que dá match faz. `effect` é chamado como
`effect(cache)` antes de o comando ser executado: levantar um erro é como se
muda o resultado, retornar é como se deixa o comando prosseguir. `fail`,
`hang` e `drop` são escritos em cima disso e são os três que valem a pena ter.

A contraparte de [`fake:on`](db.md#fakeonpattern-response), e a diferença
entre eles é a diferença entre os dois adaptadores. Aquele é um substituto:
não executa SQL nenhum, então uma query que ninguém programou levanta um
erro. Este é uma implementação real, então programar é uma **sobreposição**:
um comando que ninguém programou ainda faz seu trabalho de verdade.

**Retorna** o cache, para permitir encadeamento.

```lua
local memory = require "akkar.cache.memory"

local seen = 0
local cache = memory.new():on("INCR", function() seen = seen + 1 end)

print(cache:incr "ref_cache_n")   --> 1, o comando ainda rodou
print(cache:incr "ref_cache_n")   --> 2
print(seen)                       --> 2
```

### cache:release()

Não faz nada e não retorna nada. Uma conexão do pool se devolve a seu pool
aqui; esta não tem pool nenhum, e mostra isso não fazendo nada.

### cache:reset()

Descarta cada entrada, e coloca uma conexão `broken` de pé novamente.

Falhas programadas **permanecem**, pela mesma razão que `akkar.db.memory`
mantém suas respostas programadas: um cenário é montado uma vez e resetado
entre as requisições dentro dele. A fila modelada esvazia junto com as
entradas; a própria capacidade permanece.

**Retorna** o cache, para que possa ser encadeado.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_x", "1")
print(cache:reset():size())   --> 0
```

### cache:set(key, value, ttl)

Armazena `value` sob `key`. `ttl` é em segundos e é opcional; sem ele a
entrada nunca expira. `value` é armazenado como `tostring(value)`.

**Retorna** a string `OK`.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

print(cache:set("ref_cache_greeting", "hello"))       --> OK
print(cache:set("ref_cache_greeting", "hello", 30))   --> OK
```

### cache:size()

**Retorna** quantas entradas **ativas** o armazenamento contém: a mesma
pergunta respondida por `DBSIZE` num servidor real. Qualquer entrada expirada
encontrada durante a contagem é descartada no caminho. Antes, o método contava
a tabela, inclusive as chaves expiradas; era assim que um TTL vencido havia
uma hora ainda podia aparecer como 5.000 chaves.

### cache:sweep()

Descarta agora mesmo cada entrada expirada, em vez de esperar a próxima
leitura.

**Retorna** quantas foram descartadas.

```lua
local memory = require "akkar.cache.memory"

local clock = 1000
local cache = memory.new { now = function() return clock end }

cache:set("ref_cache_one", "1", 5)
cache:set("ref_cache_two", "2")
clock = clock + 10

print(cache:size())    --> 2, a entrada expirada ainda está ocupando memória
print(cache:sweep())   --> 1
print(cache:size())    --> 1
```

### cache:ttl(key)

**Retorna** os segundos restantes, ou `-1` quando a chave existe sem
expiração, ou `-2` quando a chave está ausente ou expirada. Esses dois
números são do Redis, então um teste escrito contra um armazenamento se
sustenta contra o outro.

```lua
local memory = require "akkar.cache.memory"
local cache = memory.new()

cache:set("ref_cache_forever", "1")
cache:set("ref_cache_brief", "1", 30)

print(cache:ttl "ref_cache_forever")   --> -1
print(cache:ttl "ref_cache_brief")     --> 30
print(cache:ttl "ref_cache_gone")      --> -2
```

## O que não está aqui

**Não existe `require "akkar.cache"`.** Não há módulo com esse nome.
`akkar/cache/` contém um único arquivo, `memory.lua`, e `akkar.cache.memory` é
todo o seu conteúdo.

**Nenhum adaptador de cache Redis.** Uma conexão de [akkar.redis](redis.md)
já responde a `get`, `set` e `del`, então ela satisfaz a capability `cache`
diretamente e não precisa de nenhum wrapper.

**Sem `KEYS`, sem `SCAN`, sem apagar por padrão.** `cache:command` levanta um
erro para esses casos em vez de fingir que os suporta.

**Sem limite de tamanho e sem política de descarte.** Nada aqui limita o
quanto a tabela pode crescer. Um cache que só cresce precisa de um `ttl` em
todo `set`.

**Sem compartilhamento entre processos.** `per_process` é `true` e não é uma
opção de configuração. Um contador que precisa estar certo em toda uma frota
de máquinas pertence ao Redis.

## Veja também

- [akkar](akkar.md) para `app:run { cache = ... }` e `app:test { cache = ... }`,
  que injetam um cache como `req.cache`
- [akkar.redis](redis.md) para o armazenamento que é compartilhado entre
  processos
- [akkar.jobs](jobs.md), cujo armazenamento Redis é construído sobre um
  objeto com formato de cache
- o código-fonte do módulo, `akkar/cache/memory.lua`, para entender por que
  um adaptador em memória cresceu até virar um terço do Redis
