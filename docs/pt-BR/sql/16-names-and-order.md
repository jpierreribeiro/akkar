# 16. Nomes, números e ordem

> **Português (Brasil)** | [Original em inglês](../../sql/16-names-and-order.md)

Ao final desta página você vai saber exatamente como o akkar decide qual migração roda primeiro, por que o número na frente não é opcional e por que um timestamp é um número melhor do que um contador.

## O nome é dado

O akkar lê duas coisas do nome de uma migração: o número no início, que decide a ordem, e o resto, que é para você.

O número é os dígitos bem no começo, seguidos de um underscore ou um hífen:

| nome | id | funciona? |
|---|---|---|
| `001_create_tasks.sql` | 1 | sim |
| `2_add_note.sql` | 2 | sim |
| `20260816120000_add_users.sql` | 20260816120000 | sim |
| `3-three.sql` | 3 | sim, um hífen também serve |
| `create_tasks.sql` | nenhum | recusado |
| `003create.sql` | nenhum | recusado, não há separador |

## O número é lido como número

Isso importa mais do que parece, e é o motivo de o akkar interpretar os dígitos em vez de ordenar os nomes como texto.

Ordene `2_users.sql`, `9_add_index.sql` e `10_add_column.sql` como texto e você obtém **10, 2, 9**, porque o caractere `"1"` vem antes de `"2"`. A décima migração rodaria primeiro.

O akkar lê os dígitos e compara os números:

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
    { name = "10_add_column.sql", sql = "select 1" },
    { name = "9_add_index.sql",   sql = "select 1" },
    { name = "2_users.sql",       sql = "select 1" },
  },
})

for _, file in ipairs(runner:files()) do print(file.id, file.name) end

conn:close()
```

```
2	2_users.sql
9	9_add_index.sql
10	10_add_column.sql
```

Dois, nove, dez, que é o que qualquer pessoa esperaria e que a ordenação de texto puro não entrega.

Isso foi um defeito real no akkar, encontrado ao compará-lo com outro executor de migrações. Vale conhecer mesmo já estando corrigido, por causa do formato do problema: tudo funciona até a décima migração, que aparece semanas depois de qualquer um pensar em checar, e nessa altura o sintoma parece uma migração quebrada, não uma ordenação quebrada.

## Um nome sem número é recusado

O akkar não vai adivinhar onde um arquivo sem número entra:

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
  files = { { name = "create_tasks.sql", sql = "select 1" } },
})

local ok, why = pcall(function() return runner:files() end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: these files have no leading id, so there is no order to run them in: create_tasks.sql
  name them like `20260816120000_add_users.sql` -- a timestamp rather than a counter, because two people branching from the same commit both pick 007 and two timestamps cannot collide
```

Recorrer à ordem de texto para o arquivo estranho significaria que a regra de ordenação muda dependendo do que está no diretório, o que é pior do que qualquer uma das duas regras isoladamente.

## Dois arquivos com o mesmo número são recusados

Este é o caso que morde equipes, e é o motivo do conselho naquela mensagem de erro:

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
    { name = "007_add_email.sql", sql = "select 1" },
    { name = "007_add_phone.sql", sql = "select 1" },
  },
})

local ok, why = pcall(function() return runner:files() end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: two migrations share an id, so which runs first is up to the filesystem: 7 (007_add_email.sql and 007_add_phone.sql)
  this is what happens when two branches both pick the next counter; renaming one to a timestamp fixes it for good
```

Veja como isso acontece, e repare que ninguém faz nada errado.

Você e um colega começam a trabalhar na segunda-feira. A última migração na `main` é `006`. Você escreve `007_add_email.sql`. O colega escreve `007_add_phone.sql`. Os dois branches passam nos testes, porque cada um tem apenas um `007`. Os dois são mesclados. Agora o diretório tem dois, e qual roda primeiro é decidido por qualquer ordem que o sistema de arquivos entregar.

O akkar recusa em vez de escolher. Uma recusa no boot com os dois nomes é um renomear de cinco minutos. Duas migrações aplicadas em uma ordem que ninguém testou é uma tarde inteira.

## Então use um timestamp, não um contador

**Duas pessoas não conseguem escolher o mesmo timestamp.** Esse é o argumento inteiro, e é por isso que toda mensagem de erro aqui sugere um.

Pegue um no shell na hora de criar o arquivo:

```sh
date +%Y%m%d%H%M%S
```

```
20260816115920
```

Então uma migração fica `20260816115920_add_email.sql`. Ela ordena corretamente como número, é única sem nenhuma coordenação, e diz quando foi escrita, o que é útil quando você está lendo um diretório com quarenta delas.

Contadores funcionam bem sozinho. As próprias páginas deste guia usam `001`, `002`, `003`, porque há só uma pessoa. No momento em que há duas pessoas, troque, e você não precisa renomear as antigas: `001` é um número menor que `20260816115920`, então as antigas simplesmente continuam ordenando primeiro.

## Uma migração que chega fora de ordem ainda roda

Este é o último caso, e vale ver porque o akkar não o recusa.

Você aplica `20260816120000`. Depois o branch de um colega é mesclado, trazendo `20260815090000`, que é **mais antigo**. Ele não foi aplicado aqui, então está pendente, então roda agora, depois do mais novo:

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

local newer = { name = "20260816120000_create_tasks.sql",
                sql = "create table sqlguide_tasks (id serial primary key)" }
local older = { name = "20260815090000_add_note.sql",
                sql = "alter table sqlguide_tasks add column note text" }

local first = migrate.new(conn, { table = "sqlguide_migrations", files = { newer } })
print("run one:", table.concat(first:apply(), ", "))

local both = migrate.new(conn, { table = "sqlguide_migrations",
                                 files = { newer, older } })
print("run two:", table.concat(both:apply(), ", "))

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
run one:	20260816120000_create_tasks.sql
run two:	20260815090000_add_note.sql
```

O arquivo mais antigo rodou por último. É isso que todo executor de migrações faz, e é a menos surpreendente das opções ruins, mas fique claro sobre o que isso significa: a ordem em que esses dois rodaram neste banco de dados não é a ordem em que vão rodar em um banco novo. Em um laptop novo, `20260815090000` roda primeiro, e se ele depende de algo que `20260816120000` criou, falha ali e funcionou aqui.

O hábito que evita isso: **antes de mesclar, faça rebase e renomeie sua migração para que ela seja a mais nova.** Isso é renomear um arquivo que ninguém aplicou ainda, o que é de graça.

## Checkpoint

Você tem isso se:

- consegue dizer o que o akkar lê do nome de uma migração
- sabe por que `10_` ordenar antes de `9_` foi um bug real e não é mais
- conhece as duas recusas, e que ambas são sobre ordenação
- usaria `date +%Y%m%d%H%M%S` para um nome em uma equipe

Próxima página: [17. O livro-razão e o checksum](17-the-ledger-and-the-checksum.md).
