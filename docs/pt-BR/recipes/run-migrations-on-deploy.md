# Rodando migrations no deploy

> **Português (Brasil)** | [Original em inglês](../../recipes/run-migrations-on-deploy.md)

Um programa que atualiza o banco de dados e encerra, seguro para ser executado a partir de todas as instâncias de um deploy ao mesmo tempo.

## O arquivo completo

Salve como `migrate.lua`, ao lado do seu `app.lua`.

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"
local logging = require "akkar.log"

local log = logging.new()

-- As migrations viajam dentro do programa, não ao lado dele. Um artefato de
-- deploy sem shell e sem arquivos ainda tem isso aqui.
local MIGRATIONS = {
  { name = "20260816090000_create_notes.sql", sql = [[
    create table notes (
      id      serial primary key,
      body    text not null,
      created timestamptz not null default now()
    ) ]] },
}

-- pool_size = 0 abre uma conexão só, sem pool. Este programa faz uma
-- conexão, usa, e termina.
local connection = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  pool_size = 0,
}()

local ok, why = pcall(function()
  local runner = migrate.new(connection, { files = MIGRATIONS })
  local applied = runner:apply()
  log:info("migrations applied", { count = #applied })
  for _, name in ipairs(applied) do log:info("migrated", { file = name }) end
end)

connection:close()

if not ok then
  log:error("migrations failed", { detail = tostring(why) })
  os.exit(1)
end
```

Execute-o antes do servidor, e deixe o código de saída interromper o deploy:

```sh
lua5.4 migrate.lua && lua5.4 app.lua
```

## Testando

```sh
lua5.4 migrate.lua
```

```
INFO  migrations applied count=1
INFO  migrated file=20260816090000_create_notes.sql
```

De novo:

```
INFO  migrations applied count=0
```

Nada aconteceu na segunda vez, e nada vai acontecer na centésima. O akkar mantém uma tabela chamada `akkar_migrations` listando o que já foi executado, identificado pelo nome e por um checksum do SQL, de forma que uma edição em uma migration que já foi aplicada é recusada em vez de ser silenciosamente ignorada.

## Por que é um programa separado e não faz parte de `app:run`

Rodar migrations dentro do servidor significa que todo processo de um deploy migra, e o schema muda enquanto a versão anterior ainda está atendendo requisições (requests) contra ele. Como um programa separado, o deploy pode ordenar os dois: migrar uma vez, depois iniciar. Executá-lo a partir de várias máquinas ao mesmo tempo continua sendo seguro, porque `runner:apply()` primeiro obtém um advisory lock do Postgres, e o segundo executor espera em vez de disputar a corrida. Migrations são só para frente, de propósito: uma migration de reversão é código que precisa estar certo no pior dia do lançamento e quase nunca é testado, então o caminho de volta é uma nova migration para frente. Durante o desenvolvimento você pode mantê-las como arquivos com `migrate.new(connection, { dir = "migrations" })` em vez de embuti-las, como mostra a [página 5](../guide/05-a-database.md) do guia.
