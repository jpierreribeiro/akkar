# akkar.etag

> **Português (Brasil)** | [Original em inglês](../../reference/etag.md)

Requisições (requests) condicionais via ETags HTTP. O módulo marca respostas bem-sucedidas com uma tag, responde `304` a um cliente que já tem a versão atual e recusa uma escrita cujo `If-Match` não corresponde mais, com `412`.

**Quando você precisa disso.** Dois clientes leem o mesmo registro, ambos editam, ambos salvam, e a segunda escrita sobrescreve silenciosamente a primeira sem erro nenhum. Este módulo transforma isso em um `412` que o segundo cliente consegue ver.

```lua no-run
local etag = require "akkar.etag"
```

`akkar.etag` é `etag.new` e `akkar.etag_of` é `etag.of`, então o middleware fica acessível sem um segundo `require`.

## etag.canonical(value)

Codifica `value` como JSON com as chaves do objeto ordenadas. `pairs()` não tem ordem definida em Lua, então a codificação simples de uma tabela pode produzir bytes diferentes em execuções diferentes e, portanto, tags diferentes. Arrays e tabelas vazias são codificados como `[]`.

**Retorna** uma string.

## etag.fnv1a(s)

FNV-1a sobre `s`, 64 bits, formatado como 16 dígitos hexadecimais em minúsculas. Não é um hash criptográfico e não pretende ser um.

**Retorna** uma string de 16 caracteres.

## etag.matches(header, tag)

Testa um valor de cabeçalho `If-Match` ou `If-None-Match` contra uma tag. `*` corresponde a qualquer coisa. Uma lista separada por vírgulas é dividida e cada candidato é aparado. Um validador fraco (`W/"x"`) nunca corresponde, porque a RFC 7232 proíbe usar um deles em uma escrita condicional.

**Retorna** um booleano.

## etag.new(options)

Middleware. Verifica as precondições antes do handler rodar e marca a resposta depois que ele retorna.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `require_on` | lista de strings | `{}` | métodos que precisam trazer `If-Match`; uma requisição sem ele responde `428` |
| `current` | function(req) | nenhum | lê o recurso como ele está agora, para que sua tag possa ser comparada com `If-Match` |

Os nomes dos métodos em `require_on` são colocados em maiúsculas, então `{ "put" }` e `{ "PUT" }` são a mesma lista. `GET` e `HEAD` são tratados como seguros e pulam toda verificação de precondição.

`current` é obrigatório na prática, não só quando você quer rigor. Quando `If-Match` está presente e nenhum `current` está configurado, a tag atual é `nil` e a requisição é recusada com `412` seja lá o que o cliente tenha enviado, incluindo `If-Match: *`. Configure `current` em qualquer rota alcançável por uma escrita condicional.

Comportamento, na ordem em que o middleware o aplica:

- método inseguro, listado em `require_on`, sem `If-Match`: `428` com corpo
  `{ error = "this request requires an if-match header", hint = "read the resource first and send the etag it returned" }`
- método inseguro com `If-Match` que não corresponde a `etag.of(current(req))`:
  `412` com corpo `{ error = "the resource has changed since you read it" }`
- o handler roda; uma resposta com status entre 200 e 299 e um `body` não nulo recebe um cabeçalho `etag`
- método seguro cujo `If-None-Match` corresponde a essa tag: `304` com o cabeçalho `etag` e sem corpo

A resposta marcada é uma cópia. A tabela que o handler retornou nunca é alterada, então um handler que retorna uma resposta içada ou memorizada não vaza a tag de uma requisição para a resposta de outra.

**Retorna** uma `function(req, next)`.

```lua
local akkar = require "akkar"

local document = { title = "the plan" }

local app = akkar.new()

app:use(akkar.etag {
  require_on = { "PUT" },
  current = function() return document end,
})

app:get("/document", function() return document end)

app:put("/document", { body = { title = "string" } }, function(req)
  document = { title = req.body.title }
  return document
end)

local client = app:test {}

local read = client:get "/document"
local tag = read.headers["etag"]

-- A mesma versão de novo: 304, e sem corpo.
local again = client:get("/document", { headers = { ["if-none-match"] = tag } })
print(again.status)                                   --> 304

-- Uma escrita sem `if-match`, em um método listado em `require_on`.
print(client:put("/document", { body = { title = "a new plan" } }).status)
--> 428

-- Uma escrita carregando uma tag que não é mais a atual.
print(client:put("/document", {
  body = { title = "a new plan" },
  headers = { ["if-match"] = '"0000000000000000"' },
}).status)                                            --> 412

-- Uma escrita carregando a tag que a leitura retornou.
print(client:put("/document", {
  body = { title = "a new plan" },
  headers = { ["if-match"] = tag },
}).status)                                            --> 200
```

## etag.of(body)

A tag de um corpo de resposta: `canonical` e depois `fnv1a`, envolvida em aspas duplas porque a RFC 7232 define uma entity-tag como uma string entre aspas.

**Retorna** uma string entre aspas de 16 dígitos hexadecimais, ou `nil` quando `body` é `nil` ou quando codificá-lo gera um erro. `etag.of` nunca gera erro.

```lua
local etag = require "akkar.etag"

print(etag.canonical { b = 2, a = 1 })    --> {"a":1,"b":2}
print(etag.of { a = 1, b = 2 })           --> "a0ebc03bdc71de7b"
print(etag.of { b = 2, a = 1 })           --> "a0ebc03bdc71de7b"
print(etag.of(nil))                       --> nil

local tag = etag.of { a = 1 }
print(etag.matches("*", tag))             --> true
print(etag.matches('"x", ' .. tag, tag))  --> true
print(etag.matches("W/" .. tag, tag))     --> false
```

## O que não está aqui

- **Uma versão de linha.** A tag é derivada do corpo da resposta, então duas edições que produzem o mesmo corpo são indistinguíveis, e uma sequência A-depois-B-depois-A pode deixar passar uma escrita obsoleta. A forma forte é uma coluna de versão que o banco de dados incrementa dentro da mesma transação da escrita, e só a aplicação sabe qual é essa coluna.
- **Verificação de nome de opção.** `etag.new` lê os dois campos acima e ignora todo o resto, então uma opção com nome errado passa em silêncio.
- **`If-Match` em um método seguro.** `GET` e `HEAD` pulam completamente o trecho de precondição.
- **Tags de arquivo.** `akkar.static` calcula suas próprias tags a partir de `mtime` e tamanho. Veja [static](static.md).

## Veja também

- [akkar](akkar.md) para `app:use`, `akkar.response` e `app:test`
- [compress](compress.md), que renomeia a tag quando codifica um corpo, e precisa ser registrado fora deste middleware
- o código-fonte do módulo, `akkar/etag.lua`, para entender por que 428 é tratado como a linha entre um recurso e um invariante
