# 15. O que é uma migração

> **Português (Brasil)** | [Original em inglês](../../sql/15-what-a-migration-is.md)

Ao final desta página você terá executado uma migração a partir de um script que você mesmo escreveu, terá visto as quatro coisas que o executor pode te contar e vai saber o que é permitido dentro de um arquivo de migração e o que não é.

A [página 5 do guia](../guide/05-a-database.md) te deu uma tabela `tasks` por meio de uma migração. Esta página explica o que estava acontecendo por baixo dos panos.

## A ideia, em três frases

Seu banco de dados tem uma forma: tabelas, colunas, índices. Essa forma precisa mudar ao longo do tempo, e precisa mudar do mesmo jeito no seu notebook, no do seu colega, no banco de dados de teste e no servidor.

**Uma migração é uma mudança nessa forma, escrita como SQL, em um arquivo com um número na frente, aplicada uma única vez e registrada.**

O registro é a parte que faz tudo funcionar. Rodar o conjunto inteiro de novo não faz nada, porque tudo nele já está registrado, o que é o que torna seguro rodar em cada início do sistema.

## O executor

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = {
    { name = "001_create_tasks.sql", sql = [[
      create table sqlguide_tasks (
        id serial primary key,
        title text not null,
        done boolean not null default false
      )
    ]] },
  },
})

for _, name in ipairs(runner:apply()) do print("applied " .. name) end
print("second run applied " .. #runner:apply() .. " files")

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
applied 001_create_tasks.sql
second run applied 0 files
```

Dois argumentos para `migrate.new`, e ambos merecem uma frase.

**A conexão.** Não a fábrica. `db.connect` te dá uma função que abre conexões, e o executor precisa de uma conexão de fato aberta, por um motivo que a [página 18](18-the-lock.md) explica. Passar a coisa errada te dá isto:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
}

local ok, why = pcall(function() return migrate.new(open, {}) end)
print(ok, why)
```

```
false	akkar.migrate: this is not a database handle; missing :one. A connection factory is not a connection -- call it first, and hand the runner the connection it returns
```

A verificação acontece em `migrate.new`, não na primeira consulta, então a pilha ainda aponta para a linha que construiu o executor.

**As opções.** `files` é a lista de migrações como dados, o que é o assunto da [página 19](19-migrations-as-data.md). Em um projeto normal você usa `dir = "migrations"` e uma pasta de arquivos `.sql` em vez disso. `table` é o nome do livro-razão, e o padrão é `akkar_migrations`.

> Todo exemplo desta trilha passa `table = "sqlguide_migrations"` para que não toque no livro-razão que o próprio banco de dados do guia usa. Seu projeto deve omitir isso e usar o padrão.

## As quatro coisas que você pode perguntar a ele

### `runner:files()`

Toda migração que ele consegue ver, na ordem em que vai executá-las, tenham sido aplicadas ou não:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = {
    { name = "002_add_note.sql",    sql = "alter table sqlguide_tasks add column note text" },
    { name = "001_create_tasks.sql", sql = "create table sqlguide_tasks (id serial primary key)" },
  },
})

for _, file in ipairs(runner:files()) do
  print(file.id, file.name, file.checksum:sub(1, 12))
end

conn:close()
```

```
1	001_create_tasks.sql	7b1055f5cfaa
2	002_add_note.sql	c4ebffb96b2a
```

Ordenado pelo número na frente, não pela ordem em que você as listou. Cada entrada carrega seu `name`, seu `id`, seu `sql`, e um `checksum` dos bytes exatos, que é o assunto da [página 17](17-the-ledger-and-the-checksum.md).

### `runner:applied()`

O que o livro-razão diz que já rodou. Em um banco de dados que nunca foi migrado é uma lista vazia em vez de um erro, porque "nada foi aplicado" é a resposta verdadeira ali:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "drop table if exists sqlguide_migrations"

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql",
              sql = "create table sqlguide_tasks (id serial primary key)" } },
})

print("before:", #runner:applied())
runner:apply()
print("after: ", #runner:applied())

for _, row in ipairs(runner:applied()) do
  print(row.name, row.checksum:sub(1, 12))
end

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
before:	0
after: 	1
001_create_tasks.sql	7b1055f5cfaa
```

Cada linha tem `name`, `checksum` e `applied_at`. Essa é a consulta que um comando `status` quer.

### `runner:pending()`

O que ainda não rodou, na ordem em que vai rodar. É `files()` menos `applied()`, e é também onde acontece a verificação do checksum.

### `runner:apply()`

Executa tudo que está pendente e retorna os nomes que aplicou, em ordem. Uma lista vazia significa que não havia nada a fazer, o que é o caso comum em todo início do sistema após o primeiro.

## O que pode ir dentro de uma migração

Vários comandos são permitidos. Separe-os com ponto e vírgula:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "drop table if exists sqlguide_migrations"

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql", sql = [[
    create table sqlguide_tasks (
      id serial primary key,
      title text not null,
      done boolean not null default false
    );
    create index sqlguide_tasks_done on sqlguide_tasks (done);
    insert into sqlguide_tasks (title) values ('the first task');
  ]] } },
})

runner:apply()

print("rows: ", conn:one("select count(*) as n from sqlguide_tasks").n)
print("index:", conn:one(
  "select count(*) as n from pg_indexes where indexname = 'sqlguide_tasks_done'").n)

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
rows: 	1
index:	1
```

Mudanças de dados também são permitidas, e essa é a terceira linha acima. Uma migração que preenche uma coluna nova para as linhas que já existem é uma migração comum.

## O que não pode ir dentro de uma

Já existe uma transação aberta ao redor do seu arquivo. O akkar a abre, executa seu SQL, escreve a linha do livro-razão, e faz o commit, tudo junto. Duas consequências decorrem disso, e são muito mais fáceis de entender agora do que de descobrir depois.

### Nada de `begin`, `commit` ou `rollback` no arquivo

A transação não é sua. Escrever `commit` no meio de uma migração encerra a transação do akkar antes da hora, e a linha do livro-razão que deveria ser atômica junto com sua mudança acaba sendo escrita separadamente. A execução ainda relata sucesso, então nada te avisa que a garantia se foi.

Deixe o controle de transação de fora. O akkar cuida disso.

### Nada que o Postgres se recuse a executar dentro de uma transação

O primeiro que as pessoas encontram é `create index concurrently`, que constrói um índice sem travar a tabela para escritas. Ele não pode rodar dentro de uma transação, e por isso não pode ir em uma migração:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "drop table if exists sqlguide_migrations"
conn:exec "drop table if exists sqlguide_tasks"

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = {
    { name = "001_tasks.sql",
      sql = "create table sqlguide_tasks (id serial primary key, title text)" },
    { name = "002_index.sql",
      sql = "create index concurrently sqlguide_tasks_title on sqlguide_tasks (title)" },
  },
})

local ok, why = pcall(function() return runner:apply() end)
print(ok, why)
print("applied so far:", conn:one("select count(*) as n from sqlguide_migrations").n)

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
false	db: ERROR: CREATE INDEX CONCURRENTLY cannot run inside a transaction block
applied so far:	1
```

O akkar escolheu a atomicidade e avisa isso. Não há como ter as duas coisas.

Olhe para a última linha, porém, porque ela é a lição mais importante. A primeira migração foi aplicada e ficou registrada. A segunda falhou, sofreu rollback, e **não** foi registrada. Nada depois dela foi tentado.

Isso é deliberado: um esquema parado em um ponto conhecido é muito melhor do que um esquema no meio de uma mudança que ninguém descreveu. Corrija o arquivo, rode de novo, e ele continua de onde parou.

Se você genuinamente precisa de `concurrently`, execute esse comando manualmente fora do sistema de migrações, ou escreva um `create index` simples e aceite o travamento.

## Checkpoint

Você entendeu isso se:

- você consegue aplicar uma migração a partir de um script e ver a segunda execução não fazer nada
- você sabe por que `migrate.new` precisa de uma conexão e não da fábrica
- você consegue listar o que `files`, `applied`, `pending` e `apply` retornam, cada um
- você sabe por que `begin` e `create index concurrently` estão fora

Próxima página: [16. Nomes, números e ordem](16-names-and-order.md).
