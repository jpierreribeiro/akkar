# akkar.strict

> **Português (Brasil)** | [Original em inglês](../../reference/strict.md)

Coloca uma metatabela em `_G` para que ler ou escrever uma global não declarada
levante um erro. Cinco funções e nenhuma configuração.

**Quando você precisa disso.** No desenvolvimento e na suíte de testes, onde
um erro de digitação que cria silenciosamente uma global é um bug que você
quer encontrar agora. Em um servidor isso é pior que um erro de digitação: uma
global escrita dentro de um handler sobrevive à requisição (request) e fica
visível para a próxima, para outro usuário.

```lua no-run
local strict = require "akkar.strict"
```

## strict.active()

**Retorna** `true` quando a verificação está instalada, `false` quando não
está.

```lua
local strict = require "akkar.strict"
assert(strict.active() == false)
local key = strict.on()
assert(strict.active() == true)
strict.off(key)
assert(strict.active() == false)
```

## strict.declare(...)

Marca um ou mais nomes como declarados, de modo que lê-los ou escrevê-los é
permitido. Aceita qualquer quantidade de strings.

**Retorna** nada.

Funciona esteja a verificação ligada ou não: o conjunto de declarados é estado
do módulo e só é consultado enquanto `strict.on()` estiver em vigor. Declarar
um nome nunca desdeclara outro, e não existe forma de desdeclarar um nome.

```lua
local strict = require "akkar.strict"

local key = strict.on()
strict.declare("counter", "registry")
counter = 0
registry = {}
assert(counter == 0)
strict.off(key)
```

## strict.declared(name)

**Retorna** `true` quando `name` está no conjunto de declarados, `false` caso
contrário. A comparação é feita exatamente contra `true`, então isso é sempre
um booleano.

Observe o que o conjunto contém depois de `strict.on()`: toda chave que estava
em `_G` naquele momento, ou seja, toda a biblioteca padrão mais qualquer coisa
que o programa tenha configurado antes de decidir ser estrito.

```lua
local strict = require "akkar.strict"

local key = strict.on()
assert(strict.declared "print" == true)     -- já estava em _G no momento do snapshot
assert(strict.declared "mystery" == false)
strict.declare "mystery"
assert(strict.declared "mystery" == true)
strict.off(key)
```

## strict.off(key)

Recoloca a metatabela que `_G` tinha antes de `strict.on()` instalar a sua
própria.

Recebe a `key` que `strict.on()` retornou e **levanta erro** sem ela. O modo
estrito é de escopo do processo inteiro, então `off` costumava ser um
interruptor que qualquer handler no processo conseguia acionar: qualquer um
deles podia desligar a verificação para o servidor inteiro e para todas as
outras requisições nele. Desligar agora pertence a quem ligou.

**Retorna** o módulo, para que as chamadas se encadeiem. Retorna imediatamente
se a verificação não está ativa, com key ou sem key.

Só a metatabela que este módulo instalou é removida. Se algo mais a substituiu
nesse meio tempo, essa outra é deixada onde está em vez de removida, a mesma
cautela que `strict.on()` demonstra ao entrar.

O conjunto de declarados sobrevive. Desligar a verificação e ligar de novo não
esquece o que foi declarado, e o segundo `strict.on()` tira um novo snapshot
de `_G` em cima disso.

```lua
local strict = require "akkar.strict"

local key = strict.on()
assert(select(1, pcall(strict.off)) == false)        -- sem key, sem interruptor
assert(select(1, pcall(strict.off, {})) == false)    -- e não qualquer tabela
assert(strict.active() == true)

strict.off(key)
undeclared_and_fine = 1          -- sem metatabela, então sem erro
assert(undeclared_and_fine == 1)
```

## strict.on()

Tira um snapshot do conteúdo atual de `_G` como declarado, depois instala
`__newindex` e `__index` em `_G`.

**Retorna** a key que `strict.off` exige. Idempotente: uma segunda chamada
enquanto ativo não faz nada, inclusive não tira um segundo snapshot, e devolve
a mesma key.

**Levanta erro** quando `_G` já carrega uma metatabela que outra coisa
instalou. Substituí-la quebraria silenciosamente o que quer que dependesse
dela, um lazy loader de um ORM, o autocomplete de um REPL, em algum lugar
longe daqui, então duas bibliotecas disputando a tabela global é reportado
como o erro de configuração que é, em vez de resolvido silenciosamente.

**Levanta erro**, vindo dos metamétodos instalados em vez de desta chamada:

Ao escrever uma global não declarada, no nível 2 para que a posição apontada
seja a de quem chamou:

```
assignment to undeclared global 'counter' at app.lua:12
  a global written in a handler outlives the request and is visible to the next one
  did you mean `local counter`?  to declare it on purpose: require('akkar.strict').declare('counter')
```

Ao ler uma:

```
read of undeclared global 'mystery' at app.lua:12
  most often a typo in a local name, or a module someone forgot to require
```

A posição depois de `at` vem de `debug.getinfo`, e é `?` quando não há frame
para ler.

```lua
local strict = require "akkar.strict"

local key = strict.on()

local ok, why = pcall(function() undeclared = 1 end)
assert(ok == false)
assert(why:find("assignment to undeclared global 'undeclared'", 1, true))

local read_ok, read_why = pcall(function() return also_undeclared end)
assert(read_ok == false)
assert(read_why:find("read of undeclared global 'also_undeclared'", 1, true))

strict.off(key)
```

## O que não está aqui

**Um escopo por módulo ou por corrotina.** A metatabela está em `_G`, então a
verificação é de escopo do processo inteiro, e o conjunto de declarados
também.

**Uma forma de desdeclarar um nome.** `strict.declare` só adiciona.

**Instalação automática.** Fazer `require` do módulo não muda nada. O akkar
liga isso no desenvolvimento e na suíte de testes, e deixa desligado em
produção a menos que seja pedido, porque um falso positivo que derruba um
servidor em produção é pior que o bug que ele estava procurando.

**Uma lista do que está declarado.** `strict.declared(name)` responde sobre um
nome de cada vez; o conjunto em si não é exportado.

## Veja também

- [akkar](akkar.md), que reexporta este módulo como `akkar.strict`
- `spec/000_strict_first_spec.lua`, nomeado assim para rodar antes de qualquer
  outra coisa
- o código-fonte do módulo, `akkar/strict.lua`, para entender por que o
  snapshot é tirado em `on()` em vez de no momento do `require`
