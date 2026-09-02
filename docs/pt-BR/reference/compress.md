# akkar.compress

> **Português (Brasil)** | [Original em inglês](../../reference/compress.md)

Compressão de resposta (response): negociação de conteúdo, o cabeçalho `Vary`, um limite de tamanho, uma lista de permissão de tipos de conteúdo e a renomeação do ETag. Tudo que um servidor que comprime precisa acertar, exceto a compressão em si, que é fornecida pela aplicação.

**Quando você precisa disso.** Quando nada na frente do akkar comprime para você: um container que fala HTTP direto com a borda (edge), um proxy que não consegue ver o corpo, ou uma resposta gerada grande o suficiente para que reduzi-la na origem compense a cópia. Se o nginx ou uma CDN termina o TLS na frente do akkar, configure a compressão lá e não registre este middleware.

```lua no-run
local compress = require "akkar.compress"
```

Não existe `akkar.compress` na tabela `akkar`. Registre o middleware como `app:use(compress.new { ... })`.

## Não existe compressor neste módulo

`compress.new` lança um erro a menos que você passe pelo menos um codificador (encoder), e o akkar não vem com nenhum. Um codificador é uma `function(bytes) -> bytes`.

```lua no-run
encoders = { gzip = function(bytes) return my_gzip(bytes) end },
```

O motivo está em `akkar/compress.lua`: nenhum binding de zlib está instalado ou pode ser declarado como dependência aqui, e um deflate feito à mão no caminho crítico (hot path) de cada resposta é uma resposta pior do que simplesmente dizer isso. O risco de errar sutilmente é um corpo que nenhum cliente consegue ler.

## Ordem: registre este primeiro

```lua no-run
app:use(compress.new { encoders = encoders })   -- mais externo
app:use(akkar.etag { require_on = { "PUT" } })
```

`build_chain` em `akkar/init.lua` envolve a partir do último registro para dentro, então `middleware[1]` é o mais externo e é o último a ver a resposta. A compressão precisa ser a última transformação aplicada a um corpo: uma resposta comprimida não tem mais um `body`, ela tem bytes `raw`, e o [etag](etag.md) registrado fora deste middleware não marcaria nada e silenciosamente pararia de responder `304`. Nada lança um erro.

## compress.accepted(header)

Faz o parsing de um cabeçalho `Accept-Encoding` em uma tabela de `token = qvalue`. Um parâmetro `q` ausente vale `1`. Um `q` que não pode ser interpretado também vale `1`, então um parâmetro que não dá para interpretar não consegue desativar a compressão para aquele cliente. Os tokens são convertidos para minúsculas.

**Retorna** uma tabela. Uma tabela vazia para um cabeçalho `nil` ou vazio.

## compress.compressible(content_type)

O teste padrão de lista de permissão. O tipo é extraído de antes do primeiro `;`, então `application/json; charset=utf-8` é reconhecido. A correspondência é feita por uma lista exata, pelo prefixo `text/` e pelos sufixos estruturados `+json` e `+xml`.

A lista exata é `application/json`, `application/javascript`, `application/xml`, `application/xhtml+xml`, `application/rss+xml`, `application/atom+xml`, `application/wasm`, `image/svg+xml` e `application/x-ndjson`.

**Retorna** um booleano. `false` para `nil`.

## compress.merge_vary(existing)

Adiciona `Accept-Encoding` a um cabeçalho `Vary` sem destruir o que já está lá. Retorna `existing` sem alterações quando ele já lista `Accept-Encoding`, com comparação sem diferenciar maiúsculas de minúsculas e com espaços em branco ao redor removidos.

**Retorna** uma string.

## compress.negotiate(header, available, prefer)

Escolhe uma codificação. `available` é um conjunto de nomes para os quais você tem um codec, `prefer` é a ordem de desempate do servidor, como uma lista. A codificação escolhida é a que está em `prefer` com o maior q aceitável, e `*` fornece o q para um token que o cliente não nomeou.

Um `header` ausente ou vazio retorna `nil`, o que significa enviar a resposta como está. A RFC 9110 permite interpretar um cabeçalho ausente como "vale tudo"; fazer isso enviaria gzip para um cliente que nunca anunciou suporte a ele, então isso não é feito aqui. `q=0` significa "não aceitável", e é isso que faz `identity;q=0` e `*;q=0` funcionarem.

**Retorna** um nome de codificação, ou `nil`.

```lua
local compress = require "akkar.compress"

local q = compress.accepted "gzip, deflate;q=0.5, *;q=0"
print(q.gzip, q.deflate, q["*"])                 --> 1   0.5   0

print(compress.compressible "application/json; charset=utf-8")  --> true
print(compress.compressible "image/svg+xml")                    --> true
print(compress.compressible "image/png")                        --> false

local available = { gzip = true, deflate = true }
print(compress.negotiate("gzip, deflate", available, { "br", "gzip", "deflate" }))
--> gzip
print(compress.negotiate("identity", available, { "gzip" }))    --> nil
print(compress.negotiate(nil, available, { "gzip" }))           --> nil

print(compress.merge_vary "Origin")     --> Origin, Accept-Encoding
print(compress.merge_vary(nil))         --> Accept-Encoding

local ok, message = pcall(compress.new, {})
print(ok)                               --> false
print(message)
```

## compress.new(options)

Middleware.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `encoders` | tabela de `name = function(bytes)` | nenhum, obrigatório | os codecs que você possui; o nome é o que vai em `Content-Encoding` |
| `min_size` | número | `1024` | corpos menores que isso nunca são comprimidos |
| `prefer` | lista de strings | `{ "br", "gzip", "deflate" }` | ordem de desempate do servidor quando o cliente é indiferente |
| `compressible` | function(content_type) | `compress.compressible` | substitui o teste de lista de permissão |
| `on_error` | function(err, req) | nenhum | chamado quando um codificador lança um erro ou retorna algo que não é string |

O corpo considerado é `res.raw`, se presente, ou então `akkar.json.encode(res.body)`, sob `res.content_type` ou `application/json`. Isso espelha exatamente o que o writer em `akkar/init.lua` envia pela rede.

`Vary: Accept-Encoding` é adicionado às respostas que este middleware avaliou e decidiu não comprimir, não apenas às que ele comprimiu. Sem isso, um cache compartilhado armazenaria qualquer representação que visse primeiro sob uma chave que não menciona a codificação.

Repassadas com `Vary` adicionado, e nada mais:

- uma resposta em streaming (`res.stream`), porque um codec `function(bytes) -> bytes` não consegue codificar um stream de forma incremental
- uma resposta que já carrega `Content-Encoding`
- um payload menor que `min_size`
- nenhuma codificação aceitável para este cliente
- um codificador que lançou um erro, ou retornou algo que não é string, ou produziu uma saída tão longa quanto ou mais longa que a entrada

Repassadas completamente intocadas, sem `Vary` também:

- status `204`, `304`, ou abaixo de `200`
- um tipo de conteúdo que o teste `compressible` rejeita, como `image/png`
- um `res.body` nulo sem `res.raw`, um corpo que não pode ser codificado em JSON, ou um payload que não é uma string

Uma falha no codificador nunca se transforma em um `500`. Ela falha de forma aberta (fails open): o cliente recebe uma resposta correta, porém maior, e `on_error` é chamado, se você tiver fornecido um.

Quando a compressão de fato acontece, a resposta é uma **cópia**. `content-encoding` é definido, `vary` é mesclado, `release` e `__pending` acompanham a resposta, e um `etag` existente recebe a codificação anexada dentro das aspas (`"abc"` se torna `"abc-gzip"`), porque os bytes codificados são uma representação diferente, e enviar ambos sob uma única tag é o bug mais antigo da compressão em HTTP.

**Retorna** uma `function(req, next)`.

**Lança um erro** no registro, não em tempo de execução:

- `akkar.compress needs encoders = { gzip = function(bytes) ... end }; akkar ships no compressor ...` quando `encoders` está ausente ou vazio
- `akkar.compress: encoder 'NAME' is a TYPE, not a function(bytes)` quando um valor em `encoders` não é uma função

```lua
local akkar    = require "akkar"
local compress = require "akkar.compress"

-- Um codec substituto, para que esta página funcione em qualquer lugar. Uma implantação real nomeia
-- o codificador `gzip` e passa um gzip de verdade; o akkar não vem com nenhum.
local function squash(bytes)
  return (bytes:gsub("aaaa+", "~"))
end

local app = akkar.new()

app:use(compress.new {
  encoders = { squash = squash },
  prefer   = { "squash" },
  min_size = 64,
})

app:get("/report", function()
  return { rows = akkar.array { ("a"):rep(4000) } }
end)

local client = app:test {}

local plain = client:get "/report"
print(plain.status, plain.headers["content-encoding"], plain.headers["vary"])
--> 200   nil   Accept-Encoding

local encoded = client:get("/report", {
  headers = { ["accept-encoding"] = "squash" },
})
print(encoded.status, encoded.headers["content-encoding"], #encoded.raw)
--> 200   squash   14
```

## compress.vary(akkar, res)

Retorna uma cópia de `res` carregando `Vary: Accept-Encoding`, ou o próprio `res` quando o cabeçalho já está lá e nada precisa ser alocado. O primeiro argumento é o módulo `akkar`, passado como parâmetro em vez de ser exigido (required) no topo do arquivo para evitar um ciclo de require.

**Retorna** uma resposta.

## O que não está aqui

- **Um compressor.** Veja a seção acima.
- **Compressão em streaming.** Uma resposta em streaming é repassada com `Vary` e nada mais. Armazená-la em buffer para comprimi-la anularia o motivo pelo qual ela foi transmitida em streaming.
- **Descompressão do corpo da requisição (request).** Uma requisição (request) que chega com `Content-Encoding: gzip` não é decodificada em nenhum lugar do akkar.
- **Uma proteção para `206`.** Uma resposta parcial vinda de [static](static.md) é comprimida como qualquer outra, e o seu `Content-Range` passa a descrever os bytes de identidade enquanto o corpo está codificado. Configure `compressible` para rejeitar os tipos para os quais você serve ranges, ou registre este middleware somente nas rotas que precisam dele.
- **Verificação de nomes de opções.** Uma chave desconhecida em `options` é ignorada silenciosamente.

## Veja também

- [akkar](akkar.md) para `app:use`, `akkar.raw` e `akkar.stream`
- [etag](etag.md), que precisa ser registrado dentro deste middleware
- [static](static.md), cujas respostas este middleware também vê
- o código-fonte do módulo, `akkar/compress.lua`, para o relato completo de por que nenhum gzip vem com o akkar e por que um contêiner gzip byte a byte correto é uma armadilha
