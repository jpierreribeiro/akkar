# akkar.scope

> **Português (Brasil)** | [Original em inglês](../../reference/scope.md)

Um handle de banco de dados que não consegue disparar uma consulta sem escopo. Toda consulta que passa por ele recebe `column = value` adicionado antes de rodar, e a instrução sem escopo nunca chega a ser montada.

**Quando você precisa dele.** Qualquer tabela cujas linhas pertençam a uma conta, um tenant ou um projeto. Chegue até ele por `req.db:scope(column, value)`; esta página documenta o handle que volta dessa chamada.

```lua no-run
local scope = require "akkar.scope"
```

Você raramente vai importar isso pelo nome. Tanto `akkar.db` quanto `akkar.db.memory` expõem essa função como `db:scope(column, value)`, e `akkar.db.scope` é a mesma função que `scope.wrap`. Ela vive no nível do contrato em vez de dentro de `akkar.db` para que o adaptador em memória tenha o mesmo escopo: uma versão falsa cuja propriedade de segurança é diferente da versão real é a forma de um teste provar a coisa errada.

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`scope.Scoped`](#scoped) | metatable |
| [`scope.wrap`](#scopewrapdb-column-value) | função |
| [`Scoped:close`](#scopedclose) | método |
| [`Scoped:exec`](#scopedexecquery) | método |
| [`Scoped:many`](#scopedmanyquery) | método |
| [`Scoped:one`](#scopedonequery) | método |
| [`Scoped:release`](#scopedrelease) | método |
| [`Scoped:scope`](#scopedscopecolumn-value) | método |
| [`Scoped:transaction`](#scopedtransactionfn) | método |
| [`Scoped:unscoped`](#scopedunscoped) | método |

## scope.wrap(db, column, value)

Envolve um handle de banco de dados. Acessível como `db:scope(column, value)` nos dois adaptadores, e exportado como `akkar.db.scope`.

| argumento | tipo | significado |
|---|---|---|
| `db` | table | o handle a ser envolvido: uma conexão, ou outro Scoped |
| `column` | string | a coluna que a condição nomeia |
| `value` | any | o valor que ela precisa ser igual. Qualquer coisa exceto `nil` |

**Retorna** um Scoped.

**Lança** `db: scope value for '<column>' is nil; a missing tenant id has to fail here rather than quietly match every row` quando `value` é nil. É esse erro que pega uma leitura de `req.auth.user_id` antes de qualquer login acontecer.

```lua
local sql    = require "akkar.sql"
local memory = require "akkar.db.memory"

local db = memory.new()
db:on(".", function() return {} end)

local mine = db:scope("user_id", 7)

mine:many(sql.select("id, title"):from "tasks")
print(db.log[1].sql)
print("value:", db.log[1].args[1])

-- O escopo prevalece sobre um user_id que quem chamou colocou na linha.
local row = { title = "buy milk", user_id = 999 }
mine:exec(sql.insert_into("tasks", row, { "title", "user_id" }))
print(db.log[2].sql)
print("owner:", db.log[2].args[2])

-- Uma string crua não pode receber escopo, então é recusada.
local ok, why = pcall(function() return mine:many "select * from tasks" end)
print("raw sql:", ok)
print(why)

-- Um tenant id nil é recusado em vez de corresponder a todas as linhas.
print(select(2, pcall(function() return db:scope("user_id", nil) end)))
```

## Scoped

O handle que `scope.wrap` retorna. Ele carrega os mesmos cinco métodos de consulta que uma conexão tem, além de `unscoped`.

Cada um de `many`, `one` e `exec` recusa uma string:

```
db: this handle is scoped to <column>, so it takes an akkar.sql query rather
than raw SQL -- a string cannot be scoped without parsing it. Use db:unscoped()
if the query genuinely covers every tenant.
```

O motivo está na própria mensagem. Adicionar uma condição a uma instrução significa entender a instrução, e uma string é só letras: onde entra o `where`, já existe um, isso é um select dentro de outro select. Responder isso exigiria um parser de SQL dentro do akkar, e um parser que discordasse do Postgres sobre o significado de uma consulta estaria errado silenciosamente.

### Scoped:close()

Repassa para o `close` do handle envolvido.

### Scoped:exec(query)

Aplica o escopo a um builder do `akkar.sql` e o executa pelo efeito colateral.

**Retorna** o que quer que o `exec` do handle envolvido retorne, que no caso do `akkar.db` inclui `affected_rows`.

**Lança** a recusa acima quando `query` é uma string, ou qualquer outra coisa sem método `scope`.

### Scoped:many(query)

Aplica o escopo a um builder do `akkar.sql` e o executa.

**Retorna** as linhas.

**Lança** a recusa acima quando `query` não é um builder.

### Scoped:one(query)

**Retorna** a primeira linha, ou `nil`. Uma linha que existe mas pertence a outro tenant é `nil` aqui, e é por isso que uma verificação de posse acaba respondendo `404` sem nenhum handler ter escolhido isso.

**Lança** a recusa acima quando `query` não é um builder.

### Scoped:release()

Repassa para o `release` do handle envolvido, devolvendo uma conexão ao pool.

### Scoped:scope(column, value)

Aplicar escopo duas vezes **restringe** em vez de substituir. Uma organização e um projeto são ambos verdadeiros ao mesmo tempo, e descartar o mais externo ampliaria a consulta.

**Retorna** um novo Scoped envolvendo este. As duas condições são unidas com AND, a mais interna primeiro.

### Scoped:transaction(fn)

Executa `fn` dentro da transação do handle envolvido. A closure recebe o **handle com escopo**, não a conexão, então nada dentro de uma transação consegue escapar do escopo contornando-o.

**Retorna** o que quer que o `transaction` do handle envolvido retorne.

### Scoped:unscoped()

**Retorna** o handle por baixo, sem nenhuma condição anexada.

É um nome longo no ponto de chamada, e essa é a funcionalidade: `grep -rn ':unscoped()'` te dá a lista completa de toda consulta em uma aplicação que atravessa entre tenants. Uma lista curta que alguém consegue ler vale mais que uma regra que ninguém consegue checar.

```lua
local sql    = require "akkar.sql"
local memory = require "akkar.db.memory"

local db = memory.new()
db:on(".", function() return {} end)

-- Aplicar escopo duas vezes restringe: as duas condições valem ao mesmo tempo.
db:scope("org_id", 1):scope("project_id", 7)
  :many(sql.select("*"):from "documents")
print(db.log[1].sql)

-- A closure recebe o handle com escopo, não a conexão.
db:scope("user_id", 7):transaction(function(tx)
  tx:exec(sql.delete_from("tasks"):where("done = ?", true))
  return true
end)
for _, entry in ipairs(db.log) do print(entry.sql) end

-- A saída de emergência, nomeada no ponto de chamada para o grep encontrar.
db:scope("user_id", 7):unscoped():many "select count(*) from tasks"
print(db.log[#db.log].sql)
```

## O que "com escopo" significa por instrução

A condição é aplicada pelo próprio método `scope` do builder, então onde ela entra depende da instrução. O próprio `akkar.scope` não entende SQL.

| instrução | o que acontece |
|---|---|
| `select` | `and column = ?` é adicionado à cláusula where |
| `update` | o mesmo, junto com as condições próprias do handler |
| `delete` | o mesmo. Um delete que não corresponde a nenhuma linha é a forma de uma linha de outro tenant sobreviver |
| `insert` | a coluna é **definida**, sobrescrevendo o que a linha trazia. Quem chama e coloca o id de outra pessoa no corpo da requisição acaba escrevendo na própria conta mesmo assim |

## O que não está aqui

**Nenhum SQL cru, e nenhuma opção que prometa que você mesmo adicionou o filtro.** Da própria docstring do módulo: "a string cannot be scoped without parsing it, and a SQL parser in the framework would be a second, worse database". Uma opção para passar uma string com uma promessa anexada é exatamente onde o filtro ausente se esconderia. `Scoped:unscoped()` é a saída de emergência, e é deliberadamente longa para que o `grep` a encontre.

**Nenhum escopo automático.** Nada lê `req.auth` por você e nada aplica um escopo a um handle que você não envolveu. A única chamada no topo de um handler é toda a interface, e um escopo aplicado de forma invisível seria um escopo que ninguém conseguiria auditar.

## Veja também

- [akkar.auth](auth.md), de onde vem o valor no qual você aplica o escopo
- a página do guia [8. Only your own tasks](../guide/08-only-your-own.md), para o bug que isso remove, mostrado antes de ser corrigido
- o código-fonte do módulo, `akkar/scope.lua`, e `spec/scope_spec.lua`, que garante que a instrução sem escopo nunca chega ao banco de dados
