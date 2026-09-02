# akkar.vm

> **Português (Brasil)** | [Original em inglês](../../reference/vm.md)

Executa Lua não confiável dentro deste processo, sob um ambiente curado, um orçamento de instruções e um teto de memória. O chunk é carregado apenas como texto, nunca como bytecode.

**Quando você precisa disso.** Um cliente publica um hook, uma regra de validação ou um campo computado, e isso precisa rodar aqui sem ler o sistema de arquivos, abrir um socket, girar para sempre ou alcançar a aplicação ao redor. Se o código for hostil, e não apenas não confiável, rode-o em um processo separado com um sandbox em nível de sistema operacional.

```lua no-run
local vm = require "akkar.vm"
```

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`vm.base_environment`](#vmbase_environment) | função |
| [`vm.compile`](#vmcompilesource-options) | função |
| [`vm.eval`](#vmevalsource-options-) | função |
| [`vm.harden`](#vmharden) | função |
| [`vm.run`](#vmrunchunk-limits-) | função |

## O ambiente que um chunk vê

| presente | notas |
|---|---|
| `assert`, `error`, `ipairs`, `next`, `pairs`, `select`, `tonumber`, `tostring`, `type` | como eles mesmos |
| `rawequal`, `rawlen`, `rawget`, `rawset`, `setmetatable`, `getmetatable` | como eles mesmos |
| `unpack` | é `table.unpack` |
| `pcall`, `xpcall` | wrappers que relançam o erro depois de um estouro de orçamento |
| `math` | uma cópia, com `math.randomseed` substituída por uma função que não faz nada |
| `table` | uma cópia |
| `string` | uma cópia, com `string.dump` removida e `string.rep` apontando para a versão limitada |
| `os` | apenas `time`, `clock`, `date`, `difftime` |
| `_G` | o próprio ambiente, então `_G.x = 1` fica contido |

| ausente | por quê |
|---|---|
| `io`, `dofile` | o sistema de arquivos |
| `require` | alcança todo módulo do processo, incluindo os do próprio akkar |
| `load` | construiria um chunk com um `_ENV` diferente, ou com bytecode |
| `debug` | `sethook`, `getlocal`, `getupvalue` desfazem tudo isso |
| `coroutine` | um hook é instalado por coroutine, então uma nova roda sem ser medida |
| `collectgarbage` | pode parar o coletor do qual o teto de memória depende |

## vm.base_environment()

Constrói uma nova cópia da tabela acima.

**Retorna** uma tabela. Cada chamada retorna uma nova, então alterar o resultado não afeta mais nada.

```lua
local vm = require "akkar.vm"

local env = vm.base_environment()
assert(type(env.math.floor) == "function")
assert(env.io == nil)
assert(env.require == nil)
assert(env.coroutine == nil)
assert(env.load == nil)
assert(env.string.dump == nil)
assert(env._G == env)
```

## vm.compile(source, options)

Carrega `source` como um chunk vinculado a um ambiente de sandbox. Chama `vm.harden()` e instala o limite sobre o `string.rep` real como efeito colateral.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `env` | table | `vm.base_environment()` | substitui o ambiente por completo |
| `expose` | table | `{}` | copiado para dentro do ambiente depois que ele é construído, então soma ao ambiente padrão |
| `name` | string | `"sandbox"` | o nome do chunk nas mensagens de erro, usado como `=<name>` |
| `max_string` | number | `1048576` | a maior string que `string.rep` pode construir enquanto este chunk roda |

O modo de carregamento é `"t"` e não há como pedir outro.

**Retorna** a função compilada, ou `nil` e `akkar.vm: could not compile: <message>`.

**Levanta** `akkar.vm.compile needs source as a string; got <type>` quando `source` não é uma string. Um erro de sintaxe é um motivo retornado, não uma exceção levantada.

```lua
local vm = require "akkar.vm"

local chunk = assert(vm.compile("return greeting .. ' world'", {
  expose = { greeting = "hello" },
  name = "tenant-hook",
}))
local ok, value = vm.run(chunk)
assert(ok)
assert(value == "hello world")

local bad, why = vm.compile "this is not lua"
assert(bad == nil)
assert(why:find("akkar.vm: could not compile", 1, true) == 1)
```

## vm.eval(source, options, ...)

Compila e executa em uma única chamada. `options` é passado para `vm.compile`, e `options.limits` é passado para `vm.run` como seus limites. Argumentos extras vão para o chunk.

**Retorna** os mesmos três valores que `vm.run` retorna. Uma falha de compilação volta como `false, <reason>, {}`, com um relatório vazio em vez de um que carregue `instructions` e `peak_kb`.

```lua
local vm = require "akkar.vm"

local ok, value, report = vm.eval("local a, b = ... return a + b", {}, 2, 40)
assert(ok == true)
assert(value == 42)
assert(type(report.instructions) == "number")

local bad, why, empty = vm.eval "return ("
assert(bad == false)
assert(why:find("could not compile", 1, true))
assert(next(empty) == nil)
```

## vm.harden()

Define `__metatable` na metatable compartilhada de strings como a string `"string metatable is not available"`, depois do que `getmetatable("")` retorna essa string em vez da tabela.

**Retorna** `true`, sempre. É idempotente, e nunca reduz uma proteção que outra parte já tenha definido: ele escreve `__metatable` apenas onde esse campo está atualmente `nil`.

Essa é uma mudança em escala de processo sobre um tipo global. Ela é feita no primeiro uso, e não no momento do `require`, e `vm.compile` a chama, então quase ninguém precisa chamá-la diretamente.

```lua no-run
local vm = require "akkar.vm"
vm.harden()
-- getmetatable("") agora retorna "string metatable is not available"
```

## vm.run(chunk, limits, ...)

Executa um chunk compilado com um hook de contagem instalado. Argumentos extras são passados para o chunk.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `instructions` | number | `10e6` | o orçamento. Excedê-lo levanta um erro dentro do chunk |
| `memory_kb` | number | `8192` | crescimento acima da leitura feita na entrada, em KB. Excedê-lo levanta um erro dentro do chunk |
| `check_every` | number | `1000` | quantas instruções da VM entre disparos do hook, e a quantidade que `instructions` soma a cada disparo |

**Retorna** três valores, sempre, nesta ordem:

1. `ok`, um booleano.
2. o **primeiro** valor de retorno do chunk quando `ok`, ou o erro quando não.
3. `report`.

| campo do relatório | significado |
|---|---|
| `instructions` | `check_every` multiplicado pelo número de disparos do hook. É `0` para um chunk que termina antes do primeiro disparo |
| `peak_kb` | o maior crescimento sobre a leitura de entrada observado em um disparo do hook |
| `exceeded` | `nil`, `"instruction budget"` ou `"memory ceiling"` |
| `results` | presente apenas quando `ok`: tudo que o chunk retornou, como uma tabela empacotada com `n` |

Só o primeiro valor de retorno fica na posição dois, porque o relatório precisa ter uma posição fixa para ser utilizável.

**Levanta** `akkar.vm.run needs a compiled chunk; got <type>` quando `chunk` não é uma função. Tudo mais que o chunk fizer volta como `false` e uma mensagem.

**As mensagens de estouro** são `akkar.vm: instruction budget of <n> exhausted` e `akkar.vm: memory ceiling of <n> KB exceeded (<m> KB)`.

Um chunk não consegue capturar seu próprio estouro e continuar rodando. O `pcall` e o `xpcall` do sandbox relançam o erro assim que o estado da execução indica que o orçamento acabou, então `while true do pcall(function() while true do end end) end` ainda termina. Erros comuns continuam capturáveis.

O hook que estava instalado antes da execução é restaurado depois, e o estado da execução é indexado pela coroutine em execução, então dois tenants rodando o mesmo chunk compilado não conseguem ver o teto um do outro nem limpar a flag um do outro.

```lua
local vm = require "akkar.vm"

local chunk = assert(vm.compile "return 1, 2, 3")
local ok, first, report = vm.run(chunk)
assert(ok == true)
assert(first == 1)
assert(report.results.n == 3)
assert(report.results[3] == 3)
assert(report.exceeded == nil)

-- Um orçamento que se esgota.
local spin = assert(vm.compile "while true do end")
local finished, why, spent = vm.run(spin, { instructions = 50000 })
assert(finished == false)
assert(spent.exceeded == "instruction budget")
assert(why:find("instruction budget of 50000 exhausted", 1, true))

-- E ele não pode ser engolido.
local greedy = assert(vm.compile "while true do pcall(function() while true do end end) end")
local caught = vm.run(greedy, { instructions = 50000 })
assert(caught == false)
```

## Efeitos em escala de processo

Duas coisas sobrevivem ao sandbox, e as duas acontecem na primeira vez que `vm.compile` roda.

**A metatable de strings é fechada**, por `vm.harden()`. A partir daí, `getmetatable("")` no host responde com uma string.

**O `string.rep` real é envolvido por um wrapper.** Esse wrapper só verifica um limite enquanto um sandbox está rodando na coroutine atual, e nos demais casos apenas repassa a chamada, então o código do host não é afetado. Ele existe porque `("x"):rep(n)` resolve, através da metatable compartilhada de strings, para a biblioteca real, e nunca para a cópia do sandbox, então limitar só a cópia não limitaria nada.

Dentro de um sandbox que excedeu seu `max_string`, a mensagem é `string.rep would build <n> bytes; the limit is <m>`.

## O que não está aqui

**Um estado Lua separado.** O Lua 5.4 não tem como criar uma VM isolada a partir do próprio Lua. Isso exige C ou um subprocesso.

**Bytecode.** O carregamento é sempre `"t"`. Bytecode malicioso escapa de todo sandbox já escrito.

**Um tempo-limite de tempo real (wall-clock).** O orçamento é em instruções, não em segundos, e uma única instrução pode fazer um trabalho ilimitado: `("x"):rep(2^30)` aloca um gigabyte antes que o hook dispare de novo. `string.rep` é limitado exatamente por isso; mais nada é.

**Um limite em `string.format`.** Ele existia aqui e foi removido. O Lua 5.4 rejeita qualquer largura igual ou maior que 100 como uma especificação de conversão inválida, então uma única diretiva pode produzir, no máximo, 99 bytes.

**Uma fronteira de segurança contra um atacante determinado que compartilhe seu processo.** Isso está dito claramente no próprio cabeçalho do módulo, e repetido aqui.

## Veja também

- [akkar.build](build.md), que também recusa bytecode, e pelo mesmo motivo
- o código-fonte do módulo, `akkar/vm.lua`, para as três fugas e por que o estado da execução é por coroutine
