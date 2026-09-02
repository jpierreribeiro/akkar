# 11. Identificadores e listas de permissão

> **Português (Brasil)** | [Original em inglês](../../sql/11-identifiers-and-allow-lists.md)

Ao final desta página você vai entender por que metade do `akkar.sql` recebe um argumento extra de lista, o que essa lista protege e o que acontece no dia em que você a deixa de fora.

Esta é a página mais importante desta trilha. Tudo o mais é um método. Esta é a ideia.

## Duas coisas diferentes entram em um comando

Um **valor** é dado: um título, um id, um booleano, uma data. Valores viajam ao lado do comando, vinculados como `$1`, `$2`. Podem ser qualquer coisa, inclusive uma string de ataque, porque não há como eles se tornarem parte do comando.

Um **identificador** é um nome no banco de dados: uma tabela, uma coluna. Identificadores viajam **dentro** do texto do comando, porque não há outro lugar para onde eles possam ir.

Essa diferença não é uma escolha do akkar. É do Postgres.

## Por que um identificador não pode ser um parâmetro

A resposta honesta é que o Postgres planeja o comando antes de ver os valores, e o plano depende de qual coluna você quis dizer. Qual índice usar, qual é o tipo da coluna, se a ordenação pode ser pulada: nada disso pode ser decidido enquanto o nome da coluna ainda é desconhecido.

Por isso `select * from $1` não é um comando que o Postgres consiga sequer interpretar:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function()
  return conn:many("select * from $1", "sqlguide_tasks")
end)
print(ok, why)

conn:close()
```

```
false	db: ERROR: syntax error at or near "$1" (15)
```

Esse aí é barulhento, e uma falha barulhenta é o caso bom. Aqui vai o caso silencioso, que é pior. `order by $1` **é** SQL válido, então roda. Só não faz o que você pensa:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_tasks"
conn:exec "create table sqlguide_tasks (id serial primary key, title text not null)"
conn:exec "insert into sqlguide_tasks (title) values ('zebra'), ('apple'), ('mango')"

for _, row in ipairs(conn:many("select id, title from sqlguide_tasks order by $1",
                               "title")) do
  print(row.id, row.title)
end

conn:exec "drop table sqlguide_tasks"
conn:close()
```

```
1	zebra
2	apple
3	mango
```

Não está ordenado. `zebra`, `apple`, `mango` é a ordem em que foram inseridos. O Postgres vinculou `$1` como a **string** `'title'`, ordenou cada linha por essa mesma constante, o que não é ordenação nenhuma, e retornou tudo intocado. Sem erro, sem aviso, e um teste com três linhas provavelmente passaria.

É por isso que `order_by` recebe um nome de coluna em vez de um valor. Nunca houve a opção de vinculá-lo.

## Então um identificador é verificado, duas vezes

Como o nome precisa ser escrito no texto, o akkar o verifica. Duas checagens separadas, e elas capturam dois problemas diferentes.

### O padrão, que sempre roda

Letras, dígitos e underscores, começando com uma letra ou um underscore. Opcionalmente um ponto, para `schema.tabela`. Nada além disso:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.select("*"):from "sqlguide_tasks; drop table sqlguide_tasks"
end)
print(ok, why)

local ok2, why2 = pcall(function()
  return sql.select("*"):from("sqlguide_tasks"):order_by("title; drop table x")
end)
print(ok2, why2)
```

```
false	akkar.sql: table name is not a valid identifier: sqlguide_tasks; drop table sqlguide_tasks
false	akkar.sql: order column is not a valid identifier: title; drop table x
```

Essa é a checagem que torna a injeção via identificador impossível. Ela roda quer você tenha passado uma lista ou não.

Ela é deliberadamente mais restrita do que o que o Postgres aceita. Um nome entre aspas com um espaço dentro é um identificador válido no Postgres, e mesmo assim o akkar recusa:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.select("*"):from("sqlguide_tasks"):order_by('"weird name"')
end)
print(ok, why)
```

```
false	akkar.sql: order column is not a valid identifier: "weird name"
```

A troca está registrada no código-fonte: o custo de recusar um nome incomum mas válido é um erro claro, e o custo de aceitar um nome malicioso é o banco de dados.

### A lista de permissão, que roda quando você a passa

O padrão barra `title; drop table x`. Ele não barra `password_hash`, porque `password_hash` é um identificador perfeitamente válido. É uma coluna real, escrita corretamente, que essa rota nunca deveria expor.

Só você sabe quais colunas uma rota deve tratar, então é você quem diz isso:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"

local ok, why = pcall(function()
  return q:order_by("password_hash", { "id", "title", "created_at" })
end)
print(ok, why)
```

```
false	akkar.sql: order column 'password_hash' is not in the allowed list (id, title, created_at)
```

Ordenar por uma coluna que você não escolheu não é inofensivo. `order by password_hash` não imprime os hashes, mas coloca as linhas em uma ordem que depende deles, e quem consegue paginar o resultado descobre a ordem. Isso é um vazamento lento de um segredo, saindo de um parâmetro de ordenação que ninguém tinha pensado.

## Onde a lista entra, em cada método que recebe uma

| método | o identificador é | o argumento de lista é |
|---|---|---|
| `sql.select(columns)` | nenhum, é o seu texto | não existe |
| `:from(table, allowed)` | a tabela | 2º |
| `sql.update(table, allowed)` | a tabela | 2º |
| `sql.delete_from(table, allowed)` | a tabela | 2º |
| `sql.insert_into(table, row, allowed_columns, allowed_table)` | cada chave de `row`, e a tabela | 3º para as colunas, 4º para a tabela |
| `:set(column, value, allowed)` | a coluna | 3º |
| `:order_by(column, allowed, direction)` | a coluna | 2º |
| `:group_by(column, allowed)` | a coluna | 3º |
| `:where_in(column, values, allowed)` | a coluna | 3º |
| `:scope(column, value, allowed)` | a coluna | 3º |
| `sql.identifier(name, allowed, what)` | o nome | 2º |

Duas entradas dessa tabela merecem atenção especial.

`:where(condition, ...)` não está nela. A condição é **o seu texto**, assim como a lista de colunas em `select`. O akkar não a lê e não consegue verificá-la. Nada vindo de uma requisição (request) deve entrar ali, nunca. Só os valores depois dela vêm de fora.

`:join(clause, ...)` também não está, pelo mesmo motivo.

## `sql.identifier`, para quando você escreve o texto sozinho

A mesma checagem, isolada, para quando você não está usando o builder:

```lua
local sql = require "akkar.sql"

local wanted = "title"                     -- finja que isso chegou como ?sort=title
local column = sql.identifier(wanted, { "id", "title", "done" }, "column name")

print("select id, title from sqlguide_tasks order by " .. column)
```

```
select id, title from sqlguide_tasks order by title
```

O terceiro argumento é só a palavra usada na mensagem de erro. Passe `"column name"` ou `"table name"` para que a mensagem fique correta:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(sql.identifier, "oops", { "id" }, "sort column")
print(ok, why)
```

```
false	akkar.sql: sort column 'oops' is not in the allowed list (id)
```

Essa é a única porta pela qual texto verificado de uma requisição chega até o SQL, e é estreita de propósito: colar aqui é seguro justamente porque `column` só pode ser uma entre três strings que você mesmo escreveu.

## O que acontece quando você deixa a lista de fora

Nada, a princípio. Esse é o problema.

Sem lista, o padrão continua rodando, então você continua protegido contra injeção. O que você perde é a resposta para "quais colunas essa rota trata", e dois bugs diferentes passam por essa brecha:

**Alguém ordenando ou agrupando por uma coluna que você não pretendia.** Como no exemplo acima.

**Alguém escrevendo uma coluna que você não pretendia.** Esse é o caso da [página 8](08-insert.md), e vale a pena repetir por completo porque nenhuma mensagem de erro aparece em lugar nenhum:

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk", is_admin = true }

print(sql.insert_into("sqlguide_tasks", body):to_string())
```

```
insert into sqlguide_tasks (is_admin, title) values ($1, $2)
```

Um comando válido, bem formado, que dá a quem chama uma coluna que você nunca quis que ela tocasse.

## Duas camadas, e por que você quer as duas

A lista de permissão gera um erro. Um erro saindo de um handler é um `500`, que não diz nada útil para quem chamou e coloca um stack trace nos seus logs.

Então faça a checagem duas vezes, em dois lugares, por dois motivos diferentes:

```lua no-run
app:get("/tasks", {
  query = {
    sort = v.string { optional = true, one_of = { "id", "title" }, default = "id" },
  },
}, function(req)
  local q = sql.select("id, title"):from "tasks"
  q:order_by(req.query.sort, { "id", "title" })
  return { tasks = akkar.array(req.db:many(q)) }
end)
```

O **schema** existe para dar a quem chama uma boa resposta. `?sort=password_hash` recebe um `422` nomeando o campo e os valores permitidos, antes mesmo do seu handler rodar.

A **lista de permissão** existe porque o schema é uma coisa separada que alguém vai editar, e um schema esquecido não deveria ser a única coisa entre um estranho e suas colunas.

A segunda checagem não é paranoia sobre seus colegas. É que essas duas linhas vivem em partes diferentes do arquivo, e o dia em que uma delas mudar sem a outra é um dia em que ninguém percebe.

## Checkpoint

Você entendeu isso se:

- consegue explicar por que `order by $1` é pior do que um erro de sintaxe
- sabe que a checagem de padrão sempre roda e a checagem de lista roda quando você a passa
- consegue nomear o que a lista barra que o padrão não barra
- passa a lista em `insert_into` e `order_by` sem que ninguém precise pedir

Próxima página: [12. one, many e exec](12-running-a-query.md).
