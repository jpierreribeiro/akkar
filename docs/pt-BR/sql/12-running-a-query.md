# 12. one, many e exec

> **Português (Brasil)** | [Original em inglês](../../sql/12-running-a-query.md)

Ao final desta página você vai saber qual dos três métodos chamar, o que cada um devolve, e o que uma linha realmente é depois que chega até o Lua.

Até agora cada página construiu uma query e imprimiu ela. Esta página envia.

## O handle

Dentro de um handler você nunca abre uma conexão. O akkar coloca uma em `req.db` para a requisição (request) e recupera depois:

```lua no-run
app:get("/tasks", function(req)
  return { tasks = akkar.array(req.db:many(sql.select("*"):from "tasks")) }
end)
```

Em um script, você abre uma você mesmo, que é o que todo exemplo desta página faz:

```lua no-run
local open = db.connect { ... , pool_size = 0 }
local conn = open()
```

São o mesmo objeto com os mesmos quatro métodos. `db.connect` retorna uma
**factory**, não uma conexão, e chamar ela é o que abre uma.
[A referência](../reference/db.md) tem a tabela de configuração completa.

## Os três, e quando recorrer a cada um

| chamada | devolve | recorra a ela quando |
|---|---|---|
| `db:one(q)` | a primeira linha, ou `nil` | você pediu uma coisa |
| `db:many(q)` | uma lista de linhas | você pediu uma lista |
| `db:exec(q)` | uma tabela com `affected_rows` | você alterou linhas e não precisa delas de volta |

Todos os três aceitam as mesmas duas formas. Um objeto de query:

```lua no-run
req.db:many(q)
```

Ou texto e valores:

```lua no-run
req.db:many("select id, title from tasks where done = $1", false)
```

O primeiro chama `:build()` por você. Não existe uma terceira forma nem um método `execute`.

## O que uma linha é

Uma tabela Lua simples, um campo por coluna, com tipos Lua:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key, title text not null, done boolean not null default false)]]
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local row = conn:one "select id, title, done from sqlguide_tasks where id = 1"

print(type(row))
print(row.id, type(row.id))
print(row.title, type(row.title))
print(row.done, type(row.done))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
table
1	number
buy milk	string
false	boolean
```

Não há mais nada a aprender sobre o formato. Nenhum objeto wrapper, nenhum método acessor, nenhum carregamento preguiçoso. É uma tabela, então ela vai direto de volta como JSON.

**Um `null` do SQL não está na tabela de jeito nenhum.** O akkar deixa o campo de fora em vez de inventar um valor para ele, então `row.note` lê como `nil`, e uma resposta (response) JSON simplesmente não tem a chave `note`. Se quem chamou precisa que a chave esteja lá, defina ela no seu handler.

## `db:one` devolve `nil` quando nada casou

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"

print(tostring(conn:one "select id from sqlguide_tasks where id = 999"))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
nil
```

Esse `nil` é o motivo de `or akkar.not_found "..."` aparecer em todo lugar nos handlers do akkar:

```lua no-run
local task = req.db:one(sql.select("*"):from("tasks"):where("id = ?", req.params.id))
return task or akkar.not_found "no task with that id"
```

`db:one` é `db:many` mais `rows[1]`. Ele não adiciona `limit 1` e não reclama se a query casou com cem linhas. Se você queria uma, coloque a condição ou o `limit` lá você mesmo.

## `db:many` sempre devolve uma lista

Mesmo quando nada casou. Uma lista vazia, nunca `nil`:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"

local rows = conn:many "select id from sqlguide_tasks"
print(type(rows), #rows)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
table	0
```

Então `ipairs(rows)` é sempre seguro. O que não é seguro é devolver essa lista direto para quem chamou, porque uma tabela Lua vazia vira `{}` em JSON em vez de `[]`. Envolva ela em `akkar.array`, que
[a página 6 do guia](../guide/06-storing-and-reading.md) explica por completo.

## `db:exec` devolve `affected_rows`

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"
conn:exec "insert into sqlguide_tasks (title) values ('buy milk')"

local result = conn:exec("update sqlguide_tasks set title = $1 where id = $2",
                         "buy oat milk", 1)
for key, value in pairs(result) do print(key, value) end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
affected_rows	1
```

Um campo, e é o que diz se a linha existia. Zero é o caso do `404`.

`exec` e `many` são a mesma chamada por baixo dos panos, então nada quebra se você escolher a outra. `many` em um insert te dá uma tabela com `affected_rows` nela e um comprimento de zero, o que é confuso de ler em vez de errado. Use o nome que diz o que você quis dizer.

## Os erros, e de onde eles vêm

Duas coisas bem diferentes podem dar errado, e elas se leem de forma diferente.

**O builder recusa**, antes de qualquer coisa ser enviada. Essas são as mensagens das últimas nove páginas, todas começando com `akkar.sql:`.

**O Postgres recusa**, depois de ser enviado. Essas começam com `db: ERROR:`:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"

local ok, why = pcall(function() return conn:many "select nope from sqlguide_tasks" end)
print(ok, why)

local ok2, why2 = pcall(function() return conn:many("select $1, $2", 1) end)
print(ok2, why2)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
false	db: ERROR: column "nope" does not exist (8)
false	db: ERROR: bind message supplies 1 parameters, but prepared statement "" requires 2
```

Ambos lançam em vez de retornar um erro, que é como o resto do akkar se comporta: uma falha viaja para cima como um erro, a cadeia de handlers da requisição transforma ela em um `500`, e você não precisa checar um valor de retorno depois de cada query.

O número entre colchetes no primeiro é a posição do caractere no comando onde o Postgres parou. Em um comando longo, é a forma mais rápida de encontrar o erro de digitação.

A segunda mensagem vale a pena reconhecer, porque não é óbvia. Ela significa que o comando tinha dois placeholders `$` e você passou um valor. Esse é o erro que o builder existe para tornar impossível: com `?` e `:where`, a contagem é checada em Lua antes de qualquer coisa ser enviada, e a mensagem nomeia a condição em vez disso.

## Uma conexão, uma requisição

Vale a pena entender o pool em um parágrafo, porque isso explica uma regra na qual você vai tropeçar de outra forma.

`db.connect` sem `pool_size` mantém dez conexões e entrega uma para cada requisição que pede `req.db`. Quando a requisição termina, a conexão volta. É por isso que você nunca fecha `req.db` você mesmo, e por que uma conexão não é compartilhada entre duas requisições ao mesmo tempo.

A regra que isso explica está na próxima página: dentro de uma transação você deve usar o handle que a closure recebeu, não `req.db`, porque uma segunda conexão emprestada está fora da transação e não vai ser desfeita.

## Checkpoint

Você tem isso se:

- você consegue dizer qual entre `one`, `many` e `exec` chamar sem pensar
- você espera `nil` de `one` e `{}` de `many` quando nada casou
- você consegue distinguir um erro `akkar.sql:` de um `db: ERROR:` e sabe de qual lado da conexão cada um veio

Próxima: [13. transaction, e a armadilha nela](13-transactions.md).
