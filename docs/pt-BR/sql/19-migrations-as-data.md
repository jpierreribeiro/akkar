# 19. Migrações como dados

> **Português (Brasil)** | [Original em inglês](../../sql/19-migrations-as-data.md)

Ao final desta página você vai saber as duas formas de passar suas migrações para o akkar, por que a segunda existe e como migrar de uma para a outra sem que toda migração pareça editada.

## A forma normal é um diretório

Uma pasta de arquivos `.sql`, um por migração, e nada mais:

```
migrations/
  20260816090000_create_tasks.sql
  20260816093000_add_note.sql
```

```lua no-run
migrate.new(conn, { dir = "migrations" }):apply()
```

Aqui está o processo de ponta a ponta, com o exemplo criando sua própria pasta para você poder rodar:

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

local dir = "/tmp/sqlguide-migrations"
os.execute("rm -rf " .. dir)
os.execute("mkdir -p " .. dir)

local function write(name, body)
  local file = assert(io.open(dir .. "/" .. name, "w"))
  file:write(body)
  file:close()
end

write("20260816090000_create_tasks.sql", [[
create table sqlguide_tasks (
  id serial primary key,
  title text not null,
  done boolean not null default false
);
]])
write("20260816093000_add_note.sql", [[
alter table sqlguide_tasks add column note text;
]])

local runner = migrate.new(conn, { dir = dir, table = "sqlguide_migrations" })

for _, file in ipairs(runner:files()) do print("found:  ", file.name) end
for _, name in ipairs(runner:apply()) do print("applied:", name) end

for _, row in ipairs(conn:many([[
  select column_name from information_schema.columns
  where table_name = 'sqlguide_tasks' order by ordinal_position]])) do
  print("column: ", row.column_name)
end

os.execute("rm -rf " .. dir)
conn:exec "drop table sqlguide_tasks"
conn:exec "drop table sqlguide_migrations"
conn:close()
```

```
found:  	20260816090000_create_tasks.sql
found:  	20260816093000_add_note.sql
applied:	20260816090000_create_tasks.sql
applied:	20260816093000_add_note.sql
column: 	id
column: 	title
column: 	done
column: 	note
```

Só arquivos terminados em `.sql` são lidos, e apenas dentro da própria pasta. Subdiretórios são ignorados de propósito: uma pasta que alguém criou para "arquivar" migrações antigas não deveria ser aplicada, e aplicar um arquivo morto é uma falha pior do que simplesmente não encontrá-lo.

Um diretório que não existe é um erro, em vez de "nada para migrar", porque um caminho digitado errado pareceria exatamente igual a um projeto que ainda não escreveu sua primeira migração:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local runner = migrate.new(conn, {
  dir = "/tmp/sqlguide-does-not-exist", table = "sqlguide_migrations" })

local ok, why = pcall(function() return runner:files() end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: cannot read the migration directory '/tmp/sqlguide-does-not-exist' -- it does not exist, or is not readable from the working directory
```

Repare nas últimas palavras. O caminho é relativo ao **diretório de trabalho do processo**, não ao seu arquivo-fonte. Rodar sua aplicação a partir de uma pasta diferente costuma ser a causa dessa mensagem quando o diretório realmente existe.

## A outra forma é uma lista

```lua no-run
migrate.new(conn, {
  files = {
    { name = "001_create_tasks.sql", sql = "create table tasks (...)" },
    { name = "002_add_note.sql",     sql = "alter table tasks add column note text" },
  },
})
```

A mesma entrada, só que passada diretamente em vez de lida do disco. Todas as regras das últimas quatro páginas continuam valendo sem mudança: os nomes ainda precisam de números, o registro é o mesmo, os checksums são calculados da mesma forma.

Passe uma ou outra, nunca as duas:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function()
  return migrate.new(conn, { dir = "migrations", files = {} })
end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: pass `dir` or `files`, not both -- two sources of migrations is two answers to what has been applied
```

E o formato de cada entrada é verificado quando você monta o executor, não quando aplica, porque a alternativa seria uma falha no meio de um deploy enquanto o lock está travado:

```lua
local db      = require "akkar.db"
local migrate = require "akkar.migrate"

local open = db.connect {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar", pool_size = 0,
}
local conn = open()

local ok, why = pcall(function()
  return migrate.new(conn, { files = { { name = "001_create_tasks.sql" } } })
end)
print(ok, why)

conn:close()
```

```
false	akkar.migrate: files[1] must be { name = string, sql = string }
```

## Por que a lista existe: um contêiner sem shell

Isso não é uma questão de conveniência. É uma implantação que foi descoberta da forma mais difícil.

Lua não tem como listar um diretório. Não existe `readdir` na biblioteca padrão, e adicionar uma biblioteca em C para isso jogaria fora justamente o que torna o `akkar build` interessante. Então o akkar delega essa tarefa ao `find`, através do `io.popen`.

O `io.popen` precisa do `/bin/sh`.

O binário de arquivo único que o `akkar build` produz roda tranquilamente em um contêiner `scratch`: dois arquivos, sem libc, sem shell. Esse é todo o propósito do runtime. E, nessa imagem, listar um diretório é impossível. A falha se parecia com isto, e é uma boa lição sobre como ler erros:

```
could not list /migrations: ... No such file or directory
```

O que está faltando é o **shell**, não o diretório. Isso foi provado, não apenas suposto: o mesmo binário, o mesmo mount, o mesmo banco de dados, aplicou as duas migrações a partir de uma imagem Alpine e nenhuma a partir da scratch.

O akkar não pode consertar isso encontrando outra forma de ler um diretório, porque simplesmente não existe uma. Então a solução é que uma implantação incapaz de listar arquivos não deveria precisar disso. Quando detecta que não há shell, o akkar acrescenta isto ao erro:

```
there is no shell in this image, which is normal for a binary built by `akkar
build` and running in a scratch container.
pass the migrations as data instead: migrate.new(db, { files = { { name = ...,
sql = ... } } })
```

Há um segundo motivo para gostar dessa abordagem, além do contêiner. Um deploy cujo esquema viaja **dentro** do binário não corre o risco de ficar dessincronizado do código. Um artefato, um esquema, e nenhuma chance de copiar o binário sem a pasta de migrações junto.

## Migrando de um diretório para uma lista

Os checksums são calculados da mesma forma nos dois caminhos, de propósito, para que a mesma migração produza a mesma linha no registro não importa por qual caminho chegou ao akkar. Caso contrário, migrar pareceria que todas as migrações foram editadas de uma vez, e a [página 17](17-the-ledger-and-the-checksum.md) explica o que o akkar faz nesse caso.

Você pode conferir isso por conta própria:

```lua
local migrate = require "akkar.migrate"

local body = "create table sqlguide_tasks (id serial primary key)\n"

local path = "/tmp/sqlguide-one-migration.sql"
local out = assert(io.open(path, "w"))
out:write(body)
out:close()

local back = assert(io.open(path, "rb"))
local from_disk = back:read "a"
back:close()
os.remove(path)

print(migrate.checksum_of(from_disk))
print(migrate.checksum_of(body))
print("same:", migrate.checksum_of(from_disk) == migrate.checksum_of(body))
```

```
e55985cb2ea74a1617203a28e2710c7c1662ebe58c12de16ef20c06afc9ec8b9
e55985cb2ea74a1617203a28e2710c7c1662ebe58c12de16ef20c06afc9ec8b9
same:	true
```

Os bytes são os bytes. Então a forma correta de migrar é incorporar os arquivos **exatamente** como estão, incluindo a quebra de linha final, que é onde isso costuma dar errado.

Gere o código Lua em vez de digitá-lo. Uma etapa de build que lê o diretório e escreve um módulo leva poucas linhas, e mantém os dois sincronizados:

```lua no-run
-- tools/embed-migrations.lua, executado antes do `akkar build`
local out = assert(io.open("migrations_embedded.lua", "w"))
out:write "return {\n"

local pipe = assert(io.popen "find migrations -maxdepth 1 -name '*.sql' | sort")
for path in pipe:lines() do
  local file = assert(io.open(path, "rb"))
  local sql = file:read "a"
  file:close()
  out:write(("  { name = %q, sql = %q },\n"):format(path:match "([^/]+)$", sql))
end
pipe:close()

out:write "}\n"
out:close()
```

O `%q` é a parte importante: é a citação (quoting) nativa do Lua, então uma migração cheia de aspas, quebras de linha e barras invertidas volta idêntica, byte a byte. Depois, sua aplicação faz:

```lua no-run
migrate.new(conn, { files = require "migrations_embedded" }):apply()
```

O gerador roda na sua máquina, onde existe um shell. O binário roda onde não existe, e ele não precisa de um.

## Qual usar

**Desenvolvimento: um diretório.** Você está criando uma nova migração a cada poucos dias, e uma pasta de arquivos é o que um editor, um diff e uma revisão de código entendem bem.

**Um contêiner scratch, ou qualquer deploy de artefato único: a lista.** Porque é a única coisa que funciona, e porque torna o binário completo.

Usar os dois juntos no mesmo projeto é perfeitamente possível, desde que cada executor use apenas um deles.

## Checkpoint

Você domina isso se:

- consegue apontar um executor para um diretório e para uma lista, e sabe que eles se comportam da mesma forma
- sabe por que a versão em diretório precisa de um shell e onde isso falha
- sabe que os checksums coincidem nos dois caminhos, e por que isso importa
- geraria a lista incorporada em vez de colá-la manualmente

Próxima página: [20. Executando-as no deploy](20-on-deploy.md).
