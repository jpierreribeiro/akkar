# akkar.workflow

> **Português (Brasil)** | [Original em inglês](../../reference/workflow.md)

Uma função de longa duração cujas etapas já concluídas não rodam duas vezes. Ela pode levar uma semana, dormir no meio de si mesma, falhar pela metade e ser repetida, e ser morta junto com o worker -- e as partes que já terminaram não acontecem de novo.

**Quando você precisa disso.** Um trabalho tem várias etapas, cada uma tocando algo que você não consegue desfazer -- uma linha, uma cobrança, um e-mail -- e o conjunto todo precisa sobreviver a uma queda entre quaisquer duas delas. Um job sozinho te dá novas tentativas (retries); ele não te dá "comece de novo, mas pule o que já deu certo".

```lua no-run
local workflow = require "akkar.workflow"
```

Um workflow é um job. Ele roda sobre [`akkar.jobs`](jobs.md) com [`akkar.jobs.postgres`](jobs.md#o-contrato-do-store), então retries com backoff, a dead letter, o lease de entrega pelo menos uma vez e o reaper são daquele módulo e não são reimplementados aqui. O que este acrescenta é uma tabela, `akkar_workflow_steps`, e dois métodos num contexto.

O formato é o do Inngest, não o do Temporal. O Temporal reexecuta um workflow contra um histórico gravado e precisa da função em sandbox contra o relógio, o gerador aleatório e toda chamada de IO, para que o replay tome os mesmos caminhos. O akkar não consegue fazer isso honestamente -- `os.time` e todo socket do processo são alcançáveis a partir de qualquer handler -- então os efeitos colaterais ficam atrás de etapas memoizadas e a função é livre para rodar de novo desde o começo.

## O que "exatamente uma vez" cobre, e o que não cobre

Leia isto antes de confiar o módulo a qualquer coisa que custe dinheiro.

**Uma etapa cujo efeito é uma escrita no banco pelo handle que ela recebe é exatamente-uma-vez.** `fn` recebe a transação em que a linha do memo é escrita, então a escrita e o registro dela são um único commit. Não existe instante em que um exista sem o outro.

```lua no-run
ctx:step("charge", function(tx)                    -- exatamente uma vez
  tx:exec("insert into ledger (order_id, cents) values ($1, $2)", id, 500)
end)
```

**Uma etapa que alcança qualquer outra coisa é pelo-menos-uma-vez com resultado memoizado.** Um POST para uma API de pagamento, um e-mail, um arquivo no S3, uma escrita por uma conexão *diferente*: o efeito e o memo não podem compartilhar uma transação, então o processo pode morrer na janela entre eles e a nova tentativa roda `fn` outra vez.

```lua no-run
ctx:step("charge", function()                      -- PELO MENOS UMA VEZ
  return stripe:charge(card, 500)                  -- pode rodar duas vezes
end)
```

O que o memo compra ali é que a chamada é tentada um número limitado de vezes em vez de uma vez por tentativa do workflow inteiro, e que o resultado dela fica estável uma vez gravado. Ele não torna o efeito único. Para um terceiro, dê à chamada remota uma chave de idempotência própria, derivada de `ctx.run` e do nome da etapa, e deixe o outro lado deduplicar -- [`akkar.idempotency`](idempotency.md) é esse mesmo mecanismo apontado para uma requisição de entrada.

**Nada fora de uma etapa é protegido**, e nada precisa ser. A função roda de novo desde o começo em toda tentativa, então o código entre as etapas roda uma vez por tentativa. Ponha dentro de uma etapa qualquer coisa que não pode se repetir.

## Índice

Todo símbolo público desta página, em ordem alfabética. `flow` é o que `workflow.new` devolve e `ctx` é o que uma função de workflow recebe.

| símbolo | tipo |
|---|---|
| [`ctx.attempt`](#ctxattempt) | campo |
| [`ctx.db`](#ctxdb) | campo |
| [`ctx.input`](#ctxinput) | campo |
| [`ctx.job`](#ctxjob) | campo |
| [`ctx.run`](#ctxrun) | campo |
| [`ctx:sleep`](#ctxsleepname-seconds) | método |
| [`ctx:step`](#ctxstepname-fn) | método |
| [`flow.queue`](#flowqueue) | campo |
| [`flow:finished`](#flowfinishedrun) | método |
| [`flow:forget`](#flowforgetrun) | método |
| [`flow:handlers`](#flowhandlers) | método |
| [`flow:result`](#flowresultrun) | método |
| [`flow:start`](#flowstartinput-options) | método |
| [`flow:steps`](#flowstepsrun) | método |
| [`flow:work`](#flowworkoptions) | método |
| [`workflow.Ctx`](#workflowctx) | tabela |
| [`workflow.Flow`](#workflowflow) | tabela |
| [`workflow.MIGRATIONS`](#workflowmigrations) | valor |
| [`workflow.migrate`](#workflowmigratedb-options) | função |
| [`workflow.new`](#workflownewdb-name-fn-options) | função |
| [`workflow.prune`](#workflowprunedb-older_than) | função |
| [`workflow.SCHEMA`](#workflowschema) | valor |

Também nesta página:
[O que "exatamente uma vez" cobre, e o que não cobre](#o-que-exatamente-uma-vez-cobre-e-o-que-não-cobre),
[A tabela](#a-tabela) e [O que não está aqui](#o-que-não-está-aqui).

## workflow.new(db, name, fn, options)

Constrói um workflow.

`db` é uma **conexão** -- algo com `:one`, `:many`, `:exec` e `:transaction` -- e não a fábrica que [`db.connect`](db.md#dbconnectconfig) devolve. Dois motivos: a fila por baixo mantém uma sessão, e o memo e as escritas da etapa têm de ser uma transação só, o que dois handles não podem ser.

`name` nomeia a fila (`akkar:queue:workflow:<name>`), o tipo do job e o prefixo de todo id de execução (run).

`fn` é chamada com um `ctx`. O valor de retorno dela é gravado como o resultado da execução.

`options` é repassado inteiro para [`jobs.new`](jobs.md#jobsnewstore-name-options), então `retries`, `backoff`, `visibility`, `dead_letter` e o resto significam o que significam lá. **`retries` é zero por padrão**, como em toda outra fila, então um workflow cuja etapa levanta um erro é enterrado na primeira falha a menos que você peça outra coisa. Mais uma opção própria:

| opção | padrão | significado |
|---|---|---|
| `step_lock_timeout` | `5` | segundos que uma etapa espera pela transação de outro worker antes de levantar um erro de contenção |

**Retorna** um `Flow`.

**Levanta**

- `akkar.workflow: expected a database handle, got <tipo>`
- `akkar.workflow: this is not a database handle; missing :<método>. A connection factory is not a connection -- call it first, and hand the workflow the connection it returns`
- `akkar.workflow: a workflow needs a name; it names the queue and prefixes every run id`
- `akkar.workflow: expected a function taking a ctx, got <tipo>`

```lua
local db       = require "akkar.db"
local workflow = require "akkar.workflow"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}

local ok, why = pcall(workflow.new, open, "signup", function() end)
print(ok, why)                    -- uma fábrica não é uma conexão

local conn = open()
local flow = workflow.new(conn, "ref_ptbr_workflow_shape", function(ctx)
  ctx:step("one", function() return 1 end)
end)
print(flow.queue.key, flow.queue.delivery)
conn:close()
```

## workflow.migrate(db, options)

Aplica o schema através de [`akkar.migrate`](migrate.md), então ele cai no mesmo ledger e sob o mesmo lock que as migrações da própria aplicação. O arquivo da fila vem junto: um banco com a tabela de etapas e nenhuma fila para rodar o workflow é uma feature instalada pela metade.

`options.table` nomeia o ledger, como faz para [`migrate.new`](migrate.md#migratenewdb-options).

**Retorna** os nomes dos arquivos aplicados, em ordem; vazio em todo boot depois do primeiro.

```lua
local db       = require "akkar.db"
local workflow = require "akkar.workflow"

local conn = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}()

conn:exec "drop table if exists ref_ptbr_workflow_ledger"
print(table.concat(workflow.migrate(conn, { table = "ref_ptbr_workflow_ledger" }), ", "))
print(#workflow.migrate(conn, { table = "ref_ptbr_workflow_ledger" }))   -- 0, na segunda vez

conn:exec "drop table if exists ref_ptbr_workflow_ledger"
conn:close()
```

## workflow.SCHEMA

O `create table` de `akkar_workflow_steps` e o índice dele, como string. Aplique-o direto onde a aplicação não usa `akkar.migrate`.

```lua no-run
conn:exec(workflow.SCHEMA)
```

## workflow.MIGRATIONS

A lista de um elemento que `akkar.migrate` recebe em `files`:
`{ { name = "20260902130000_akkar_workflow_steps.sql", sql = workflow.SCHEMA } }`.
Concatene com o `MIGRATIONS` do próprio `akkar.jobs.postgres` para montar uma lista única, que é o que `workflow.migrate` faz.

```lua no-run
local files = {}
for _, f in ipairs(postgres.MIGRATIONS) do files[#files + 1] = f end
for _, f in ipairs(workflow.MIGRATIONS) do files[#files + 1] = f end
```

## workflow.prune(db, older_than)

Apaga o memo de toda execução intocada por `older_than` segundos -- trinta dias por padrão -- e devolve quantas execuções sumiram.

Execuções inteiras, pela idade da linha mais nova delas. Apagar só pela idade da linha cortaria uma execução viva ao meio, descartando as etapas que ela terminou semana passada enquanto dorme até a semana que vem, e um workflow cujo memo sumiu roda aquelas etapas de novo.

Não há ttl numa linha, porque o memo de um workflow adormecido precisa sobreviver ao sono dele e este módulo não tem como saber quanto tempo é isso. **A retenção é sua, e ela precisa exceder o sono mais longo que qualquer workflow aqui tira.** Uma tabela de etapas que ninguém poda cresce pela vida inteira da aplicação.

**Retorna** um número.

```lua no-run
local removed = workflow.prune(conn, 90 * 86400)
```

## Flow

O que `new` devolve.

### flow:start(input, options)

Empurra uma execução. `input` é entregue à função como `ctx.input`; ele passa por JSON, então é um valor simples.

`options` é o de [`queue:push`](jobs.md#queuepushkind-payload-options): `delay`, `id`, `id_ttl`. **O id de deduplicação é sobre o push, não sobre a execução** -- uma duplicata recusada não devolve id nenhum, então uma aplicação que precise reencontrar a execução original tem de tê-la guardado.

**Retorna** o id da execução e a profundidade da fila, ou `false, "duplicate"`.

```lua no-run
local run = flow:start { email = "a@b.c" }
local again, why = flow:start({ email = "a@b.c" }, { id = "signup:a@b.c" })
```

### flow:work(options)

Consome a fila deste workflow até `options.should_stop` dizer o contrário. As opções são as de [`queue:consume`](jobs.md#queueconsumehandlers-options), e o retorno é o relatório dele.

**Retorna** `{ handled, failed, retried, buried, duplicated }`.

```lua
local db       = require "akkar.db"
local workflow = require "akkar.workflow"

local conn = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}()
conn:exec(require("akkar.jobs.postgres").SCHEMA)
conn:exec(workflow.SCHEMA)

-- O PONTO INTEIRO, NUMA PÁGINA SÓ. Três etapas; a segunda falha na primeira
-- vez em que é alcançada. A função roda duas vezes, desde o começo, e o efeito
-- colateral da etapa um acontece uma vez.
local ran, explode = { one = 0, two = 0, three = 0 }, true

local flow = workflow.new(conn, "ref_ptbr_workflow_signup", function(ctx)
  ctx:step("one",   function() ran.one = ran.one + 1 return { id = 41 } end)
  ctx:step("two",   function()
    ran.two = ran.two + 1
    if explode then explode = false error("o gateway disse não", 0) end
    return "charged"
  end)
  ctx:step("three", function() ran.three = ran.three + 1 return "receipt" end)
  return "shipped"
end, { retries = 3, backoff = { base = 0.01, jitter = false } })

conn:exec("delete from akkar_jobs where queue = $1", flow.queue.key)

local run = flow:start { order = 41 }
local turns = 0
flow:work {
  timeout = 0, idle = 0.01,
  should_stop = function()
    turns = turns + 1
    return turns > 200 or flow:finished(run)
  end,
}

print("one rodou", ran.one, "two rodou", ran.two, "three rodou", ran.three)
print("resultado", flow:result(run))

flow:forget(run)
conn:exec("delete from akkar_jobs where queue = $1 or queue like $2",
          flow.queue.key, flow.queue.key .. ":%")
conn:close()
```

### flow:handlers()

A tabela de handlers para [`queue:consume`](jobs.md#queueconsumehandlers-options), indexada pelo tipo de job deste workflow. Junte várias para rodar mais de um workflow num worker só.

**Retorna** uma tabela.

```lua no-run
local handlers = {}
for _, flow in ipairs { signup, billing } do
  for kind, handler in pairs(flow:handlers()) do handlers[kind] = handler end
end
signup.queue:consume(handlers)
```

### flow:steps(run)

O que uma execução memoizou, da mais antiga para a mais nova: uma lista de `{ step, kind, result }` com o resultado já decodificado. `kind` é `"step"` ou `"sleep"`. A linha terminal está incluída e se chama `__done`.

**Retorna** uma lista.

### flow:finished(run)

Verdadeiro assim que a função tiver retornado para esta execução.

**Retorna** um booleano.

### flow:result(run)

O que a função retornou, ou `nil` quando ela ainda não retornou -- o que é indistinguível de um workflow que retornou nil, então pergunte `finished` antes se a diferença importa.

### flow:forget(run)

Descarta o memo de uma execução e devolve quantas linhas sumiram. A próxima execução daquela run roda, portanto, todas as etapas de novo, o que é exatamente o ponto quando uma execução está sendo deliberadamente reproduzida e uma catástrofe quando não está.

**Retorna** um número.

### flow.queue

A fila [`akkar.jobs`](jobs.md) por baixo, para `depth`, `dead_letters`, `reap` e tudo mais que aquele módulo oferece. `flow.queue.key` é `akkar:queue:workflow:<name>`.

## Ctx

O que uma função de workflow recebe.

### ctx:step(name, fn)

Roda `fn` uma vez por execução e devolve o que ela devolveu na primeira vez.

`fn` é chamada com a transação em que o memo é escrito, então uma escrita no banco feita por ela é exatamente-uma-vez junto com a etapa. Qualquer outra coisa que `fn` toque é pelo-menos-uma-vez; veja [O que "exatamente uma vez" cobre](#o-que-exatamente-uma-vez-cobre-e-o-que-não-cobre).

O resultado de uma etapa é guardado como JSON e decodificado no replay, então ele é **um valor** e é o que o JSON conseguir carregar: `7` volta como `7.0`, e uma função, um userdata ou um cursor de banco não podem ser resultado de etapa de jeito nenhum. A primeira execução também vê o valor já no formato JSON, então um workflow não pode funcionar na primeira tentativa e falhar na segunda por causa de um inteiro que virou float.

`nil` é um resultado legítimo. É a EXISTÊNCIA da linha que diz que a etapa terminou, nunca o conteúdo de `result`.

Nomes de etapa são as chaves do memo, então precisam ser únicos dentro de um workflow, e nomes começando com `__` são reservados.

**Retorna** o resultado da etapa.

**Levanta**

- o que `fn` levantar -- a etapa fica sem reivindicação, então uma nova tentativa do workflow roda ela de novo
- `akkar.workflow: a step needs a name; it is the key the result is stored under, so it cannot be nil or empty`
- `akkar.workflow: '<nome>' is reserved -- names beginning with '__' belong to this module`
- `akkar.workflow: step '<nome>' ran twice in one execution -- step names are the memo's keys and must be unique within a workflow`
- `akkar.workflow: step '<nome>' was started inside step '<outro>'. ...` para uma etapa aninhada
- `akkar.workflow: the result of step '<nome>' cannot be encoded as JSON ...`
- `akkar.workflow: step '<nome>' of run '<run>' is being run by another worker and did not finish within <n>s ...`

### ctx:sleep(name, seconds)

Suspende o workflow e o retoma num worker novo assim que `seconds` tiverem passado. Ele grava um horário de vencimento e empurra o workflow de volta para a própria fila com aquele atraso, numa transação só, e então desmonta a função -- de modo que nada segura uma corrotina, uma conexão ou um processo durante o período. O worker confirma o job e segue em frente.

**Ele não retorna na execução que o alcança primeiro.** Tudo depois da chamada pertence à continuação. Numa execução posterior, depois que o vencimento passou, ele retorna normalmente e a função segue adiante.

O horário de vencimento é o motivo pelo qual um sono não é simplesmente gravado como "feito". Um workflow que suspendeu e depois foi reentregue -- o worker dele morreu entre o commit e a confirmação, que é exatamente o que "pelo menos uma vez" significa -- roda desde o começo e alcança o sono outra vez; uma linha que só dissesse "isto aconteceu" deixaria ele passar direto e rodar o trabalho de amanhã hoje, ao lado de uma continuação que ainda está na fila. O relógio comparado é o do servidor, pelo motivo que `akkar.jobs.postgres` dá longamente sobre `clock_timestamp()`.

O desmonte é um `error` carregando um sentinela privado, então **não envolva `ctx:sleep` num `pcall`**: capturá-lo faz a função seguir como se o tempo tivesse passado, e não há como este módulo distinguir aquele `pcall` de qualquer outro.

**Levanta**

- o sentinela de suspensão, sempre, na execução que agenda a continuação
- `akkar.workflow: step '<nome>' tried to sleep. ...` para um sono dentro de uma etapa
- os mesmos erros de nome que `ctx:step` levanta

### ctx.run

O id da execução: `<name>:<24 caracteres hexadecimais>`, estável através de toda nova tentativa, toda reentrega e toda continuação desta execução. É a chave sob a qual toda linha de memo é escrita, e é a coisa certa da qual derivar uma chave de idempotência de saída.

Ele é cunhado por `flow:start` em vez de tirado de `job.uid`, e a diferença importa. `uid` é estável através de toda nova tentativa e reentrega de **um job**, que é tudo de que um job simples precisa; mas `ctx:sleep` empurra um job *novo* para retomar, e um push novo cunha um uid novo. Um memo indexado por `uid` estaria perdido no primeiro sono, e toda etapa antes dele rodaria uma segunda vez.

### ctx.input

O que `flow:start` recebeu, depois de uma ida e volta por JSON.

### ctx.job

O job de que esta execução veio -- `uid`, `attempts`, `kind` e o resto do [que `queue:pop` devolve](jobs.md#queuepoptimeout) -- ou `nil` quando o workflow foi invocado diretamente.

### ctx.attempt

Qual tentativa é esta, contando a partir de 1.

### ctx.db

A conexão sobre a qual o workflow foi construído. Use-a para leituras que não precisam ser memoizadas; uma escrita pertence a uma etapa, pelo handle que a etapa recebe.

## workflow.Flow

A metatabela do que `new` devolve.

## workflow.Ctx

A metatabela do contexto que uma função de workflow recebe.

## A tabela

Uma tabela, e uma linha nela é uma etapa concluída.

```sql
akkar_workflow_steps (run, step, kind, result, due_at, created_at)
primary key (run, step)
```

Não há coluna de lease, nem token, nem expiração, e isso não é uma simplificação. A reivindicação e a conclusão são a mesma transação:

```sql
begin
  insert into akkar_workflow_steps (run, step)   -- a reivindicação
  ... as escritas da própria etapa ...
  update ... set result = ...                    -- o memo
commit
```

O `insert ... on conflict do nothing` de um segundo worker naquela chave espera a primeira transação se resolver e então ou encontra a linha, e reproduz o resultado dela, ou insere a sua própria porque a primeira deu rollback. **Uma linha que existe é sempre uma etapa concluída**: um worker morto no meio de uma etapa não deixa nada para trás, porque o insert dele morreu junto.

Aquela espera é limitada por `step_lock_timeout`. Passando disso a etapa levanta um erro de contenção em vez de segurar uma conexão do pool pelo tempo da etapa de outra pessoa, e a política de retries da fila traz a execução de volta -- e a essa altura a etapa está concluída e é reproduzida.

## O que não está aqui

**Uma tabela de execuções, uma coluna de status, uma lista de workflows rodando.** A fila guarda a vitalidade de uma execução e a tabela de etapas guarda a história dela; um terceiro registro do mesmo fato é uma terceira coisa que pode discordar. O custo está declarado: uma execução que ainda não concluiu nenhuma etapa só é visível como um job em `akkar_jobs`, e `flow:steps` responde sobre uma execução cujo id você já tem.

**Etapas em paralelo, fan-out, `Promise.all`.** As etapas rodam na ordem em que a função as chama. Um workflow que quer duas coisas ao mesmo tempo empurra dois jobs.

**Cancelamento, sinais, esperar por um evento externo.** Uma execução para quando a função dela retorna ou quando a fila a enterra.

**Replay determinístico, uma VM em sandbox, um orquestrador hospedado.** Veja o topo desta página.

**Qualquer store que não seja Postgres.** O memo e as escritas da etapa têm de ser uma transação só, o que é uma propriedade de um banco de dados e não de uma fila.

## Veja também

- [akkar.jobs](jobs.md) -- a fila sobre a qual isto roda, e tudo o que ela já garante
- [akkar.idempotency](idempotency.md) -- o mesmo padrão de reivindicação/replay, para uma requisição de entrada
- [akkar.db](db.md) -- `db:transaction` e os savepoints dele
- [akkar.migrate](migrate.md) -- como o schema é aplicado
