# akkar.sql

> **Português (Brasil)** | [Original em inglês](../../reference/sql.md)

Constrói statements SQL a partir de dados. Um valor é sempre vinculado como parâmetro, nunca escrito no texto do statement, e não existe nenhum método que aceite SQL puro.

**Quando você precisa disso.** Quando o statement depende do que o chamador pediu: um filtro opcional, uma coluna de ordenação vinda de uma query string, uma lista de ids. Um statement fixo não precisa deste módulo, `db:many("select ...", value)` já basta.

```lua no-run
local sql = require "akkar.sql"
```

## Índice

Todos os símbolos públicos desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`query:all_rows`](#queryall_rows) | método |
| [`query:build`](#querybuild) | método |
| [`query:for_update`](#queryfor_update) | método |
| [`query:from`](#queryfromtable_name-allowed) | método |
| [`query:group_by`](#querygroup_bycolumn-allowed) | método |
| [`query:is_scoped`](#queryis_scoped) | método |
| [`query:join`](#queryjoinclause-) | método |
| [`query:limit`](#querylimitn) | método |
| [`query:offset`](#queryoffsetn) | método |
| [`query:on_conflict_do_nothing`](#queryon_conflict_do_nothingcolumns-allowed) | método |
| [`query:order_by`](#queryorder_bycolumn-allowed-direction) | método |
| [`query:returning`](#queryreturningcolumns) | método |
| [`query:scope`](#queryscopecolumn-value-allowed) | método |
| [`query:set`](#querysetcolumn-value-allowed) | método |
| [`query:skip_locked`](#queryskip_locked) | método |
| [`query:to_string`](#queryto_string) | método |
| [`query:values`](#queryvalues) | método |
| [`query:where`](#querywherecondition-) | método |
| [`query:where_in`](#querywhere_incolumn-values-allowed) | método |
| [`sql.cast`](#sqlcastvalue-postgres_type) | função |
| [`sql.delete_from`](#sqldelete_fromtable_name-allowed) | função |
| [`sql.identifier`](#sqlidentifiername-allowed-what) | função |
| [`sql.insert_into`](#sqlinsert_intotable_name-row-allowed_columns-allowed_table) | função |
| [`sql.jsonb`](#sqlcastvalue-postgres_type) | função |
| [`sql.Query`](#sqlquery) | tabela |
| [`sql.select`](#sqlselectcolumns) | função |
| [`sql.timestamptz`](#sqlcastvalue-postgres_type) | função |
| [`sql.update`](#sqlupdatetable_name-allowed) | função |
| [`sql.uuid`](#sqlcastvalue-postgres_type) | função |

Também nesta página: [Identificadores e valores](#identificadores-e-valores), e
[O que não está aqui](#o-que-não-está-aqui).

## sql.cast(value, postgres_type)

Marca um valor vinculado com um tipo SQL explícito, de modo que seu placeholder é emitido como
`$N::type` enquanto o valor em si continua vinculado como parâmetro. `sql.uuid(v)`, `sql.jsonb(v)` e
`sql.timestamptz(v)` são as três formas nomeadas disponíveis.

O PostgreSQL não converte automaticamente um parâmetro declarado como texto para uma coluna do tipo `uuid`,
e o pgmoon declara strings Lua como texto. Sem o cast, a comparação vira um erro de tipo no servidor, e a saída mais fácil seria interpolação de string,
que é justamente a porta que este módulo existe para fechar.

O conjunto de tipos é fechado de propósito. É um valor tipado, não uma válvula de escape para cast bruto: apenas o nome do tipo chega ao texto SQL, e somente a partir dessa lista.

**Retorna** um valor tipado opaco, utilizável em qualquer lugar onde um valor vinculado é aceito: `where`,
`scope`, `set` e uma linha (row) de `insert_into`.

**Levanta erro** `akkar.sql: unsupported parameter cast: <name>` para qualquer outro tipo.

```lua
local sql = require "akkar.sql"

local id = "5b06ddf5-4158-45e8-9726-60e064478cac"
local q = sql.select("*"):from("ref_sql_items")
  :where("id = ?", sql.uuid(id))
print(q:to_string())                     --> ... where (id = $1::uuid)
print(q:values()[1] == id)               --> true

print(pcall(sql.cast, "x", "uuid); drop table t; --"))
```

## sql.delete_from(table_name, allowed)

Inicia um statement `delete`. `allowed` é uma lista opcional de nomes de tabelas; quando
fornecida, `table_name` precisa estar entre elas.

**Retorna** uma [Query](#query).

**Levanta erro** quando `table_name` não é um identificador simples, ou não está em `allowed`.

Um `delete` sem `where` levanta erro em tempo de `build`, a menos que
[`:all_rows()`](#queryall_rows) tenha sido chamado.

```lua
local sql = require "akkar.sql"

local q = sql.delete_from("ref_sql_tasks", { "ref_sql_tasks" })
q:where("id = ?", 7)

print(q:to_string())
print(q:values()[1])
```

## sql.identifier(name, allowed, what)

Verifica um identificador e o retorna. `what` é a palavra usada na mensagem de
erro (`"column name"`, `"table name"`). `allowed` é uma lista opcional; quando
fornecida, `name` precisa estar nela.

Esta é a mesma verificação que toda outra função deste módulo usa. Chame-a
diretamente quando você estiver escrevendo texto SQL à mão e ainda assim precisar
verificar um nome vindo de uma requisição (request).

**Retorna** `name`, sem alterações.

**Levanta erro** `akkar.sql: <what> is not a valid identifier: <name>` quando o nome
não é composto por letras, dígitos e underscores (opcionalmente com um ponto para um nome
qualificado), e `akkar.sql: <what> '<name>' is not in the allowed list (...)` quando
ele não está em `allowed`.

```lua
local sql = require "akkar.sql"

print(sql.identifier("title", { "id", "title" }, "column name"))
print(sql.identifier("public.tasks", nil, "table name"))

local ok, why = pcall(sql.identifier, "password_hash", { "id", "title" },
                      "column name")
print(ok, why)
```

## sql.insert_into(table_name, row, allowed_columns, allowed_table)

Inicia um `insert`. Os nomes de colunas vêm das chaves de `row`, então, numa rota
real, eles vieram do corpo de uma requisição; cada uma delas é verificada, e
`allowed_columns` é como uma rota diz quais colunas um cliente pode escrever.

As colunas são ordenadas por nome, então a mesma linha (row) sempre produz o mesmo texto de statement.

**Retorna** uma [Query](#query).

**Levanta erro** quando uma chave de `row` não é um identificador simples ou não está em
`allowed_columns`, quando `table_name` falha na mesma verificação contra
`allowed_table`, e em tempo de `build` com `akkar.sql: insert with no columns`
quando `row` estava vazia.

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("ref_sql_tasks",
                          { title = "buy milk", done = false },
                          { "title", "done" })
q:returning "id, title, done"

print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

## sql.Query

A metatable de [Query](#query), exportada para que um teste possa verificar
`getmetatable(q) == sql.Query`. Nada mais precisa dela.

```lua no-run
local sql = require "akkar.sql"
local is_query = getmetatable(sql.select "*") == sql.Query
```

## sql.select(columns)

Inicia um `select`. `columns` é texto SQL, com `"*"` como padrão. Não é
verificado, porque é escrito por você e não por um chamador: passe um nome de coluna que veio
de uma requisição por [`sql.identifier`](#sqlidentifiername-allowed-what)
primeiro.

A tabela é definida separadamente, com [`:from`](#queryfromtable_name-allowed).

**Retorna** uma [Query](#query).

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title, done"):from "ref_sql_tasks"
q:where("done = ?", false)
q:order_by("title", { "id", "title" })
q:limit(10)

print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

## sql.update(table_name, allowed)

Inicia um `update`. `allowed` é uma lista opcional de nomes de tabelas. Colunas são
definidas com [`:set`](#querysetcolumn-value-allowed).

**Retorna** uma [Query](#query).

**Levanta erro** quando `table_name` falha na verificação de identificador, em tempo de `build` com
`akkar.sql: update with no columns; call :set()` quando nada foi definido, e em tempo de `build` quando não há
`where` e nenhum
[`:all_rows()`](#queryall_rows).

```lua
local sql = require "akkar.sql"

local q = sql.update("ref_sql_tasks", { "ref_sql_tasks" })
q:set("done", true, { "done", "title" })
q:where("id = ?", 3)
q:returning "id, done"

print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

## Query

O que as cinco funções acima retornam. Todo método retorna a query, então as chamadas
se encadeiam. Nada é montado até [`:build`](#querybuild), que também é o que
`db:one`, `db:many` e `db:exec` chamam quando recebem uma query em vez de
uma string.

Um `?` em qualquer condição marca um valor. A numeração em `$1`, `$2` acontece uma vez,
em `build`, então fragmentos se compõem sem que ninguém precise contar placeholders.

### query:all_rows()

Diz que um `update` ou um `delete` sem `where` foi intencional. Sem isso,
`build` levanta erro em vez de escrever um statement que atinge todas as linhas.

**Retorna** a query.

```lua
local sql = require "akkar.sql"

local q = sql.delete_from("ref_sql_sessions")
local ok, why = pcall(function() return q:to_string() end)
print(ok, why)

print(q:all_rows():to_string())
```

### query:build()

Monta o statement. Retorna o texto SQL seguido pelos valores vinculados, na
ordem dos placeholders, que é exatamente a lista de argumentos que `db:many` recebe.

**Retorna** `sql, value1, value2, ...`.

**Levanta erro** `akkar.sql: no table; call :from()` quando nenhuma tabela foi definida, e os
erros específicos de cada tipo listados nas cinco funções iniciais.

```lua
local sql = require "akkar.sql"
local db  = require "akkar.db.memory"

local fake = db.new():on("select id, title", { id = 1, title = "buy milk" })

local q = sql.select("id, title"):from("ref_sql_tasks"):where("id = ?", 1)
print(q:build())

-- db:one chama :build por conta própria, então a query vai direto.
print(fake:one(q).title)
```

### query:for_update()

Trava as linhas selecionadas até que a transação em curso seja concluída. A cláusula
é escrita por último, depois de `limit`, porque o PostgreSQL a rejeita em qualquer outro lugar,
e o builder é a única coisa que decide a ordem, então um chamador não consegue
errar isso.

**Retorna** a query.

**Levanta erro** `akkar.sql: for_update is only valid on select queries`.

```lua
local sql = require "akkar.sql"

print(sql.select("id, stock"):from("ref_sql_variants")
        :where("id = ?", "v-1"):limit(1):for_update():to_string())
```

### query:from(table_name, allowed)

Define a tabela. `allowed` é uma lista opcional de nomes de tabelas.

`table_name` precisa ser um identificador simples ou `schema.name`. Um alias
(`"tasks t"`) é recusado, porque não é um identificador.

**Retorna** a query.

**Levanta erro** `akkar.sql: table name is not a valid identifier: <name>`.

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("public.ref_sql_tasks"):to_string())

local ok, why = pcall(function()
  return sql.select("*"):from "ref_sql_tasks t"
end)
print(ok, why)
```

### query:group_by(column, allowed)

Adiciona um `group by` em uma coluna. A coluna é um identificador, então é verificada
contra `allowed` quando uma lista é fornecida.

**Retorna** a query.

**Levanta erro** em uma coluna que falha na verificação de identificador.

```lua
local sql = require "akkar.sql"

local q = sql.select("done, count(*) as n"):from "ref_sql_tasks"
q:group_by("done", { "done" })
print(q:to_string())
```

### query:is_scoped()

Se [`:scope`](#queryscopecolumn-value-allowed) foi chamado. É isso
que um handle escopado de `akkar.scope` verifica antes de executar qualquer coisa.

**Retorna** `true` ou `false`.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "ref_sql_documents"
print(q:is_scoped())
q:scope("project_id", 9)
print(q:is_scoped())
```

### query:join(clause, ...)

Adiciona texto de join a um `select`, com seus próprios valores. A cláusula é escrita por completo,
incluindo a palavra `join`, e `?` nela vincula um valor como em qualquer outro
lugar.

A cláusula em si é texto SQL e não é verificada, então nada vindo de uma requisição
deve estar nela.

**Retorna** a query.

```lua
local sql = require "akkar.sql"

local q = sql.select("ref_sql_tasks.id, ref_sql_users.name")
             :from "ref_sql_tasks"
q:join("join ref_sql_users on ref_sql_users.id = ref_sql_tasks.user_id " ..
       "and ref_sql_users.active = ?", true)
q:where("ref_sql_tasks.done = ?", false)

print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

### query:limit(n)

Adiciona `limit`. O número é vinculado como valor, não escrito no texto.

**Retorna** a query.

**Levanta erro** `akkar.sql: limit must be a non-negative integer, got <n>`. Um float
é recusado, então `limit(10.0)` falha e `limit(10)` não falha.

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("ref_sql_tasks"):limit(10):to_string())

local ok, why = pcall(function()
  return sql.select("*"):from("ref_sql_tasks"):limit(10.0)
end)
print(ok, why)
```

### query:offset(n)

Adiciona `offset`, vinculado como valor. Mesma regra do `limit`.

**Retorna** a query.

**Levanta erro** `akkar.sql: offset must be a non-negative integer, got <n>`.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "ref_sql_tasks"
q:limit(10):offset(20)
print(q:to_string())
for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

### query:on_conflict_do_nothing(columns, allowed)

Torna um `insert` idempotente. Com `columns`, emite um alvo de conflito,
`on conflict (a, b) do nothing`; sem um, um `on conflict do nothing` puro.
A cláusula é escrita antes de `returning`, e uma linha que entrou em conflito não retorna
nada, o que é como o chamador distingue "inserido" de "já existia".

`columns` são identificadores, não valores, então são verificados exatamente como
qualquer outro identificador escolhido pelo chamador nesta página.

**Retorna** a query.

**Levanta erro** `akkar.sql: on_conflict_do_nothing is only valid on inserts`,
`akkar.sql: conflict columns must be a non-empty list`, e os
erros de identificador de [`sql.identifier`](#sqlidentifiername-allowed-what).

```lua
local sql = require "akkar.sql"

print(sql.insert_into("ref_sql_event_ids", { event_id = "e-1" })
        :on_conflict_do_nothing({ "tenant_id", "event_id" })
        :returning("event_id"):scope("tenant_id", "t-1"):to_string())
```

### query:order_by(column, allowed, direction)

Define o `order by`. `direction` é `"asc"` (o padrão) ou `"desc"`, em qualquer capitalização.

Um nome de coluna não pode ser um valor vinculado, porque o Postgres não consegue planejar
`order by $1`. Então uma coluna vinda de um chamador precisa ser verificada
contra `allowed`, uma lista que você escreveu.

Chamar duas vezes substitui a ordenação anterior em vez de somar a ela.

**Retorna** a query.

**Levanta erro** `akkar.sql: order column '<name>' is not in the allowed list (...)`
e `akkar.sql: order direction must be asc or desc, got <direction>`.

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "ref_sql_tasks"
q:order_by("title", { "id", "title" }, "desc")
print(q:to_string())

local ok, why = pcall(function()
  q:order_by("password_hash", { "id", "title" })
end)
print(ok, why)
```

### query:returning(columns)

Adiciona `returning`, de modo que um `insert`, `update` ou `delete` retorna as linhas que
atingiu. `columns` é texto SQL, com `"*"` como padrão.

**Retorna** a query.

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("ref_sql_tasks", { title = "buy milk" }, { "title" })
print(q:returning("id, title"):to_string())
```

### query:scope(column, value, allowed)

Vincula a query a um único tenant (inquilino).

Em um `select`, `update` ou `delete`, adiciona `column = value` como condição. Em
um `insert`, define essa coluna na linha, substituindo o que quer que a linha já tivesse,
de modo que um corpo (body) reivindicando o id de outro tenant não consegue escrever nele.

**Retorna** a query, marcada como escopada.

**Levanta erro** em uma coluna que falha na verificação de identificador, e
`akkar.sql: scope value for '<column>' is nil` quando `value` é nil.

```lua
local sql = require "akkar.sql"

local read = sql.select("*"):from "ref_sql_documents"
print(read:scope("project_id", 42):to_string())

local write = sql.insert_into("ref_sql_documents",
                              { title = "notes", project_id = 1 },
                              { "title", "project_id" })
write:scope("project_id", 42)
print(write:to_string())
for index, value in ipairs(write:values()) do
  print(index, tostring(value))
end
```

### query:set(column, value, allowed)

Define uma coluna em um `update`. A coluna é um identificador e o valor é um
valor, e eles não podem trocar de lugar. Chame uma vez por coluna.

**Retorna** a query.

**Levanta erro** em uma coluna que falha na verificação de identificador.

```lua
local sql = require "akkar.sql"

local q = sql.update("ref_sql_tasks")
q:set("done", true, { "done", "title" })
q:set("title", "buy oat milk", { "done", "title" })
q:where("id = ?", 3)
print(q:to_string())
```

### query:skip_locked()

Pega as linhas que ninguém mais está segurando em vez de esperar atrás delas. Só faz
sentido junto com [`for_update`](#queryfor_update), e essa combinação é verificada em
`build` e não aqui, então tanto `skip_locked():for_update()` quanto
`for_update():skip_locked()` funcionam, já que rejeitar um seria rejeitar um
statement perfeitamente bem formado no momento em que é executado.

Correto apenas para uma reivindicação cuja marca é durável: uma fila que, na mesma
transação que trava as linhas, escreve algo que as remove do seu
próprio predicado. Sem essa marca, ambos os concorrentes leem as mesmas linhas no momento em que
o primeiro faz commit e pular (skip) não oferece nada.

**Retorna** a query.

**Levanta erro** `akkar.sql: skip_locked is only valid on select queries` aqui, e
`akkar.sql: skip_locked requires for_update` a partir de `build`.

```lua
local sql = require "akkar.sql"

print(sql.select("id"):from("ref_sql_jobs"):where("available_at <= now()")
        :limit(10):for_update():skip_locked():to_string())
```

### query:to_string()

Apenas o texto do statement, sem os valores. Para testes e para logging.

Os valores são deliberadamente deixados de fora: uma linha de log mostrando valores
reais inseridos na SQL é como uma query segura vira uma query insegura ao ser copiada.

**Retorna** o texto SQL.

**Levanta erro** o que [`:build`](#querybuild) levantar, já que o chama.

```lua
local sql = require "akkar.sql"

print(sql.select("id"):from("ref_sql_tasks"):where("id = ?", 1):to_string())
```

### query:values()

Os valores vinculados como uma lista, na ordem dos placeholders. Para asserções.

**Retorna** uma tabela.

**Levanta erro** o que [`:build`](#querybuild) levantar.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "ref_sql_tasks"
q:where("done = ?", false):where("title like ?", "buy%"):limit(5)

for index, value in ipairs(q:values()) do
  print(index, tostring(value))
end
```

### query:where(condition, ...)

Adiciona uma condição. As condições são unidas com `and`. Cada `?` em `condition`
recebe um valor dos argumentos.

**Retorna** a query.

**Levanta erro** `akkar.sql: condition has N placeholder(s) but M value(s) were
given: <condition>` quando as contagens diferem. A contagem é de caracteres `?`
em qualquer lugar do texto, então um `?` dentro de um literal de string também conta.

Em um `insert`, uma condição e seus valores são descartados em tempo de `build` sem
gerar erro. `where` em um insert não tem sentido, e nada avisa isso.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "ref_sql_tasks"
q:where("done = ?", false)
q:where("title like ?", "buy%")
print(q:to_string())

local ok, why = pcall(function() q:where("id = ?") end)
print(ok, why)
```

### query:where_in(column, values, allowed)

Adiciona `column in (...)` com um placeholder por elemento, de modo que uma lista chegando como
dado permanece como dado.

Uma lista vazia vira a condição `false`, que não corresponde a nenhuma linha. `in ()` é
um erro de sintaxe no Postgres, e descartar a condição em vez disso retornaria
todas as linhas em vez de nenhuma.

**Retorna** a query.

**Levanta erro** em uma coluna que falha na verificação de identificador.

```lua
local sql = require "akkar.sql"

local some = sql.select("*"):from "ref_sql_tasks"
some:where_in("id", { 1, 2, 3 }, { "id" })
print(some:to_string())

local none = sql.select("*"):from "ref_sql_tasks"
none:where_in("id", {}, { "id" })
print(none:to_string())
```

## Identificadores e valores

Um valor pode ser um parâmetro. Um identificador não pode: o Postgres não tem placeholder
para um nome de tabela ou coluna, porque o plano de execução depende de qual delas é.

Então os dois são tratados de forma diferente, em todo este módulo:

| o quê | como viaja | como é verificado |
|---|---|---|
| um valor, em `where`, `set`, `where_in`, `limit`, `offset`, `scope` | vinculado como `$1`, `$2` | não é verificado, pode ser qualquer coisa |
| um identificador, em `from`, `set`, `order_by`, `group_by`, `where_in`, `scope`, `insert_into` | escrito no texto | padrão, mais sua lista `allowed` |
| texto SQL, em `select`, `returning`, `join`, `where` | escrito no texto tal como fornecido | não é verificado, então nada vindo de uma requisição deve estar aqui |

O padrão de identificador é `^[%a_][%w_]*$`, ou dois desses com um ponto
entre eles. É mais restrito do que o Postgres aceita. Um nome entre aspas com um
espaço nele é recusado, e o custo disso é um erro claro, enquanto o custo
de aceitar um nome malicioso é o banco de dados.

## O que não está aqui

`where_raw` não existe, e nenhuma outra forma de adicionar SQL não verificado carregando
valores também não existe. Uma válvula de escape é por onde a injeção passa.

`query:order` não existe. O próprio cabeçalho do módulo mostra `q:order("name")`;
o método é [`order_by`](#queryorder_bycolumn-allowed-direction) e ele recebe
uma lista de permissão (allow-list).

Não há `or`. As condições são unidas com `and`. Escreva a alternância
dentro de uma única condição: `q:where("(a = ? or b = ?)", x, y)`.

Não há `execute`. Uma query é entregue a `db:one`, `db:many` ou `db:exec`,
que chamam `:build` por você.

## Veja também
- [akkar.db](db.md) executa o que este módulo constrói
- [akkar.scope](scope.md) usa `:scope` e `:is_scoped` para recusar uma query sem escopo
- [akkar.migrate](migrate.md) não usa isto: uma migração é SQL que você escreveu
- o código-fonte do módulo, `akkar/sql.lua`, para entender por que não há válvula de escape
