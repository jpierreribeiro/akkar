# Teste algo que acessa o banco de dados

> **Português (Brasil)** | [Original em inglês](../../recipes/test-with-the-database.md)

Executa suas rotas contra um Postgres de verdade, com as linhas limpas entre um teste e o próximo.

Você precisa do busted, e do banco de dados da [página 5](../guide/05-a-database.md) do guia. A tabela usada aqui é a mesma de [Execute migrações no deploy](run-migrations-on-deploy.md):

```sql
create table notes (
  id      serial primary key,
  body    text not null,
  created timestamptz not null default now()
)
```

## A aplicação

`notes.lua`:

```lua
local akkar = require "akkar"
local db    = require "akkar.db"
local v     = akkar.v

local app = akkar.new()

app:get("/notes", function(req)
  return { notes = akkar.array(req.db:many "select id, body from notes order by id") }
end)

app:post("/notes", { body = { body = v.string { min = 1 } } }, function(req)
  return akkar.created(req.db:one(
    "insert into notes (body) values ($1) returning id, body", req.body.body))
end)

if ... == nil then
  app:run {
    port = 3000,
    db = db.connect {
      host = "127.0.0.1", port = 55432, database = "akkar",
      user = "postgres", password = "akkar",
      statement_timeout = 5,
    },
  }
end

return app
```

## O spec

`spec/notes_spec.lua`. Marcado como `no-run` porque quem executa é o busted, não o `lua5.4`.

```lua no-run
local db  = require "akkar.db"
local app = require "notes"

local SETTINGS = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

describe("the notes API", function()
  -- O cliente de teste usa seu próprio banco de dados, então é o spec que decide
  -- com o que as rotas conversam, e o arquivo sob teste não é editado por causa dos testes.
  local client = app:test { db = db.connect(SETTINGS) }

  -- Uma conexão própria do spec, para preparar as linhas e conferi-las.
  local admin

  setup(function()
    local one_off = {}
    for key, value in pairs(SETTINGS) do one_off[key] = value end
    one_off.pool_size = 0
    admin = db.connect(one_off)()
  end)

  teardown(function() admin:close() end)

  before_each(function() admin:exec "delete from notes" end)

  it("stores what was posted", function()
    local res = client:post("/notes", { body = { body = "buy milk" } })
    assert.equal(201, res.status)

    local row = admin:one "select body from notes order by id"
    assert.equal("buy milk", row.body)
  end)

  it("lists what is already there", function()
    admin:exec("insert into notes (body) values ($1)", "read the guide")

    local res = client:get "/notes"
    assert.equal(200, res.status)
    assert.equal(1, #res.body.notes)
    assert.equal("read the guide", res.body.notes[1].body)
  end)

  it("writes nothing when the body is refused", function()
    local res = client:post("/notes", { body = { body = "" } })
    assert.equal(422, res.status)
    assert.equal(0, admin:one("select count(*)::int as n from notes").n)
  end)
end)
```

## Experimente

```sh
busted spec/notes_spec.lua
```

```
+++
3 successes / 0 failures / 0 errors / 0 pending : 0.15714 seconds
```

## Por que limpar entre os testes em vez de uma única transação ao redor deles

Envolver cada teste em uma transação e desfazê-la depois é o truque de sempre, e ele não funciona aqui: o akkar pega uma conexão do pool por requisição (request) e a devolve depois, então a requisição não fica dentro da transação que seu spec abriu em outra conexão. Apagar as linhas no `before_each` é o que resta, e isso é honesto quanto ao custo, que é um comando por teste. Dê à conexão própria do spec `pool_size = 0` para que seja uma única conexão, e não um segundo pool concorrendo com o do cliente. Se um teste não precisa de banco de dados nenhum, não dê um a ele: `app:test { db = require("akkar.db.memory").factory(function(fake) fake:on("select id, body from notes", { id = 1, body = "buy milk" }) end) }` responde com linhas programadas e levanta erro em qualquer consulta que ninguém previu.
