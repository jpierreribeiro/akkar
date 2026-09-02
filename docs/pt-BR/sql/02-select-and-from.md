# 2. select e from

> **Português (Brasil)** | [Original em inglês](../../sql/02-select-and-from.md)

Ao final desta página você vai saber o que cada um dos dois argumentos de um
`select` pode ser, qual deles é verificado e qual não é, e por que essa
diferença existe.

## `select` recebe texto, e é o seu texto

```lua
local sql = require "akkar.sql"

print(sql.select("id, title, done"):from("sqlguide_tasks"):to_string())
```

```
select id, title, done from sqlguide_tasks
```

Tudo o que você passa para `sql.select` é copiado para a instrução exatamente
como você escreveu. Não é verificado, e não é escapado.

Isso soa alarmante depois da página sobre injeção. Mas não é, e o motivo vale
a pena dizer com clareza: **a lista de colunas é escrita por você, no seu
arquivo de código-fonte, e não muda quando uma requisição chega.** O dado
perigoso é o que vem de um estranho, e uma string constante no seu próprio
arquivo nunca é isso.

Então expressões são tranquilas, porque são suas:

```lua
local sql = require "akkar.sql"

print(sql.select("id, upper(title) as shout, done"):from("sqlguide_tasks"):to_string())
print(sql.select("count(*) as n"):from("sqlguide_tasks"):to_string())
```

```
select id, upper(title) as shout, done from sqlguide_tasks
select count(*) as n from sqlguide_tasks
```

E deixar o argumento de fora te dá tudo:

```lua
local sql = require "akkar.sql"

print(sql.select():from("sqlguide_tasks"):to_string())
print(sql.select("*"):from("sqlguide_tasks"):to_string())
```

```
select * from sqlguide_tasks
select * from sqlguide_tasks
```

Prefira nomear as colunas. `select *` entrega ao chamador toda coluna que a
tabela tiver, incluindo as que você adicionar no mês que vem, incluindo
`password_hash`.

### Se um nome de coluna realmente vem do chamador

Então ele deixa de ser o seu texto, e precisa ser verificado. `sql.identifier`
é a verificação, sozinha:

```lua
local sql = require "akkar.sql"

local wanted = "title"                       -- finja que isso veio de ?fields=
local column = sql.identifier(wanted, { "id", "title", "done" }, "column name")
print(sql.select("id, " .. column):from("sqlguide_tasks"):to_string())

local ok, why = pcall(sql.identifier, "password_hash", { "id", "title", "done" },
                      "column name")
print(ok, why)
```

```
select id, title from sqlguide_tasks
false	akkar.sql: column name 'password_hash' is not in the allowed list (id, title, done)
```

Essa é a única forma pela qual texto escolhido pelo chamador chega a uma
instrução: comparado contra uma lista que você escreveu, e recusado se não
estiver na lista. [Página 11](11-identifiers-and-allow-lists.md) é inteirinha
sobre isso.

## `from` recebe um identificador, e é verificado

O nome da tabela é diferente da lista de colunas, porque passa pela mesma
porta pela qual uma requisição um dia poderia passar. Por isso é verificado
sempre, contra um padrão:

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("sqlguide_tasks"):to_string())
print(sql.select("*"):from("public.sqlguide_tasks"):to_string())
```

```
select * from sqlguide_tasks
select * from public.sqlguide_tasks
```

Letras, dígitos e sublinhados, começando com letra ou sublinhado.
Opcionalmente um ponto, para `schema.table`. Qualquer outra coisa é recusada:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.select("*"):from "sqlguide_tasks t"
end)
print(ok, why)
```

```
false	akkar.sql: table name is not a valid identifier: sqlguide_tasks t
```

**Um alias de tabela não é um identificador, então você não pode ter um.**
`tasks t` são duas palavras. Esse é um limite real e muda a forma como você
escreve joins, então a [página 6](06-join.md) cobre o que fazer em vez disso:
escrever o nome completo da tabela em todo lugar.

### O segundo argumento é uma lista de permissões

`from` recebe uma lista opcional de nomes de tabela. Quando você a passa, a
tabela precisa ser uma delas:

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("sqlguide_tasks", { "sqlguide_tasks", "sqlguide_people" })
      :to_string())

local ok, why = pcall(function()
  return sql.select("*"):from("accounts", { "sqlguide_tasks", "sqlguide_people" })
end)
print(ok, why)
```

```
select * from sqlguide_tasks
false	akkar.sql: table name 'accounts' is not in the allowed list (sqlguide_tasks, sqlguide_people)
```

Você raramente vai precisar disso em `from`, porque a tabela costuma ser uma
constante no seu handler. Ela existe para o caso em que não é, e o mesmo
argumento aparece em `insert_into`, `update` e `delete_from`, onde importa
mais.

## Esquecer o `from`

A tabela é a única coisa sem a qual uma query não pode ser montada:

```lua
local sql = require "akkar.sql"

local ok, why = pcall(function()
  return sql.select("*"):where("id = ?", 1):build()
end)
print(ok, why)
```

```
false	akkar.sql: no table; call :from()
```

Repare quando esse erro chega: no `build`, não no `select`. Nada é verificado
quanto a estar completo até você pedir a instrução final, porque até lá você
ainda pode estar prestes a adicionar a peça que falta.

## O que vai onde, em uma tabela

| você passa | para | verificado? | por quê |
|---|---|---|---|
| `"id, title"` | `sql.select` | não | é o seu texto, no seu arquivo |
| `"sqlguide_tasks"` | `:from` | sim, padrão e lista opcional | é um identificador, então não pode ser vinculado |
| `false`, `10`, `"buy%"` | `:where`, `:limit` | não verificado, e não precisa ser | é vinculado como valor e nunca pode virar SQL |

## Ponto de verificação

Você está com isso se:

- `sql.select("id"):from("sqlguide_tasks"):to_string()` imprime
  `select id from sqlguide_tasks`
- você consegue explicar por que a lista de colunas não é verificada e o nome
  da tabela é
- `from "tasks t"` lançar um erro é algo que você espera, não algo que te
  surpreende

Próxima página: [3. where, e o ponto de interrogação](03-where.md).
