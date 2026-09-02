# akkar.redis

> **Português (Brasil)** | [Original em inglês](../../reference/redis.md)

O adaptador Redis. Ele fala RESP2 sobre um socket cqueues, então um comando cede o event loop enquanto espera, em vez de travar todas as outras requisições no processo.

**Quando você precisa dele.** Estado que precisa ser compartilhado entre processos: um cache que dois workers concordam entre si, um rate limit contado em toda a frota, uma fila de jobs que um worker separado lê. `akkar.jobs.redis`, `akkar.limit` e `akkar.idempotency` recebem todos uma conexão daqui.

```lua no-run
local redis = require "akkar.redis"
```

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`conn.broken`](#connection) | campo |
| [`conn.in_flight`](#connection) | campo |
| [`conn:close`](#connclose) | método |
| [`conn:command`](#conncommand) | método |
| [`conn:del`](#conndel) | método |
| [`conn:expire`](#connexpirekey-seconds) | método |
| [`conn:get`](#conngetkey) | método |
| [`conn:incr`](#connincrkey) | método |
| [`conn:pfadd`](#connpfaddkey-) | método |
| [`conn:pfcount`](#connpfcountkey-) | método |
| [`conn:pfmerge`](#connpfmergedestination-) | método |
| [`conn:ping`](#connping) | método |
| [`conn:release`](#connrelease) | método |
| [`conn:set`](#connsetkey-value-ttl) | método |
| [`conn:settimeout`](#connsettimeoutseconds) | método |
| [`conn:ttl`](#connttlkey) | método |
| [`redis.connect`](#redisconnectconfig) | função |
| [`redis.Redis`](#redisredis-metatable) | tabela |

## redis.connect(config)

Constrói um conector. Ele não abre uma conexão; chamar o que ele retorna, sim.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `host` | string | `"127.0.0.1"` | |
| `port` | number | `6379` | |
| `timeout` | number | `5` | quanto tempo uma única leitura pode esperar, em segundos. Sem um limite, um Redis que aceita a conexão e depois para de responder deixa um worker parado para sempre. |
| `password` | string | nenhum | envia `AUTH` assim que o socket abre |
| `database` | number | nenhum | envia `SELECT` assim que o socket abre |
| `pool_size` | number | `10` | quantas conexões manter. `0` significa nenhum pool. |

**Retorna** uma tabela chamável que mantém um pool. Chamá-la entrega uma
`Connection`; `conn:release()` a devolve. Com `pool_size = 0` ela retorna uma
função simples em vez disso, e toda chamada abre uma conexão nova.

**Levanta erro**, no momento em que uma conexão é aberta, e não aqui, quando `AUTH`
ou `SELECT` é recusado. O socket é fechado antes do erro ser levantado, então uma
senha errada não vaza um descritor por tentativa.

Um `host` ou `port` errado não levanta erro aqui e não levanta erro quando o
conector é chamado. O socket é conectado de forma preguiçosa (lazy), então uma
conexão recusada aparece no primeiro comando como `redis: write failed: 111`.

A configuração não é verificada quanto a chaves desconhecidas. `redis.connect { prot = 6380 }`
conecta na 6379 sem reclamar, o que não é como `app:run{}` se comporta.

```lua
local redis = require "akkar.redis"

local connect = redis.connect { host = "127.0.0.1", port = 6379 }
local conn = connect()

print(conn:ping())                              --> PONG
print(conn:set("ref_redis_hello", "world"))     --> OK
print(conn:get "ref_redis_hello")               --> world
print(conn:del "ref_redis_hello")               --> 1

conn:release()
```

Conexões voltam do pool, então uma que foi liberada é entregue de novo:

```lua
local redis = require "akkar.redis"

local connect = redis.connect { port = 6379, pool_size = 4 }

local first = connect()
first:release()
local second = connect()
print(first == second)   --> true
second:release()

-- pool_size = 0 é uma função simples, e toda chamada é um socket novo.
local unpooled = redis.connect { port = 6379, pool_size = 0 }
print(type(unpooled))    --> function
local fresh = unpooled()
print(fresh:ping())      --> PONG
fresh:close()
```

## redis.Redis (metatable)

A metatable da conexão. `Redis._encode` e `Redis._read_reply` ficam pendurados nela
para os testes de protocolo e não fazem parte do contrato.

## Connection

O que o conector entrega. Ela responde a `get`, `set` e `del`, que é todo o
contrato da capability `cache`, então pode ser passada para `app:run { cache =
... }` diretamente, sem wrapper.

Dois campos carregam a saúde da conexão, e o pool lê os dois antes de
entregá-la de novo:

| campo | significado |
|---|---|
| `broken` | uma escrita falhou, uma leitura falhou, ou a resposta não era RESP. O stream está fora de sincronia e a conexão não deve ser reutilizada. |
| `in_flight` | definido antes da escrita e limpo depois que a resposta é lida. Continuar definido significa que uma coroutine foi abandonada no meio de um comando, e o próximo leitor receberia a resposta de outra pessoa. |

Uma resposta de erro do servidor (`WRONGTYPE`, `NOSCRIPT`) não é uma conexão quebrada.
É o servidor respondendo normalmente com más notícias, e o stream continua
sincronizado depois disso.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:command("LPUSH", "ref_redis_list", "a")

-- GET contra uma lista é uma resposta de erro, não uma falha de transporte.
local ok, err = pcall(conn.get, conn, "ref_redis_list")
print(ok, err)
print(conn.broken)     --> nil, a conexão ainda está utilizável
print(conn:ping())     --> PONG

conn:del "ref_redis_list"
conn:release()
```

### conn:close()

Fecha o socket e o esquece. Seguro chamar duas vezes.

Todo comando posterior **levanta erro** `redis: connection is closed`.

### conn:command(...)

Envia um comando e lê uma resposta. Cada argumento é codificado como uma bulk
string, então um valor contendo um espaço ou uma quebra de linha é inofensivo. Este é
o método a partir do qual todo outro nesta página é construído, e é como você alcança um
verbo para o qual o akkar não tem um helper.

**Retorna** a resposta: uma string para uma resposta simples ou bulk, um número para uma
resposta inteira, uma tabela para uma resposta em array, `nil` para uma resposta nula.

**Levanta erro** `redis: connection is closed` quando o socket sumiu,
`redis: write failed: <errno>` quando o comando não pôde ser enviado, e
`redis: <server text>` para qualquer outra coisa, inclusive respostas de erro do
servidor.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:command("HSET", "ref_redis_user", "name", "noether", "city", "erlangen")
print(conn:command("HGET", "ref_redis_user", "name"))   --> noether

local pair = conn:command("HMGET", "ref_redis_user", "name", "city")
print(pair[1], pair[2])                                 --> noether erlangen

conn:del "ref_redis_user"
conn:release()
```

### conn:del(...)

Apaga toda chave informada.

**Retorna** quantas existiam.

### conn:expire(key, seconds)

Coloca um novo prazo de expiração em uma chave existente.

**Retorna** `1` quando a chave estava lá, `0` quando não estava.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:set("ref_redis_session", "abc")
print(conn:expire("ref_redis_session", 60))    --> 1
print(conn:expire("ref_redis_absent", 60))     --> 0

conn:del "ref_redis_session"
conn:release()
```

### conn:get(key)

**Retorna** o valor como uma string, ou `nil` quando a chave está ausente. Nunca um
sentinela de JSON null: um desses vazando para dentro de um handler já foi um defeito
real.

### conn:incr(key)

Adiciona um, tratando uma chave ausente como zero.

**Retorna** o novo valor como um número.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:del "ref_redis_counter"
print(conn:incr "ref_redis_counter")   --> 1
print(conn:incr "ref_redis_counter")   --> 2

conn:del "ref_redis_counter"
conn:release()
```

### conn:pfadd(key, ...)

Adiciona uma ou mais observações a um HyperLogLog do Redis.

**Retorna** `1` quando pelo menos um registro interno mudou, `0` caso contrário.
Isso não é exatamente a mesma coisa que "o item era novo": uma observação nova
pode deixar todo registro inalterado assim que o sketch já tiver dados suficientes.

HyperLogLog estima itens distintos sem armazenar os próprios itens. O Redis usa
no máximo cerca de 12 KB por sketch denso e reporta um erro padrão de 0,81%. Isso
é uma distribuição de erro, não uma promessa de que toda resposta está dentro de
0,81% da contagem exata. Use um set quando a resposta precisar ser exata.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

local bikes = "ref_redis_hll_bikes"
local commuter = "ref_redis_hll_commuter"
local all = "ref_redis_hll_all"
conn:del(bikes, commuter, all)

print(conn:pfadd(bikes, "Hyperion", "Deimos", "Phoebe", "Quaoar"))  --> 1
print(conn:pfcount(bikes))                                             --> 4

conn:pfadd(commuter, "Salacia", "Mimas", "Quaoar")
print(conn:pfcount(bikes, commuter))                                   --> 6
print(conn:pfmerge(all, bikes, commuter))                              --> OK
print(conn:pfcount(all))                                               --> 6

conn:del(bikes, commuter, all)
conn:release()
```

O sketch é uma string do Redis, então `get` e `set` podem serializá-lo e restaurá-lo.
Use `conn:expire(key, seconds)` quando um sketch diário ou mensal deve expirar.

### conn:pfcount(key, ...)

**Retorna** a cardinalidade aproximada como um número. Com várias chaves ele
estima a união delas sem armazenar uma chave mesclada. Uma única chave ausente
conta como zero.

`PFCOUNT` com uma única chave armazena em cache o resultado e é barato.
`PFCOUNT` com várias chaves constrói uma união temporária, é O(N) no número de
sketches, e tem um custo constante bem maior. Não coloque um fan-in grande em
um caminho de requisição de alto tráfego.

### conn:pfmerge(destination, ...)

Mescla os sketches de origem em `destination` e **retorna** `"OK"`.
Um destino já existente participa da união em vez de ser limpo primeiro. O
destino pode em seguida ser contado, expirado, serializado ou mesclado de novo
como qualquer outro HyperLogLog.

Os helpers seguem as próprias assinaturas de `PFADD`, `PFCOUNT` e `PFMERGE` do
Redis e todos passam por [`conn:command`](#conncommand), então herdam seu prazo
de execução, timeout do socket e regras de saúde de conexão.

### conn:ping()

**Retorna** a string `PONG`. A forma mais barata de descobrir se a conexão
está viva.

### conn:release()

Devolve a conexão para o seu pool, ou a fecha quando não há pool.

Chame em todo caminho. Uma conexão que é obtida e nunca liberada é uma que o
pool não pode entregar para mais ninguém.

### conn:set(key, value, ttl)

Armazena `value` sob `key`. `ttl` é em segundos e opcional; com ele a chamada
vira `SET key value EX ttl`.

**Retorna** a string `OK`.

Para `SET` com `NX`, use `conn:command("SET", key, value, "NX", "EX", ttl)`,
que responde `nil` em vez de `OK` quando a chave já existia. Esse `nil` é o
que faz do `SET` uma reivindicação em vez de uma escrita, e é sobre isso que
o `akkar.jobs.redis` constrói a deduplicação.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:del "ref_redis_lock"
print(conn:command("SET", "ref_redis_lock", "1", "NX", "EX", 60))            --> OK
print(tostring(conn:command("SET", "ref_redis_lock", "1", "NX", "EX", 60)))  --> nil

conn:del "ref_redis_lock"
conn:release()
```

### conn:settimeout(seconds)

Define quanto tempo uma leitura nesta conexão pode esperar. Passar nada
recoloca o padrão da própria conexão, então um chamador que elevou o limite
não consegue deixar o socket sem limite por acidente.

**Retorna** a conexão, para permitir encadeamento.

Necessário porque um comando é legitimamente mais lento que os demais.
`BRPOP key N` bloqueia dentro do servidor por até N segundos, e um timeout de
socket abaixo de N mataria uma espera que está funcionando exatamente como
pretendido. `akkar.jobs.redis` eleva o limite ao redor das suas próprias
chamadas bloqueantes e o recoloca em todo caminho.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379, timeout = 5 }()

conn:settimeout(15)          -- um comando bloqueante está prestes a rodar
print(conn:command("BRPOP", "ref_redis_empty", 1))   --> nil, nada chegou
conn:settimeout(nil)         -- de volta aos 5 segundos da própria conexão

conn:release()
```

### conn:ttl(key)

**Retorna** os segundos restantes, `-1` quando a chave existe sem expiração,
`-2` quando a chave está ausente.

```lua
local redis = require "akkar.redis"
local conn = redis.connect { port = 6379 }()

conn:set("ref_redis_brief", "1", 30)
print(conn:ttl "ref_redis_brief")     --> 30
print(conn:ttl "ref_redis_gone")      --> -2

conn:del "ref_redis_brief"
conn:release()
```

## O que não está aqui

**Sem pipelining.** Um comando, uma resposta, uma viagem de ida e volta. Um script
por meio de `EVAL` é como várias operações custam uma única viagem, e isso as
torna atômicas também.

**Sem pub/sub.** Uma conexão inscrita para de responder a comandos comuns, o que
uma conexão vinda de um pool não pode fazer. `conn:command("SUBSCRIBE", ...)`
envia o comando e depois deixa você segurando uma conexão que o pool nunca deve
receber de volta.

**Sem helpers de `MULTI` e `EXEC`.** Os comandos brutos passam por `conn:command`,
mas nada aqui mantém uma transação em uma única conexão para você. Use um script.

**Sem cluster, sem sentinel, sem TLS.** Um host, uma porta, um socket simples.

**Sem validação de configuração.** Chaves desconhecidas na tabela de `connect` são
ignoradas em vez de rejeitadas, o que não é como [`app:run`](akkar.md#apprunconfig)
se comporta.

**Sem RESP3.** O leitor de respostas trata os cinco tipos do RESP2 e levanta erro
`unexpected RESP tag` em qualquer outra coisa.

## Veja também

- [akkar.cache.memory](cache.md) para o mesmo contrato sem um servidor, para
  testes e implantações de processo único
- [akkar.jobs](jobs.md), cujo store Redis é construído sobre uma conexão daqui
- [akkar](akkar.md) para `app:run { cache = ... }`, que recebe uma conexão
  diretamente
- o código-fonte do módulo, `akkar/redis.lua`, para entender por que o protocolo
  é escrito por extenso em vez de depender de uma biblioteca
