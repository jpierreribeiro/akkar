# 14. escopo (scope), para que uma query não atravesse tenants

> **Português (Brasil)** | [Original em inglês](../../sql/14-scope.md)

Ao final desta página você será capaz de entregar a um handler um handle de banco de dados que não consegue ler nem escrever nas linhas de outro cliente, mesmo que a query esteja errada.

[Página 8 do guia](../guide/08-only-your-own.md) apresenta isso com a lista de tarefas. Esta página é o mecanismo por trás disso, e as partes que o guia não precisou abordar.

## O bug que isso elimina

Uma aplicação com mais de um cliente mantém as linhas deles nas mesmas tabelas, com uma coluna dizendo de quem é cada uma: `project_id`, `account_id`, `tenant_id`. Toda query precisa dizer qual é:

```sql
select * from documents where project_id = $1 and id = $2
```

Ninguém escreve a versão sem `and project_id = $1` de propósito. Isso acontece em uma rota entre duzentas, numa quinta-feira, com pressa. E a revisão de código não pega isso de forma confiável, porque a query errada parece exatamente igual às duzentas certas, menos cinco palavras.

Por isso a possibilidade é eliminada em vez do hábito.

## `Query:scope` adiciona a condição

Em um `select`, `update` ou `delete`, o scope adiciona uma condição:

```lua
local sql = require "akkar.sql"

local q = sql.select("id, title"):from "sqlguide_notes"
q:where("id = ?", 7)
q:scope("project_id", 42)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select id, title from sqlguide_notes where id = $1 and project_id = $2
1	7
2	42
```

O valor é vinculado como qualquer outro valor. A coluna é um identificador, então ela aceita a lista de permissão (allow-list) opcional de sempre como terceiro argumento.

`:is_scoped()` diz se o método já foi chamado:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_notes"
print(q:is_scoped())
q:scope("project_id", 42)
print(q:is_scoped())
```

```
false
true
```

Ele existe para suas próprias verificações, em um teste. Nada dentro do akkar lê esse valor.

### Em um insert, ele sobrescreve a linha

Essa é a metade que as pessoas esquecem, e é a metade perigosa. Uma leitura sem escopo mostra a alguém os dados de outro tenant. Uma **escrita** sem escopo coloca dados dentro de outro tenant.

```lua
local sql = require "akkar.sql"

local body = { title = "notes", project_id = 2 }    -- quem chamou informou o project 2

local q = sql.insert_into("sqlguide_notes", body, { "title", "project_id" })
q:scope("project_id", 42)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
insert into sqlguide_notes (project_id, title) values ($1, $2)
1	42
2	notes
```

Quem chamou pediu o project 2 e recebeu o project 42, que é aquele em que realmente está. **O cliente não tem voz nessa decisão.** Se a linha não tivesse nenhum `project_id`, o scope adiciona a coluna:

```lua
local sql = require "akkar.sql"

local q = sql.insert_into("sqlguide_notes", { title = "notes" }, { "title" })
q:scope("project_id", 42)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, tostring(value)) end
```

```
insert into sqlguide_notes (project_id, title) values ($1, $2)
1	42
2	notes
```

O mesmo comando (statement) nos dois casos, o que é proposital: uma única forma em vez de duas, independentemente de o cliente ter enviado a coluna ou não.

## `db:scope` é o handle que você realmente usa

Chamar `:scope` em cada query manualmente é um hábito, e hábitos são exatamente o que isso está substituindo. Por isso o certo é escopar o handle uma única vez, no topo do handler, e usá-lo para tudo:

```lua no-run
local db = req.db:scope("project_id", req.user.project_id)
return db:many(sql.select("*"):from "documents")
```

Toda query que passa por `db` recebe a condição aplicada automaticamente. O comando sem escopo nunca chega a ser montado, então não existe uma janela em que ele possa ser enviado.

## O handle recusa SQL puro (raw SQL)

Essa é a parte que surpreende as pessoas, e não é um descuido:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec [[create table sqlguide_notes (
  id serial primary key, project_id integer not null, title text not null)]]
conn:exec [[insert into sqlguide_notes (project_id, title) values
  (42, 'ours one'), (42, 'ours two'), (7, 'theirs')]]

local mine = conn:scope("project_id", 42)

for _, row in ipairs(mine:many(sql.select("id, title"):from "sqlguide_notes")) do
  print(row.id, row.title)
end

local ok, why = pcall(function()
  return mine:many "select title from sqlguide_notes"
end)
print(ok, why)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
1	ours one
2	ours two
false	db: this handle is scoped to project_id, so it takes an akkar.sql query rather than raw SQL -- a string cannot be scoped without parsing it. Use db:unscoped() if the query genuinely covers every tenant.
```

Duas linhas de três, e uma recusa.

O motivo está na mensagem. Para acrescentar `and project_id = 42` a uma string, o akkar precisaria entender a string: encontrar o `where`, saber se há um `union` nela, perceber uma subquery, acertar os parênteses. Isso é um parser de SQL vivendo dentro do framework, e um parser de SQL que discorda do Postgres em um único caso extremo é pior do que nenhuma proteção, porque pareceria proteção.

Um objeto query não precisa ser interpretado (parsing). O akkar o construiu, então ele já sabe onde estão as condições.

## `unscoped`, e por que ele tem um nome

Algumas queries realmente precisam atravessar tenants: um relatório administrativo, uma contagem noturna, uma migração. Por isso a saída de emergência existe, e ela é explicitada no próprio ponto de chamada:

```lua no-run
req.db:unscoped():many "select count(*) from documents"
```

`unscoped()` não faz absolutamente nada. Em uma conexão simples, ele retorna a conexão. Em um handle escopado, ele retorna a conexão por baixo.

Todo o valor dele está em que `grep -rn ':unscoped()'` te dá a lista completa de queries no seu código que conseguem ver todos os tenants. Uma lista curta que alguém consegue realmente ler é mais valiosa do que uma regra que ninguém consegue verificar.

## As três coisas que ele não deixa você errar

### Um id de tenant nulo é recusado, e em voz alta

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function() return conn:scope("project_id", nil) end)
print(ok, why)

conn:close()
```

```
false	db: scope value for 'project_id' is nil; a missing tenant id has to fail here rather than quietly match every row
```

Pense no que seria a alternativa. `where project_id = null` nunca é verdadeiro, então um nil não bateria com nenhuma linha e toda listagem voltaria vazia, o que parece "esse cliente não tem dados" quando na verdade é "a sessão está quebrada". Falhar aqui é o jeito correto de agir.

### Escopar duas vezes restringe ainda mais

Uma organização e um projeto são ambos verdadeiros ao mesmo tempo, então o segundo scope soma à primeira condição em vez de substituí-la:

```lua
local sql = require "akkar.sql"

local q = sql.select("*"):from "sqlguide_notes"
q:scope("org_id", 3)
q:scope("project_id", 42)

print(q:to_string())
for index, value in ipairs(q:values()) do print(index, value) end
```

```
select * from sqlguide_notes where org_id = $1 and project_id = $2
1	3
2	42
```

O mesmo vale para handles: `req.db:scope("org_id", 3):scope("project_id", 42)` produz um handle com as duas condições.

### Uma transação continua escopada

O closure recebe o handle **escopado**, não a conexão, então nada dentro de uma transação consegue ultrapassar o escopo:

```lua
local db = require "akkar.db"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:scope("project_id", 42):transaction(function(tx)
  local ok, why = pcall(function() return tx:many "select 1" end)
  print(ok, why)
end)

conn:close()
```

```
false	db: this handle is scoped to project_id, so it takes an akkar.sql query rather than raw SQL -- a string cannot be scoped without parsing it. Use db:unscoped() if the query genuinely covers every tenant.
```

A mesma recusa dentro da transação e fora dela.

## Como fica quando isso te salva

Um update mirando na linha de outra pessoa. A condição está certa, o id existe, e nada acontece:

```lua
local db  = require "akkar.db"
local sql = require "akkar.sql"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

conn:exec "drop table if exists sqlguide_notes"
conn:exec [[create table sqlguide_notes (
  id serial primary key, project_id integer not null, title text not null)]]
conn:exec "insert into sqlguide_notes (project_id, title) values (7, 'theirs')"

local mine = conn:scope("project_id", 42)

local q = sql.update "sqlguide_notes"
q:set("title", "renamed", { "title" })
q:where("id = ?", 1)

print("changed:", mine:exec(q).affected_rows)
print("still:  ", conn:one("select title from sqlguide_notes where id = 1").title)

conn:exec "drop table sqlguide_notes"
conn:close()
```

```
changed:	0
still:  	theirs
```

O handler pediu para renomear a nota 1. A nota 1 pertence ao project 7. O handle está escopado para 42, então o comando enviado foi `... where id = $1 and project_id = $2`, e ele não bateu com nada.

`affected_rows` igual a `0` vira então um `404`, que também é a resposta correta a dar para quem perguntou sobre uma linha que não é dela. Dizer que ela existe mas pertence a outra pessoa já é, por si só, um vazamento.

## Checkpoint

Você domina isso se:

- consegue escopar um handle e ver a condição extra no SQL
- sabe o que o scope faz em um insert, e por que ele sobrescreve o corpo (body)
- consegue explicar por que um handle escopado recusa uma string
- sabe para que serve o `unscoped()` e por que ele não é apenas uma omissão

Próximo: [15. O que é uma migration](15-what-a-migration-is.md).
