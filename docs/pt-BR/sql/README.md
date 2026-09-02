# SQL e migrações, ensinadas devagar

> **Português (Brasil)** | [Original em inglês](../../sql/README.md)

Este é um tutorial. Ele ensina cada parte de `akkar.sql` e
`akkar.migrate`, uma ideia de cada vez, com o SQL que sai mostrado ao lado do
Lua que o produziu.

Não é a referência. [`docs/pt-BR/reference/sql.md`](../reference/sql.md) e
[`docs/pt-BR/reference/migrate.md`](../reference/migrate.md) listam cada função com
seus argumentos e seu valor de retorno, em ordem alfabética, para quem
já sabe o que está procurando. Esta trilha é para quem ainda
não sabe.

## Antes de começar

Você deveria ter feito a [página 5](../guide/05-a-database.md) e a
[página 6](../guide/06-storing-and-reading.md) do guia para iniciantes. Elas te dão
um container do Postgres, uma tabela `tasks`, e as duas ideias sobre as quais tudo aqui
se constrói: um valor nunca entra no texto de uma instrução, e uma migração é
um arquivo numerado que roda uma única vez.

Esta trilha começa onde aquelas páginas param. Ela não as repete.

Você precisa do mesmo container rodando:

```sh
docker start akkar-pg
```

Todo exemplo em toda página é um arquivo completo. Copie, rode com
`lua5.4 whatever.lua`, e funciona. Os exemplos que precisam de uma tabela criam a
própria, com prefixo `sqlguide_`, e a derrubam de novo no final, para que nada
que você já tenha seja afetado.

## As páginas

### Construindo uma query

1. [O objeto query](01-the-query-object.md), e as três formas de olhar para ele
2. [select e from](02-select-and-from.md)
3. [where, e o ponto de interrogação](03-where.md)
4. [where_in, para uma lista](04-where-in.md)
5. [order_by, limit e offset](05-order-limit-offset.md)
6. [join](06-join.md)
7. [group_by](07-group-by.md)

### Alterando linhas

8. [insert_into](08-insert.md)
9. [update e set](09-update.md)
10. [delete_from](10-delete.md)
11. [Identificadores e listas de permissão](11-identifiers-and-allow-lists.md), a
    página de segurança

### Executando o que você construiu

12. [one, many e exec](12-running-a-query.md)
13. [transaction, e a armadilha nela](13-transactions.md)
14. [scope, para que uma query não atravesse tenants](14-scope.md)

### Migrações

15. [O que é uma migração](15-what-a-migration-is.md)
16. [Nomes, números e ordem](16-names-and-order.md)
17. [O livro-razão e o checksum](17-the-ledger-and-the-checksum.md)
18. [O lock](18-the-lock.md)
19. [Migrações como dado](19-migrations-as-data.md)
20. [Rodando no deploy](20-on-deploy.md)

## A versão curta, se você só ler uma tela

Valores são vinculados (bound). Identificadores são conferidos contra uma lista que você escreveu. Não existe
terceira opção, e não existe atalho de escape:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where("done = ?", false)            -- um valor: vinculado
q:order_by("title", { "id", "title" }) -- um identificador: conferido
q:limit(20)                            -- um valor: vinculado

print(q:to_string())
```

```
select id, title from sqlguide_tasks where done = $1 order by title asc limit $2
```

Tudo o mais nessas páginas é essa frase, em detalhe.
