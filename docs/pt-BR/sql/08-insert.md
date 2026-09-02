# 8. insert_into

> **Português (Brasil)** | [Original em inglês](../../sql/08-insert.md)

Ao final desta página você será capaz de escrever uma linha a partir de um corpo de requisição, obter a linha finalizada de volta na mesma viagem de ida e volta, e terá visto o que acontece com um insert que confia no corpo.

## A forma

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("sqlguide_tasks",
                          { title = "buy milk", done = false },
                          { "title", "done" })

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
insert into sqlguide_tasks (done, title) values ($1, $2)
1	false
2	buy milk
```

Quatro argumentos, e o terceiro é o importante:

| argumento | é | exemplo |
|---|---|---|
| `table_name` | a tabela, um identificador | `"sqlguide_tasks"` |
| `row` | uma tabela Lua de coluna para valor | `{ title = "buy milk" }` |
| `allowed_columns` | a lista de colunas que quem chama pode escrever | `{ "title", "done" }` |
| `allowed_table` | uma lista opcional de nomes de tabela | geralmente omitida |

Os nomes das colunas são as **chaves de `row`**. Numa rota real, `row` veio do corpo de uma requisição (request), então essas chaves vieram de um estranho. É por isso que elas são checadas, e é por isso que o terceiro argumento existe.

### As colunas saem ordenadas

`done` veio antes de `title` acima, mesmo você tendo escrito `title` primeiro. Tabelas Lua não têm ordem, então o akkar ordena os nomes para ter uma. O resultado é que a mesma linha sempre produz o mesmo texto de statement, o que é um detalhe pequeno mas que importa: duas grafias do mesmo insert são dois statements para o Postgres planejar, e um já basta.

### Um campo que não está lá não é uma coluna

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk" }        -- no `done` was sent

local q = sql.insert_into("sqlguide_tasks",
                          { title = body.title, done = body.done },
                          { "title", "done" })
print(q:to_string())
```

```
insert into sqlguide_tasks (title) values ($1)
```

`body.done` era `nil`, então a chave nunca esteve na tabela, então a coluna não está no statement. O banco de dados então aplica qualquer valor padrão que a coluna tenha. Isso geralmente é o que você quer. Vale saber que isso está acontecendo, porque significa que um insert não pode propositalmente definir uma coluna como `null` passando `nil`. Se você precisa de um null explícito, escreva esse statement como texto.

## `returning` te dá a linha finalizada

O Postgres pode responder a um insert com a linha que acabou de escrever:

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("sqlguide_tasks", { title = "buy milk" }, { "title" })
q:returning "id, title, done"

print(q:to_string())
```

```
insert into sqlguide_tasks (title) values ($1) returning id, title, done
```

Sem isso, você teria que rodar uma segunda query para descobrir qual `id` o banco de dados escolheu. Com isso, uma viagem de ida e volta, e nenhum chute. Chamado sem argumento, ele retorna tudo:

```lua
local sql = require "akkar.sql"

print(sql.insert_into("sqlguide_tasks", { title = "buy milk" }, { "title" })
      :returning():to_string())
```

```
insert into sqlguide_tasks (title) values ($1) returning *
```

`returning` funciona em `update` e `delete` também, e é texto que você escreveu, então não é checado.

## A coisa inteira, contra um banco de dados real

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
  title text not null,
  done boolean not null default false)]]

local body = { title = "buy milk" }        -- pretend this is req.body

local made = conn:one(
  sql.insert_into("sqlguide_tasks", body, { "title", "done" })
     :returning "id, title, done")

print(made.id, made.title, tostring(made.done))

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
1	buy milk	false
```

`db:one` é a escolha certa para um insert com `returning`, porque uma linha volta. Sem `returning`, use `db:exec`.

## A lista de permissões, e o que acontece sem ela

Aqui está a parte que vale a página inteira.

`allowed_columns` é uma lista das colunas que quem chama **(caller)** pode escrever. Deixe de fora e o akkar checa se cada chave é um identificador válido, o que impede uma injeção, e então escreve toda coluna que o corpo continha.

Veja o que isso significa quando o corpo contém uma coluna que você não esperava:

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk", is_admin = true }   -- the caller added a field

local careless = sql.insert_into("sqlguide_tasks", body)
print(careless:to_string())
for index, value in ipairs(careless:values()) do print(index, tostring(value)) end
```

```
insert into sqlguide_tasks (is_admin, title) values ($1, $2)
1	true
2	buy milk
```

`is_admin = true`, escrito por quem chamou, dentro da sua tabela. Nenhuma injeção, nenhum crash, nada em um log. O statement está perfeitamente formado e faz exatamente o que o corpo pediu.

Isso tem um nome: **mass assignment** (atribuição em massa). É a segunda forma mais comum de um corpo fazer algo que você não pretendia, depois da injeção, e diferente da injeção, parece correto em uma revisão porque o código é curto e não há concatenação de strings em lugar nenhum.

A lista é o conserto:

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk", is_admin = true }

local ok, why = pcall(function()
  return sql.insert_into("sqlguide_tasks", body, { "title", "done" })
end)
print(ok, why)
```

```
false	akkar.sql: column name 'is_admin' is not in the allowed list (title, done)
```

A mensagem nomeia a coluna que foi recusada e imprime a lista inteira contra a qual foi checada, para que você veja de imediato se quem chamou enviou algo estranho ou se você esqueceu de permitir uma coluna que pretendia.

A checagem acontece em `insert_into`, antes de qualquer statement existir, então a coluna recusada nunca chega a um statement.

Dois hábitos decorrem disso, e são baratos:

**Passe a lista sempre.** Mesmo quando o corpo é validado por um schema, porque o schema é um arquivo separado que alguém vai editar.

**Construa a linha você mesmo em vez de passar o corpo.** A versão mais forte pega os campos que quer pelo nome, de modo que uma chave inesperada não consegue chegar ao builder de jeito nenhum:

```lua no-run
local row = { title = req.body.title, done = req.body.done }
sql.insert_into("tasks", row, { "title", "done" })
```

Então um corpo com `is_admin` nele produz uma linha sem um, e a lista de permissões é sua segunda linha de defesa em vez de ser a única.

## As outras recusas

### Uma chave que não é um identificador

```lua
local sql = require "akkar.sql"

local body = { ["title, is_admin"] = "buy milk" }

local ok, why = pcall(function()
  return sql.insert_into("sqlguide_tasks", body, nil)
end)
print(ok, why)
```

```
false	akkar.sql: column name is not a valid identifier: title, is_admin
```

Essa é a checagem que roda mesmo sem lista de permissões, e é o que torna a chave de um objeto JSON segura para usar como nome de coluna.

### Uma linha vazia

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.insert_into("sqlguide_tasks", {}, { "title" }):build()
end)
print(ok, why)
```

```
false	akkar.sql: insert with no columns
```

Note que esta espera até `build`. Até lá, você ainda pode estar prestes a chamar `:scope`, que adiciona uma coluna própria.

### A tabela, se ela variar

O quarto argumento é a lista de permissões para o nome da tabela:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.insert_into("accounts", { title = "x" }, { "title" }, { "sqlguide_tasks" })
end)
print(ok, why)
```

```
false	akkar.sql: table name 'accounts' is not in the allowed list (sqlguide_tasks)
```

## Uma linha por vez

O builder insere uma linha. Para várias, rode vários inserts dentro de uma única [transação](13-transactions.md), que é o que o endpoint de bulk do guia faz, ou escreva um `insert ... values (...), (...)` de várias linhas como texto.

E `:where` em um insert é silenciosamente descartado, o que a [página 3](03-where.md) mostra. Se sua intenção era "somente se ainda não existir", isso é `on conflict`, e vai em texto que você mesmo escreve.

## Ponto de verificação

Você tem isso se:

- consegue inserir uma linha a partir de um corpo e obter o id de volta em uma única chamada
- consegue explicar mass assignment para alguém em duas frases
- passa `allowed_columns` sem pensar duas vezes
- sabe que `insert with no columns` acontece em `build`, não em `insert_into`

Próxima página: [9. update and set](09-update.md).
