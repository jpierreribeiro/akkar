# akkar.migrate

> **Português (Brasil)** | [Original em inglês](../../reference/migrate.md)

Executa arquivos SQL simples uma única vez cada, em ordem numérica, dentro de uma transação, sob um lock consultivo (advisory lock) do Postgres, e registra cada um em uma tabela de controle (ledger).

**Quando você precisa disso.** Na inicialização, antes de o servidor começar a escutar, para que um banco de dados novo receba seu esquema e um já existente receba o que houver de novo. Também em um deploy incremental (rolling deploy), onde várias instâncias sobem ao mesmo tempo e só uma delas pode aplicar alguma coisa.

```lua no-run
local migrate = require "akkar.migrate"
```

## Índice

Todo símbolo público desta página, em ordem alfabética. `runner` é o que `migrate.new` retorna.

| símbolo | tipo |
|---|---|
| [`migrate.checksum_of`](#migratechecksum_ofbytes) | função |
| [`migrate.LOCK_KEY`](#migratelock_key) | valor |
| [`migrate.Migrate`](#migratemigrate) | tabela |
| [`migrate.new`](#migratenewdb-options) | função |
| [`runner:applied`](#runnerapplied) | método |
| [`runner:apply`](#runnerapply) | método |
| [`runner:files`](#runnerfiles) | método |
| [`runner:pending`](#runnerpending) | método |

Também nesta página:
[O que um arquivo de migração pode conter](#o-que-um-arquivo-de-migração-pode-conter),
[O que a conexão precisa ser](#o-que-a-conexão-precisa-ser) e
[O que não está aqui](#o-que-não-está-aqui).

## migrate.checksum_of(bytes)

O SHA-256 de uma string, em hexadecimal minúsculo. É isso que vai na coluna `checksum` do ledger e é isso que uma execução posterior compara.

**Retorna** uma string de 64 caracteres.

```lua
local migrate = require "akkar.migrate"

print(migrate.checksum_of "create table ref_migrate_users (id int)")
```

## migrate.LOCK_KEY

O bigint passado para `pg_advisory_lock`. É `0x616b6b6172`, o ASCII de `akkar`, e é fixo: uma única chave significa no máximo uma execução de migração por banco de dados por vez.

O Postgres não atribui nenhum significado a ela. Ela é reconhecível para que `select * from pg_locks where locktype = 'advisory'` às três da manhã diga de quem é o lock.

```lua
local migrate = require "akkar.migrate"

print(migrate.LOCK_KEY)
print(string.format("%x", migrate.LOCK_KEY))
```

## migrate.Migrate

A metatable do [Runner](#runner), exportada para os testes. Mais nada precisa dela.

```lua no-run
local migrate = require "akkar.migrate"
local is_runner = getmetatable(runner) == migrate.Migrate
```

## migrate.new(db, options)

Envolve uma conexão em um runner. Nada é executado ainda e nada é lido do banco de dados.

`db` é verificado aqui em vez de na primeira query, para que um handle incapaz de cumprir o contrato falhe enquanto a pilha (stack) ainda indica quem o construiu.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `dir` | string | `"migrations"` | diretório de arquivos `.sql`, lido em um nível de profundidade |
| `files` | lista | nenhum | migrações como dados: `{ { name = ..., sql = ... }, ... }`. Não combine com `dir` |
| `table` | string | `"akkar_migrations"` | a tabela de controle (ledger) |
| `lock_timeout` | número | `30` | segundos para aguardar o lock consultivo |

`files` existe para um deploy que não consegue listar um diretório. O binário produzido por `akkar build` roda em um container efêmero sem shell, e `io.popen "find ..."` precisa de um.

**Retorna** um [Runner](#runner).

**Levanta exceção (Raises)**

- `akkar.migrate: expected a database handle, got <type>`
- `akkar.migrate: this is not a database handle; missing :<method>. A connection factory is not a connection -- call it first, and hand the runner the connection it returns`
- `akkar.migrate: '<name>' is not a usable table name; it goes into SQL as an identifier ...` para um nome de ledger que não seja letras, dígitos e sublinhados, ou que tenha mais de 63 caracteres
- `akkar.migrate: pass `dir` or `files`, not both -- two sources of migrations is two answers to what has been applied`
- `akkar.migrate: `files` must be a list of { name, sql }, got <type>`
- `akkar.migrate: files[N] must be { name = string, sql = string }`

```lua
local memory  = require "akkar.db.memory"
local migrate = require "akkar.migrate"

local runner = migrate.new(memory.new(), {
  table = "ref_migrate_ledger",
  files = {
    { name = "001_create_users.sql", sql = "create table ref_migrate_users (id int)" },
  },
})
print(getmetatable(runner) == migrate.Migrate)

local ok, why = pcall(migrate.new, memory.new(), { table = "drop table x" })
print(ok, why)
```

## Runner

O que `new` retorna. Quatro métodos. Só `apply` escreve alguma coisa.

### runner:apply()

Aplica tudo que está pendente e retorna os nomes que aplicou, em ordem. Vazio em toda inicialização após a primeira, que é o caso comum.

A sequência, nesta ordem, e a ordem é o ponto principal:

1. `set lock_timeout = <lock_timeout * 1000>`
2. `select pg_advisory_lock(LOCK_KEY)`, que bloqueia até que o lock seja nosso
3. `set lock_timeout = 0`, para que uma migração longa não fique presa à paciência do deploy
4. `create table if not exists <ledger>`
5. calcula a lista de pendentes, **agora**, com o lock em mãos
6. por arquivo: `begin`, o SQL do arquivo, a linha do ledger, `commit`
7. `select pg_advisory_unlock(LOCK_KEY)`, tanto no caminho de sucesso quanto no de falha

A lista de pendentes é calculada depois do lock, nunca antes. Uma lista calculada primeiro e aplicada depois é exatamente a condição de corrida (race) que o lock existe para fechar.

A linha do ledger é escrita na mesma transação que a migração, de modo que uma falha (crash) deixa o banco de dados alterado e registrado, ou nenhum dos dois.

O lock é de nível de sessão, não de nível de transação, porque cada migração faz commit por conta própria e um lock com escopo de transação seria liberado no primeiro `commit`.

**Retorna** uma lista de nomes de arquivo.

**Levanta exceção (Raises)**

- `akkar.migrate: another runner has held the migration lock for more than N seconds. ...` quando `lock_timeout` se esgota
- o que quer que a primeira migração que falhar tenha levantado. Essa é revertida (rollback) e não é registrada, e as seguintes não são tentadas
- o que quer que [`pending`](#runnerpending) levante, incluindo o erro de checksum alterado
- `akkar.migrate: the migrations applied but the advisory lock could not be released: <why>. The lock is session scoped, so closing this connection clears it`

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  table = "ref_migrate_ledger",
  files = {
    { name = "001_create_users.sql", sql = [[
      create table ref_migrate_users (
        id    serial primary key,
        email text not null unique
      )
    ]] },
    { name = "002_add_name.sql",
      sql = "alter table ref_migrate_users add column name text" },
  },
})

for _, name in ipairs(runner:apply()) do print("applied " .. name) end
print("second run applied " .. #runner:apply())

conn:exec "drop table ref_migrate_users"
conn:exec "drop table ref_migrate_ledger"
conn:close()
```

### runner:applied()

O que o ledger diz que já foi executado, ordenado por nome.

Cada linha é `{ name, checksum, applied_at }`. Note que a ordenação é por nome, que é ordem de string, diferente de [`files`](#runnerfiles) e [`pending`](#runnerpending), que seguem a ordem numérica do id.

Em um banco de dados que nunca foi migrado, o método responde com uma lista vazia em vez de um erro sobre tabela ausente: "nada foi aplicado" é a resposta verdadeira nesse caso, e é a que um comando de status precisa.

**Retorna** uma lista de linhas.

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  table = "ref_migrate_ledger",
  files = { { name = "001_create_users.sql",
              sql = "create table ref_migrate_users (id int)" } },
})

print("before", #runner:applied())
runner:apply()
for _, row in ipairs(runner:applied()) do
  print(row.name, row.checksum:sub(1, 12), row.applied_at ~= nil)
end

conn:exec "drop table ref_migrate_users"
conn:exec "drop table ref_migrate_ledger"
conn:close()
```

### runner:files()

Toda migração, na ordem em que será aplicada. Lê o diretório, ou a lista `files`, e calcula o hash de cada uma. Não toca no banco de dados.

Cada entrada é `{ id, name, path, sql, checksum }`. `path` é `nil` quando as migrações vieram de `files`.

O id são os dígitos no início do nome, até o primeiro `_` ou `-`, lidos como número. A ordenação é por esse número, então `10_x.sql` roda depois de `9_x.sql`.

**Retorna** uma lista de entradas.

**Levanta exceção (Raises)**

- `akkar.migrate: these files have no leading id, so there is no order to run them in: <names>` com a sugestão de nomeá-los como `20260816120000_add_users.sql`
- `akkar.migrate: two migrations share an id, so which runs first is up to the filesystem: 7 (007_a.sql and 007_b.sql)`
- `akkar.migrate: cannot read the migration directory '<dir>' -- it does not exist, or is not readable from the working directory`, com um segundo parágrafo sobre containers efêmeros quando não há shell
- `akkar.migrate: could not list <dir>: <why>` quando o próprio `io.popen` falha
- `akkar.migrate: cannot read <path>: <why>`

```lua
local memory  = require "akkar.db.memory"
local migrate = require "akkar.migrate"

local runner = migrate.new(memory.new(), {
  files = {
    { name = "10_add_index.sql", sql = "create index on ref_migrate_users (email)" },
    { name = "9_add_email.sql",  sql = "alter table ref_migrate_users add column email text" },
  },
})

for _, file in ipairs(runner:files()) do
  print(file.id, file.name, file.checksum:sub(1, 8), tostring(file.path))
end

local unnumbered = migrate.new(memory.new(), {
  files = { { name = "create_users.sql", sql = "select 1" } },
})
local ok, why = pcall(function() return unnumbered:files() end)
print(ok, (why:gsub("\n.*", "")))
```

### runner:pending()

O que ainda não foi executado, na ordem em que será executado. Uma leitura, então é seguro chamar a partir de um comando de status.

Um arquivo já presente no ledger cujos bytes sejam diferentes hoje faz o método levantar uma exceção. Isso é um erro, e não um aviso, porque um aviso rola pela tela durante um deploy e a frase "o esquema é o que as migrações dizem" acabou de se tornar falsa.

Duas consequências de comparar bytes exatos, ditas em vez de descobertas:

- um checkout que reescreve as terminações de linha muda todos os checksums, e todo arquivo passa a ser lido como editado. Mantenha as terminações de linha da árvore de trabalho estáveis; não há flag aqui para isso
- um arquivo que foi aplicado e desde então foi apagado do disco **não** é um erro. Compactar migrações antigas depois que já estão em todo lugar é normal

**Retorna** uma lista de entradas, no mesmo formato que [`files`](#runnerfiles) retorna.

**Levanta exceção (Raises)** `akkar.migrate: '<name>' has changed since it was applied (ledger
<hash>, file <hash>) -- the database no longer matches the files. Restore the
file, or write a new migration for whatever the edit was trying to say`, mais tudo o que `files` levanta.

Diferente de todo outro erro neste módulo, esse é levantado com um nível (level) em vez de 0, então uma posição de origem é anexada a ele. Quando chamado a partir de [`apply`](#runnerapply), a posição é uma linha dentro de `akkar/migrate.lua`, não uma linha do seu código.

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local files = { { name = "001_create_users.sql",
                  sql = "create table ref_migrate_users (id int)" } }
local runner = migrate.new(conn, { table = "ref_migrate_ledger", files = files })

print("pending before", #runner:pending())
runner:apply()
print("pending after", #runner:pending())

local edited = migrate.new(conn, {
  table = "ref_migrate_ledger",
  files = { { name = "001_create_users.sql",
              sql = "create table ref_migrate_users (id bigint)" } },
})
local ok, why = pcall(function() return edited:pending() end)
print(ok, why)

conn:exec "drop table ref_migrate_users"
conn:exec "drop table ref_migrate_ledger"
conn:close()
```

## O que um arquivo de migração pode conter

Uma ou mais instruções, e nada que entre em conflito com a transação que as envolve.

- Nenhum `begin`, `commit` ou `rollback`. Já existe uma transação aberta.
- Nada que o Postgres recuse a executar dentro de uma transação. `create index concurrently` é o primeiro que as pessoas encontram, e não há como ter tanto ele quanto a atomicidade acima. Este módulo escolhe a atomicidade.

Nomenclatura: dígitos, depois `_` ou `-`, depois qualquer coisa. `001_create_users.sql`, `20260816120000_add_users.sql`. Um nome sem dígitos no início é recusado, e dois nomes com o mesmo número são recusados.

Um timestamp vence um contador assim que duas pessoas passam a escrever migrações, porque duas pessoas ramificando (branching) do mesmo commit escolheriam ambas `007`, e dois timestamps não colidem.

```lua no-run
-- migrations/20260816120000_add_users.sql
--
-- create table users (
--   id    serial primary key,
--   email text not null unique
-- );
```

## O que a conexão precisa ser

Uma conexão que este runner mantém durante toda a execução. O lock consultivo vive na sessão, então um handle que volta para um pool no meio do caminho leva o lock junto. `db.connect { pool_size = 0 }` fornece uma conexão que não é de mais ninguém.

**Nenhum `statement_timeout` nela.** O Postgres conta a espera por um lock consultivo dentro do `statement_timeout`, então uma conexão configurada com um timeout do tamanho de uma requisição (request) cancela a espera, e cancela uma migração longa também. `lock_timeout` é o parâmetro correto para isso, e este módulo o define por conta própria.

```lua no-run
local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  pool_size = 0,                 -- uma conexão só nossa
                                 -- e propositalmente sem statement_timeout
}
local runner = migrate.new(open(), { dir = "migrations" })
```

## O que não está aqui

Não há migrações de reversão (down migrations) e não haverá. Uma migração de reversão é escrita contra um esquema e executada contra dados, e `alter table drop column` reverte de forma limpa em uma tabela vazia e destrói uma coluna de dados reais em uma tabela cheia. Se uma migração estava errada, o conserto é outra migração.

Não há `runner:rollback`, `runner:reset` nem `runner:redo`, pelo mesmo motivo.

Não há `runner:create` que escreva um novo arquivo. Nomear é a única decisão que este módulo se recusa a tomar por você.

Não há recursão de diretório. `find -maxdepth 1`, então um diretório de backup, um `.sql~` de editor ou uma subpasta `archive/` não são pegos. Aplicar um arquivo de arquivo morto (archive) é uma falha pior do que não encontrá-lo.

## Veja também
- [akkar.db](db.md) abre a conexão sobre a qual isto roda
- [akkar.sql](sql.md) é para instruções que um handler constrói, não para migrações
- o código-fonte do módulo, `akkar/migrate.lua`, para o raciocínio por trás de somente avançar (up-only) e de uma espera de lock limitada
