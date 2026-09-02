# 5. order_by, limit e offset

> **Português (Brasil)** | [Original em inglês](../../sql/05-order-limit-offset.md)

Ao final desta página você será capaz de ordenar um resultado por uma coluna escolhida por quem chama a rota e devolver essa página de resultado por vez.

## `order_by` recebe um identificador, então recebe uma lista de permissões

Um nome de coluna não pode ser vinculado (bound). O Postgres não consegue planejar `order by $1`, porque o plano depende de qual coluna é essa. Então o nome é escrito diretamente na instrução, e isso significa que ele precisa ser verificado:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:order_by("title", { "id", "title", "created_at" })

print(q:to_string())
```

```
select id, title from sqlguide_tasks order by title asc
```

O segundo argumento é a lista completa de colunas pelas quais quem chama a rota pode ordenar. Ela é escrita por você. Qualquer coisa que não esteja nessa lista é recusada:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"

local ok, why = pcall(function()
  return q:order_by("password_hash", { "id", "title", "created_at" })
end)
print(ok, why)
```

```
false	akkar.sql: order column 'password_hash' is not in the allowed list (id, title, created_at)
```

Essa recusa vira um `500` se chegar até quem chama a rota, então faça a mesma verificação no schema da rota com `one_of` e quem chama recebe um `422` limpo em vez disso. As duas verificações, por dois motivos: o schema existe para dar uma boa resposta a quem chama, e a lista de permissões existe porque um schema que você esqueceu de escrever não deveria ser a única coisa entre um desconhecido e suas colunas.
[A página 6 do guia](../guide/06-storing-and-reading.md) mostra os dois juntos.

### Direção

O terceiro argumento é `"asc"` ou `"desc"`. Deixar de fora significa `"asc"`. A caixa não importa:

```lua
local sql = require "akkar.sql"

print(sql.select("id"):from("sqlguide_tasks"):order_by("id", nil, "desc"):to_string())
print(sql.select("id"):from("sqlguide_tasks"):order_by("id", nil, "DESC"):to_string())

local ok, why = pcall(function()
  return sql.select("id"):from("sqlguide_tasks"):order_by("id", nil, "sideways")
end)
print(ok, why)
```

```
select id from sqlguide_tasks order by id desc
select id from sqlguide_tasks order by id desc
false	akkar.sql: order direction must be asc or desc, got sideways
```

Só essas duas palavras são aceitas, então uma direção tirada direto de uma query string não pode virar outra coisa.

### Apenas uma coluna

Chamar `order_by` duas vezes não adiciona uma segunda coluna. Ela substitui a primeira:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:order_by("title", { "id", "title" })
q:order_by("id", { "id", "title" }, "desc")

print(q:to_string())
```

```
select id, title from sqlguide_tasks order by id desc
```

A ordenação por `title` desapareceu. E você não consegue contrabandear duas colunas em uma única chamada, porque duas colunas separadas por vírgula não formam um identificador:

```lua
local sql = require "akkar.sql"

local q = sql.select("id"):from "sqlguide_tasks"
local ok, why = pcall(function() return q:order_by("title, id", { "title, id" }) end)
print(ok, why)
```

```
false	akkar.sql: order column is not a valid identifier: title, id
```

Esse é um limite real do builder, e é o preço da verificação. Se você precisa de `order by done, created_at desc`, essa query é fixa em vez de escolhida por quem chama, então escreva como texto e entregue para `db:many` você mesmo.

## `limit` e `offset` são valores

Diferente do nome da coluna, os números são vinculados (bound):

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:order_by("id", { "id" })
q:limit(10)
q:offset(20)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select id, title from sqlguide_tasks order by id asc limit $1 offset $2
1	10
2	20
```

`limit` vem antes de `offset` no texto final, não importa em qual ordem você os chamou, e a numeração segue o texto.

Ambos recusam qualquer coisa que não seja um número inteiro igual ou maior que zero:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function() return sql.select("*"):from("t"):limit(10.0) end)
print(ok, why)

local ok2, why2 = pcall(function() return sql.select("*"):from("t"):limit(-1) end)
print(ok2, why2)

local ok3, why3 = pcall(function() return sql.select("*"):from("t"):offset("20") end)
print(ok3, why3)
```

```
false	akkar.sql: limit must be a non-negative integer, got 10.0
false	akkar.sql: limit must be a non-negative integer, got -1
false	akkar.sql: offset must be a non-negative integer, got 20
```

O primeiro caso surpreende as pessoas. `10.0` é um float em Lua, não um inteiro, e é exatamente isso que `tonumber(req.query.limit)` te dá quando quem chama a rota mandou `10.0`. O último surpreende pelo motivo oposto: a mensagem imprime `20` porque as aspas não aparecem, mas o valor era o **texto** `"20"`, que é o que uma query string sempre contém até que algo o converta.

Valide no schema da rota, onde `integer` faz a conversão e a recusa por você:

```lua no-run
app:get("/tasks", {
  query = {
    limit  = v.integer { optional = true, default = 20, min = 1, max = 100 },
    offset = v.integer { optional = true, default = 0, min = 0 },
  },
}, function(req)
  local q = sql.select("id, title"):from "sqlguide_tasks"
  q:order_by("id", { "id", "title" })
  q:limit(req.query.limit):offset(req.query.offset)
  return { tasks = akkar.array(req.db:many(q)) }
end)
```

## Uma página por vez, contra uma tabela de verdade

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
conn:exec [[insert into sqlguide_tasks (title) values
  ('one'), ('two'), ('three'), ('four'), ('five')]]

local function page(number, size)
  local q = sql.select("id, title"):from "sqlguide_tasks"
  q:order_by("id", { "id", "title" })
  q:limit(size)
  q:offset((number - 1) * size)
  return conn:many(q)
end

for number = 1, 3 do
  local titles = {}
  for _, row in ipairs(page(number, 2)) do titles[#titles + 1] = row.title end
  print("page " .. number, table.concat(titles, ", "))
end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
page 1	one, two
page 2	three, four
page 3	five
```

Essa função `page` segue duas regras, e as duas importam.

**Sempre ordene quando você pagina.** Sem `order by`, o Postgres pode devolver as linhas em qualquer ordem que quiser, e ele é livre para escolher uma ordem diferente para a página 2 da que escolheu para a página 1. Você acabaria recebendo linhas repetidas e perdendo outras, e isso funcionaria bem nos testes com uma tabela pequena.

**Ordene por algo único.** `order by title` numa tabela com duas linhas chamadas "one" deixa essas duas em uma ordem indefinida entre si, e o mesmo problema de duplicação e perda volta em uma forma menor. Ordenar por uma coluna escolhida por quem chama a rota é aceitável, contanto que a query seja determinística no geral. Com este builder isso significa ordenar por `id` sempre que possível.

### `offset` fica mais lento conforme o número da página aumenta

`offset 10000` significa que o Postgres encontra dez mil linhas e as descarta antes de começar a te entregar qualquer coisa. Isso é tranquilo para as primeiras páginas e ruim para a página quinhentos.

A outra abordagem é lembrar o último id que você viu e pedir as linhas depois dele:

```lua
local sql = require "akkar.sql"

local last_id = 4

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where("id > ?", last_id)
q:order_by("id", { "id" })
q:limit(2)

print(q:to_string())
```

```
select id, title from sqlguide_tasks where id > $1 order by id asc limit $2
```

Sem `offset` nenhum, então o banco de dados pula direto para o lugar certo usando o índice. [A receita de paginação](../recipes/paginate-a-list.md) desenvolve isso com cuidado.

## Checkpoint

Você entendeu isto se:

- consegue ordenar por uma coluna escolhida por quem chama a rota e sabe para que serve o segundo argumento
- sabe que chamar `order_by` duas vezes substitui em vez de adicionar
- sabe por que `limit(10.0)` é recusado e `limit(10)` não é
- sempre adiciona `order by` quando usa `limit` e `offset`

Próxima página: [6. join](06-join.md).
