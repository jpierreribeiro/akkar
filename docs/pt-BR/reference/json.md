# akkar.json

> **Português (Brasil)** | [Original em inglês](../../reference/json.md)

O serializador por trás de um contrato. Tudo no akkar que transforma um valor Lua
em JSON, ou texto JSON em um valor Lua, passa por este módulo em vez de
passar diretamente por uma biblioteca JSON.

**Quando você precisa dele.** Quando uma lista vazia precisa ser codificada como `[]` e não `{}`, quando um
`null` de JSON decodificado precisa ser diferenciado de uma chave ausente, ou quando você está
substituindo a biblioteca JSON usada por todo o processo.

```lua no-run
local json = require "akkar.json"
```

Os mesmos valores são reexportados a partir do módulo de nível superior: `akkar.json` é este
módulo, `akkar.null` é `json.null`, `akkar.array` é `json.array` e
`akkar.empty_array` é `json.empty_array`. As duas grafias representam o mesmo valor.

## Conteúdo

- [json.array(value)](#jsonarrayvalue)
- [json.decode(text)](#jsondecodetext)
- [json.empty_array](#jsonempty_array)
- [json.encode(value)](#jsonencodevalue)
- [json.implementation()](#jsonimplementation)
- [json.null](#jsonnull)
- [json.use(replacement)](#jsonusereplacement)

## json.array(value)

Marca uma tabela como um array JSON, de modo que uma tabela **vazia** seja codificada como `[]` em vez de
`{}`. Define a metatable de array do serializador atual em `value` e retorna a mesma
tabela. `value` pode ser omitido, e nesse caso uma nova tabela vazia é marcada.

Uma tabela que já tem elementos é codificada como um array mesmo sem isso, então o
marcador só muda o comportamento no caso vazio.

**Retorna** a tabela recebida, com uma metatable definida nela.

**Levanta** nada.

```lua
local json = require "akkar.json"

local rows = {}
assert(json.encode({ tasks = rows })            == '{"tasks":{}}')
assert(json.encode({ tasks = json.array(rows) }) == '{"tasks":[]}')

-- Tabelas que já não estão vazias são codificadas como arrays.
assert(json.encode(json.array { 1, 2, 3 }) == "[1,2,3]")

-- Chamado sem argumento, cria uma nova tabela marcada.
assert(json.encode(json.array()) == "[]")
```

O marcador vive na tabela, então ele não sobrevive a um ciclo de codificação e decodificação:
`json.decode('{"tasks":[]}').tasks` é uma tabela vazia comum e
é recodificada como `{}`.

## json.decode(text)

Transforma texto JSON em um valor Lua chamando o `decode` do serializador atual.

**Retorna** o valor decodificado.

**Levanta** o que quer que o serializador levante em uma entrada malformada. Com o padrão
(`cjson`) isso é um erro cuja mensagem indica a posição.

```lua
local json = require "akkar.json"

local value = json.decode '{"id":1,"tags":["a","b"]}'
assert(value.id == 1)
assert(value.tags[2] == "b")

local ok = pcall(json.decode, "{not json}")
assert(ok == false)
```

## json.empty_array

Uma tabela vazia já marcada por `json.array`, pronta para ser retornada por um handler.

Ela é construída uma única vez, quando o módulo é carregado. Um serializador instalado depois com
`json.use` não a altera: ela mantém o marcador do serializador que estava
ativo no momento do carregamento.

```lua
local json = require "akkar.json"

assert(json.encode(json.empty_array) == "[]")
assert(json.encode({ tasks = json.empty_array }) == '{"tasks":[]}')
```

Não insira nada nela. É uma única tabela compartilhada, então tudo que for colocado ali é visto por
todo mundo que a chamar. Use `json.array {}` para uma tabela que você pretende preencher.

## json.encode(value)

Transforma um valor Lua em texto JSON chamando o `encode` do serializador atual.

**Retorna** uma string.

**Levanta** o que quer que o serializador levante. Com o padrão isso inclui um
valor que ele não consegue representar, como uma função, e uma tabela com chaves de array e
de objeto ao mesmo tempo.

```lua
local json = require "akkar.json"

assert(json.encode { ok = true } == '{"ok":true}')
assert(json.encode { 1, 2 } == "[1,2]")

local ok = pcall(json.encode, { f = print })
assert(ok == false)
```

A ordem das chaves em um objeto codificado não é definida e não é estável entre
processos. Não compare duas codificações da mesma tabela quanto à igualdade.

## json.implementation()

Retorna o serializador atualmente instalado. Ele existe para o único chamador que
legitimamente precisa disso: um teste que verifica qual serializador está em uso.

**Retorna** a tabela do serializador.

**Levanta** nada.

```lua no-run
local json = require "akkar.json"
assert(json.implementation() == require "cjson")
```

## json.null

O valor que um `null` de JSON decodificado se torna. Com o serializador padrão ele é
o sentinela de null do cjson, um userdata.

`nil` não está disponível para isso, porque um campo `nil` não pode ser diferenciado
de uma chave ausente, e essa é a diferença entre "defina este campo como null" e
"não toque neste campo". Compare por identidade.

`json.use` faz `json.null` apontar de novo para o sentinela do novo serializador. `akkar.null`
é capturado uma única vez quando `akkar` é carregado e **não** é reapontado, então uma troca depois
disso deixa as duas grafias com valores diferentes. Faça a troca no boot, antes
que qualquer coisa esteja usando qualquer uma das duas.

```lua
local json = require "akkar.json"

local body = json.decode '{"nickname":null}'
assert(body.nickname == json.null)      -- presente, e explicitamente nulo
assert(body.missing  == nil)            -- ausente

assert(json.encode { nickname = json.null } == '{"nickname":null}')
```

## json.use(replacement)

Instala um serializador para o processo inteiro. Somente no boot, antes de `app:run`.

`replacement` precisa responder a `encode` e `decode` como funções e precisa declarar
`null`. Nada mais é verificado.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `encode` | function | obrigatório | `encode(value)` retorna texto JSON |
| `decode` | function | obrigatório | `decode(text)` retorna um valor Lua |
| `null` | any non-nil | obrigatório | o valor que um null de JSON decodificado se torna |
| `array_mt` | table | não verificado | a metatable que `json.array` define; veja abaixo |

**Retorna** o serializador anterior, para que quem chamou possa restaurá-lo.

**Levanta**

- quando `encode` não é uma função:
  `akkar.json: a serializer must answer :encode`
- quando `decode` não é uma função:
  `akkar.json: a serializer must answer :decode`
- quando `null` é nil:
  `akkar.json: a serializer must declare ...`, o texto completo nomeando `null` como
  o valor que um null de JSON decodificado se torna e dizendo que nil não está disponível para isso

```lua
local json = require "akkar.json"

-- Capture o atual PRIMEIRO. Lê-lo de volta dentro do próprio `encode` do
-- substituto chamaria o substituto, o que nunca terminaria.
local inner = json.implementation()

local counted = 0
local previous = json.use {
  encode   = function(value) counted = counted + 1 return inner.encode(value) end,
  decode   = inner.decode,
  null     = inner.null,
  array_mt = inner.array_mt,
}

assert(json.encode { ok = true } == '{"ok":true}')
assert(counted == 1)

json.use(previous)
assert(json.implementation() == previous)
```

`array_mt` não é validado, e `json.array` lê esse campo. Um serializador instalado
sem um faz de `json.array` uma operação inócua: `setmetatable(t, nil)` é bem-sucedido, e uma
tabela vazia marcada volta a ser codificada como `{}` sem erro nenhum em lugar nenhum. Carregue
`array_mt` junto em qualquer substituto.

## O que não está aqui

- **Uma tradução de sentinelas null na entrada.** Percorrer cada corpo decodificado
  para substituir nulls foi medido em 1,47x o tempo de uma requisição (request) e removido. O sentinela
  está no contrato em vez disso.
- **Um formatador legível, um parser em streaming, ou um schema.** A validação de requisição é
  `app:post(path, options, handler)` em [akkar](akkar.md).
- **Serializadores por requisição ou por app.** `json.use` vale para o processo inteiro.

## Veja também

- [akkar](akkar.md) para `akkar.null`, `akkar.array` e `akkar.empty_array`,
  que são esses valores sob seus nomes de nível superior
- [akkar.idempotency](idempotency.md), que armazena uma resposta (response) codificando-a
  e a reproduz decodificando-a, então um corpo reproduzido é o resultado do ciclo de JSON
  do original
- o código-fonte do módulo, `akkar/json.lua`, para entender por que o sentinela está no contrato
  em vez de estar escondido atrás dele
