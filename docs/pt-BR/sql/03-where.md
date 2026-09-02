# 3. where, e a interrogação

> **Português (Brasil)** | [Original em inglês](../../sql/03-where.md)

Ao final desta página você será capaz de escrever qualquer condição de que precisar, incluindo as que têm vários valores, as que são opcionais e as que precisam de `or`.

## Uma `?` para cada valor

`:where` recebe uma condição e, em seguida, um valor para cada `?` presente nela.

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_tasks"
q:where("done = ?", false)

print(q:to_string())
print(q:values()[1])
```

```
select id, title from sqlguide_tasks where done = $1
false
```

O `?` é uma marca dizendo "aqui vai um valor". Não é o valor em si. O valor viaja ao lado do comando, em uma lista separada, e o Postgres recebe os dois como coisas diferentes.

Vários `?` em uma condição recebem vários valores, na ordem:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("id between ? and ?", 10, 20)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select * from sqlguide_tasks where id between $1 and $2
1	10
2	20
```

## Duas condições significam `and`

Chame `:where` quantas vezes quiser. Cada condição é unida às anteriores com `and`:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("done = ?", false)
q:where("title like ?", "buy%")
q:where("id > ?", 3)

print(q:to_string())
```

```
select * from sqlguide_tasks where done = $1 and title like $2 and id > $3
```

É isso que torna um filtro opcional fácil de escrever. Cada um é um `if` que ou adiciona uma condição ou não adiciona nada:

```lua
local sql = require "akkar.sql"

local function search(filters)
  local q = sql.select("id, title"):from "sqlguide_tasks"
  if filters.done ~= nil then q:where("done = ?", filters.done) end
  if filters.text then q:where("title like ?", "%" .. filters.text .. "%") end
  return q
end

print(search({}):to_string())
print(search({ done = true }):to_string())
print(search({ done = true, text = "milk" }):to_string())
print(search({ done = true, text = "milk" }):values()[2])
```

```
select id, title from sqlguide_tasks
select id, title from sqlguide_tasks where done = $1
select id, title from sqlguide_tasks where done = $1 and title like $2
%milk%
```

Repare no último valor. `"%milk%"` foi construído colando strings, e isso é completamente seguro, porque é um **valor**. Ele entra na lista de valores. Os sinais de porcentagem fazem parte do texto que o banco de dados compara, não do comando. Colar strings só é perigoso quando o resultado vira SQL.

## Não existe método `or`

As condições são sempre unidas com `and`. Quando você quiser um `or`, escreva-o dentro de uma condição, e coloque parênteses ao redor:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("(title like ? or note like ?)", "%milk%", "%milk%")
q:where("done = ?", false)

print(q:to_string())
```

```
select * from sqlguide_tasks where (title like $1 or note like $2) and done = $3
```

Os parênteses não são decoração. Sem eles o comando fica lido como `a or b and c`, e `and` tem precedência maior que `or` em SQL, então você acabaria com `a or (b and c)`, que é uma pergunta diferente. O akkar não pode adicionar os parênteses para você, porque ele não interpreta sua condição.

## Uma condição sem nenhum valor

Perfeitamente normal, e você não passa nada depois dela:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("note is null")
q:where("done = ?", false)

print(q:to_string())
print("#values", #q:values())
```

```
select * from sqlguide_tasks where note is null and done = $1
#values	1
```

`is null` é a forma correta de perguntar sobre um valor ausente. `note = ?` sem nada para vincular não é, e a próxima seção trata do que acontece se você tentar.

## Os erros, e as mensagens

### A contagem não bate

O akkar conta os caracteres `?` e conta os valores que você passou. Se forem diferentes, ele para imediatamente, na chamada de `:where`, em vez de construir um comando que não pode funcionar:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"

local ok, why = pcall(function() return q:where("id = ?") end)
print(ok, why)

local ok2, why2 = pcall(function() return q:where("id = ?", 1, 2) end)
print(ok2, why2)
```

```
false	akkar.sql: condition has 1 placeholder(s) but 0 value(s) were given: id = ?
false	akkar.sql: condition has 1 placeholder(s) but 2 value(s) were given: id = ?
```

A mensagem termina com a própria condição, para que você consiga ver a qual das condições de um handler longo ela se refere.

### Uma interrogação dentro de uma string também conta

A contagem é dos caracteres `?` em qualquer lugar do texto. Ela não sabe que um deles está dentro de aspas:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
local ok, why = pcall(function() return q:where("title = 'what?'") end)
print(ok, why)
```

```
false	akkar.sql: condition has 1 placeholder(s) but 0 value(s) were given: title = 'what?'
```

A solução não é lutar contra isso. Um literal dentro de uma condição é um valor, então ele deveria ter sido vinculado desde o início:

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("sqlguide_tasks"):where("title = ?", "what?"):to_string())
```

```
select * from sqlguide_tasks where title = $1
```

Agora a interrogação dentro do valor é só um caractere dentro de uma string. Essa é a regra geral usando um chapéu pequeno: se é um valor, vincule-o.

### Um valor `nil`, e uma mensagem que culpa o akkar

Vale a pena conhecer esse caso antes que ele aconteça com você, porque a mensagem é enganosa.

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_tasks"
q:where("title = ?", nil)

local ok, why = pcall(function() return q:to_string() end)
print(ok, why)
```

```
false	akkar.sql: 1 placeholder(s) but 0 value(s) -- this is a bug in akkar.sql
```

Ela diz "this is a bug in akkar.sql" e quase certamente não é. É um `nil` nos seus valores.

Veja o que aconteceu. `:where` contou os argumentos corretamente, viu um valor e aceitou a condição. Mas `nil` não pode ser armazenado em uma lista Lua, então nada entrou na lista de valores, e no momento do `build` havia um `?` sem valor por trás. A checagem interna que dispara por último é a que percebe isso, e ela assume que a culpa é do akkar.

De onde vem o `nil` no código real é de um campo que não estava no corpo da requisição (request):

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk" }        -- nenhum `note` foi enviado

local q = sql.select("*"):from "sqlguide_tasks"
q:where("note = ?", body.note)             -- body.note é nil

local ok, why = pcall(function() return q:to_string() end)
print(ok, why)
```

```
false	akkar.sql: 1 placeholder(s) but 0 value(s) -- this is a bug in akkar.sql
```

Duas soluções, e qual delas você quer depende do que você tinha em mente.

Se um campo ausente significa "não filtre por isso de jeito nenhum", proteja-o, que é o padrão de filtro opcional visto mais acima nesta página:

```lua
local sql = require "akkar.sql"

local body = { title = "buy milk" }

local q = sql.select("*"):from "sqlguide_tasks"
if body.note ~= nil then q:where("note = ?", body.note) end

print(q:to_string())
```

```
select * from sqlguide_tasks
```

Se um campo ausente significa "encontre as linhas em que essa coluna está vazia", diga isso em SQL, porque `= null` nunca é verdadeiro em SQL mesmo quando a coluna é nula:

```lua
local sql = require "akkar.sql"

print(sql.select("*"):from("sqlguide_tasks"):where("note is null"):to_string())
```

```
select * from sqlguide_tasks where note is null
```

### `where` em um insert é descartado

Um `insert` não tem onde colocar uma condição, e o akkar a descarta sem avisar nada:

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("sqlguide_tasks", { title = "buy milk" }, { "title" })
q:where("id = ?", 1)

print(q:to_string())
print("#values", #q:values())
```

```
insert into sqlguide_tasks (title) values ($1)
#values	1
```

A condição desaparece e o `1` nunca aparece. Se sua intenção era "insira somente se essa linha ainda não existir", isso é um comando diferente, `insert ... on conflict do nothing`, e ele vai no texto que você mesmo passa para `db:exec`.

## Ponto de checagem

Você domina isto se:

- consegue escrever uma condição com dois valores e sabe qual `$` cada um vira
- sabe que duas chamadas de `:where` significam `and`, e como conseguir um `or`
- reconheceria `condition has 1 placeholder(s) but 0 value(s)` como um erro de contagem e `this is a bug in akkar.sql` como um `nil` que você mesmo passou

Próximo: [4. where_in, para uma lista](04-where-in.md).
