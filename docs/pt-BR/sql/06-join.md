# 6. join

> **Português (Brasil)** | [Original em inglês](../../sql/06-join.md)

Ao final desta página você será capaz de ler linhas de duas tabelas ao mesmo
tempo, e vai conhecer as duas coisas sobre o `join` do akkar que, do
contrário, custariam uma tarde do seu tempo: ele não tem aliases, e a
cláusula é texto pelo qual você é responsável.

## O que é um join, em um parágrafo

Cada uma das suas tarefas pertence a uma pessoa. A tabela `sqlguide_tasks`
não guarda o nome da pessoa, guarda o id dela, porque guardar o nome nos dois
lugares significa mudá-lo nos dois lugares. Um join é como você pede as duas
tabelas em uma única pergunta: "toda tarefa, com o nome da pessoa a quem ela
pertence".

## A cláusula é escrita por completo

`:join` recebe a cláusula inteira, começando pela palavra `join`:

```lua
local sql = require "akkar.sql"

local q = sql.select("sqlguide_tasks.title, sqlguide_people.name")
             :from "sqlguide_tasks"
q:join "join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"

print(q:to_string())
```

```
select sqlguide_tasks.title, sqlguide_people.name from sqlguide_tasks join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id
```

Você escreve a palavra `join`, então também é você quem escolhe o tipo. O
`left join` mantém as linhas que não têm correspondência do outro lado:

```lua
local sql = require "akkar.sql"

local q = sql.select("sqlguide_tasks.title, sqlguide_people.name")
             :from "sqlguide_tasks"
q:join "left join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"

print(q:to_string())
```

```
select sqlguide_tasks.title, sqlguide_people.name from sqlguide_tasks left join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id
```

Chame `:join` mais de uma vez para mais de uma tabela. Cada cláusula é
anexada na ordem em que você a adicionou.

## Não há aliases, então escreva o nome completo sempre

A maior parte do SQL que você vai ler usa aliases curtos: `from tasks t join
people p on p.id = t.person_id`. Você não pode fazer isso aqui, porque
`:from` recusa `tasks t`. São duas palavras, e o nome de uma tabela precisa
ser um único identificador:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function() return sql.select("*"):from "sqlguide_tasks t" end)
print(ok, why)
```

```
false	akkar.sql: table name is not a valid identifier: sqlguide_tasks t
```

Então a regra para consultas com join é: **escreva o nome completo da
tabela na frente de cada coluna, em todo lugar.** Na lista do select, na
condição do join e na cláusula where. Dá mais trabalho para digitar e sempre
funciona.

A única coisa que você não consegue fazer de jeito nenhum é ligar uma tabela
a ela mesma, porque esse é exatamente o caso que precisa de dois nomes para
uma tabela. Se você precisar disso, escreva a instrução inteira como texto e
passe para `db:many` com seus próprios valores.

## Valores em uma cláusula de join

Um `?` dentro de uma cláusula de join vincula um valor, do mesmo jeito que em
uma condição:

```lua
local sql = require "akkar.sql"

local q = sql.select("sqlguide_tasks.title"):from "sqlguide_tasks"
q:join("join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id "
    .. "and sqlguide_people.name = ?", "ana")
q:where("sqlguide_tasks.title like ?", "buy%")

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select sqlguide_tasks.title from sqlguide_tasks join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id and sqlguide_people.name = $1 where sqlguide_tasks.title like $2
1	ana
2	buy%
```

Repare na numeração. O join fica antes do `where` no texto final, então o
valor dele é `$1` e o da condição é `$2`, mesmo que você tenha adicionado a
condição depois. Você não precisou saber disso, e essa é justamente a
vantagem de deixar o `build` fazer a contagem.

## A cláusula não é verificada, então nada vindo de uma requisição entra nela

Este é o único lugar em `akkar.sql` onde ainda é possível escrever uma
injeção, e vale a pena ser direto sobre isso.

O texto que você passa para `:join` é copiado para a instrução exatamente
como foi dado. O akkar não o lê. É a mesma regra da lista de colunas em
[`select`](02-select-and-from.md): seguro porque é o seu texto, no seu
arquivo, fixado antes de qualquer requisição (request) chegar.

Então isto é um bug, e o akkar não tem como impedir você de escrevê-lo:

```lua no-run
-- NUNCA. Agora quem chama controla parte da instrução.
q:join("join " .. req.query.table .. " on ...")
```

Se um nome de tabela realmente precisar variar, passe-o por `sql.identifier`
com uma lista antes, exatamente como a [página 2](02-select-and-from.md)
mostrou para colunas. Não existe versão disso em que texto de requisição não
verificado tenha lugar em um join.

## Cuidado com duas colunas de mesmo nome

Uma linha volta como uma única tabela Lua plana, um campo por coluna do
resultado. Se duas colunas na sua lista do select tiverem o mesmo nome, elas
colidem, e **a última vence**:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local row = conn:one "select 1 as id, 2 as id"
print(row.id)

conn:close()
```

```
2
```

Nada avisa. Em um join entre duas tabelas que têm as duas um `id`, isso é a
diferença entre o id da tarefa e o id da pessoa, silenciosamente.

Então dê nomes a elas:

```lua
local sql = require "akkar.sql"

local q = sql.select("sqlguide_tasks.id as task_id, "
               .. "sqlguide_people.id as person_id, sqlguide_people.name")
             :from "sqlguide_tasks"
q:join "join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"

print(q:to_string())
```

```
select sqlguide_tasks.id as task_id, sqlguide_people.id as person_id, sqlguide_people.name from sqlguide_tasks join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id
```

`as task_id` renomeia a coluna no resultado, então a linha tem `row.task_id`
e `row.person_id` e nada se perde.

## O conjunto completo, contra um banco de dados de verdade

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
  person_id integer references sqlguide_people(id),
  title text not null)]]
conn:exec "insert into sqlguide_people (name) values ('ana'), ('bo')"
conn:exec [[insert into sqlguide_tasks (person_id, title) values
  (1, 'buy milk'), (2, 'walk the dog'), (null, 'nobody owns me')]]

local inner = sql.select("sqlguide_tasks.title, sqlguide_people.name")
                 :from "sqlguide_tasks"
inner:join "join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"
inner:order_by("title", { "title" })

print "join:"
for _, row in ipairs(conn:many(inner)) do print("", row.title, row.name) end

local outer = sql.select("sqlguide_tasks.title, sqlguide_people.name")
                 :from "sqlguide_tasks"
outer:join "left join sqlguide_people on sqlguide_people.id = sqlguide_tasks.person_id"
outer:order_by("title", { "title" })

print "left join:"
for _, row in ipairs(conn:many(outer)) do print("", row.title, tostring(row.name)) end

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_people"
conn:close()
```

```
join:
	buy milk	ana
	walk the dog	bo
left join:
	buy milk	ana
	nobody owns me	nil
	walk the dog	bo
```

O `join` simples descartou a tarefa sem pessoa. O `left join` a manteve e
deu `nil` para o nome, porque o akkar deixa um `null` do SQL totalmente de
fora da tabela de resultado, e um campo ausente em Lua é lido como `nil`.

Esse último detalhe importa quando você envia a linha adiante como JSON: um
campo que é `nil` simplesmente não está no objeto. Se quem chama precisar
ver esse campo, defina um valor padrão no seu handler.

## Ponto de checagem

Você está pronto se:

- consegue ligar duas tabelas e receber de volta uma única linha plana
- sabe por que não há aliases e o que escrever no lugar deles
- sabe que `?` funciona dentro de uma cláusula de join e que o resto da
  cláusula não é verificado
- daria um alias a duas colunas que compartilham um nome em vez de deixar
  uma delas vencer

A seguir: [7. group_by](07-group-by.md).
