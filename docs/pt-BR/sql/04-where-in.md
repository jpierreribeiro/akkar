# 4. where_in, para uma lista

> **Português (Brasil)** | [Original em inglês](../../sql/04-where-in.md)

Ao final desta página você será capaz de perguntar "esta coluna é um destes valores" com uma lista que chegou de quem chamou, e vai saber o que acontece quando essa lista está vazia.

## O problema

Você tem uma lista de ids e quer as linhas de todos eles. Em SQL isso é:

```sql
select id, title from sqlguide_tasks where id in (1, 2, 3)
```

O número de valores não é fixo. É quantos quem chamou enviou. Então você não pode escrever a condição de antemão, e `:where("id in (?)", ids)` também não funciona, porque um `?` vincula um valor e uma lista Lua é um valor só que o Postgres não entende.

## `where_in` escreve um placeholder por elemento

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where_in("id", { 1, 2, 3 }, { "id" })

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select id, title from sqlguide_tasks where id in ($1, $2, $3)
1	1
2	2
3	3
```

Três elementos, três placeholders, três valores. Cinco elementos dariam cinco. Todos são vinculados, então uma lista de strings vinda de uma requisição (request) continua sendo uma lista de strings:

```lua
local sql = require "akkar.sql"

local titles = { "buy milk", "'); drop table sqlguide_tasks; --" }

local q = sql.select("id"):from "sqlguide_tasks"
q:where_in("title", titles, { "id", "title" })

print(q:to_string())
print(q:values()[2])
```

```
select id from sqlguide_tasks where title in ($1, $2)
'); drop table sqlguide_tasks; --
```

A string de ataque está na lista de valores, onde é texto e nada mais. O comando tem dois placeholders e nenhum texto vindo do usuário.

## O terceiro argumento é a lista de permissão

`where_in` recebe um **nome de coluna**, e um nome de coluna é um identificador, então não pode ser vinculado. Ele é checado da mesma forma que `from`:

```lua
local sql = require "akkar.sql"

local q = sql.select("id"):from "sqlguide_tasks"
local ok, why = pcall(function()
  return q:where_in("password_hash", { 1, 2 }, { "id", "title" })
end)
print(ok, why)
```

```
false	akkar.sql: column name 'password_hash' is not in the allowed list (id, title)
```

Você pode deixar a lista de fora quando a coluna é uma constante que você mesmo escreveu. Passe-a sempre que o nome da coluna puder ter vindo de uma requisição.

## Uma lista vazia não corresponde a nada, de propósito

Esta é a parte que pega as pessoas de surpresa, e o akkar decidiu isso por você:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where_in("id", {}, { "id" })

print(q:to_string())
print("#values", #q:values())
```

```
select id, title from sqlguide_tasks where false
#values	0
```

A condição virou a palavra `false`, que nenhuma linha pode satisfazer. Então uma lista vazia te dá um resultado vazio.

Outras duas coisas poderiam ter acontecido, e ambas são piores.

**Escrever `id in ()`** é um erro de sintaxe no Postgres. A query falharia com uma mensagem sobre um parêntese, a partir de uma requisição que não estava errada, só vazia.

**Descartar a condição** deixaria `select id, title from sqlguide_tasks` sem nenhum `where`, o que retorna **toda linha da tabela**. Essa é a perigosa. "Me mostre as tarefas com estes ids" com uma lista vazia responderia com as tarefas de todo mundo. A mesma query em uma página com um filtro de tenant ainda estaria delimitada, mas em uma página sem esse filtro é um vazamento de dados causado por um array vazio em um corpo JSON.

Aqui está contra um banco de dados de verdade, para você ver que "nenhuma linha" é o que realmente volta:

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
conn:exec "insert into sqlguide_tasks (title) values ('buy milk'), ('walk the dog'), ('read the guide')"

local some = sql.select("id, title"):from "sqlguide_tasks"
some:where_in("id", { 1, 3 }, { "id" })
print("some:", #conn:many(some))

local none = sql.select("id, title"):from "sqlguide_tasks"
none:where_in("id", {}, { "id" })
print("none:", #conn:many(none))

print("everything:", #conn:many(sql.select("id"):from "sqlguide_tasks"))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
some:	2
none:	0
everything:	3
```

Dois, depois nenhum, depois três. A linha do meio é o assunto desta seção.

## Dois limites que vale conhecer

**Um buraco na lista quebra tudo.** Uma lista Lua com um `nil` no meio tem um tamanho que o Lua não consegue determinar com certeza, e você recebe a mensagem enganosa da [página 3](03-where.md):

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where_in("id", { 1, nil, 3 }, { "id" })

local ok, why = pcall(function() return q:to_string() end)
print(ok, why)
```

```
false	akkar.sql: 3 placeholder(s) but 2 value(s) -- this is a bug in akkar.sql
```

Não é um bug no akkar. É um `nil` na sua lista. Construa a lista com `list[#list + 1] = value` para que ela não possa ter buracos.

**Uma lista muito longa não vai caber.** O Postgres permite no máximo 65535 parâmetros vinculados em um único comando. Uma lista mais longa que isso falha com uma mensagem que não se explica:

```lua no-run
local ids = {}
for i = 1, 70000 do ids[i] = i end
q:where_in("id", ids, { "id" })
```

```
db: ERROR: invalid message format
```

Se você tem dezenas de milhares de ids, `where_in` é a ferramenta errada. Coloque-os em uma tabela e faça um join com ela, ou envie-os em lotes.

## Checkpoint

Você entendeu isso se:

- `where_in("id", { 1, 2, 3 }, { "id" })` te dá `id in ($1, $2, $3)`
- você sabe dizer o que uma lista vazia produz, e por que a alternativa foi recusada
- você sabe que a coluna é checada e os valores não são

Próxima: [5. order_by, limit e offset](05-order-limit-offset.md).
