# Teste uma rota

> **Português (Brasil)** | [Original em inglês](../../recipes/test-a-route.md)

Envia requisições (request) através de toda a sua aplicação, incluindo validação e
middleware, sem abrir um socket ou vincular uma porta.

Você precisa do busted:

```sh
luarocks install --local busted
```

## A aplicação

`app.lua`, que inicia um servidor quando você o executa e devolve a
aplicação quando um spec a solicita:

```lua
local akkar = require "akkar"
local v     = akkar.v

local app = akkar.new()

local tasks = { { id = 1, title = "buy milk", done = false } }

app:get("/tasks", function()
  return { tasks = akkar.array(tasks) }
end)

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  for _, task in ipairs(tasks) do
    if task.id == req.params.id then return task end
  end
  return akkar.not_found "no task with that id"
end)

app:post("/tasks", { body = { title = v.string { min = 1 } } }, function(req)
  local task = { id = #tasks + 1, title = req.body.title, done = false }
  tasks[#tasks + 1] = task
  return akkar.created(task)
end)

-- Só inicia um servidor quando este arquivo é executado diretamente. Quando um spec o
-- requisita, ele devolve a aplicação em vez disso.
if ... == nil then app:run { port = 3000 } end

return app
```

## O spec

`spec/tasks_spec.lua`. Este bloco está marcado como `no-run` porque quem executa é o busted,
não o `lua5.4`: `describe`, `it` e `assert.equal` vêm do busted.

```lua no-run
local app = require "app"

describe("the tasks API", function()
  -- Sem socket, sem porta, sem servidor. O cliente de teste percorre a mesma cadeia que uma
  -- requisição real percorre.
  local client = app:test()

  it("lists the tasks", function()
    local res = client:get "/tasks"
    assert.equal(200, res.status)
    assert.equal("buy milk", res.body.tasks[1].title)
  end)

  it("answers 404 for an id that is not there", function()
    local res = client:get "/tasks/999"
    assert.equal(404, res.status)
    assert.equal("no task with that id", res.body.error)
  end)

  it("refuses a task with no title", function()
    local res = client:post("/tasks", { body = {} })
    assert.equal(422, res.status)
    assert.equal("required", res.body.fields["body.title"])
  end)

  it("creates one", function()
    local res = client:post("/tasks", { body = { title = "walk the dog" } })
    assert.equal(201, res.status)
    assert.equal("walk the dog", res.body.title)
    assert.is_number(res.body.id)
  end)
end)
```

## Experimente

A partir do diretório que contém `app.lua`:

```sh
busted spec/tasks_spec.lua
```

```
++++
4 successes / 0 failures / 0 errors / 0 pending : 0.149255 seconds
```

`app:test()` fornece um cliente com `get`, `post`, `put`, `patch`, `delete`,
`head` e `options`. Cada um recebe um caminho e uma tabela de opções com `body`,
`headers` e `timeout`, e devolve `{ status, body, raw, headers }`. O
corpo já vem decodificado, então `res.body.tasks[1].title` funciona sem que seja necessário fazer parsing de
nada.

## Por que em processo e não via HTTP

O cliente de teste chama a mesma função que o servidor chama, então validação,
middleware, schemas de resposta (response) e tratamento de erros são todos executados exatamente como em
produção, e nada fica sem testar além do socket. O que você ganha com
isso é velocidade e determinismo: nenhuma porta ocupada, nenhum servidor para iniciar e
parar, nenhuma espera antes da primeira requisição, e quatro casos em um sétimo de
segundo. Uma coisa não sobrevive à viagem: o content type é escrito no
fio, não na resposta, então `res.headers["content-type"]` é nil em um
teste mesmo que um cliente real o veria. Faça a asserção em `res.raw` para um
corpo que não seja JSON. Para apontar as mesmas rotas para um banco de dados, veja
[Teste algo que acessa o banco de dados](test-with-the-database.md).
