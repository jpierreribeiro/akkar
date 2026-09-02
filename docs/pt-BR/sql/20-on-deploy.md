# 20. Executando isso no deploy

> **Português (Brasil)** | [Original em inglês](../../sql/20-on-deploy.md)

Ao final desta página você terá um script de migração que pode rodar em todo deploy, saberá onde ele entra na sequência e saberá como escrever uma migração que não quebra a versão do seu app que ainda está em execução.

Esta é a última página da trilha.

## O script

Um arquivo, e ele faz uma coisa só:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

-- Uma conexão própria, e NENHUM statement_timeout nela.
-- O Postgres conta a espera pelo advisory lock contra o statement_timeout,
-- e uma migração longa não é uma query descontrolada.
local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  pool_size = 0,
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

local applied = runner:apply()

print("applied " .. #applied .. " migration(s)")
for _, name in ipairs(applied) do print("  " .. name) end

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
applied 1 migration(s)
  001_create_tasks.sql
```

No seu projeto é o mesmo arquivo, com `dir = "migrations"` no lugar de `files`, sem a linha `table`, e sem o `drop table` no final. Os dois drops estão aqui só para esta página limpar depois de si mesma.

Rode com `lua5.4 migrate.lua`, ou a partir de um binário construído pelo `akkar build` com `./myapp run migrate.lua`.

## Onde isso entra no deploy

**Antes de o código novo começar a atender requisições (request), e depois de o código novo existir.**

A ordem que funciona:

1. Construir a nova versão.
2. Rodar as migrações, usando os arquivos de migração da nova versão.
3. Iniciar a nova versão.
4. Parar a versão antiga.

O passo 2 precisa acontecer com os arquivos novos, porque são eles que descrevem o schema que o código novo espera. E precisa terminar antes do passo 3, porque senão o código novo vai falhar na primeira requisição.

O `docs/DEPLOY.md` tem o detalhe no nível de container, incluindo o ponto prático importante de que uma imagem `scratch` não tem shell, então não consegue ler um diretório de migrações. Esse é o assunto da [página 19](19-migrations-as-data.md) e o motivo de `files` existir.

### Rodar em toda instância não tem problema

Você não precisa se organizar para que exatamente uma instância rode as migrações. Deixe todas rodarem. [O lock](18-the-lock.md) torna isso seguro: uma entra, as outras esperam, e depois não encontram nada para fazer.

Vale a pena escolher isso deliberadamente, porque a alternativa, um passo especial de migração que roda uma única vez em algum lugar, é uma peça de maquinário de implantação que pode ser esquecida, pulada, ou executada contra o banco de dados errado.

## Uma falha interrompe o deploy, porque ela sai com código diferente de zero

Um erro vindo de `apply` não é capturado por nada, então o script gera uma exceção e o Lua sai com status `1`. Toda ferramenta de deploy do mundo sabe o que isso significa.

Aqui está uma falha real, com um erro de digitação na segunda migração (`add colum` em vez de `add column`):

```lua no-run
local runner = migrate.new(conn, {
  files = {
    { name = "001_create_tasks.sql",
      sql = "create table sqlguide_tasks (id serial primary key)" },
    { name = "002_typo.sql",
      sql = "alter table sqlguide_tasks add colum note text" },
  },
})

local applied = runner:apply()
print("applied " .. #applied .. " migration(s)")
```

```
lua5.4: db: ERROR: syntax error at or near "text" (43)
stack traceback:
	[C]: in function 'error'
	./akkar/migrate.lua:568: in method 'apply'
	migrate.lua:26: in main chunk
	[C]: in ?
exit=1
```

O `print` nunca rodou. E o registro (ledger), depois disso, tinha exatamente uma linha nele, `001_create_tasks.sql`, então o banco de dados parou em um ponto que está registrado. Corrija o erro de digitação, faça o deploy de novo, e `002` roda.

**Não envolva `apply` em `pcall` para manter o deploy seguindo.** Um serviço que inicia contra um schema que ele não tem vai falhar em requisições reais em vez disso, o que é a mesma interrupção (outage) com a causa removida de vista.

## Verificando sem aplicar

Às vezes você quer saber antes de apertar o botão. `pending()` te conta isso, e não toca em nada:

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
  files = {
    { name = "001_create_tasks.sql",
      sql = "create table sqlguide_tasks (id serial primary key)" },
    { name = "002_add_note.sql",
      sql = "alter table sqlguide_tasks add column note text" },
  },
})

print("applied: " .. #runner:applied())
for _, file in ipairs(runner:pending()) do print("pending: " .. file.name) end

runner:apply()

print("after, applied: " .. #runner:applied())
print("after, pending: " .. #runner:pending())

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
applied: 0
pending: 001_create_tasks.sql
pending: 002_add_note.sql
after, applied: 2
after, pending: 0
```

Isso é um comando `status`. É também a verificação a ser rodada no CI em um pull request: se `pending()` gerar uma exceção ali, alguém editou uma migração já aplicada, e é muito melhor descobrir isso nessa hora.

## Escreva migrações que não quebram a versão em execução

Esta é a parte que pega quem fez tudo certo até aqui.

Durante um deploy gradual (rolling deploy), a versão antiga e a versão nova estão rodando **ao mesmo tempo**, contra o banco de dados que você acabou de migrar. Então uma migração não pode quebrar o código antigo, nem mesmo pelos trinta segundos antes de ele sumir.

A regra: **uma migração pode adicionar, e não pode tirar, até que nada use a coisa que está sendo tirada.**

Uma renomeação é o exemplo mais claro. Não renomeie uma coluna em uma única migração. Em vez disso:

1. **Adicione** a coluna nova. Faça o deploy de código que escreve nas duas e lê da antiga.
2. Faça o backfill da coluna nova a partir da antiga, em uma migração.
3. Faça o deploy de código que lê da nova.
4. **Depois** remova a coluna antiga, em uma migração posterior, uma vez que nada mais a lê.

Quatro deploys em vez de um, e nenhum deles tem um momento em que o código em execução e o banco de dados discordam.

O mesmo formato se aplica aos outros:

| mudança | segura agora | precisa de um passo posterior |
|---|---|---|
| adicionar uma coluna anulável (nullable) | sim | não |
| adicionar uma coluna com valor padrão (default) | sim | não |
| adicionar um índice | sim, embora trave escritas enquanto constrói | não |
| adicionar uma restrição `not null` | só se toda linha já tiver um valor | fazer backfill antes |
| renomear uma coluna | não | adicionar, backfill, trocar, remover |
| remover uma coluna | não | parar de usar, fazer deploy, depois remover |
| mudar o tipo de uma coluna | não | coluna nova, backfill, trocar, remover |

Se você pode se dar ao luxo de ter downtime, aceite ele e ignore tudo isso. É muito mais simples. Só faça isso de propósito, e não por acidente.

## Só para frente

Não existe uma down migration no akkar e nunca vai existir, o que a [página 15](15-what-a-migration-is.md) e o próprio código-fonte do módulo argumentam em detalhe. Vale deixar clara aqui a consequência disso para o seu deploy:

**Seu plano de rollback não pode ser "rodar a down migration".** Ele tem que ser ou "o schema novo ainda funciona com o código antigo", o que a regra de expandir-e-contrair acima te garante, ou "restaurar de um backup", que você deveria ter testado.

Uma migração que estava errada é corrigida por outra migração que diz o que deveria ter sido dito.

## Checkpoint

Você tem isso se:

- você tem um script de migração que sai com código diferente de zero quando algo falha
- você sabe que ele roda antes de a versão nova atender requisições, e que rodá-lo em toda instância não tem problema
- você consegue dizer por que não se usa `pcall` ao redor de `apply`
- você consegue descrever os quatro passos de renomear uma coluna sem downtime

## O fim da trilha

Agora você conhece todo método em `akkar.sql` e toda opção em `akkar.migrate`.

Para onde ir agora:

- [A referência de `akkar.sql`](../reference/sql.md) e [de `akkar.migrate`](../reference/migrate.md), para consultar quando precisar
- [`docs/DEPLOY.md`](../../DEPLOY.md), para o detalhe no nível de container
- [As receitas](../recipes/README.md), para tarefas completas construídas a partir dessas peças
- O código-fonte, `akkar/sql.lua` e `akkar/migrate.lua`, que é curto e explica suas próprias decisões em detalhe
