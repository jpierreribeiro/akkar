# 1. O objeto query

> **Português (Brasil)** | [Original em inglês](../../sql/01-the-query-object.md)

Ao final desta página você vai saber o que `akkar.sql` entrega para você, as três formas de olhar para esse valor e de onde exatamente vem o `$1` na instrução finalizada.

Nada aqui toca o banco de dados. Uma query é um valor Lua comum até você entregá-la a `req.db`, e esta página é só sobre esse valor.

## Uma query é uma tabela que guarda pedaços

`sql.select` não constrói nenhum SQL. Ela cria uma tabela e coloca uma informação nela. Cada método que você chama depois disso adiciona outra informação e devolve a mesma tabela.

```lua
local sql = require "akkar.sql"

local q = sql.select "id, title"
print(type(q))

local same = q:from "sqlguide_tasks"
print(same == q)
```

```
table
true
```

`same == q` é `true` porque `:from` retornou exatamente a query em que foi chamado. É por isso que as chamadas podem ser escritas em cadeia, e também podem ser escritas separadas em linhas diferentes. Estas duas são a mesma query, construída de duas formas:

```lua
local sql = require "akkar.sql"

local chained = sql.select("id, title"):from("sqlguide_tasks"):where("done = ?", false)

local apart = sql.select "id, title"
apart:from "sqlguide_tasks"
apart:where("done = ?", false)

print(chained:to_string())
print(apart:to_string())
```

```
select id, title from sqlguide_tasks where done = $1
select id, title from sqlguide_tasks where done = $1
```

A segunda forma é a que você quer dentro de um handler, porque dá para colocar um `if` no meio dela:

```lua no-run
local q = sql.select("id, title"):from "sqlguide_tasks"
if req.query.done ~= nil then
  q:where("done = ?", req.query.done)
end
```

Uma cadeia não pode ter um `if` no meio. Essa é a razão de este módulo existir: a query muda dependendo do que quem chamou pediu, e o jeito antigo de fazer isso era colar strings.

## As três formas de olhar para ela

Você vai usar as três, para três tarefas diferentes.

### `:to_string()` te dá o texto

Use quando quiser ver o que você construiu. É para leitura, para uma linha de log e para um teste.

```lua
local sql = require "akkar.sql"

local q = sql.select("id"):from("sqlguide_tasks"):where("id = ?", 1)
print(q:to_string())
```

```
select id from sqlguide_tasks where id = $1
```

Repare no que está faltando nessa linha: o número `1` não está nela. Isso é proposital. Uma linha de log com os valores reais escritos dentro do SQL é justamente o texto que alguém copia depois para uma instrução que não é segura, então `to_string` nunca produz uma.

### `:values()` te dá os valores

Uma lista Lua simples, na ordem em que os placeholders aparecem.

```lua
local sql = require "akkar.sql"

local q = sql.select "*"
q:from "sqlguide_tasks"
q:where("done = ?", false)
q:where("title like ?", "buy%")
q:limit(5)

for index, value in ipairs(q:values()) do
  print(index, type(value), tostring(value))
end
```

```
1	boolean	false
2	string	buy%
3	number	5
```

Três coisas que vale a pena notar.

Os valores mantêm seus tipos Lua. `false` continua sendo um booleano, não o texto `"false"`. É isso que "o valor nunca vira texto" significa na prática.

`limit(5)` também colocou um valor na lista. O limite é um número, então ele é vinculado (bound) como qualquer outro número, em vez de ser escrito dentro da instrução.

A ordem é a ordem dos placeholders no texto finalizado, não a ordem em que você chamou os métodos. Nesta query elas coincidem. Em um `update` não coincidem, e a [página 9](09-update.md) mostra o porquê.

### `:build()` te dá os dois, prontos para enviar

`build` retorna o texto primeiro e depois cada valor, como retornos separados.

```lua
local sql = require "akkar.sql"

local q = sql.select("id"):from("sqlguide_tasks"):where("done = ?", false):limit(5)

local text, first, second = q:build()
print(text)
print(type(first), tostring(first))
print(type(second), tostring(second))
```

```
select id from sqlguide_tasks where done = $1 limit $2
boolean	false
number	5
```

Esse formato não é acidente. É exatamente a lista de argumentos que `db:many` espera:

```lua no-run
req.db:many(q:build())
```

E como isso é muito comum, você nem precisa escrever assim. `db:one`, `db:many` e `db:exec` chamam `build` para você quando você entrega uma query a eles:

```lua no-run
req.db:many(q)
```

As duas linhas fazem a mesma coisa. Use a mais curta.

## De onde vem o `$1`

Você escreve `?`. O Postgres quer `$1`, `$2`, `$3`. A troca acontece uma única vez, em `build`, contando da esquerda para a direita ao longo do texto finalizado.

Isso importa mais do que parece. Considere três condições separadas, adicionadas em três momentos diferentes:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("done = ?", false)
q:where("title like ?", "buy%")
q:where("id > ?", 10)
q:limit(3)

print(q:to_string())
```

```
select * from sqlguide_tasks where done = $1 and title like $2 and id > $3 limit $4
```

Ninguém contou. Se você tivesse escrito `$1`, `$2`, `$3` por conta própria, cada filtro opcional mudaria a numeração de todos os filtros seguintes, e um número errado é uma query que lê o valor errado ou falha completamente. Contar placeholders manualmente é a outra metade do motivo pelo qual as pessoas desistem e concatenam strings.

Repare no `and` entre as condições. As condições são sempre unidas com `and`, e a [página 3](03-where.md) diz o que fazer quando você quer `or`.

## Nada é enviado ainda

Nenhum dos exemplos acima abriu uma conexão. A query é dado. Ela vira uma instrução quando você a entrega a um handle de banco de dados, e não antes, e é por isso que você pode construir uma em um teste e conferi-la com `to_string` sem nenhum Postgres rodando.

## Checkpoint

Você domina isto se conseguir responder sem olhar:

- O que `sql.select("id"):from "t"` retorna? Uma query, que é uma tabela Lua.
- Qual dos três métodos você usa em um teste? `to_string` e `values`.
- Qual deles `db:many` chama para você? `build`.
- Quem transforma `?` em `$1`? `build` faz isso, uma única vez, da esquerda para a direita.

Próxima página: [2. select e from](02-select-and-from.md).
