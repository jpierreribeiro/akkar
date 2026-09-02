# akkar.idempotency

> **Português (Brasil)** | [Original em inglês](../../reference/idempotency.md)

Middleware que lembra a resposta de uma requisição (request) que carrega um cabeçalho `Idempotency-Key`, de forma que a mesma requisição enviada duas vezes seja executada apenas uma vez. Deduplicação na porta de entrada, não um handler idempotente.

**Quando você precisa disso.** Quando um cliente reenvia um `POST` para o qual nunca recebeu resposta (response) (uma conexão caiu, um proxy expirou) e executar o handler pela segunda vez cobraria um cartão duas vezes ou criaria uma segunda linha.

```lua no-run
local idempotency = require "akkar.idempotency"
```

A grafia de nível superior é o construtor, não o módulo: `akkar.idempotency` é `idempotency.new`, então `akkar.idempotency { namespace = false }` e `idempotency.new { ttl = 86400 }` constroem o mesmo middleware. `fingerprint_of` e `CLAIM_SCRIPT` só são acessíveis via `require "akkar.idempotency"`.

## idempotency.CLAIM_SCRIPT

O script Lua do Redis que reivindica, reproduz ou recusa, como uma string. Exportado para que um teste possa fazer uma asserção sobre ele. Lê-lo não faz parte do uso do módulo.

A decisão inteira é um único script porque a nova tentativa que importa é aquela que chega enquanto a primeira requisição ainda está em execução.

```lua
local idempotency = require "akkar.idempotency"
assert(type(idempotency.CLAIM_SCRIPT) == "string")
```

## idempotency.fingerprint_of(req)

Constrói o resumo de uma requisição que decide se uma chave reutilizada nomeia a mesma requisição. É
`req.method .. " " .. req.path .. " " .. #body .. ":" .. sha256_hex(body)`,
em que `body` é a codificação canônica de `req.body`, ou `""` quando `req.body`
é nil. O corpo inteiro é submetido a hash, então nenhuma parte dele fica fora da comparação.

Não é um hash criptográfico. Ele separa a nova tentativa de um cliente honesto do erro de um cliente honesto, e não é uma defesa contra alguém que já escolhe a chave.

**Retorna** uma string.

**Levanta** nada. Um corpo que não pode ser codificado recorre a `tostring(req.body)`.

```lua
local idempotency = require "akkar.idempotency"

local print_ = idempotency.fingerprint_of {
  method = "POST", path = "/charges", body = { amount = 100 },
}
assert(print_ ==
  "POST /charges 14:" ..
  "4d4bbe59c6aad22442cde199a6a8a5f034405fcd78fb5a81c24ef249de1c45f1")

-- Mesmo sem nenhum corpo, ainda há fingerprint: o digest da string vazia.
assert(idempotency.fingerprint_of { method = "POST", path = "/charges" } ==
  "POST /charges 0:" ..
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
```

Dois limites costumavam decorrer do formato, e ambos desapareceram; eles são registrados aqui porque um leitor que os aprendeu em outro lugar deve saber que eles não valem mais.

Apenas os primeiros 512 bytes do corpo codificado eram comparados, então dois corpos longos de mesmo tamanho que concordassem nos primeiros 512 bytes eram considerados uma única requisição, e a segunda era respondida com a resposta armazenada da primeira, junto com
`idempotent-replay: true`. Agora o corpo inteiro é submetido a hash, então uma diferença em qualquer ponto dele é uma diferença aqui.

E a ordem das chaves na codificação era a do `cjson`, que não é estável entre processos, então um mesmo corpo codificado por dois workers produzia dois fingerprints diferentes, e uma nova tentativa que caísse no outro worker era respondida com `422`. O `canonical` ordena as chaves, então isso não acontece mais.

O que continua verdadeiro é a frase acima: isto não é uma defesa contra alguém que já escolhe a chave.

## idempotency.new(options)

Constrói o middleware.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `ttl` | number | `86400` | segundos que uma resposta armazenada permanece reproduzível |
| `lock_ttl` | number | `60` | segundos que uma reivindicação sobre uma requisição em execução permanece válida |
| `prefix` | string | `"akkar:idem:"` | adicionado antes da chave, como prefixo |
| `header` | string | `"idempotency-key"` | o cabeçalho lido, em minúsculas |
| `methods` | list of string | `{ "POST", "PATCH" }` | métodos aos quais isso se aplica, em maiúsculas |
| `max_bytes` | number | `65536` | maior corpo de resposta codificado que é armazenado |
| `required` | boolean | `false` | recusa uma requisição coberta que não carrega nenhuma chave |
| `cache` | cache | `req.cache` | o armazenamento onde lembrar |

`methods` tem como padrão os dois métodos que o HTTP ainda não define como idempotentes. `GET`, `HEAD`, `PUT` e `DELETE` já são, então passam direto.

`lock_ttl` precisa durar mais que uma requisição, mas não pode durar mais que o dia inteiro. Sessenta segundos contra o prazo padrão de 30 segundos. Aumente-o se você aumentou o `timeout`: uma reivindicação que expira enquanto sua requisição ainda está em execução deixa uma nova tentativa entrar ao lado dela, que é exatamente a cobrança duplicada que este módulo evita.

**Retorna** middleware.

**Levanta** sem um `namespace`. A chave de idempotência é um cabeçalho que o cliente escolhe, então um único espaço de chaves global permite que um tenant reproduza o corpo de resposta armazenado de outro tenant; passe `namespace = function(req) return req.tenant.id end`, ou `namespace = idempotency.GLOBAL` (que é `false`) para declarar que a aplicação atende a um único tenant. Em tempo de requisição, ele levanta o que quer que o armazenamento levante quando não há nenhum armazenamento configurado.

Um armazenamento que não consegue responder (um que não consegue rodar os scripts, ou um Redis que oscilou) recebe **503** com `retry-after: 1`, e o handler não é executado. Falhar aberto aqui seria exatamente a cobrança duplicada que este middleware existe para evitar, então ele falha fechado e informa qual garantia está indisponível.

```lua
local akkar        = require "akkar"
local idempotency  = require "akkar.idempotency"
local memory       = require "akkar.cache.memory"

local app = akkar.new()
app:use(idempotency.new { ttl = 60, namespace = idempotency.GLOBAL })

local runs = 0
app:post("/charges", { body = { amount = "integer" } }, function(req)
  runs = runs + 1
  return akkar.created { id = "ch_1", amount = req.body.amount }
end)

local client = app:test { cache = memory.new() }
local headers = { ["idempotency-key"] = "ref_idem_charge_1" }

local first = client:post("/charges", { body = { amount = 100 }, headers = headers })
assert(first.status == 201)
assert(first.headers["idempotent-replay"] == nil)

local retry = client:post("/charges", { body = { amount = 100 }, headers = headers })
assert(retry.status == 201)
assert(retry.headers["idempotent-replay"] == "true")

assert(runs == 1)                     -- o handler rodou uma vez
```

### O que acontece com cada requisição

| situação | resposta |
|---|---|
| método fora de `methods` | passa direto, nada é armazenado |
| sem chave, `required = false` | passa direto, nada é armazenado |
| sem chave, `required = true` | `400`, corpo `{ error = "this endpoint requires an idempotency-key header" }` |
| chave com mais de 255 caracteres | `400`, corpo `{ error = "idempotency-key must be at most 255 characters" }` |
| primeira vez que essa chave é vista | o handler roda; um `2xx` é armazenado por `ttl` |
| repetição, a primeira ainda em execução | `409` com `retry-after: 1` |
| repetição, mesma chave, corpo diferente | `422` |
| repetição após conclusão | o status e o corpo armazenados, mais `idempotent-replay: true` |
| o handler levantou um erro | a reivindicação é liberada, o erro é relançado |
| a resposta é transmitida em streaming | a reivindicação é liberada, nada é armazenado |
| o status não é `2xx` | a reivindicação é liberada, nada é armazenado |
| o corpo codificado ultrapassa `max_bytes` | a reivindicação é liberada, um aviso é registrado no log, nada é armazenado |

Somente `2xx` é lembrado. Armazenar em cache um `500` significaria que a nova tentativa, que é todo o propósito disso, nunca poderia ter sucesso.

Uma repetição com a mesma chave e um corpo diferente:

```lua
local akkar        = require "akkar"
local idempotency  = require "akkar.idempotency"
local memory       = require "akkar.cache.memory"

local app = akkar.new()
app:use(idempotency.new { namespace = idempotency.GLOBAL })
app:post("/charges", { body = { amount = "integer" } }, function(req)
  return akkar.created { amount = req.body.amount }
end)

local client = app:test { cache = memory.new() }
local headers = { ["idempotency-key"] = "ref_idem_charge_2" }

assert(client:post("/charges", { body = { amount = 100 }, headers = headers }).status == 201)

local wrong = client:post("/charges", { body = { amount = 999 }, headers = headers })
assert(wrong.status == 422)
assert(wrong.body.error ==
       "this idempotency-key was already used for a different request")
```

Uma repetição enquanto a primeira ainda está em execução:

```lua
local akkar        = require "akkar"
local idempotency  = require "akkar.idempotency"
local memory       = require "akkar.cache.memory"

local app = akkar.new()
app:use(idempotency.new { namespace = idempotency.GLOBAL })

local client
app:post("/charges", function()
  -- Enviado de dentro do handler, então a primeira reivindicação ainda está retida.
  local again = client:post("/charges", {
    headers = { ["idempotency-key"] = "ref_idem_charge_3" },
  })
  return { second = again.status, retry_after = again.headers["retry-after"] }
end)

client = app:test { cache = memory.new() }

local res = client:post("/charges", {
  headers = { ["idempotency-key"] = "ref_idem_charge_3" },
})
assert(res.status == 200)
assert(res.body.second == 409)
assert(res.body.retry_after == "1")
```

### Um corpo reproduzido é o resultado de ida e volta pelo JSON

A resposta é armazenada ao ser codificada e reproduzida ao ser decodificada, então uma reprodução não é a mesma tabela que o handler retornou. Duas consequências:

- uma tabela marcada por `json.array` perde a marcação, então uma lista vazia é reproduzida como `{}` em vez de `[]`
- um inteiro volta como o que quer que o serializador decodifique, que com o padrão é um float

```lua
local akkar        = require "akkar"
local json         = require "akkar.json"
local idempotency  = require "akkar.idempotency"
local memory       = require "akkar.cache.memory"

local app = akkar.new()
app:use(idempotency.new { namespace = idempotency.GLOBAL })
app:post("/tasks", function() return { tasks = json.array {} } end)

local client = app:test { cache = memory.new() }
local headers = { ["idempotency-key"] = "ref_idem_tasks_1" }

local first = client:post("/tasks", { headers = headers })
assert(json.encode(first.body) == '{"tasks":[]}')

local replay = client:post("/tasks", { headers = headers })
assert(replay.headers["idempotent-replay"] == "true")
assert(json.encode(replay.body) == '{"tasks":{}}')     -- a marcação não sobreviveu
```

## Não está aqui

- **Um handler idempotente.** Se o handler cobra um cartão e então trava antes de retornar, a cobrança aconteceu e nada aqui sabe disso. Isso exige a própria chave de idempotência do processador de pagamento, por baixo desta.
- **Uma garantia mais forte que o armazenamento.** Com `akkar.cache.memory` o registro é por processo, então uma frota de seis instâncias deduplica seis vezes, o que não é deduplicação. `akkar.limit.shared(cache)` diz qual das duas você tem.
- **Armazenamento de uma resposta transmitida em streaming ou grande demais.** Ambas liberam a reivindicação e fazem o handler rodar de novo numa repetição.
- **Geração de chave.** O cliente escolhe a chave.

## Veja também

- [akkar](akkar.md) para `app:use`, que instala o middleware, e para `akkar.idempotency`, o mesmo construtor sob seu nome de nível superior
- [akkar.limit](limit.md) para `limit.shared`, que responde se o armazenamento é compartilhado, e para a mesma disciplina de avaliação de scripts
- [akkar.json](json.md) para a codificação pela qual uma resposta armazenada passa
- o código-fonte do módulo, `akkar/idempotency.lua`, para entender por que existem dois ttls
