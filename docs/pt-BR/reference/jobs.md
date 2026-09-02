# akkar.jobs

> **Português (Brasil)** | [Original em inglês](../../reference/jobs.md)

A semântica de uma fila de jobs sem nenhum armazenamento embutido: o que é um job, o que acontece quando um handler falha, e o que um worker loop faz. O armazenamento é um objeto separado chamado store, e este módulo envolve um.

**Quando você precisa disso.** Um handler tem trabalho que quem chamou não está esperando (um e-mail, um relatório, uma imagem redimensionada) e a resposta deve sair antes que esse trabalho termine.

```lua no-run
local jobs = require "akkar.jobs"
```

Dois stores acompanham o akkar. [`akkar.jobs.memory`](#akkarjobsmemory) mantém os jobs numa tabela Lua, [`akkar.jobs.redis`](#akkarjobsredis) mantém os jobs no Redis.

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`jobs.delay_for`](#jobsdelay_forattempt-backoff) | função |
| [`jobs.new`](#jobsnewstore-name-options) | função |
| [`jobs.Queue`](#queue) | tabela |
| [`memory.new`](#memorynewname-options) | função |
| [`memory.Store`](#memorystore-metatable) | tabela |
| [`memory.store`](#memorystore) | função |
| [`queue:ack`](#queueackjob) | método |
| [`queue:consume`](#queueconsumehandlers-options) | método |
| [`queue:dead_depth`](#queuedead_depth) | método |
| [`queue:dead_key`](#queuedead_key) | método |
| [`queue:dead_letters`](#queuedead_letterslimit) | método |
| [`queue:depth`](#queuedepth) | método |
| [`queue:fail`](#queuefailjob-err) | método |
| [`queue:in_flight`](#queuein_flight) | método |
| [`queue:pop`](#queuepoptimeout) | método |
| [`queue:push`](#queuepushkind-payload-options) | método |
| [`queue:reap`](#queuereapnow) | método |
| [`queue:reliable`](#queuereliable) | método |
| [`redis.new`](#redisnewcache-name-options) | função |
| [`redis.Store`](#redisstore) | tabela |
| [o contrato do store](#o-contrato-do-store) | contrato |

## O contrato do store

Um store é qualquer tabela com estes três métodos. `jobs.new` verifica se eles existem e recusa qualquer outra coisa.

| método | significado |
|---|---|
| `store:enqueue(key, encoded)` | adiciona ao fim; retorna a nova profundidade |
| `store:dequeue(key, timeout)` | a entrada mais antiga, ou `nil` no timeout |
| `store:depth(key)` | quantos estão esperando |

Estes são opcionais, e cada um oferece uma funcionalidade nomeada. Pedir a funcionalidade a um store que não implementa o método é um erro na chamada, não uma funcionalidade que silenciosamente não faz nada.

| método | o que oferece |
|---|---|
| `store:schedule(key, encoded, run_at)` | `push` com `options.delay`, e cada retry |
| `store:promote(key, now)` | um job atrasado ou em retry de fato ficar pronto para execução |
| `store:claim(key, id, ttl)` | `push` com `options.id` |
| `store:unclaim(key, id)` | devolver esse id quando o push para o qual ele foi reservado falha |
| `store:claim_and_enqueue(key, id, ttl, encoded, run_at)` | reservar e empurrar, em um único passo indivisível |
| `store:claim_pop(key, timeout)` | entrega ao menos uma vez |
| `store:ack(key, encoded)` | entrega ao menos uma vez |
| `store:expired(key, visibility, now, limit)` | entrega ao menos uma vez |
| `store:in_flight(key)` | entrega ao menos uma vez |
| `store:peek(key, limit)` | `queue:dead_letters` |
| `store:trim(key, keep)` | a lista de dead letters se manter abaixo de `max_dead` |

Os dois stores que acompanham o akkar implementam todos eles.

**Os últimos quatro vêm como um conjunto.** `jobs.new` só ativa a entrega ao menos uma vez quando os quatro estão presentes, porque um store que arrenda um job sem conseguir dizer quais arrendamentos expiraram fica com esse job para sempre, o que é uma falha pior do que nunca arrendá-lo. Um store com três dos quatro tem entrega no máximo uma vez e diz isso explicitamente; veja [`jobs.new`](#jobsnewstore-name-options).

`store:expired` retorna os jobs codificados cujo arrendamento expirou, **do
mais antigo para o mais novo**, e carimba cada um que retorna, para que um
segundo reaper chegando no meio de uma passagem não pegue nada. Ele não os
remove: eles permanecem em trânsito até que `queue:reap` tenha escrito a
próxima cópia e confirmado a antiga, então um reaper que morre no meio custa
uma reentrega em vez do job. O `now` dele é um ponto de acesso para testes;
deixado de fora, o store responde com seu próprio relógio, que no caso do
Redis é o `TIME` do servidor e é o único relógio que todo worker de uma frota
compartilha.

A ordem do mais antigo para o mais novo faz parte do contrato, e agora os dois
stores a respeitam. O store Redis não respeitava: `RPOPLPUSH` insere no início
da lista de processamento, então a janela de `LRANGE` voltava do mais novo para
o mais antigo. Uma recuperação em massa — durante um deploy, um encerramento por
OOM ou a reinicialização de uma frota, que são justamente os momentos em que
mais de um arrendamento expira de uma vez — reentregava em LIFO no Redis e em
FIFO na memória. LIFO deixa a entrada no fim da lista sem atendimento; essa é
a entrada que foi reentregue mais vezes e, portanto, a mais próxima de
`max_redeliveries`. Todos os specs existentes recuperavam um único job, caso
em que a ordem não pode ser observada.

## jobs.delay_for(attempt, backoff)

O cronograma de backoff, exposto para que quem chama possa imprimi-lo ou testá-lo. `attempt` é `1` para o primeiro retry.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `first` | number | `base` | a primeira janela, em segundos |
| `factor` | number | `base` | pelo que cada janela é multiplicada |
| `base` | number | `2` | define `first` e `factor` de uma vez, dando `base ^ attempt` |
| `max` | number | `300` | o teto sobre essa janela |
| `jitter` | boolean | `true` | quando não for `false`, a resposta é um sorteio uniforme entre zero e a janela |

A janela é `first * factor ^ (attempt - 1)`, limitada por `max`. `base` é o atalho para o caso em que os dois são o mesmo número, e é o padrão, então `{}` resulta em `2, 4, 8, 16`, exatamente como antes.

`first` e `factor` existem porque `base ^ attempt` não consegue expressar o cronograma que a maioria dos sistemas de retry usa: um primeiro atraso fixo que dobra a cada vez. Entregar webhooks para o endpoint de outra pessoa é o caso comum:

```lua no-run
{ first = 60, factor = 2, max = 4 * 60 * 60 }   --> 60, 120, 240, 480, ... 4h
```

**A resolução é abaixo de um segundo**, e a fração importa: com jitter ligado, a resposta é uma fração da janela, e os dois stores preservam isso. O store de memória agenda contra um relógio monotônico e o store Redis lê os microssegundos do `TIME` do servidor.

Jitter não é enfeite. Cem jobs que falharam contra um banco de dados que acabou de voltar, de outra forma, todos tentariam de novo no mesmo segundo.

**Retorna** um atraso em segundos.

```lua
local jobs = require "akkar.jobs"

-- Sem jitter, é a própria janela, limitada por max.
print(jobs.delay_for(1, { jitter = false }))            --> 2.0
print(jobs.delay_for(3, { jitter = false }))            --> 8.0
print(jobs.delay_for(20, { jitter = false }))           --> 300

-- Com jitter, em algum ponto de [0, window).
local delay = jobs.delay_for(3, {})
assert(delay >= 0 and delay < 8)
```

## jobs.new(store, name, options)

Envolve um store com a semântica de fila. `name` separa uma fila de outra; jobs enviados sob um nome só são pegos por workers lendo esse nome. O padrão é `"default"`.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `retries` | number | `0` | tentativas após a primeira. `0` significa que um handler que lança erro é enterrado ou descartado imediatamente. |
| `backoff` | table | `{}` | passado para `jobs.delay_for`; veja os campos dela acima |
| `dead_letter` | boolean | `true` | manter o que finalmente falhou numa segunda lista. Só um `false` explícito desativa isso. |
| `max_dead` | number | `1000` | quantas dead letters manter, quando o store consegue fazer `trim` |
| `delivery` | string | inferido | `"at_least_once"` ou `"at_most_once"`. Deixado de fora, é ao menos uma vez sempre que o store consegue arrendar. |
| `visibility` | number | `300` | segundos que um worker pode segurar um job antes que outro possa pegá-lo |
| `max_redeliveries` | number | `5` | reentregas antes de um job ir para as dead letters |
| `reap_every` | number | `visibility / 10` | segundos entre os reaps automáticos que `pop` executa |

**Retorna** uma `Queue`. Seu campo `key` é `"akkar:queue:" .. name`, que é a chave no Redis quando o store é Redis.

**Lança** `akkar.jobs: store does not satisfy the contract; missing :enqueue` (ou `:dequeue`, ou `:depth`) quando o store não é um store.

**Lança** `akkar.jobs: retries need a store that can schedule, and this one implements neither :schedule nor :promote ...` quando `retries` é maior que zero e o store não consegue segurar um job até mais tarde. Recusado na construção em vez de na primeira falha.

**Lança** `akkar.jobs: delivery must be 'at_least_once' or 'at_most_once' ...` para qualquer outro valor, de modo que um erro de digitação não vire silenciosamente um downgrade.

**Lança** `akkar.jobs: at-least-once delivery needs a store that can hold a job in flight ...` quando `delivery = "at_least_once"` é pedido a um store que não consegue arrendar. Aceitar a configuração e entregar no máximo uma vez mesmo assim é o único resultado pior do que não oferecer a opção.

Um store que não consegue arrendar ainda assim constrói uma fila. Essa fila reporta `delivery == "at_most_once"` em vez de afirmar o contrário, e `delivery = "at_most_once"` sobre um store que CONSEGUE arrendar é como você pede esse comportamento de propósito.

```lua
local jobs   = require "akkar.jobs"
local memory = require "akkar.jobs.memory"

local queue = jobs.new(memory.store(), "ref_jobs_email", {
  retries = 3,
  backoff = { base = 2, max = 300 },
})

print(queue.key)         --> akkar:queue:ref_jobs_email
print(queue.retries)     --> 3
print(queue.delivery)    --> at_least_once
print(queue:reliable())  --> true

-- O mesmo store, instruído a ser pouco confiável de propósito.
local careless = jobs.new(memory.store(), "ref_jobs_careless",
                          { delivery = "at_most_once" })
print(careless.delivery)  --> at_most_once

-- Um store com apenas os três métodos obrigatórios não pode fazer retry.
local bare = {
  enqueue = function() return 1 end,
  dequeue = function() return nil end,
  depth   = function() return 0 end,
}
print(pcall(jobs.new, bare, "ref_jobs_bare", { retries = 1 }))
```

## Queue

O objeto que `jobs.new` retorna. Sua metatable é exportada como `jobs.Queue`.

Um job passando por ela é uma tabela com estes campos:

| campo | significado |
|---|---|
| `uid` | a identidade deste job, cunhada por `push` e inalterada em cada retry e reentrega |
| `kind` | a string passada para `push`; um worker a procura em sua tabela de handlers |
| `payload` | o segundo argumento de `push`, depois de ir e voltar por JSON |
| `id` | o id de deduplicação, quando um foi fornecido |
| `queued_at` | o momento em que `push` foi chamado |
| `attempts` | quantas vezes um handler falhou neste job |
| `redeliveries` | quantas vezes um worker pegou este job e parou de responder |
| `last_error`, `first_failed_at`, `died_at` | adicionados por `fail`, quando se aplicam |

**`uid` é o campo para deduplicar, e não é `id`.** `id` impede um segundo PUSH e é opcional; `uid` está presente em todo job e identifica um job ao longo de quantas execuções ele tiver. `attempts` e os bytes codificados mudam num retry, então nenhum dos dois pode ser essa chave. Escreva seu marcador de "já fiz isso" sob `uid`, na mesma transação que o efeito colateral, e um handler que roda duas vezes faz seu trabalho uma única vez.

`redeliveries` é contado separadamente de `attempts` de propósito: `attempts` é o handler dizendo não, e um worker morto por OOM não é o handler dizendo nada. Debitar uma reentrega do orçamento de retries enterraria trabalho saudável depois de um deploy que reiniciou a frota três vezes.

O payload passa por JSON, então uma tabela volta como tabela e um número volta como float Lua. Não coloque uma linha de banco de dados num payload: coloque um id, e leia a linha atualizada quando o job rodar.

### queue:ack(job)

Marca um job como concluído para que ele pare de ser recuperável. `consume` chama isso para você depois que um handler retorna; no caminho de falha, [`queue:fail`](#queuefailjob-err) faz isso, assim que o retry ou o sepultamento é registrado.

**Retorna** `true` quando o job ainda estava reservado para você, e `false` quando não estava, o que significa que o arrendamento já havia expirado e outra pessoa está com o job, então esta execução foi uma duplicata e `visibility` está mais curto do que o tempo real de execução do handler. Esse é o único sintoma de um timeout de visibilidade configurado baixo demais, e `consume` conta isso como `duplicated`.

**Retorna** `true` sob entrega no máximo uma vez, onde nunca houve nada para retirar.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_ack"
queue:push("ping", {})

local job = queue:pop(0)
print(queue:in_flight())   --> 1
print(queue:ack(job))      --> true
print(queue:in_flight())   --> 0
```

### queue:consume(handlers, options)

O worker loop. Ele desenfileira um job, procura `job.kind` em `handlers`, chama o handler com `(job.payload, job)` sob `pcall`, e confirma. Repete até que `should_stop()` responda true.

Um job cujo `kind` não está em nenhum handler não é descartado. Ele segue o mesmo caminho de falha de um handler que lança erro, porque a causa usual é um deploy em andamento em que o worker roda um código mais antigo do que o produtor.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `should_stop` | function | nunca para | chamado antes de cada pop; o loop termina quando retorna true |
| `timeout` | number | `1` | segundos para esperar um job em cada pop |
| `log` | table | nenhum | um logger `akkar.log`. Sem um, um job que falha é silencioso. |

**Retorna** `{ handled, failed, retried, buried, duplicated }`. `duplicated` conta jobs cujo handler terminou depois que o arrendamento já havia expirado, o que significa que estavam rodando duas vezes.

**A entrega é ao menos uma vez, a menos que a fila tenha sido configurada de outra forma**, e `queue.delivery` diz qual você tem.

**O reaper roda encostado no `pop`**, então qualquer worker consumindo de uma fila também está recuperando ela, e não há processo zelador para esquecer de implantar. Um job cujo worker foi morto volta para a fila dentro de `visibility + reap_every` segundos e não antes, porque não há como distinguir um worker morto de um worker lento a não ser esperando.
[`queue:reap`](#queuereapnow) é público para quem quiser um mesmo assim.

Um `consume` sem `should_stop` nunca retorna. Num processo de servidor, rode-o sob `app:task` em vez de chamá-lo diretamente.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_consume"
queue:push("greet", { who = "world" })
queue:push("greet", { who = "again" })

local rounds = 0
local stats = queue:consume({
  greet = function(payload) print("hello " .. payload.who) end,
}, {
  timeout = 0,
  should_stop = function() rounds = rounds + 1 return rounds > 3 end,
})

print(stats.handled, stats.failed, stats.duplicated)   --> 2 0 0
```

### queue:dead_depth()

**Retorna** quantos jobs finalmente falharam e estão na lista de dead letters. Um número que cresce é algo a se observar.

### queue:dead_key()

**Retorna** a chave sob a qual a lista de dead letters vive, que é `queue.key .. ":dead"`.

```lua
local memory = require "akkar.jobs.memory"

print(memory.new("ref_jobs_keys"):dead_key())
--> akkar:queue:ref_jobs_keys:dead
```

### queue:dead_letters(limit)

Lê as dead letters sem removê-las, das mais antigas para as mais novas. `limit` tem como padrão `100`. Bytes que não conseguissem ser decodificados ficam de fora do resultado.

**Retorna** um array de jobs.

**Lança** `akkar.jobs: this store cannot list dead letters; it implements no :peek` quando o store não tem `peek`.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_dead"
queue:push("boom", { order = 41 })

local job = queue:pop(0)
queue:fail(job, "the payment gateway said no")

local dead = queue:dead_letters(10)
print(#dead, dead[1].kind, dead[1].last_error)
--> 1  boom  the payment gateway said no
```

### queue:depth()

**Retorna** quantos jobs estão esperando. Não conta jobs agendados para mais tarde, nem jobs que um worker está segurando no momento.

### queue:fail(job, err)

Devolve um job que falhou depois do seu backoff, ou o sepulta. `consume` chama isso; chame você mesmo apenas se estiver escrevendo seu próprio loop.

Incrementa `job.attempts`, define `job.last_error` e define `job.first_failed_at` se ainda não estivesse definido.

**Retorna** um destes:

| retorno | quando |
|---|---|
| `"retried", delay` | `job.attempts` ainda está dentro de `retries`. O job é reagendado `delay` segundos à frente. |
| `"buried"` | esgotaram-se os retries, e `dead_letter` está ligado |
| `"dropped"` | esgotaram-se os retries, e `dead_letter` é `false` |

```lua
local jobs   = require "akkar.jobs"
local memory = require "akkar.jobs.memory"

local queue = jobs.new(memory.store(), "ref_jobs_fail", {
  retries = 1,
  backoff = { base = 2, max = 60, jitter = false },
})

queue:push("charge", { order = 41 })
local job = queue:pop(0)

print(queue:fail(job, "gateway timeout"))   --> retried  2.0
print(queue:fail(job, "gateway timeout"))   --> buried
print(queue:dead_depth())                   --> 1
```

### queue:in_flight()

**Retorna** quantos jobs estão atualmente reservados por um worker, ou `0` sob entrega no máximo uma vez, onde nada é jamais mantido.

### queue:pop(timeout)

Espera por um job, até `timeout` segundos. `timeout` tem como padrão `5`, e `0` significa olhar sem esperar.

Antes de olhar, pede ao store para promover qualquer coisa cujo atraso já tenha vencido. Segue o caminho confiável quando o store oferece um: o job se move para um conjunto de processamento ao sair da fila, num único passo, e permanece lá até ser confirmado.

**Retorna** o job, ou `nil` no timeout, ou `nil, "akkar.jobs: undecodable job discarded"` quando os bytes na cabeça da fila não são JSON. Bytes indecodificáveis são confirmados e então movidos para a lista de dead letters em vez de descartados.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_pop"
print(tostring(queue:pop(0)))   --> nil, a fila está vazia

queue:push("resize", { image_id = 7 })
local job = queue:pop(0)
print(job.kind, job.payload.image_id, job.attempts)   --> resize 7.0 0.0
```

### queue:push(kind, payload, options)

Enfileira um job. `kind` é a string que um worker procura em sua tabela de handlers. `payload` é codificado como JSON.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `delay` | number | nenhum | segurar o job por esta quantidade de segundos antes que um worker possa pegá-lo |
| `id` | string | nenhum | recusar este push se o mesmo id foi enviado recentemente |
| `id_ttl` | number | `3600` | por quanto tempo esse id fica reservado, em segundos |

**Retorna** a profundidade depois do push, ou `false, "duplicate"` quando `id` já estava reservado.

**Lança** `akkar.jobs: this store cannot deduplicate -- it implements no :claim ...` quando `id` é fornecido e o store não tem `claim`.

**Lança** `akkar.jobs: this store cannot delay a job; it implements no :schedule` quando `delay` é fornecido e o store não tem `schedule`.

Um `id` é deduplicação na porta de entrada. Impede que o mesmo job seja enfileirado duas vezes. Não impede que um job que foi enfileirado uma vez rode duas vezes, que é o que `reap` e a entrega ao menos uma vez tornam possível; veja [`queue:reliable()`](#queuereliable).

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_push"

print(queue:push("welcome_email", { account_id = 13 },
                 { id = "welcome:13" }))            --> 1
print(queue:push("welcome_email", { account_id = 13 },
                 { id = "welcome:13" }))            --> false  duplicate

-- Retido por uma hora, então ainda não está esperando.
queue:push("digest", { account_id = 13 }, { delay = 3600 })
print(queue:depth())                                --> 1
```

### queue:reap(now)

Devolve à fila cada job cujo worker parou de responder, e sepulta os que já sobreviveram a mais workers do que `max_redeliveries`.

**Retorna** quantos foram reentregues e quantos foram sepultados, ou `0, 0` sob entrega no máximo uma vez, onde nada é jamais mantido.

**Deixe `now` de fora.** Assim o store responde com o relógio que todo worker compartilha, no caso do Redis, o próprio `TIME` do servidor, lido dentro do script, e esse é o ponto todo: um corte calculado por um único worker tornava cada reap uma afirmação sobre o tempo feita por uma máquina que poderia ter acabado de ser ajustada pelo NTP. Uma correção para a frente reclamaria jobs que outros workers estavam ativamente executando; uma correção para trás não reclamaria nada, nunca mais.

O que decide se algo está obsoleto é [`visibility`](#jobsnewstore-name-options), que é a configuração da fila em vez de uma opinião de quem chama, **e ela precisa exceder o tempo máximo que um handler pode legitimamente levar.** Configure-a baixa demais e um job lento é entregue a um segundo worker enquanto o primeiro ainda está trabalhando nele.

`now` é um ponto de acesso para testes, para uma spec ou um operador que não pode esperar uma janela inteira passar: ele move o corte e nada mais, então o momento da reserva ainda é escrito a partir do relógio do store.

`pop` faz reap para você a cada `reap_every` segundos, então chamar isso diretamente é opcional.

```lua
local memory = require "akkar.jobs.memory"

local queue = memory.new "ref_jobs_reap"
queue:push("slow", {})

-- Um worker pega o job e morre sem confirmá-lo.
queue:pop(0)
print(queue:depth(), queue:in_flight())   --> 0  1

-- Nada venceu ainda: o arrendamento tem cinco minutos pela frente. Entre
-- parênteses porque `reap` responde com dois números, reentregados e sepultados.
print((queue:reap()))                     --> 0

-- Um instante além da janela de visibilidade, porque este exemplo não pode
-- esperar cinco minutos. Num worker você não passaria nada e deixaria o
-- tempo passar.
print((queue:reap(os.time() + 301)))      --> 1
print(queue:depth(), queue:in_flight())   --> 1  0
```

### queue:reliable()

**Retorna** `true` quando esta fila sobrevive a um worker morrendo no meio de um job, o que é o mesmo que `queue.delivery == "at_least_once"`.

Responde o que esta fila FAZ em vez do que seu store poderia fazer, porque `delivery = "at_most_once"` torna essas duas perguntas diferentes.

Vale a pena perguntar em vez de presumir. A resposta decide se um job que importa pode passar por esta fila.

## akkar.jobs.memory

Armazenamento em processo para uma fila de jobs. Implementa todo método do contrato, obrigatório e opcional, então retries, atrasos, deduplicação e reaping podem todos ser exercitados sem Redis.

```lua no-run
local memory = require "akkar.jobs.memory"
```

`dequeue` não bloqueia, seja qual for o timeout passado. Trabalho só pode chegar deste mesmo processo, então dormir esperando por ele seria um deadlock em vez de uma espera.

### memory.new(name, options)

**Retorna** uma `Queue` sobre um store novo, que é `jobs.new(memory.store(), name, options)`. `options` é repassado inteiro, então tudo em [`jobs.new`](#jobsnewstore-name-options) funciona aqui.

### memory.store()

**Retorna** um store cru, para entregar a `jobs.new`.

### memory.Store (metatable)

A metatable do store. Seus métodos além do contrato são `store:processing_key(key)` e `store:scheduled_depth(key)`.

```lua
local jobs   = require "akkar.jobs"
local memory = require "akkar.jobs.memory"

local store = memory.store()
local queue = jobs.new(store, "ref_jobs_store", { retries = 2 })

queue:push("later", {}, { delay = 60 })
print(store:scheduled_depth(queue.key))   --> 1
print(queue:depth())                      --> 0
```

## akkar.jobs.redis

Armazenamento Redis para uma fila de jobs. A semântica fica em `akkar.jobs`; isto apenas armazena e recupera.

```lua no-run
local redis = require "akkar.jobs.redis"
```

Uma lista Redis dá FIFO de graça. O agendamento é um sorted set com pontuação pelo segundo em que um job vence. A deduplicação é `SET NX EX`, que é atômico entre todo processo conversando com esse Redis, e é essa a razão pela qual a deduplicação pertence ao store e não ao worker.

### redis.new(cache, name, options)

`cache` é uma conexão, não um conector: `akkar.redis.connect{}` retorna uma função que abre conexões, então a chamada precisa dos `()` extras.

**Retorna** uma `Queue`. `options` é repassado inteiro para [`jobs.new`](#jobsnewstore-name-options), da mesma forma que `memory.new`.

```lua no-run
local redis = require "akkar.redis"
local jobs  = require "akkar.jobs.redis"

local queue = jobs.new(redis.connect { port = 6379 }(), "email")
```

### redis.Store

A metatable do store, exposta para que uma fila com opções possa ser construída sobre ela:

```lua no-run
local jobs      = require "akkar.jobs"
local redisjobs = require "akkar.jobs.redis"
local redis     = require "akkar.redis"

local store = setmetatable({ cache = redis.connect { port = 6379 }() },
                           redisjobs.Store)

local queue = jobs.new(store, "email", { retries = 3, dead_letter = true })
```

Seus métodos além do contrato são `store:processing_key(key)`, `store:claimed_key(key)`, `store:scheduled_key(key)` e `store:scheduled_depth(key)`.

### As chaves Redis que uma fila usa

Para uma fila chamada `email`, com `key` igual a `akkar:queue:email`:

| chave | contém |
|---|---|
| `akkar:queue:email` | a lista de jobs esperando |
| `akkar:queue:email:scheduled` | um sorted set de jobs atrasados e em retry, com pontuação por quando vencem |
| `akkar:queue:email:processing` | a lista de jobs que um worker atualmente detém |
| `akkar:queue:email:processing:at` | um sorted set pontuando cada job retido por quando foi tomado; é isto que `reap` lê |
| `akkar:queue:email:dead` | a lista de jobs que finalmente falharam |
| `akkar:queue:email:claim:<id>` | uma chave por id de deduplicação, com o `id_ttl` nela |

Um ciclo completo contra um Redis ativo:

```lua
local cqueues = require "cqueues"
local redis   = require "akkar.redis"
local jobs    = require "akkar.jobs.redis"

local loop = cqueues.new()
loop:wrap(function()
  local conn  = redis.connect { host = "127.0.0.1", port = 6379 }()
  local queue = jobs.new(conn, "ref_jobs_demo")

  print(queue:reliable())                       --> true
  queue:push("welcome_email", { account_id = 13 }, { id = "ref_jobs:13" })
  print(queue:push("welcome_email", { account_id = 13 },
                   { id = "ref_jobs:13" }))     --> false  duplicate
  print(queue:depth())                          --> 1

  local job = queue:pop(0)
  print(job.kind, queue:in_flight())            --> welcome_email  1
  queue:ack(job)
  print(queue:depth(), queue:in_flight())       --> 0  0

  conn:del(queue.key, queue.key .. ":scheduled", queue.key .. ":processing",
           queue.key .. ":processing:at", queue:dead_key(),
           queue.key .. ":claim:ref_jobs:13")
  conn:release()
end)
assert(loop:loop())
```

## O que não está aqui

**Sem agendador.** Nada chama `reap` por você, e nada roda um job num cron. A fila mantém um job até que um worker o peça, e `options.delay` é a única temporização que ela conhece.

**Sem comando de worker.** `queue:consume` é um loop Lua que você coloca em seu próprio arquivo, ou uma [`app:task`](akkar.md#apptaskname-fn) no processo do servidor. O akkar não vem com um binário `akkar worker`.

**Sem prioridades.** Um nome, uma lista FIFO. Duas prioridades significam duas filas e dois workers.

**Sem store de Postgres.** O contrato existe para que um possa ser escrito; nenhum acompanha o akkar.

**Sem deduplicação automática de uma reentrega.** `push` com um `id` impede um segundo push; nada impede que o mesmo job seja entregue duas vezes, porque é isso que entrega ao menos uma vez significa. Escreva um marcador sob `job.uid` dentro da transação que faz o trabalho.

## Veja também

- [akkar](akkar.md) para `app:task`, que roda um consumer dentro do próprio loop do servidor
- [akkar.redis](redis.md) para `connect`, que produz a conexão que `akkar.jobs.redis` precisa
- [akkar.work](work.md) para a outra resposta a trabalho lento: fazer yield dentro da requisição em vez de deixá-lo de lado
- a página do guia sobre [trabalho em segundo plano](../guide/10-background-work.md) para o mesmo conteúdo ensinado em vez de listado
- o código-fonte do módulo, `akkar/jobs.lua`, para entender por que a semântica e o armazenamento são separados
