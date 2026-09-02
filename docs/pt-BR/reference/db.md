# akkar.db

> **Português (Brasil)** | [Original em inglês](../../reference/db.md)

O adaptador do Postgres. Ele transforma uma tabela de configuração em uma fábrica que abre conexões, e dá a cada conexão quatro métodos: `one`, `many`, `exec` e `transaction`.

**Quando você precisa dele.** Uma vez, na inicialização, para construir a fábrica que você passa para `app:run { db = open }`. Dentro de um handler você usa `req.db`, que é uma dessas conexões, e você nunca chama esse módulo de novo.

```lua no-run
local db = require "akkar.db"
```

## Índice

Todo símbolo público desta página, em ordem alfabética. `conn` é o que a fábrica retorna; `fake` é uma instância de `akkar.db.memory`.

| símbolo | tipo |
|---|---|
| [`conn:close`](#connclose) | método |
| [`conn:exec`](#connexecsql-) | método |
| [`conn:many`](#connmanysql-) | método |
| [`conn:one`](#connonesql-) | método |
| [`conn:query`](#connquerysql-) | método |
| [`conn:release`](#connrelease) | método |
| [`conn:scope`](#connscopecolumn-value) | método |
| [`conn:transaction`](#conntransactionfn) | método |
| [`conn:unscoped`](#connunscoped) | método |
| [`db.connect`](#dbconnectconfig) | função |
| [`db.Pool`](#dbpool) | reexportação |
| [`db.scope`](#dbscopehandle-column-value) | reexportação |
| [`fake:close`](#fakeclose) | método |
| [`fake:count`](#fakecountpattern) | método |
| [`fake:drop`](#fakedroppattern) | método |
| [`fake:exec`](#fakeexecsql-) | método |
| [`fake:fail`](#fakefailpattern-message) | método |
| [`fake:hang`](#fakehangpattern-seconds) | método |
| [`fake:many`](#fakemanysql-) | método |
| [`fake:on`](#fakeonpattern-response) | método |
| [`fake:one`](#fakeonesql-) | método |
| [`fake:query`](#fakequerysql-) | método |
| [`fake:received`](#fakereceivedpattern) | método |
| [`fake:release`](#fakerelease) | método |
| [`fake:reset`](#fakereset) | método |
| [`fake:scope`](#fakescopecolumn-value) | método |
| [`fake:transaction`](#faketransactionfn) | método |
| [`fake:unscoped`](#fakeunscoped) | método |
| [`memory.factory`](#memoryfactoryconfigure) | função |
| [`memory.new`](#memorynewoptions) | função |

Também nesta página: [O pool](#o-pool), [O driver pq](#o-driver-pq) e
[Não está aqui](#não-está-aqui).

## db.connect(config)

Constrói uma fábrica. Ela não conecta: nada chega ao Postgres até que a fábrica seja chamada, e nada em `config` é verificado até lá também.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `host` | string | `"127.0.0.1"` | onde está o Postgres |
| `port` | number | `5432` | sua porta |
| `database` | string | nenhum | o nome do banco de dados |
| `user` | string | nenhum | o papel (role) com o qual fazer login |
| `password` | string | nenhum | sua senha |
| `pool_size` | number | `10` | quantas conexões manter; `0` significa sem pool |
| `statement_timeout` | number | nenhum | segundos, definido na conexão com `set statement_timeout` |
| `driver` | string | `"pgmoon"` | `"pgmoon"` ou `"pq"` |
| `buffered_reads` | boolean | `true` | somente pgmoon; `false` restaura as leituras de socket por mensagem originais do pgmoon |
| `ssl` | boolean | `false` | somente pgmoon; pede TLS ao servidor |
| `ssl_required` | boolean | **segue `ssl`** | somente pgmoon; recusa continuar se o servidor negar TLS |
| `ssl_verify` | boolean | `false` | somente pgmoon; verifica o certificado do servidor contra um repositório de CA e o nome do host |
| `cafile` | string | nenhum | somente pgmoon; um pacote de CA para confiar em vez dos padrões do sistema |
| `cert` / `key` | string | nenhum | somente pgmoon; um certificado de cliente e sua chave |
| `ssl_version` | string | `"TLS"` | somente pgmoon; o nome do protocolo OpenSSL |
| `cqueues_openssl_context` | object | nenhum | somente pgmoon; seu próprio objeto OpenSSL, usado como está |

`statement_timeout` é o que interrompe a consulta (query), diferente de interromper a espera por ela. O akkar pode abandonar uma query lenta, mas só o Postgres pode parar de executá-la, então uma implantação com um prazo de requisição (request) e sem `statement_timeout` recebe um aviso na inicialização citando essa configuração.

**Retorna** `open`. Com `pool_size = 0`, é uma função simples sem argumentos que retorna uma [Connection](#connection). Caso contrário, é uma tabela chamável cujo campo `pool` é o [akkar.pool](pool.md) por trás dela, para que `app:run` possa fechá-la no desligamento.

**Não lança** nada. `open` lança:

- `db: could not connect to <host>:<port> (database "<db>", user "<user>") -- <reason>`,
  com `Nothing is listening there. Is the database running?` adicionado quando
  o motivo menciona uma conexão recusada
- `db: could not set statement_timeout: <reason>`, depois de desconectar
- `db: unknown driver '<name>'; expected 'pgmoon' or 'pq'`
- `db: driver 'pq' needs the C module akkar.pq_native, which is a separate rock: luarocks install akkar-pq ...`
- `the server does not support SSL connections`, encapsulada na mesma sentença
  `db: could not connect to ...`, quando o TLS foi solicitado e recusado

```lua
local db = require "akkar.db"

local open = db.connect {
  host      = "127.0.0.1",
  port      = 55432,
  database  = "akkar",
  user      = "postgres",
  password  = "akkar",
  pool_size = 0,
}

local conn = open()
print(conn:one("select 1 as n").n)
conn:close()
```

### TLS para o Postgres

somente pgmoon — o driver `pq` usa o `sslmode` do libpq em vez disso.

```lua no-run
local open = db.connect {
  host     = "db.internal",
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  ssl        = true,
  ssl_verify = true,
  cafile     = "/etc/ssl/certs/internal-ca.pem",   -- opcional; caso contrário, usa o repositório do sistema
}
```

**`ssl_required` segue o valor padrão de `ssl`.** Pedir TLS significa exigi-lo, e o motivo está na forma do protocolo: o PostgreSQL negocia TLS **em texto claro**. O cliente envia um SSLRequest e o servidor responde com um único byte, `S` para sim ou `N` para não. Um driver que trata `N` como "tudo bem, prossiga" continua no socket sem criptografia — e tudo o que `ssl_verify` configurou é então ignorado, porque nenhum handshake chega a acontecer: nenhum certificado é apresentado, nenhuma CA é consultada, nenhum nome de host é verificado. Qualquer um capaz de responder esse byte remove a criptografia, e a conexão reporta sucesso.

Então `ssl = true` sozinho recusa um servidor que nega, com `the server does not
support SSL connections`. TLS oportunista — tentar, e aceitar texto claro se o servidor disser não — ainda está disponível, mas precisa ser dito explicitamente:

```lua no-run
local open = db.connect {
  host = "127.0.0.1", database = "akkar", user = "postgres", password = "akkar",
  ssl = true, ssl_required = false,       -- permite deliberadamente um downgrade
}
```

`ssl_verify = true` é o que faz o certificado significar alguma coisa. Ele constrói um cliente OpenSSL com `VERIFY_PEER`, um repositório de CA (`cafile`, ou os padrões do sistema), e um parâmetro de verificação carregando o nome que o certificado precisa corresponder — `setHost` para um nome de host, com SNI enviado, e `setIP` para um literal de IP, sem SNI. Sem isso, o próprio contexto do pgmoon não verifica nada, então `ssl = true` sozinho te dá uma conexão criptografada com quem quer que tenha respondido. `cert` e `key` adicionam um certificado de cliente; `cqueues_openssl_context` substitui toda essa construção por um objeto que você mesmo montou. `db.tls_client(config)` é essa construção, exposta para que possa ser inspecionada em um teste.

`spec/db_tls_downgrade_spec.lua` é a prova: um servidor falso que responde `N` e nada mais. O caso obrigatório precisa recusar; o caso oportunista precisa ir *mais longe*, até uma resposta (response) de inicialização que nunca chega.

## db.Pool

O módulo [akkar.pool](pool.md), reexportado. `db.Pool == require "akkar.pool"`.

Presente para que quem chama e já tem `akkar.db` possa construir um pool de outra coisa sem um segundo `require`.

```lua no-run
local db = require "akkar.db"
local pool = db.Pool.new(open_something, 4)
```

## db.scope(handle, column, value)

O `wrap` de `akkar.scope`, reexportado. Ele envolve qualquer handle de banco de dados para que toda query que ele execute carregue `column = value`. É a mesma função que [`conn:scope`](#connscopecolumn-value), acessível sem ter uma conexão em mãos, e é a mesma que `akkar.db.memory` usa.

**Retorna** um handle [Scoped](scope.md#scoped): `one`, `many`, `exec`,
`transaction`, `scope`, `unscoped`, `release`, `close`.

**Lança** `db: scope value for '<column>' is nil; a missing tenant id has to
fail here rather than quietly match every row`.

```lua
local db     = require "akkar.db"
local memory = require "akkar.db.memory"
local sql    = require "akkar.sql"

local fake = memory.new():on("project_id", { id = 1, title = "notes" })
local scoped = db.scope(fake, "project_id", 42)

print(scoped:one(sql.select("id, title"):from "ref_db_documents").title)
print(fake.log[1].sql)
```

## Connection

O que `open()` retorna. Uma linha (row) é uma tabela Lua simples com um campo por coluna. Um `NULL` do SQL é deixado de fora da linha por completo, então uma coluna que era nula é lida como `nil` em vez de como um valor sentinela.

Todo método aceita ou um texto SQL mais valores, ou uma query do [akkar.sql](sql.md), que ele constrói para você.

### conn:close()

Desconecta. A conexão fica inutilizável depois disso e não volta para nenhum pool.

Use [`release`](#connrelease) em vez disso para uma conexão que vem de um pool.

**Retorna** nada.

```lua no-run
conn:close()
```

### conn:exec(sql, ...)

Executa uma instrução (statement) pelo seu efeito. É a mesma chamada que `many`, só que com outro nome, para que o `grep` consiga distinguir um insert de uma leitura.

**Retorna** o que quer que o driver responda, o que não tem o mesmo formato para toda instrução: uma tabela com `affected_rows` para `insert`, `update` e `delete`, o booleano `true` para DDL como `create table`, e as linhas para uma instrução com `returning`.

**Lança** `db: <message from Postgres>`.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "create table ref_db_notes (id serial primary key, body text)"
conn:exec("insert into ref_db_notes (body) values ($1), ($2)", "one", "two")

local gone = conn:exec("delete from ref_db_notes where body = $1", "one")
print(gone.affected_rows)

conn:exec "drop table ref_db_notes"
conn:close()
```

### conn:many(sql, ...)

Executa uma instrução e retorna suas linhas.

**Retorna** uma lista de linhas, vazia quando nada corresponde. Uma instrução que não responde nenhum conjunto de resultados (`create table`) dá uma lista vazia em vez do valor que o driver retornaria.

**Lança** `db: <message from Postgres>`.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local rows = conn:many "select 1 as n union all select 2 order by n"
for _, row in ipairs(rows) do print(row.n) end
print(#conn:many "select 1 where false")

conn:close()
```

### conn:one(sql, ...)

Executa uma instrução e retorna sua primeira linha.

**Retorna** uma linha, ou `nil` quando nada corresponde. É por isso que `or akkar.not_found "..."` fica bem legível logo depois.

**Lança** `db: <message from Postgres>`.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

print(conn:one("select $1::text as greeting", "hello").greeting)
print(conn:one "select 1 as n where false")

conn:close()
```

### conn:query(sql, ...)

A única chamada sobre a qual as outras três são construídas. Ela retorna a resposta do driver sem alteração, então nada normaliza um conjunto de resultados ausente para uma lista vazia.

Prefira `one`, `many` ou `exec`. Isso está aqui porque é público e porque uma conexão que lançou um erro dentro dela é marcada como quebrada e não vai voltar para o pool.

**Retorna** o resultado do driver.

**Lança** `db: <message>` tanto para um erro retornado quanto para um lançado.

```lua no-run
local rows = conn:query("select id from ref_db_notes where id = $1", 1)
```

### conn:release()

Devolve a conexão ao pool de onde ela veio, ou a fecha quando não há pool.

Uma conexão ainda dentro de uma transação, uma cujo rollback falhou, e uma com uma query ainda em andamento são descartadas em vez de voltarem para o pool. O akkar chama isso para você no fim de toda requisição (request), em todo caminho de saída.

**Retorna** nada.

```lua no-run
conn:release()
```

### conn:scope(column, value)

Retorna um handle que não consegue emitir uma query sem escopo. Toda query do [akkar.sql](sql.md) que passa por ele recebe `column = value` adicionado, e texto SQL puro é recusado de cara, porque uma string não pode ter escopo aplicado sem que seja analisada (parsed).

Aplicar escopo a um handle que já tem escopo o restringe ainda mais. As duas condições valem.

**Retorna** um handle [Scoped](scope.md#scoped).

**Lança** `db: scope value for '<column>' is nil ...` no momento do wrap, e
`db: this handle is scoped to <column>, so it takes an akkar.sql query rather
than raw SQL ...` quando recebe uma string.

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec [[create table ref_db_docs (
  id serial primary key, project_id int not null, title text not null)]]
conn:exec "insert into ref_db_docs (project_id, title) values (1, 'ours'), (2, 'theirs')"

local mine = conn:scope("project_id", 1)
for _, row in ipairs(mine:many(sql.select("id, title"):from "ref_db_docs")) do
  print(row.title)
end

local ok, why = pcall(function()
  return mine:many "select title from ref_db_docs"
end)
print(ok, why)

conn:exec "drop table ref_db_docs"
conn:close()
```

### conn:transaction(fn)

Executa `fn(tx)` entre `begin` e `commit`. `tx` é essa mesma conexão. Qualquer coisa lançada lá dentro provoca rollback e é relançada, então uma resposta lançada com `error(akkar.bad_request "...")` ainda chega até quem chamou.

**Retornar um 4xx de dentro faz commit.** Uma closure que retornou não falhou, então a transação teve sucesso. Lance um erro para recusar.

**Retorna** o que `fn` retornou.

**Lança** o que `fn` lançou, sem alteração. Uma conexão cujo `rollback` também falhou é marcada como quebrada e não vai mais para o pool.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "create table ref_db_ledger (id serial primary key, body text)"

conn:transaction(function(tx)
  tx:exec("insert into ref_db_ledger (body) values ($1)", "kept")
end)

local ok = pcall(function()
  conn:transaction(function(tx)
    tx:exec("insert into ref_db_ledger (body) values ($1)", "undone")
    error "changed my mind"
  end)
end)

print(ok, conn:one("select count(*)::int as n from ref_db_ledger").n)

conn:exec "drop table ref_db_ledger"
conn:close()
```

### conn:unscoped()

Retorna a própria conexão. Não faz nada.

Ele existe para que `grep -rn ':unscoped()'` seja a lista completa de queries que cruzam tenants. Em um handle vindo de [`scope`](#connscopecolumn-value), ele retorna a conexão por baixo, que é onde a fuga realmente acontece.

**Retorna** a conexão.

```lua no-run
local everyone = req.db:unscoped():many "select count(*) from documents"
```

## O pool

Com `pool_size` acima de zero, a fábrica é uma tabela chamável e `open.pool` é a instância de [akkar.pool](pool.md). Chamar a fábrica retira uma conexão; [`release`](#connrelease) a devolve.

Uma conexão só volta quando está apta para reuso: não está dentro de uma transação, não está marcada como quebrada, não está segurando uma query que ninguém leu, e não está fechada. Qualquer outra coisa é fechada e seu slot é liberado, para que a próxima requisição abra uma nova.

Quando o pool está cheio, quem chama cede até que uma conexão seja devolvida. Isso não bloqueia o processo e não abre uma décima primeira conexão.

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  pool_size = 4,
}

local conn = open()
print(conn:one("select 1 as n").n)

local stats = open.pool:stats()
print("size", stats.size, "live", stats.live, "idle", stats.idle)

conn:release()
print("idle after release", open.pool:stats().idle)

open.pool:close()
```

## O driver pq

`driver = "pq"` usa `akkar.pq`, um driver sobre o libpq que espera em Lua.

### Instalando

A metade em C é um **rock separado**, porque vincular o libpq ao próprio `akkar` quebraria o `luarocks install akkar` para todo mundo que não usa Postgres:

```sh
luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir)
```

`PQ_INCDIR` é necessário no Debian e no Ubuntu, onde `libpq-fe.h` fica em `/usr/include/postgresql` em vez de em qualquer lugar que o LuaRocks olhe por padrão. Em um sistema que coloca esse arquivo em um lugar padrão, o simples `luarocks install akkar-pq` funciona. A partir de um checkout, `src/build.sh` faz a mesma coisa.

Sem o módulo em C, a fábrica lança um erro e cita a linha de instalação — a opção falha de forma explícita no momento da conexão, não silenciosamente na primeira query.

### O que isso oferece, e por que não é o padrão

Medido de ponta a ponta sobre HTTP em uma máquina reservada, contra o pgmoon:

| rota | pgmoon | akkar.pq |
|---|---:|---:|
| uma linha | 7.040 req/s | **8.969** (1,27x) |
| cem linhas | 2.392 | **5.031** (2,10x) |
| mil linhas | 333 | **928** (2,79x) |
| p99, mil linhas, saturado | 1.300 ms | **475 ms** |

**O pgmoon continua sendo o padrão, e não por causa de nenhuma dúvida sobre o `akkar.pq`.** A metade em C é um rock separado, então um padrão `pq` falharia na primeira query para todo mundo que instalou só o `akkar`. Isso é uma questão de empacotamento, não de julgamento.

Uma objeção anterior sobre consistência foi **retirada**. Ela relatava que o `akkar.pq` perdia em duas janelas de trinta, enquanto o pgmoon não perdia em nenhuma; investigado, o número não se reproduz — variação de 1,8% e zero janelas anômalas na mesma configuração — e a única irregularidade que se reproduz é o harness dividindo um número pequeno de conexões entre processos, o que prejudica mais o pgmoon. `bench/driver/ANOMALY.md` traz os quatro experimentos, dois dos quais refutaram uma hipótese.

Então: **se você instalar o `akkar-pq`, use-o.** Tanto os números quanto a correção estão em `bench/driver/RESULTS.md` §5.

Tudo nesta página se comporta da mesma forma nos dois casos: o shim dá ao `akkar.pq` o mesmo formato do pgmoon, e a `Connection`, a transação, o wrapper de escopo e o pool nunca sabem qual driver está por baixo.

Três campos de configuração chegam até o `akkar.pq` e são ignorados pelo pgmoon: `application_name` (padrão `"akkar"`), `sslmode` e `connect_timeout`.

```lua no-run
local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  driver = "pq",
  application_name = "reports",
}
```

## akkar.db.memory

Um módulo separado, `require "akkar.db.memory"`, que responde aos mesmos quatro métodos. Não é um motor de SQL: ele não analisa (parse) a query, apenas a compara com respostas que você programou, e uma query que ninguém programou lança um erro.

**Quando você precisa dele.** Para testar um handler cujo trabalho com o banco de dados não é o que está sendo testado, e para testar formatos de falha que um banco de dados real não vai produzir sob demanda: uma conexão derrubada, uma query que trava.

```lua no-run
local memory = require "akkar.db.memory"
```

### memory.factory(configure)

Constrói uma instância, executa `configure(instance)` nela se for informado, e a envolve no formato chamável que `app:run{}` e `app:test{}` esperam para `db`.

Toda chamada retorna a mesma instância, então um teste pode programá-la uma vez e depois fazer asserções sobre ela através de `factory.instance`.

`configure` é uma função que programa o fake, como acima. Ela também pode ser uma tabela, caso em que são as opções de [`memory.new`](#memorynewoptions) — então `memory.factory { max_qps = 1500 }` se lê do mesmo jeito que o resto do framework. Os dois juntos ficam `memory.factory(options, program)`.

**Retorna** uma tabela chamável com um campo `instance`.

```lua
local akkar  = require "akkar"
local memory = require "akkar.db.memory"

local factory = memory.factory(function(fake)
  fake:on("^select id, title from ref_db_tasks", { id = 1, title = "buy milk" })
end)

local app = akkar.new()
app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  return req.db:one("select id, title from ref_db_tasks where id = $1",
                    req.params.id)
end)

local res = app:test { db = factory }:get "/tasks/1"
print(res.status, res.body.title)
print(factory.instance:received "ref_db_tasks")
```

### memory.new(options)

Uma instância nova, sem nada programado. `options` pode ser omitido.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `max_qps` | number | nenhum | quantas instruções o servidor executa por segundo |
| `latency_ms` | number | nenhum | quanto tempo cada instrução leva |

Passar a própria instância como `db` também funciona: `app:test{}` aceita tanto uma tabela quanto uma fábrica, e toda requisição então a compartilha.

**Retorna** uma instância Memory.

**Lança** um erro quando `max_qps` não é maior que zero, ou `latency_ms` é negativo.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new()
print(pcall(function() return fake:one "select 1" end))
```

#### Capacidade: max_qps e latency_ms

Os dois juntos formam um banco de dados que é lento, ou saturado, ou as duas coisas, sem que ele exista de verdade — assim um handler pode ser testado contra a dependência que um diagrama de capacidade descreve, em vez de contra uma que sempre responde instantaneamente.

Eles são **uma única fila, não dois atrasos somados**. Uma instrução ocupa o servidor por `latency_ms`, e `max_qps` diz com que frequência uma nova pode começar; o que for a restrição mais apertada é o que quem chama sente. A 1500/s e 8 ms, o tempo de serviço é o limitante, porque 8 ms de trabalho não podem ser emitidos 1500 vezes por segundo. A 50/s e 8 ms, a taxa é o limitante.

`begin` e `commit` são cobrados como qualquer outra coisa, porque são idas e voltas (round trips) em um servidor real.

**A espera passa pelo [akkar.time](time.md), nunca por um relógio de parede próprio.** Sob `akkar.time.manual`, um segundo modelado passa instantaneamente, então um teste continua determinístico e rápido; sob o relógio real, os mesmos números custam segundos de verdade. Uma única configuração, e qual comportamento você obtém é decidido por qual relógio está instalado. (`fake:hang` é deliberadamente a exceção — veja abaixo.)

É um modelo, e ele assume isso. O tempo de serviço de um servidor real depende do plano de execução, do cache e dos locks que ele está esperando. Isso reproduz uma fila com uma taxa de serviço fixa, que é o que um diagrama de capacidade retrata — e o ponto de um único número configurar as duas coisas é que a previsão e a medição podem então ser comparadas e flagradas em desacordo.

```lua
local memory = require "akkar.db.memory"
local time   = require "akkar.time"

local clock   = time.manual { monotime = 0 }
local restore = time.set(clock)

local fake = memory.new { max_qps = 1500, latency_ms = 8 }
fake:on("^select", { { id = 1 } })

for i = 1, 10 do fake:many "select 1" end

print(("%.3f"):format(clock.monotime()))   --> 0.080, e nada esperou
restore()
```

### Memory

Os métodos abaixo pertencem à instância. `on`, `fail`, `hang` e `drop` retornam a instância, então eles podem ser encadeados.

Padrões (patterns) são padrões Lua, comparados em qualquer parte do SQL com `string.find`. Por isso, uma string simples sem caracteres mágicos funciona como uma correspondência por substring. `^` ancora no início da instrução; `-`, `%`, `(`, `.` e `+` significam o que significam em um padrão Lua.

**O primeiro padrão programado que corresponder vence**, na ordem em que foram adicionados. Um `:on "^select"` amplo, adicionado primeiro, ofusca todo `select` programado depois dele.

#### fake:close()

Não faz nada. Presente para que o handle responda ao mesmo contrato de uma conexão real.

#### fake:count(pattern)

Quantas queries recebidas correspondem a `pattern`. Sem argumento, quantas queries foram recebidas ao todo, o que inclui o `begin` e o `commit` que uma transação enviou.

**Retorna** um número.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():on("^insert", { id = 1 })
fake:transaction(function(tx) tx:exec "insert into ref_db_tasks (title) values ($1)" end)

print(fake:count "^insert", fake:count())
```

#### fake:drop(pattern)

Programa uma query correspondente para derrubar a conexão, não apenas falhar. Ela lança `db: connection reset by peer`, e **toda** query depois disso lança a mesma coisa, que é o que um socket fechado faz. Só [`reset`](#fakereset) desfaz isso.

A diferença em relação a `fail` está no que um pool precisa fazer a respeito: uma query que falhou deixa uma conexão saudável, uma que foi derrubada nunca deve voltar.

**Retorna** a instância.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():drop("^select 2"):on("^select", { n = 1 })

print(fake:one("select 1").n)
print(pcall(function() return fake:one "select 2" end))
print(pcall(function() return fake:one "select 1" end))

fake:reset()
print(fake:one("select 1").n)
```

#### fake:exec(sql, ...)

Como `many`, com outro nome.

#### fake:fail(pattern, message)

Programa uma query correspondente para lançar `db: <message>`, com o padrão `db: query failed`. A conexão continua utilizável.

**Retorna** a instância.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new()
fake:fail("^insert into ref_db_tasks", "duplicate key value violates unique constraint")

print(pcall(function()
  return fake:exec "insert into ref_db_tasks (title) values ($1)"
end))
```

#### fake:hang(pattern, seconds)

Programa uma query correspondente para esperar `seconds` (60 por padrão) e então lançar `db: query hung and was never answered`.

A espera é real e ela cede, e esse é o objetivo: ela encena uma coroutine abandonada no meio de uma query, o que lançar o erro imediatamente não faz.

**Ela espera no relógio real mesmo quando um relógio manual está instalado**, o que é o oposto do que `latency_ms` faz. Um relógio manual colapsaria a espera para nada, e `hang` silenciosamente viraria `fail` com outro nome.

**Retorna** a instância.

```lua
local memory = require "akkar.db.memory"
local time   = require "akkar.time"

local fake = memory.new():hang("pg_sleep", 0.1)

local started = time.monotime()
print(pcall(function() return fake:one "select pg_sleep(30)" end))
print("waited:", time.monotime() - started >= 0.1)
```

#### fake:many(sql, ...)

Encontra a primeira resposta correspondente e a retorna como uma lista de linhas.

Uma resposta que é uma função é chamada como `response(sql, ...)`. Uma resposta que é uma única linha é retornada como uma lista de uma linha, então `one` e `many` funcionam ambos sobre a mesma programação. Uma resposta `nil`, incluindo uma função que não retorna nada, é uma lista vazia.

**Uma tabela vazia é uma linha vazia, não zero linhas.** `{}` não tem `[1]`, então ela toma o caminho de linha única, e `one` devolve uma tabela truthy sem nada dentro. Para programar uma ausência de resultado, use uma função:

```lua no-run
fake:on("where id", function() return nil end)   -- zero linhas
fake:on("where id", {})                          -- UMA linha, sem colunas
```

E `reset` não desprograma nada — ele limpa o log e as flags de transação. Como `many` retorna o **primeiro** padrão que corresponde, programar o mesmo padrão de novo nunca vence. Construa um fake novo para um cenário que precise de uma resposta diferente para a mesma query.

**Retorna** uma lista de linhas.

**Lança** `akkar.db.memory: no response programmed for query: <sql>` e
`akkar.db.memory: query needs SQL, got <type>`.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new()
  :on("^select id, title", { id = 1, title = "buy milk" })
  :on("^insert into ref_db_tasks", function(_, title)
        return { id = 42, title = title }
      end)

print(#fake:many "select id, title from ref_db_tasks")
print(fake:one("insert into ref_db_tasks (title) values ($1) returning id, title",
               "walk the dog").title)
```

#### fake:on(pattern, response)

Programa uma resposta. `response` é uma linha, uma lista de linhas, ou uma função chamada como `response(sql, ...)` cujo valor de retorno é usado da mesma forma.

**Retorna** a instância.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new()
  :on("^select id from ref_db_tasks", { { id = 1 }, { id = 2 } })
  :on("^select count", { n = 2 })

print(#fake:many "select id from ref_db_tasks")
print(fake:one("select count(*) as n from ref_db_tasks").n)
```

#### fake:one(sql, ...)

A primeira linha de `many`, ou `nil`.

#### fake:query(sql, ...)

Aquilo sobre o que `one`, `many` e `exec` são construídos. Uma query do [akkar.sql](sql.md) é construída aqui, exatamente como o adaptador real a constrói, então o log guarda o SQL que um servidor teria recebido.

`begin`, `commit` e `rollback` são respondidos pelo próprio adaptador, então um teste não precisa programá-los.

**Retorna** a resposta programada.

```lua
local memory = require "akkar.db.memory"
local sql    = require "akkar.sql"

local fake = memory.new():on("select id from ref_db_tasks", { id = 7 })

print(fake:one(sql.select("id"):from("ref_db_tasks"):where("id = ?", 7)).id)
print(fake.log[1].sql)
print(fake.log[1].args[1])
```

#### fake:received(pattern)

Se uma query correspondente a `pattern` foi recebida.

**Retorna** `false`, ou `true` mais a entrada de log, que é
`{ sql = ..., args = table.pack(...) }`.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():on("^update", { id = 1 })
fake:exec("update ref_db_tasks set done = true where id = $1", 3)

local seen, call = fake:received "^update"
print(seen, call.sql, call.args[1])
print(fake:received "^delete")
```

#### fake:release()

Não faz nada. Presente para que o akkar possa liberá-la como qualquer outra conexão.

#### fake:reset()

Limpa o log de queries, as marcas `committed` e `rolled_back`, e qualquer estado de derrubada (dropped). As respostas programadas permanecem.

**Retorna** a instância.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():on("^select", { n = 1 })
fake:one "select 1"
print(fake:count())
print(fake:reset():count())
```

#### fake:scope(column, value)

O mesmo escopo do adaptador real, através do mesmo módulo, para que um fake não possa ter uma propriedade de segurança mais fraca do que a conexão que ele representa.

**Retorna** um handle [Scoped](scope.md#scoped).

#### fake:transaction(fn)

Mesmo formato do real: `commit` no final, `rollback` em caso de erro lançado, e o erro é relançado para que uma resposta lançada ainda funcione.

Depois disso, `fake.committed` ou `fake.rolled_back` fica `true`, e `fake.depth` conta o aninhamento enquanto ela roda.

**Retorna** o que `fn` retornou.

```lua
local memory = require "akkar.db.memory"

local fake = memory.new():on("^insert", { id = 1 })

fake:transaction(function(tx) tx:exec "insert into ref_db_tasks (title) values ($1)" end)
print("committed", fake.committed)

print(pcall(function()
  fake:transaction(function() error "no" end)
end))
print("rolled back", fake.rolled_back)
```

#### fake:unscoped()

Retorna a instância. Assim como em uma conexão real, ela está lá para ser encontrada com grep.

## Não está aqui

`db.escape` não existe, e nenhum helper de quoting existe tampouco. Valores viajam como parâmetros sobre o protocolo estendido, então não há nada para escapar. Um nome de coluna não é um valor, e essa é a tarefa de
[`sql.identifier`](sql.md#sqlidentifiername-allowed-what).

Não existe `db.transaction(conn, fn)`. Uma transação tem escopo de closure sobre a conexão, então não há como deixar um `begin` aberto por esquecer uma linha.

Não existe cache de prepared statement. Os parâmetros são vinculados sobre o protocolo estendido em uma instrução sem nome, o que é uma vinculação segura e não é a mesma coisa que um plano do lado do servidor mantido em cache entre chamadas.

Não existe reconexão. Uma conexão que quebrou é descartada, e a próxima chamada à fábrica abre uma nova.

## Veja também
- [akkar](akkar.md) para `app:run { db = open }` e para `req.db`
- [akkar.sql](sql.md) constrói as instruções que este módulo executa
- [akkar.scope](scope.md) é o handle que `conn:scope` retorna
- [akkar.pool](pool.md) é o que `pool_size` cria
- [akkar.migrate](migrate.md) pega uma dessas conexões e a mantém durante toda uma execução
- o código-fonte do módulo, `akkar/db.lua`, para os tipos de parâmetro, as leituras em buffer e por que a transação faz commit de um 4xx retornado
