# akkar.watch

> **Português (Brasil)** | [Original em inglês](../../reference/watch.md)

Verifica periodicamente um conjunto de arquivos e reinicia um comando sempre
que algum deles muda. Quatro funções: três que respondem perguntas sobre o
sistema de arquivos, e um loop que as usa.

**Quando você precisa disso.** Durante o desenvolvimento, para que salvar
`app.lua` traga o servidor de volta sem precisar apertar uma tecla. Nada aqui
é alcançável a partir de `app:run`, e nada aqui pertence à produção: o
processo é parado e iniciado novamente, então uma requisição (request) em
andamento é descartada.

```lua no-run
local watch = require "akkar.watch"
```

## Índice

Todos os símbolos públicos desta página, em ordem alfabética, e o comando que
os encapsula.

| símbolo | tipo |
|---|---|
| [`akkar watch`](#linha-de-comando-akkar-watch) | comando |
| [`watch.changed`](#watchchangedbefore-after) | função |
| [`watch.files`](#watchfilesroots-pattern) | função |
| [`watch.run`](#watchruncommand-roots-options) | função |
| [`watch.snapshot`](#watchsnapshotpaths) | função |

## Linha de comando: akkar watch

```sh
akkar watch [--root DIR] [--interval SECONDS] [--pattern GLOB] -- <command>
```

| flag | valor | padrão | significado |
|---|---|---|---|
| `--root` | DIR | `.`, repetível | um diretório para monitorar |
| `--interval` | SECONDS | `0.5` | segundos entre verificações, passado por `tonumber` |
| `--pattern` | GLOB | `*.lua` | o padrão de `find -name` |
| `--` | | obrigatório | tudo que vem depois disso é o comando, unido com espaços simples |

**Grava** dois arquivos no diretório de trabalho, ambos com nomes fixos que a
linha de comando não expõe: `akkar-watch.out`, que guarda a saída padrão e o
erro padrão do processo filho, e `akkar-watch.pid`, que guarda o líder do
grupo de processos do filho. O arquivo pid é removido a cada parada e escrito
novamente a cada início.

**Imprime** o comando e as raízes quando começa:

```
akkar watch: ./myapp run app.lua
  roots: ., lib
```

e uma linha para cada reinício:

```
akkar watch: 3 file(s) changed, restarting -- ./app.lua
```

O arquivo mencionado é a primeira mudança em ordem classificada, não
necessariamente aquele que foi salvo.

**Códigos de saída.** O loop não termina sozinho: `akkar watch` roda até ser
interrompido, e não existe `--once`. Ele sai com código 2 antes de iniciar
qualquer coisa para uma opção desconhecida, para uma flag sem valor, para um
argumento solto antes de `--`, e quando nenhum comando vem depois de `--`.

## watch.changed(before, after)

Compara dois snapshots.

**Retorna** uma lista ordenada de caminhos cujo timestamp é diferente, mais
todo caminho em `before` que está ausente em `after`. Adições e remoções
contam igualmente: um caminho presente somente em `after` difere de `nil` e
aparece, e um caminho presente somente em `before` é adicionado pela segunda
passagem.

```lua
local watch = require "akkar.watch"

local before = { ["a.lua"] = 100, ["b.lua"] = 200 }
local after  = { ["a.lua"] = 100, ["b.lua"] = 201, ["c.lua"] = 300 }

local changes = watch.changed(before, after)
assert(#changes == 2)
assert(changes[1] == "b.lua")
assert(changes[2] == "c.lua")

-- Um arquivo que desapareceu também é uma mudança.
local gone = watch.changed(before, { ["a.lua"] = 100 })
assert(#gone == 1 and gone[1] == "b.lua")
```

## watch.files(roots, pattern)

Todo arquivo sob `roots` que corresponde a `pattern`. Executa `find <root>
-name <pattern> -type f`, então precisa de um shell, e uma raiz que não
existe não contribui com nada em vez de lançar um erro.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `roots` | lista de string | obrigatório | diretórios para pesquisar, cada um separadamente |
| `pattern` | string | `"*.lua"` | o padrão de `find -name` |

**Retorna** uma lista ordenada de caminhos. Duplicatas não são removidas,
então um caminho sob duas raízes sobrepostas aparece duas vezes.

```lua
local watch = require "akkar.watch"

local dir = "/tmp/ref_watch_1"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "return 1\n"
file:close()

local found = watch.files { dir }
assert(#found == 1)
assert(found[1] == dir .. "/app.lua")

os.execute(("rm -rf %q"):format(dir))
```

## watch.run(command, roots, options)

Inicia `command`, depois monitora e o reinicia sempre que algo sob `roots`
muda. O loop só termina quando `options.should_stop()` responde true, e essa
pergunta é feita no topo de cada iteração, antes do sleep.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `interval` | number | `0.5` | segundos passados para `sleep` |
| `pattern` | string | `"*.lua"` | passado para `watch.files` |
| `log` | string | `"akkar-watch.out"` | para onde vai a saída do processo filho. Nunca `/dev/null` |
| `pidfile` | string | `"akkar-watch.pid"` | onde o líder do grupo de processos do filho é registrado |
| `should_stop` | function | `function() return false end` | chamada no topo de cada iteração; uma resposta true encerra o loop |
| `on_restart` | function | nenhum | chamada com a lista de caminhos alterados, antes do stop e do start |
| `sleep` | function | `os.execute("sleep <seconds>")` | como o loop espera |
| `start` | function | `setsid sh -c 'echo $$ > pidfile; exec <command>' >log 2>&1 &` | como o processo filho é iniciado |
| `stop` | function | lê `pidfile`, envia `TERM` para o pid negativo e depois para o pid, remove `pidfile` | como o processo filho é parado |

A ordem em cada tick é: perguntar a `should_stop`, dormir, listar os
arquivos, tirar um snapshot deles, comparar. Havendo diferença: adotar o
novo snapshot, contar o reinício, chamar `on_restart`, `stop`, `start`.
`stop` também é chamada uma vez antes do primeiro `start`, e mais uma vez
depois que o loop termina.

O `sleep` padrão dispara um processo externo para `sleep(1)` em vez de usar
`cqueues.sleep`, porque o watcher precisa rodar onde nada está instalado. O
`stop` padrão mata pelo pid e nunca pela linha de comando: o comando aparece
literalmente na própria linha de comando do watcher, então uma
correspondência por padrão mataria o próprio watcher.

**Retorna** `{ restarts = <count>, watching = <number of files at the last
poll> }`.

**Não lança** nada por conta própria.

```lua
local watch = require "akkar.watch"

local dir = "/tmp/ref_watch_2"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "return 1\n"
file:close()

-- Todo efeito colateral é substituído, então nada é gerado e nada é morto.
local started, stopped, ticks = {}, 0, 0
local report = watch.run("./myapp run app.lua", { dir }, {
  sleep = function() end,
  start = function(cmd) started[#started + 1] = cmd end,
  stop  = function() stopped = stopped + 1 end,
  should_stop = function()
    ticks = ticks + 1
    if ticks == 2 then
      local added = assert(io.open(dir .. "/second.lua", "w"))
      added:write "return 2\n"
      added:close()
    end
    return ticks > 4
  end,
})

assert(report.restarts == 1)
assert(report.watching == 2)
assert(#started == 2)          -- o primeiro start, e o que vem depois da mudança
assert(stopped == 3)           -- antes do primeiro start, no reinício, no final

os.execute(("rm -rf %q"):format(dir))
```

Executar isso com os padrões gera um grupo de processos desanexado, grava
`akkar-watch.pid` e `akkar-watch.out` no diretório de trabalho, e não
retorna.

## watch.snapshot(paths)

O horário de modificação de cada caminho, lido com `stat -c %Y`. Executa um
processo por caminho.

**Retorna** uma tabela que mapeia cada caminho para um número, ou para `nil`
onde `stat` não respondeu nada, que é como se parece um arquivo que foi
apagado entre o `find` e o `stat`.

`stat` em vez de ler o arquivo: abrir um arquivo que o editor está no meio de
escrever dá uma leitura truncada, e um watcher que reinicia a cada
salvamento parcial reinicia duas vezes por tecla pressionada.

```lua
local watch = require "akkar.watch"

local dir = "/tmp/ref_watch_3"
os.execute(("rm -rf %q && mkdir -p %q"):format(dir, dir))
local file = assert(io.open(dir .. "/app.lua", "w"))
file:write "return 1\n"
file:close()

local seen = watch.snapshot { dir .. "/app.lua", dir .. "/absent.lua" }
assert(type(seen[dir .. "/app.lua"]) == "number")
assert(seen[dir .. "/absent.lua"] == nil)

os.execute(("rm -rf %q"):format(dir))
```

## Não está aqui

**inotify.** Verificação periódica com `stat`, duas vezes por segundo por
padrão. inotify significaria menos syscalls e mais uma dependência em C, num
projeto cuja proposta de build é justamente ter menos dependências dessas.

**Hot swapping.** Isto para e inicia um processo. `App:swap_host` substitui
uma aplicação em execução no próprio lugar e é um recurso diferente, com uma
resposta ainda não definida para o ciclo de vida de capability.

**Um caminho configurável de log ou pid na linha de comando.** `watch.run`
aceita `options.log` e `options.pidfile`; `akkar watch` não passa nenhum dos
dois, então a linha de comando sempre usa `akkar-watch.out` e
`akkar-watch.pid`.

## Veja também

- [akkar.build](build.md), para o binário que isto reinicia
- [akkar](akkar.md), para `app:swap_host`, que é o hot swapping que isto não é
- `bin/akkar`, para a linha de comando que o encapsula
- o código-fonte do módulo, `akkar/watch.lua`, para entender por que ele mata
  pelo pid e não por padrão
