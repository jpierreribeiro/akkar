# akkar.build

> **Português (Brasil)** | [Original em inglês](../../reference/build.md)

Transforma uma aplicação e seus módulos em um único arquivo C e, a menos que seja instruído a não fazer isso, vincula esse arquivo em um único executável contendo a VM Lua, todo módulo Lua como código-fonte e todo módulo nativo.

**Quando você precisa disso.** Você está produzindo um artefato implantável: uma imagem de container sem Lua, sem LuaRocks e sem `.so` nela. Quase todo mundo chega a este módulo pelo comando `akkar build`, e não pelo Lua.

```lua no-run
local build = require "akkar.build"
```

## Índice

Todo símbolo público desta página, em ordem alfabética, e os dois comandos que os envolvem.

| símbolo | tipo |
|---|---|
| [`akkar archive`](#linha-de-comando-akkar-archive) | comando |
| [`akkar build`](#linha-de-comando-akkar-build) | comando |
| [`build.archive`](#buildarchiveoptions) | função |
| [`build.collect`](#buildcollectroot-into) | função |
| [`build.emit`](#buildemitplan) | função |
| [`build.module_name_for`](#buildmodule_name_forroot-path) | função |
| [`build.module_name_of`](#buildmodule_name_ofsymbol) | função |
| [`build.plan`](#buildplanoptions) | função |
| [`build.recipes`](#buildrecipes) | tabela |
| [`build.required_names`](#buildrequired_namespaths) | função |
| [`build.run`](#buildrunoptions) | função |
| [`build.symbols_in`](#buildsymbols_inarchive) | função |

## Linha de comando: akkar build

```sh
akkar build app.lua [options]
```

`app.lua` é o arquivo de entrada. Ele é embutido como qualquer outro módulo, sob o nome `__akkar_entry`, e requerido pelo `main` gerado.

| flag | valor | padrão | significado |
|---|---|---|---|
| `-o` | NAME | o nome base do arquivo de entrada sem `.lua` | o executável a ser escrito |
| `--root` | DIR | nenhum, repetível | um diretório de módulos Lua para embutir. O primeiro root vence, então listar seu próprio diretório primeiro sobrepõe um módulo de biblioteca |
| `--archive` | A.a | nenhum, repetível | um archive estático de módulos nativos |
| `--lua-lib` | PATH | nenhum | `liblua.a`. Obrigatório, a menos que `--c-only` |
| `--lua-inc` | DIR | nenhum | o diretório que contém `lua.h`. Obrigatório, a menos que `--c-only` |
| `--libs` | "..." | `-lm -ldl -lpthread` | flags extras do linker |
| `--cc` | NAME | `$CC`, ou `cc` | o compilador |
| `--c-only` | | desligado | escreve o C e para, sem compilar |

O diretório que contém o próprio akkar é anexado aos roots sem que seja pedido, então `--root` nunca precisa nomear o akkar. Tudo mais que a aplicação precisa é um root que quem chama declara.

**Escreve** o arquivo C em `<output>.c`, e o executável em `<output>`, a menos que `--c-only`.

**Imprime** uma linha em caso de sucesso, na saída padrão:

```
akkar build: 141 Lua modules, 47 native modules -> /build/akkar-app
```

O último campo é o binário, ou o arquivo C quando `--c-only` foi passado.

**Códigos de saída.** 0 em caso de sucesso. 2 em qualquer falha, com o motivo na saída de erro padrão prefixado com `akkar: `. Não existe código de saída 1 para este comando. As falhas são: uma opção desconhecida, uma flag sem valor depois dela, nenhum arquivo de entrada (`build needs an entry file: akkar build app.lua`), um `--lua-lib` ou `--lua-inc` ausente durante a compilação, e qualquer coisa que `build.run` retorne como motivo.

## Linha de comando: akkar archive

```sh
akkar archive LIBRARY --source DIR --lua-inc DIR [options]
```

Compila a árvore de código-fonte de um rock C em um único archive estático que `akkar build --archive` consegue consumir.

| flag | valor | padrão | significado |
|---|---|---|---|
| `--source` | DIR | nenhum, obrigatório | o diretório de código-fonte descompactado |
| `--lua-inc` | DIR | nenhum, obrigatório | o diretório que contém `lua.h` |
| `--lua-api` | VERSION | `5.4` | substituído no target do make da receita e nos globs de objetos |
| `-o` | PATH | `<library>.a` | o archive a ser escrito |
| `--cc` | NAME | `$CC`, ou `cc` | o compilador |

`LIBRARY` é uma chave de [`build.recipes`](#buildrecipes): `cqueues`, `luaossl`, `lua-cjson` ou `lpeg`.

**Imprime** `akkar archive: 12 objects -> cqueues.a`.

**Códigos de saída.** 0 em caso de sucesso, 2 para uma linha de comando incorreta, e 1 para um nome de biblioteca desconhecido. Um nome de biblioteca ausente é uma falha de linha de comando e imprime os nomes conhecidos; um nome que não é uma receita passa pela linha de comando e chega a `build.archive`, cujo raise não é capturado aqui, então ele chega como um traceback do Lua em vez de uma mensagem de uma linha `akkar: `.

**Ausente em `akkar help`.** `akkar archive` é despachado por `bin/akkar` e está ausente do texto de uso que `akkar help` imprime.

## O que o binário construído faz

O `main` gerado lê o `argv` antes de requerer o módulo de entrada embutido.

| invocação | comportamento |
|---|---|
| `./app` | requer `__akkar_entry`, o arquivo de entrada embutido |
| `./app run other.lua` | carrega e executa `other.lua` do disco em vez disso, com `arg[0]` definido para esse caminho e `arg[1..]` para os parâmetros restantes |
| `./app --akkar-version` | imprime a string `built_with` e encerra com 0 |
| qualquer outra coisa | o módulo de entrada de novo, com `arg` construído como um interpretador standalone construiria |

Um raise do módulo de entrada imprime `akkar: <message>` na saída de erro padrão e encerra com 1.

## build.archive(options)

Compila o código-fonte de uma biblioteca em um archive estático. Todo comando que ele executa mantém sua saída, então uma falha nomeia o comando e cita o que ele disse.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `source` | string | obrigatório | o diretório de código-fonte descompactado |
| `output` | string | obrigatório | o `.a` a ser escrito |
| `lua_include` | string | obrigatório | onde `lua.h` mora |
| `recipe` | string ou tabela | `{}` | uma chave de `build.recipes`, ou uma tabela do mesmo formato |
| `lua_api` | string | `"5.4"` | substituído em `recipe.make` e em cada padrão de `recipe.objects` |
| `sources` | lista de string | nenhum | usado quando a receita não tem `make` nem `sources` próprio |
| `cc` | string | `$CC`, ou `cc` | o compilador |
| `stage` | string | `source .. "/.akkar-archive"` | onde objetos colidentes são copiados antes do archiving |

Com `recipe.make` definido, `make <target> CPPFLAGS=...` executa em `source`, os globs de `recipe.objects` são expandidos, e nomes base colidentes são renomeados para `dup1_<base>` quando `recipe.prefix_collisions` é verdadeiro. Sem isso, cada arquivo em `sources` é compilado com `-c -O2 -fPIC`.

**Retorna** `{ archive = output, objects = <count> }`, ou `nil` e um motivo.

**Faz raise de** `akkar.build: no source directory`, `akkar.build: no lua_include`, `akkar.build: no output` quando esses estão ausentes, e `akkar.build: no recipe for '<name>'; pass `sources` or `make` explicitly` para um nome de receita que não está em `build.recipes`.

**Retorna `nil` e um motivo** quando `make` falha, quando uma compilação falha, quando dois objetos compartilham um nome base e a receita não diz qual vence, quando nenhum arquivo objeto foi produzido, e quando `ar` falha.

```lua no-run
-- Compilar um rock de verdade precisa do seu código-fonte descompactado, então isso não é executado aqui.
local build = require "akkar.build"
local result, why = build.archive {
  recipe = "lpeg",
  source = "/tmp/lpeg-1.1.0",
  lua_include = "/usr/include/lua5.4",
  output = "/tmp/lpeg.a",
}
```

## build.collect(root, into)

Encontra todo arquivo `.lua` sob `root` e mapeia seu nome de módulo para seu caminho. Executa `find`, então precisa de um shell.

**Retorna** `into`, ou uma nova tabela, indexada pelo nome do módulo. Uma chave existente nunca é sobrescrita, o que é o que faz o primeiro root vencer.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_1"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/greet.lua", "w"))
file:write "return {}\n"
file:close()

local found = build.collect(dir)
assert(found.greet == dir .. "/greet.lua")

os.execute(("rm -rf %q"):format(dir))
```

## build.emit(plan)

Escreve o host C para um plano e o retorna como uma string. Todo módulo Lua entra como um array hex dos bytes do seu código-fonte e é registrado em `package.preload`; todo módulo nativo é declarado e registrado sob seu nome real.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `entry` | string | obrigatório | o nome do módulo que o `main` requer |
| `lua` | tabela | obrigatório | `[module name] = path` |
| `native` | tabela | `{}` | `[module name] = luaopen symbol` |
| `built_with` | string | `"akkar dev-1"` | o que o binário imprime para `--akkar-version` |

**Retorna** o código-fonte C, ou `nil` e `cannot read <path> for module <name>: <why>` quando um arquivo listado não pode ser lido.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_2"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "print 'hello'\n"
file:close()

local source = build.emit {
  entry = "__akkar_entry",
  lua = { __akkar_entry = dir .. "/app.lua" },
  native = {},
  built_with = "akkar dev-1",
}
assert(source:find("AKKAR_ENTRY", 1, true))
assert(source:find("int main(int argc, char **argv)", 1, true))

os.execute(("rm -rf %q"):format(dir))
```

## build.module_name_for(root, path)

O nome do módulo pelo qual um arquivo sob `root` seria requerido. `init.lua` é removido, seguindo o comportamento de `package.path`, então `<root>/akkar/init.lua` é `akkar`, e não `akkar.init`.

**Retorna** uma string.

```lua
local build = require "akkar.build"
assert(build.module_name_for("/srv/app", "/srv/app/akkar/init.lua") == "akkar")
assert(build.module_name_for("/srv/app", "/srv/app/lib/util.lua") == "lib.util")
```

## build.module_name_of(symbol)

O nome do módulo ao qual um símbolo `luaopen_` pertence, por regra: um underscore inicial faz parte do nome, todo outro underscore é um separador.

**Retorna** uma string, ou `nil` quando o símbolo não começa com `luaopen_`.

A regra não consegue recuperar um nome que genuinamente contém um underscore. `luaopen__openssl_x509_verify_param` é `_openssl.x509.verify_param`, e isso responde `_openssl.x509.verify.param`. É por isso que `build.plan` consulta `build.required_names` primeiro e recorre a esta regra apenas para símbolos que nada pediu por nome.

```lua
local build = require "akkar.build"
assert(build.module_name_of "luaopen_lpeg" == "lpeg")
assert(build.module_name_of "luaopen__cqueues_socket" == "_cqueues.socket")
assert(build.module_name_of "not_a_symbol" == nil)
```

## build.plan(options)

Coleta os módulos Lua sob todo root, adiciona o arquivo de entrada sob um nome que nenhuma aplicação escolheria, lê os símbolos `luaopen_` de todo archive, e decide qual símbolo pertence a qual nome de módulo.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `entry` | string | obrigatório | caminho do arquivo Lua de entrada |
| `roots` | lista de string | `{}` | diretórios de módulos Lua; o primeiro root vence em uma colisão de nome |
| `archives` | lista de string | `{}` | archives estáticos dos quais ler símbolos |
| `native` | tabela | `{}` | `[module name] = symbol`, aplicado por último, então vence sobre qualquer coisa derivada |
| `entry_name` | string | `"__akkar_entry"` | o nome sob o qual o arquivo de entrada é embutido |

A nomeação acontece em três passagens: nomes literalmente requeridos pelos códigos-fonte embutidos primeiro, depois `build.module_name_of` para o que sobrar de símbolo, depois `options.native`.

**Retorna** `{ entry = <name>, lua = { [name] = path }, native = { [name] = symbol } }`, ou `nil` e um motivo quando um archive não pode ser lido.

**Faz raise de** `akkar.build: no entry file` quando `entry` está ausente.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_3"
os.execute(("rm -rf %q && mkdir -p %q/lib"):format(dir, dir))
local lib = assert(io.open(dir .. "/lib/greet.lua", "w"))
lib:write "return {}\n"
lib:close()
local entry = assert(io.open(dir .. "/app.lua", "w"))
entry:write 'require "greet"\n'
entry:close()

local plan = build.plan { entry = dir .. "/app.lua", roots = { dir .. "/lib" } }
assert(plan.entry == "__akkar_entry")
assert(plan.lua.greet == dir .. "/lib/greet.lua")
assert(plan.lua.__akkar_entry == dir .. "/app.lua")

os.execute(("rm -rf %q"):format(dir))
```

## build.recipes

O que cada biblioteca conhecida precisa, como uma tabela indexada pelo nome da biblioteca. Qualquer coisa que não esteja aqui ainda pode ser arquivada passando os mesmos campos para `build.archive` explicitamente.

| chave | campos | por quê |
|---|---|---|
| `cqueues` | `make = "all%s"`, `objects = { "src/%s/*.o", "src/lib/*.o" }`, `prefix_collisions = true` | `src/lib` e `src/<api>` ambos definem `socket.o`, `dns.o` e `notify.o` |
| `luaossl` | `make = "all%s"`, `cppflags = "-DHAVE_DLADDR=0"`, `objects = { "src/%s/*.o" }` | sem a flag o binário morre na inicialização em um `dlopen` de si mesmo |
| `lua-cjson` | `sources = { "lua_cjson.c", "fpconv.c", "strbuf.c" }` | `fpconv.c` ou `dtoa.c`, nunca ambos: cada um define `fpconv_strtod` |
| `lpeg` | `sources = { "lpcap.c", "lpcode.c", "lpcset.c", "lpprint.c", "lptree.c", "lpvm.c" }` | seis códigos-fonte nomeados e nada mais |

`%s` em `make` e em `objects` é substituído por `lua_api`.

## build.required_names(paths)

Lê todo `require "name"` e `require 'name'` literal dos arquivos em `paths` e os retorna como um conjunto. `paths` é iterado com `pairs`, então a tabela `plan.lua` pode ser passada diretamente.

**Retorna** uma tabela onde `[name] = true`.

Um módulo obtido através de um nome computado é invisível aqui, assim como é para qualquer ferramenta que lê o código-fonte em vez de executá-lo.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_4"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write 'local x = require "cqueues"\nlocal y = require("akkar.db")\n'
file:close()

local names = build.required_names { dir .. "/app.lua" }
assert(names.cqueues == true)
assert(names["akkar.db"] == true)

os.execute(("rm -rf %q"):format(dir))
```

## build.run(options)

Planeja, emite o C, escreve-o, e vincula o executável a menos que `compile` seja `false`. É isso que `akkar build` chama.

Aceita todo campo que [`build.plan`](#buildplanoptions) aceita, mais:

| campo | tipo | padrão | significado |
|---|---|---|---|
| `output` | string | `"akkar-app"` | o executável a ser escrito |
| `c_out` | string | `output .. ".c"` | o arquivo C a ser escrito |
| `compile` | boolean | `true` | `false` escreve o C e retorna sem vincular |
| `cc` | string | `$CC`, ou `cc` | o compilador |
| `cflags` | string | `"-Os"` | flags do compilador |
| `libs` | string | `"-lm -ldl -lpthread"` | flags do linker, anexadas por último |
| `lua_library` | string | obrigatório ao compilar | `liblua.a` |
| `lua_include` | string | obrigatório ao compilar | onde `lua.h` mora |

A linha de vinculação sempre carrega `-no-pie` e `-rdynamic`. `-no-pie` não é opcional: luaossl pede ao carregador dinâmico a imagem em execução, e um executável independente de posição não pode ser reaberto dessa forma.

`built_with` não é carregado adiante aqui. `build.plan` retorna apenas `entry`, `lua` e `native`, então um binário construído por `build.run` sempre reporta `akkar dev-1` para `--akkar-version`. Defini-lo precisa de um plano feito à mão passado para [`build.emit`](#buildemitplan).

**Retorna** `{ c = <path>, binary = <path>, modules = { lua = n, native = n } }`, ou `{ c = <path>, modules = ... }` sem `binary` quando `compile` é `false`. Retorna `nil` e um motivo quando o planejamento falha, quando a emissão falha, quando o arquivo C não pode ser aberto, ou quando o compilador se recusa (`the compiler refused (<kind> <code>): <command>`).

**Faz raise de** `akkar.build: no lua_library (the path to liblua.a)` e `akkar.build: no lua_include (the directory holding lua.h)` quando esses estão ausentes e `compile` não é `false`. Esses dois são raises, não motivos retornados, diferente de toda outra falha desta função.

```lua
local build = require "akkar.build"

local dir = "/tmp/ref_build_5"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "print 'hello'\n"
file:close()

-- `compile = false` escreve o host C e para, então nenhum compilador está envolvido.
local result, why = build.run {
  entry = dir .. "/app.lua",
  output = dir .. "/app",
  compile = false,
}
assert(result, why)
assert(result.c == dir .. "/app.c")
assert(result.binary == nil)
assert(result.modules.lua >= 1)

os.execute(("rm -rf %q"):format(dir))
```

## build.symbols_in(archive)

Lê os símbolos `luaopen_` definidos por um archive estático, executando `nm -g --defined-only`.

**Retorna** uma lista ordenada de nomes de símbolos, ou `nil` e `could not run nm: <why>`. Um archive que não existe não é um erro aqui: `nm` escreve na saída de erro padrão, que é descartada, e a lista volta vazia.

```lua no-run
local build = require "akkar.build"
local symbols = build.symbols_in "/build/cqueues.a"
-- { "luaopen__cqueues", "luaopen__cqueues_socket", ... }
```

## Não está aqui

**Resolução de dependências.** Este módulo embute os módulos sobre os quais é informado. Ele não descobre o que uma aplicação carrega.

**Compilação cruzada.** Ele constrói para a máquina em que executa.

**Bytecode.** Módulos Lua são embutidos como código-fonte. Bytecode não é portável entre versões ou tamanhos de palavra, e `akkar.vm` se recusa a carregá-lo por princípio.

**`--trace`.** O cabeçalho do módulo menciona `akkar build --trace` como a forma de descobrir o que uma aplicação carrega. Essa flag não existe, nem em `bin/akkar` nem aqui.

## Veja também

- [akkar.vm](vm.md), que se recusa a aceitar bytecode pelo mesmo motivo que este módulo não o emite
- [Colocando isso na internet](../guide/12-deploying.md), que constrói isso em uma imagem de container
- `bin/akkar`, para a linha de comando que envolve isso
- o código-fonte do módulo, `akkar/build.lua`, para o porquê da regra de nomeação ser o que é
