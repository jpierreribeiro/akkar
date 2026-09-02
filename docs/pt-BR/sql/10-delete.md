# 10. delete_from

> **Português (Brasil)** | [Original em inglês](../../sql/10-delete.md)

Ao final desta página você será capaz de apagar uma linha, distinguir entre "apaguei" e "não existia" e vai conhecer os dois erros que impedem um delete.

## A forma

```lua
local sql = require "akkar.sql"

local q = sql.delete_from("sqlguide_tasks", { "sqlguide_tasks" })
q:where("id = ?", 7)

print(q:to_string())
print(q:values()[1])
```

```
delete from sqlguide_tasks where id = $1
7
```

Dois argumentos: a tabela e uma lista de permissão (allow-list) opcional de nomes de tabela. Não existe `set` nem lista de colunas, porque um delete remove linhas inteiras.

## A mesma recusa do `update`

Um `delete` sem condição esvazia a tabela:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function() return sql.delete_from("sqlguide_tasks"):build() end)
print(ok, why)
```

```
false	akkar.sql: delete with no where clause would affect every row; add a condition or call :all_rows() to say you meant it
```

E a mesma saída de emergência, para os casos em que esvaziar uma tabela é realmente o trabalho. Limpar sessões expiradas periodicamente é o exemplo honesto:

```lua
local sql = require "akkar.sql"

print(sql.delete_from("sqlguide_sessions"):all_rows():to_string())
```

```
delete from sqlguide_sessions
```

Recorra a `:all_rows()` somente no código em que uma tabela inteira é de fato o alvo, e nunca em um handler que pegou um id vindo da requisição (request). Em um handler, um id ausente deve virar um `400`, não um `delete` que é executado com sucesso.

## Apagou alguma coisa?

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local function remove(id)
  local q = sql.delete_from "sqlguide_tasks"
  q:where("id = ?", id)
  return conn:exec(q).affected_rows
end

print("first time: ", remove(1))
print("second time:", remove(1))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
first time: 	1
second time:	0
```

Essa é toda a lógica de uma rota `DELETE`: `1` é um `204`, e `0` é um `404`. A lista de tarefas do guia faz exatamente isso na [página 6](../guide/06-storing-and-reading.md).

`returning` também funciona aqui, e é útil quando você quer informar ao chamador o que foi removido, ou registrar isso em um log de auditoria:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local q = sql.delete_from "sqlguide_tasks"
q:where("id = ?", 1)
q:returning "id, title"

local row = conn:one(q)
print(row.id, row.title)
print(tostring(conn:one(q)))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
1	buy milk
nil
```

A segunda chamada não apagou nada, então `returning` não retornou nenhuma linha, então `db:one` devolveu `nil`. Uma verificação em vez de duas.

## O erro que você vai realmente encontrar

Não o do builder. O do banco de dados, quando outra tabela aponta para a linha que você está apagando:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "drop table if exists sqlguide_people"
conn:exec "create table sqlguide_people (id serial primary key, name text not null)"
conn:exec [[create table sqlguide_tasks (
  id serial primary key,
  person_id integer not null references sqlguide_people(id),
  title text not null)]]
conn:exec "insert into sqlguide_people (name) values ('ana')"
conn:exec "insert into sqlguide_tasks (person_id, title) values (1, 'buy milk')"

local q = sql.delete_from "sqlguide_people"
q:where("id = ?", 1)

local ok, why = pcall(function() return conn:exec(q) end)
print(ok, why)

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_people"
conn:close()
```

```
false	db: ERROR: update or delete on table "sqlguide_people" violates foreign key constraint "sqlguide_tasks_person_id_fkey" on table "sqlguide_tasks"
Key (id)=(1) is still referenced from table "sqlguide_tasks".
```

O Postgres está protegendo você de uma tarefa cujo dono não existe. A segunda linha nomeia exatamente a linha e exatamente a tabela que ainda apontam para ela.

Três saídas, e a escolha depende do que a sua aplicação significa:

**Apague os filhos primeiro**, dentro de uma única [transação](13-transactions.md), para que você nunca acabe tendo apagado só metade.

**Deixe o banco de dados fazer isso**, declarando a referência como `references sqlguide_people(id) on delete cascade` na migração que a cria. Assim, apagar uma pessoa apaga suas tarefas. Isso é conveniente e silencioso, então use onde as linhas filhas realmente não têm sentido sem o pai.

**Não apague de jeito nenhum.** Adicione uma coluna `deleted_at timestamptz`, defina-a em vez de remover a linha, e acrescente `where deleted_at is null` às suas leituras. Nada se perde, as referências continuam válidas, e o "desfazer exclusão" se torna possível. O custo é que toda consulta (query) precisa lembrar dessa condição, e esquecê-la mostra linhas apagadas para alguém.

## Ponto de checagem

Você está pronto se:

- consegue apagar por id e responder `404` quando nada corresponder
- sabe para que serve `:all_rows()` e por que ele precisa ser digitado
- reconheceria um erro de chave estrangeira e saberia suas três opções

Próxima página: [11. Identifiers and allow-lists](11-identifiers-and-allow-lists.md).
