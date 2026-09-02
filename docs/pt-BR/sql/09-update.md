# 9. update e set

> **Português (Brasil)** | [Original em inglês](../../sql/09-update.md)

Ao final desta página você será capaz de alterar uma linha com segurança, e terá encontrado a recusa que se coloca entre você e a instrução que altera todas as linhas da tabela.

## `set` uma vez por coluna

```lua
local sql = require "akkar.sql"

local q = sql.update "sqlguide_tasks"
q:set("done", true, { "done", "title" })
q:set("title", "buy oat milk", { "done", "title" })
q:where("id = ?", 3)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
update sqlguide_tasks set done = $1, title = $2 where id = $3
1	true
2	buy oat milk
3	3
```

`set` recebe três coisas: a coluna, o valor e a lista de permissão. A coluna é um identificador, então é escrita no texto e verificada. O valor é um valor, então é vinculado (bound). **Eles nunca podem trocar de lugar**, e não existe chamada que permita isso.

O terceiro argumento é a mesma defesa presente em `insert_into`: é a lista de colunas que quem chama pode alterar. Sem ela, um corpo (body) contendo `is_admin` e um handler que percorre em loop os campos do corpo acabaria alterando essa coluna.

### Os valores saem na ordem do texto

Observe a numeração acima. Os dois valores de `set` são `$1` e `$2`, e o valor da condição é `$3`, porque `set` vem antes de `where` na instrução final. Se você tivesse escrito `$1`, `$2`, `$3` por conta própria e depois adicionasse outra linha de `set`, todo número posterior estaria errado.

Este é o caso em que `:values()` não corresponde à ordem em que você chamou as coisas, o que a [página 1](01-the-query-object.md) já havia avisado:

```lua
local sql = require "akkar.sql"

local q = sql.update "sqlguide_tasks"
q:where("id = ?", 3)              -- chamado primeiro
q:set("title", "new", { "title" }) -- chamado depois

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
update sqlguide_tasks set title = $1 where id = $2
1	new
2	3
```

Você chamou `where` primeiro e mesmo assim seu valor saiu em segundo lugar, porque `build` numera o texto final, não a ordem das suas chamadas.

## A recusa que importa

Um `update` sem `where` altera todas as linhas da tabela. Essa instrução é legítima em uma migração e quase nunca é legítima em um handler, então o akkar não vai montar uma por acidente:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.update("sqlguide_tasks"):set("done", true, { "done" }):build()
end)
print(ok, why)
```

```
false	akkar.sql: update with no where clause would affect every row; add a condition or call :all_rows() to say you meant it
```

O erro que isso captura não é "esqueci o que é `where`". É um handler em que a condição é adicionada dentro de um `if`, e o `if` era falso:

```lua no-run
local q = sql.update "tasks"
q:set("done", true, { "done" })
if req.params.id then q:where("id = ?", req.params.id) end   -- e se ele for nil?
req.db:exec(q)
```

Sem a recusa, um id ausente marcaria todas as tarefas do banco de dados como concluídas. Com ela, essa requisição (request) levanta um erro e responde `500`, o que é um dia ruim em vez de uma catástrofe.

### `all_rows` quando você quer mesmo isso

Algumas atualizações realmente devem afetar tudo. Diga isso explicitamente:

```lua
local sql = require "akkar.sql"

print(sql.update("sqlguide_tasks"):set("done", false, { "done" })
      :all_rows():to_string())
```

```
update sqlguide_tasks set done = $1
```

O valor de `all_rows` é ser uma palavra que alguém pode procurar. `grep -rn ':all_rows()'` lista todas as instruções no seu código que podem alterar uma tabela inteira, e essa lista deveria ser curta e deveria ser sem graça.

### Um update sem nada definido

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.update("sqlguide_tasks"):where("id = ?", 1):build()
end)
print(ok, why)
```

```
false	akkar.sql: update with no columns; call :set()
```

Isso geralmente significa que o handler construiu suas chamadas de `set` em um loop sobre os campos enviados por quem chamou, e quem chamou não enviou nenhum. Um corpo de PATCH vazio é um `400`, e verificar isso antes de chegar ao banco de dados dá a quem chamou uma resposta melhor do que esse erro daria.

### Uma coluna que não está na lista

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.update("sqlguide_tasks"):set("is_admin", true, { "done", "title" })
end)
print(ok, why)
```

```
false	akkar.sql: column name 'is_admin' is not in the allowed list (done, title)
```

## Executando, e sabendo se algo aconteceu

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key, title text not null, done boolean not null default false)]]
conn:exec "insert into sqlguide_tasks (title) values ('buy milk'), ('walk the dog')"

local q = sql.update "sqlguide_tasks"
q:set("done", true, { "done", "title" })
q:where("id = ?", 1)

local result = conn:exec(q)
print("changed:", result.affected_rows)

local missing = sql.update "sqlguide_tasks"
missing:set("done", true, { "done" })
missing:where("id = ?", 999)
print("changed:", conn:exec(missing).affected_rows)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
changed:	1
changed:	0
```

`affected_rows` é como você distingue "eu atualizei isso" de "não havia nada com esse id". Zero é o caso que merece um `404`, e é fácil esquecer disso, porque uma atualização que não mudou nada não falha.

### Ou peça a linha de volta

`returning` transforma o update em uma query que responde com o que foi alterado, o que economiza a segunda consulta e a verificação de `affected_rows` de uma só vez:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key, title text not null, done boolean not null default false)]]
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local q = sql.update "sqlguide_tasks"
q:set("done", true, { "done" })
q:where("id = ?", 1)
q:returning "id, title, done"

local row = conn:one(q)
print(row.id, row.title, tostring(row.done))

local none = sql.update "sqlguide_tasks"
none:set("done", true, { "done" })
none:where("id = ?", 999)
none:returning "id"
print(tostring(conn:one(none)))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
1	buy milk	true
nil
```

`nil` vindo de `db:one` significa que nenhuma linha correspondeu, que é exatamente o formato que `or akkar.not_found "..."` espera.

## Uma armadilha: `limit` em um update

O builder permite que você chame `:limit` em um update. O Postgres não suporta isso, e você só descobre quando a instrução é executada:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key, title text not null, done boolean not null default false)]]

local q = sql.update "sqlguide_tasks"
q:set("done", true, { "done" })
q:where("id = ?", 1)
q:limit(1)

print(q:to_string())

local ok, why = pcall(function() return conn:exec(q) end)
print(ok, why)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
update sqlguide_tasks set done = $1 where id = $2 limit $3
false	db: ERROR: syntax error at or near "limit" (51)
```

O builder montou isso tranquilamente. `limit` e `offset` pertencem ao `select`, e o builder não verifica em que tipo de instrução você está. Se você quiser atualizar apenas algumas das linhas correspondentes, nomeie-as na condição, com `where_in` ou uma subquery escrita como texto.

## Checkpoint

Você domina isto se:

- consegue atualizar uma linha e ler `affected_rows` para ver se ela existia
- sabe por que um update sem condição é recusado, e como dizer que essa era mesmo sua intenção
- sabe que os valores de `set` vêm antes dos valores da condição na numeração
- não recorreria a `limit` em um update de novo

Próximo: [10. delete_from](10-delete.md).
