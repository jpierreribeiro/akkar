# 7. group_by

> **Português (Brasil)** | [Original em inglês](../../sql/07-group-by.md)

Ao final desta página você será capaz de contar e somar linhas por grupo, e
vai conhecer as duas coisas que o builder não faz aqui e o que escrever no
lugar delas.

## Contando sem agrupar antes

Um agregado é uma função que transforma várias linhas em um número: `count`,
`sum`, `avg`, `min`, `max`. Eles entram na lista de colunas, que é o seu texto,
então nada de novo é necessário para usá-los:

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
  id serial primary key,
  owner text not null,
  done boolean not null default false,
  minutes integer not null default 0)]]
conn:exec [[insert into sqlguide_tasks (owner, done, minutes) values
  ('ana', false, 10), ('ana', true, 5), ('ana', false, 30), ('bo', true, 15)]]

local q = sql.select("count(*) as n, avg(minutes) as mean"):from "sqlguide_tasks"
print(q:to_string())

local row = conn:one(q)
print(row.n, row.mean)

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
select count(*) as n, avg(minutes) as mean from sqlguide_tasks
4	15.0
```

Voltou uma única linha, porque é isso que um agregado sobre uma tabela
inteira é: uma resposta só. Use `db:one` para isso, não `db:many`.

Dê um nome a cada agregado com `as`. Sem isso, o Postgres chama a coluna de
`count`, e `row.count` fica pior de ler do que `row.n` e entra em conflito
assim que você tiver dois deles.

## `group_by` divide as linhas antes

Adicione um `group by` e você recebe uma linha por valor distinto daquela
coluna, em vez de uma linha para a tabela inteira:

```lua
local sql = require "akkar.sql"

local q = sql.select("owner, count(*) as n, sum(minutes) as total")
             :from "sqlguide_tasks"
q:group_by("owner", { "owner", "done" })
q:order_by("n", { "n", "owner" }, "desc")

print(q:to_string())
```

```
select owner, count(*) as n, sum(minutes) as total from sqlguide_tasks group by owner order by n desc
```

O segundo argumento é uma lista de permissões, pelo mesmo motivo que existe
em `order_by`: um nome de coluna é um identificador, é escrito diretamente na
instrução, e não pode ser vinculado (bound). Se a coluna de agrupamento vem
de quem chama, é essa lista que impede que alguém nomeie uma coluna que você
nunca quis expor.

Executando:

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
  id serial primary key,
  owner text not null,
  done boolean not null default false,
  minutes integer not null default 0)]]
conn:exec [[insert into sqlguide_tasks (owner, done, minutes) values
  ('ana', false, 10), ('ana', true, 5), ('ana', false, 30), ('bo', true, 15)]]

local q = sql.select("owner, count(*) as n, sum(minutes) as total")
             :from "sqlguide_tasks"
q:group_by("owner", { "owner", "done" })
q:order_by("n", { "n", "owner" }, "desc")

for _, row in ipairs(conn:many(q)) do
  print(row.owner, row.n, row.total)
end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
ana	3	45
bo	1	15
```

Duas linhas para dois donos. `order_by("n", ...)` ordenou pelo nome que você
deu à contagem, o que o Postgres permite, e é por isso que nomear seus
agregados compensa duas vezes.

### Toda coluna simples na lista do select tem que estar no group by

Essa é uma regra do SQL, não uma regra do akkar, e é o primeiro erro que se
encontra aqui. Se você seleciona `owner, title, count(*)` e agrupa só por
`owner`, o Postgres recusa, porque existem três títulos diferentes no grupo e
ele não sabe qual você queria.

A correção é ou adicionar a coluna ao agrupamento, ou envolvê-la em um
agregado como `min(title)`. Como `group_by` aceita apenas uma coluna, a
resposta prática é: selecione a coluna de agrupamento, e agregados de tudo o
mais.

## `where` filtra antes de agrupar

A condição se aplica às linhas, e roda primeiro:

```lua
local sql = require "akkar.sql"

local q = sql.select("owner, count(*) as n"):from "sqlguide_tasks"
q:where("done = ?", false)
q:group_by("owner", { "owner" })
q:order_by("owner", { "owner" })

print(q:to_string())
```

```
select owner, count(*) as n from sqlguide_tasks where done = $1 group by owner order by owner asc
```

Leia isso como: descarte as tarefas concluídas, depois conte o que sobrou,
por dono. Não é a mesma pergunta que "donos que não concluíram nenhuma
tarefa", e confundir as duas é o erro clássico de agrupamento.

## As duas coisas que o builder não faz

### Uma única coluna de agrupamento

Chamar `group_by` duas vezes substitui em vez de somar, exatamente como
`order_by`:

```lua
local sql = require "akkar.sql"

local q = sql.select("count(*) as n"):from "sqlguide_tasks"
q:group_by("owner", { "owner", "done" })
q:group_by("done", { "owner", "done" })

print(q:to_string())
```

```
select count(*) as n from sqlguide_tasks group by done
```

O `group by owner` sumiu. Não existe forma de agrupar por duas colunas pelo
builder.

### Não existe `having`

`having` é a condição que se aplica **depois** do agrupamento, aquela que diz
"só donos com mais de duas tarefas". O builder não tem método para isso, e
`:where` não serve, porque `where` roda antes.

Os dois casos são o mesmo sinal: a query deixou de depender da requisição
(request) e virou um relatório fixo. Escreva como texto e passe os valores
normalmente:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec [[create table sqlguide_tasks (
  id serial primary key,
  owner text not null,
  done boolean not null default false,
  minutes integer not null default 0)]]
conn:exec [[insert into sqlguide_tasks (owner, done, minutes) values
  ('ana', false, 10), ('ana', true, 5), ('ana', false, 30), ('bo', true, 15)]]

for _, row in ipairs(conn:many([[
  select owner, done, count(*) as n
  from sqlguide_tasks
  group by owner, done
  having count(*) > $1
  order by owner, done]], 1)) do
  print(row.owner, tostring(row.done), row.n)
end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
ana	false	2
```

Essa instrução tem duas colunas de agrupamento e um `having`, e é
completamente segura: a única coisa que varia é `$1`, que está vinculado.
**O builder é para instruções cujo formato muda com a requisição. Uma
instrução fixa não precisa dele**, e recorrer a texto aqui não é um passo
atrás.

## Checkpoint

Você tem isso se:

- consegue produzir uma linha por dono com uma contagem nela
- sabe que `where` filtra as linhas antes de o agrupamento acontecer
- sabe que o builder faz uma coluna de agrupamento e nenhum `having`, e que
  uma instrução fixa escrita como texto com `$1` é a resposta certa quando
  você precisa de mais

Próxima página: [8. insert_into](08-insert.md).
