# Paginar uma lista

> **Português (Brasil)** | [Original em inglês](../../recipes/paginate-a-list.md)

Uma página de linhas, mais um cursor que quem chama devolve para pegar a próxima página.

Você vai precisar da tabela `tasks` da [página 5](../guide/05-a-database.md) do guia.

## O arquivo inteiro

```lua
local akkar = require "akkar"
local db    = require "akkar.db"
local sql   = require "akkar.sql"
local v     = akkar.v

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

local app = akkar.new()

app:get("/tasks", {
  query = {
    after = "integer?",
    limit = v.integer { min = 1, max = 100, default = 20 },
  },
}, function(req)
  local size = math.tointeger(req.query.limit)

  -- Uma linha a mais que a página, para a resposta saber se há uma próxima.
  local query = sql.select "id, title, done"
    :from("tasks", { "tasks" })
    :order_by("id", { "id" }, "asc")
    :limit(size + 1)

  if req.query.after then query:where("id > ?", req.query.after) end

  local rows = req.db:many(query)

  local next_after = nil
  if #rows > size then
    rows[size + 1] = nil
    next_after = rows[size].id
  end

  return { tasks = akkar.array(rows), next_after = next_after }
end)

app:run { port = 3000, db = open }
```

## Teste

```sh
lua5.4 app.lua
```

Em um segundo terminal:

```sh
curl "http://127.0.0.1:3000/tasks?limit=2"
```

```
{"tasks":[{"title":"buy milk","id":8,"done":false},{"title":"call the bank","id":9,"done":false}],"next_after":9}
```

Seus ids serão números diferentes. Envie `next_after` de volta como `after` para pegar a página seguinte a essa:

```sh
curl "http://127.0.0.1:3000/tasks?limit=2&after=9"
```

```
{"tasks":[{"title":"read the guide","id":10,"done":false},{"title":"buy a birthday card","id":11,"done":false}],"next_after":11}
```

A última página não tem o campo `next_after` de jeito nenhum. É assim que quem chama sabe que deve parar.

O cursor é o id da última linha da página, então ele precisa ser a coluna pela qual você ordena. Ordenar por qualquer outra coisa exige que essa coluna também esteja no cursor, com um desempate por `id` depois dela, ou linhas com valores iguais acabam sendo puladas ou repetidas.

## Por que cursor e não offset

`offset 10000` faz o Postgres ler e descartar dez mil linhas antes de retornar qualquer coisa, então a página 500 é bem mais lenta que a página 1 e vai ficando mais lenta conforme a tabela cresce. `where id > ?` lê o índice direto até a posição e retorna o mesmo número de linhas independentemente da página, então o custo se mantém constante. Um cursor também sobrevive a escritas: uma linha inserida enquanto alguém está paginando desloca em um todo offset posterior, o que mostra a mesma linha duas vezes ou pula uma, e um cursor nunca faz isso. A troca é que quem chama não consegue pular direto para a página 500 sem percorrer o caminho até lá.
