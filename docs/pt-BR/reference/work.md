# akkar.work

> **Português (Brasil)** | [Original em inglês](../../reference/work.md)

Funções auxiliares para trabalho que computa em vez de esperar. Um processo roda uma VM Lua em um núcleo com um agendador cooperativo, então um handler que computa por 250 ms trava todas as outras requisições por 250 ms. Essas funções transformam uma trava longa em muitas travas curtas.

**Quando você precisa disso.** Um handler monta um CSV, renderiza uma lista grande ou percorre uma tabela com milhares de linhas, e outras requisições ficam lentas enquanto isso acontece.

```lua no-run
local work = require "akkar.work"
```

Para trabalho que quem chamou nem está esperando, este não é o módulo certo. Coloque em uma fila: veja [akkar.jobs](jobs.md).

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`work.chunked`](#workchunkedevery) | function |
| [`work.queue`](#workqueuecache-name) | function |
| [`work.yielding`](#workyieldingevery-fn) | function |

## work.chunked(every)

**Retorna** uma função que envolve outra função e retorna o wrapper. O wrapper repassa seus próprios argumentos adiante, **acrescenta um `yield` como mais um argumento**, e retorna o que a função envolvida retornar. Chamar esse `yield` cede a vez ao agendador uma vez a cada `every` chamadas, exatamente como [`work.yielding`](#workyieldingevery-fn) faz -- o wrapper só poupa você de construir o contador.

```lua no-run
local slow = work.chunked(500)(function(rows, yield)
  return render(rows, yield)
end)
```

**O yield precisa ser chamado.** Esse wrapper já foi um wrapper de identidade: a função envolvida era invocada sem o `yield` pelo qual o orçamento é gasto, então nada dentro dela conseguia alcançar o agendador, e `chunked` ao longo de um milhão de iterações produzia zero viagens ao agendador enquanto se documentava como um orçamento de yield. Agora ele é passado, mas um corpo que o ignora continua sem ceder nada -- não há como interromper código Lua que não coopera, e o cabeçalho deste módulo explica por quê.

```lua
local cqueues = require "cqueues"
local work    = require "akkar.work"

local loop = cqueues.new()
loop:wrap(function()
  local neighbour = 0
  loop:wrap(function()
    for _ = 1, 1000 do neighbour = neighbour + 1 cqueues.poll(0) end
  end)

  local total = work.chunked(1000)(function(n, yield)
    local sum = 0
    for i = 1, n do sum = sum + i yield() end
    return sum
  end)(1000000)

  print(total)                     --> 500000500000
  print(neighbour > 0)             --> true
end)
assert(loop:loop())
```

## work.queue(cache, name)

Constrói uma fila de jobs sobre uma conexão Redis. Ela repassa para `akkar.jobs.redis.new(cache, name)` e nada além disso, então qualquer código escrito contra o antigo `work.queue` continua funcionando.

**Retorna** uma `Queue`. Tudo o que ela pode fazer está documentado em [akkar.jobs](jobs.md).

Código novo deve chamar `akkar.jobs.redis` diretamente. A fila está ali porque a semântica de um job é separada de onde um job é armazenado, e essa função é anterior a essa separação.

```lua
local work  = require "akkar.work"
local redis = require "akkar.redis"

local conn  = redis.connect { port = 6379 }()
local queue = work.queue(conn, "ref_work_demo")

print(queue.key)          --> akkar:queue:ref_work_demo
queue:push("resize", { image_id = 7 })
print(queue:depth())      --> 1

local job = queue:pop(0)
print(job.kind)           --> resize
queue:ack(job)

conn:del(queue.key, queue.key .. ":processing", queue.key .. ":processing:at")
conn:release()
```

## work.yielding(every, fn)

Chama `fn(yield)`. Chamar `yield()` dentro de `fn` cede a vez ao agendador uma vez a cada `every` chamadas, e não faz nada nas chamadas intermediárias. O contador fica guardado dentro do helper, então o corpo do loop escreve `yield()` e ninguém precisa manter um módulo.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `every` | number | `500` | um yield real a cada esse número de chamadas de `yield()` |
| `fn` | function | obrigatório | chamada imediatamente como `fn(yield)` |

**Retorna** o que `fn` retornar.

Ceder a vez não é grátis. Medido em um loop de cerca de 200 ms, registrado no código-fonte do módulo:

| `every` | a própria tarefa | pior espera do vizinho |
|---|---|---|
| sem yield | 202 ms | 200.5 ms |
| 50000 | 520 ms | 28.7 ms |
| 2000 | 557 ms | 0.9 ms |

A latência do vizinho cai duas ordens de grandeza e a própria tarefa fica cerca de 2.7 vezes mais lenta, porque cada yield custa uma viagem pelo agendador. Escolha um `every` mais grosseiro quando a tarefa importa mais que os vizinhos, mais fino quando é o contrário.

```lua
local cqueues = require "cqueues"
local work    = require "akkar.work"

local loop = cqueues.new()
loop:wrap(function()
  local neighbour = 0
  loop:wrap(function()
    for _ = 1, 100 do neighbour = neighbour + 1 cqueues.poll(0) end
  end)

  local total = work.yielding(10, function(yield)
    local sum = 0
    for i = 1, 100 do
      sum = sum + i
      yield()
    end
    return sum
  end)

  print(total)                      --> 5050
  print("neighbour ran", neighbour) --> 10
end)
assert(loop:loop())
```

Dentro de um handler, fica assim. A resposta sai depois que o loop inteiro rodou, e as requisições ao lado não ficam esperando durante isso:

```lua
local akkar = require "akkar"
local work  = require "akkar.work"

local app = akkar.new()

app:get("/report", function()
  local rows = {}
  work.yielding(500, function(yield)
    for i = 1, 5000 do
      rows[#rows + 1] = { id = i, total = i * 3 }
      yield()
    end
  end)
  return { rows = akkar.array(rows) }
end)

local res = app:test{}:get "/report"
print(res.status, #res.body.rows)   --> 200 5000
```

## O que não está aqui

**Nada que conserte uma chamada C bloqueante.** Hash de senha roda dentro do C pelo tempo que for necessário e o Lua nunca recupera o controle, então não existe um ponto em que um yield poderia acontecer. As respostas para isso ficam fora deste módulo: rode um processo por núcleo para que um worker bloqueado represente apenas 1/N da capacidade, reduza o fator de custo de forma consciente, ou mova o trabalho para trás de uma fila e mude o que o endpoint promete.

**Sem threads.** Um processo, uma VM, um núcleo. Mais CPU significa mais processos.

**Sem orçamento de tempo.** `every` conta chamadas, não milissegundos. Um loop cujas iterações variam muito de custo cede a vez de forma desigual, e nada aqui mede isso.

**Sem yield automático.** Nada insere um yield em um loop no qual você não escreveu um.

## Veja também

- [akkar.jobs](jobs.md) para a outra resposta: deixar a requisição por completo e deixar um processo separado fazer o trabalho em outro núcleo
- [akkar](akkar.md) para `app:test{}`, e para o watchdog que reporta um loop bloqueado em vez de consertar um
- o código-fonte do módulo, `akkar/work.lua`, para as medições acima e para o que nenhum dos dois helpers resolve
