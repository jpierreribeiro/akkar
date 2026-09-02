# 17. O livro-caixa e o checksum

> **Português (Brasil)** | [Original em inglês](../../sql/17-the-ledger-and-the-checksum.md)

Ao final desta página você vai saber o que o akkar registra sobre uma migração,
por que essa linha é escrita no mesmo instante da mudança em si, e por que
editar uma migração que já rodou é recusado em vez de apenas avisado.

## O livro-caixa é uma tabela pequena

O akkar cria essa tabela na primeira vez que você aplica alguma coisa:

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
  files = { { name = "001_create_tasks.sql",
              sql = "create table sqlguide_tasks (id serial primary key)" } },
})
runner:apply()

for _, row in ipairs(conn:many([[
  select column_name, data_type
  from information_schema.columns
  where table_name = 'sqlguide_migrations'
  order by ordinal_position]])) do
  print(row.column_name, row.data_type)
end

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
name	text
checksum	text
applied_at	timestamp with time zone
```

Três colunas:

- **`name`** é o nome do arquivo, e é a chave primária. É isso que "aplicada
  uma vez" significa no fim das contas: uma segunda linha com o mesmo nome não
  pode existir.
- **`checksum`** é uma impressão digital dos bytes exatos do arquivo.
- **`applied_at`** é quando ela rodou.

A tabela se chama `akkar_migrations` a menos que você diga o contrário. O nome
entra no SQL como um identificador, então não pode ser um parâmetro vinculado,
então é verificado quando você constrói o executor:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function()
  return migrate.new(conn, { table = "my migrations; drop table users" })
end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: 'my migrations; drop table users' is not a usable table name; it goes into SQL as an identifier, which cannot be a bound parameter, so it must be letters, digits and underscores
```

O nome vem da sua própria configuração em vez de vir de uma requisição
(request), então isso não é uma porta que qualquer um pode atravessar hoje. Mesmo
assim é verificado, porque "não alcançável de fora" é uma propriedade do código
que chama, e código que chama muda.

## A linha é escrita dentro da mesma transação

Esta é a frase que faz o módulo valer a pena existir:

```
begin
  <your migration>
  insert into akkar_migrations (name, checksum) values (...)
commit
```

As duas coisas, ou nenhuma.

Imagine a outra ordem: aplicar a mudança, dar commit, e só então registrar.
Agora imagine o processo sendo derrubado nesse intervalo. Isso acontece: um
kill por falta de memória, uma conexão perdida, um timeout de implantação. A
mudança é aplicada e não registrada, então na próxima inicialização ela
aparece como pendente e é aplicada **de novo**.

Para um `create table` a segunda execução falha ruidosamente, que é o caso
bom. Para um `insert`, ou um `update ... set count = count + 1`, ela tem
sucesso silenciosamente e seus dados ficam errados.

Você consegue ver a atomicidade pelo lado que falha. Uma migração que gera um
erro sofre rollback **e** não é registrada, e nada depois dela é tentado:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()
conn:exec "drop table if exists sqlguide_migrations"
conn:exec "drop table if exists sqlguide_first"
conn:exec "drop table if exists sqlguide_never"

local runner = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = {
    { name = "001_first.sql", sql = "create table sqlguide_first (id int)" },
    { name = "002_boom.sql",  sql =
      "create table sqlguide_boom (id int); select this_function_does_not_exist()" },
    { name = "003_never.sql", sql = "create table sqlguide_never (id int)" },
  },
})

local ok, why = pcall(function() return runner:apply() end)
print(ok, why)

print("first exists:", conn:one("select to_regclass('sqlguide_first') is not null as p").p)
print("boom exists: ", conn:one("select to_regclass('sqlguide_boom') is not null as p").p)
print("never exists:", conn:one("select to_regclass('sqlguide_never') is not null as p").p)
print("recorded:    ", conn:one("select count(*) as n from sqlguide_migrations").n)

conn:exec "drop table sqlguide_first"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
false	db: ERROR: function this_function_does_not_exist() does not exist (45)
first exists:	true
boom exists: 	false
never exists:	false
recorded:    	1
```

Leia essas quatro linhas com atenção, porque elas são todo o design.

`001` rodou e está registrada. `002` falhou: o `create table` dentro dela
sofreu rollback mesmo que essa instrução em si estivesse correta, porque o
arquivo inteiro é uma única transação. `003` nunca foi tentada. E o livro-caixa
tem exatamente uma linha, então ele é um relato honesto de onde o banco de
dados realmente está.

Corrija o arquivo, rode de novo, e ele continua a partir de `002`.

## O checksum, e por que uma edição é um erro

O checksum é um SHA-256 dos bytes exatos do arquivo:

```lua
local migrate = require "akkar.migrate"

print(migrate.checksum_of "create table sqlguide_tasks (id serial primary key)")
print(migrate.checksum_of "create table sqlguide_tasks (id serial primary key) ")
```

```
7b1055f5cfaae63c414f4f512a1fc2f2f1094836330353de5b6e26b3481da5d0
b0566e097c3e5aaab431691e981fef57cbe42c0fa6ef959fdf0b55afe0291003
```

Um espaço no final, uma impressão digital completamente diferente. É para isso
que serve um hash.

Se um arquivo que já foi aplicado tem bytes diferentes hoje do que quando
rodou, o akkar para:

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

local original = "create table sqlguide_tasks (id serial primary key)"
local edited   = original .. ", title text)"

migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql", sql = original } },
}):apply()

local changed = migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql", sql = edited } },
})

local ok, why = pcall(function() return changed:apply() end)
print(ok)
print(why)

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
false
./akkar/migrate.lua:544: akkar.migrate: '001_create_tasks.sql' has changed since it was applied (ledger 7b1055f5cfaae63c414f4f512a1fc2f2f1094836330353de5b6e26b3481da5d0, file a50bdd97901b307bb678bb2adcc74938fba3086a8f76bc928a1d4688ed92b027) -- the database no longer matches the files. Restore the file, or write a new migration for whatever the edit was trying to say
```

O `./akkar/migrate.lua:544:` no início é o Lua dizendo qual linha gerou o
erro. A mensagem que importa para você começa em `akkar.migrate:`, e ela
fornece as duas impressões digitais para que você veja de imediato que elas
são diferentes.

### Por que isso é um erro e não um aviso

Porque um aviso passa rolando durante uma implantação.

Pense no que sua edição realmente fez. A migração já rodou. Editar o arquivo
não muda o banco de dados. Isso muda a **história** sobre o banco de dados, de
modo que, a partir de agora, "o esquema é o que as migrações dizem" é falso, e
toda afirmação que alguém fizer baseada nessa frase está errada. Um colega
configurando um notebook novo recebe sua versão editada e um esquema diferente
do seu, e nenhum dos dois consegue perceber.

**Editar uma migração já aplicada nunca é a resposta. Escrever uma nova
sempre é.** Se a mudança estava errada, `002_fix_it.sql` diz o que deveria ter
sido dito, e os dois arquivos juntos são a história verdadeira.

O conserto para o erro é, portanto, devolver o arquivo exatamente como ele
estava, e colocar a mudança que você queria em um arquivo novo.

### Duas arestas afiadas

**Fins de linha contam.** Os bytes são comparados exatamente, então um
checkout que reescreve fins de linha muda todo checksum e todo arquivo passa a
ser lido como editado. O akkar não os normaliza, porque não consegue
distinguir um fim de linha dentro de uma string literal de um entre
instruções. Mantenha os fins de linha da sua árvore de trabalho estáveis, o
que para a maioria das pessoas significa deixar o git em paz com eles.

**Um arquivo que foi aplicado e depois apagado não é um erro.** Compactar
migrações antigas depois que elas já estão em todo servidor é uma coisa comum
de se fazer, e recusar isso faria do akkar o motivo pelo qual seu diretório
nunca pode ser limpo:

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

migrate.new(conn, {
  table = "sqlguide_migrations",
  files = { { name = "001_create_tasks.sql",
              sql = "create table sqlguide_tasks (id serial primary key)" } },
}):apply()

local squashed = migrate.new(conn, { table = "sqlguide_migrations", files = {} })
print("pending:", #squashed:pending())
print("applied:", #squashed:applied())

conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
pending:	0
applied:	1
```

O livro-caixa ainda lembra dela. Simplesmente não há arquivo para comparar, e
tudo bem.

## Checkpoint

Você entendeu isso se:

- você consegue nomear as três colunas do livro-caixa e dizer qual delas é a
  chave
- você consegue explicar por que a linha do livro-caixa é escrita na mesma
  transação, usando a história da queda no meio do caminho
- você sabe o que fazer quando recebe um erro de checksum, e não é "editar o
  livro-caixa"
- você sabe que uma migração apagada é normal e uma editada não é

Próxima página: [18. O lock](18-the-lock.md).
