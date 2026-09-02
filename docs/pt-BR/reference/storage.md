# akkar.storage

> **Português (Brasil)** | [Original em inglês](../../reference/storage.md)

Armazenamento de objetos via HTTP contra qualquer coisa compatível com S3: S3, R2, B2, Spaces, MinIO, Garage. Quatro operações de objeto, um construtor de URL pré-assinada e o maquinário do AWS Signature Version 4 por baixo deles, tudo exportado.

**Quando você precisa disso.** Sua aplicação aceita uploads e precisa colocá-los em algum lugar, ou entrega ao navegador uma URL que faz upload ou download diretamente, sem que os bytes passem por este processo. Isso não adiciona nenhuma dependência: o transporte é `akkar.http` e a aritmética é `akkar.crypto`.

```lua no-run
local storage = require "akkar.storage"
```

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`storage.EMPTY_SHA256`](#storageempty_sha256) | constante |
| [`storage.Store`](#store) | metatabela |
| [`storage.UNSIGNED`](#storageunsigned) | constante |
| [`storage.authority_of`](#storageauthority_ofendpoint) | função |
| [`storage.canonical_headers`](#storagecanonical_headersheaders) | função |
| [`storage.canonical_query`](#storagecanonical_queryquery) | função |
| [`storage.canonical_request`](#storagecanonical_requestrequest) | função |
| [`storage.connect`](#storageconnectconfig) | função |
| [`storage.encode_key`](#storageencode_keykey) | função |
| [`storage.hex_sha256`](#storagehex_sha256data) | função |
| [`storage.parse_endpoint`](#storageparse_endpointendpoint) | função |
| [`storage.presign_query`](#storagepresign_queryrequest-credentials) | função |
| [`storage.sign`](#storagesignrequest-credentials) | função |
| [`storage.signing_key`](#storagesigning_keysecret-date-region-service) | função |
| [`storage.uri_encode`](#storageuri_encodetext-encode_slash) | função |
| [`Store:address`](#storeaddresskey) | método |
| [`Store:call`](#storecallmethod-key-options) | método |
| [`Store:delete`](#storedeletekey-options) | método |
| [`Store:get`](#storegetkey-options) | método |
| [`Store:head`](#storeheadkey-options) | método |
| [`Store:presign`](#storepresignmethod-key-options) | método |
| [`Store:put`](#storeputkey-body-options) | método |

## storage.EMPTY_SHA256

O SHA-256 em hexadecimal da string vazia,
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. É o hash do
payload de toda requisição (request) sem corpo.

## storage.UNSIGNED

A string `UNSIGNED-PAYLOAD`. O hash do payload que uma URL pré-assinada
carrega, porque não é possível calcular o hash do corpo de um upload que
ainda não aconteceu.

## storage.authority_of(endpoint)

A autoridade exatamente como o lua-http vai escrevê-la, dada uma tabela vinda
de `storage.parse_endpoint`.

**Retorna** `host` quando a porta é a padrão para o esquema (443 para
`https`, 80 para `http`), e `host:port` caso contrário.

Isso precisa bater, porque `host` é um cabeçalho assinado. Assinar
`host:443` contra uma requisição que diz `host` resulta em um 403 cuja
mensagem aponta a assinatura, e não a causa.

```lua
local storage = require "akkar.storage"

assert(storage.authority_of(storage.parse_endpoint "https://s3.example.com")
       == "s3.example.com")
assert(storage.authority_of(storage.parse_endpoint "http://127.0.0.1:9000")
       == "127.0.0.1:9000")
assert(storage.authority_of(storage.parse_endpoint "https://s3.example.com:443")
       == "s3.example.com")
```

## storage.canonical_headers(headers)

Deixa cada nome em minúsculas, remove espaços das bordas de cada valor e
reduz sequências internas de espaços em branco a um único espaço, depois
ordena por nome.

**Retorna** dois valores: o bloco canônico de cabeçalhos, que termina com sua
própria quebra de linha, e a lista de cabeçalhos assinados, em minúsculas e
unida por ponto e vírgula.

A quebra de linha final não é opcional. A linha em branco que separa o bloco
da lista de cabeçalhos assinados vem da junção feita em
`storage.canonical_request`, então há duas quebras de linha seguidas e
nenhuma das duas pode ser descartada.

```lua
local storage = require "akkar.storage"

local block, signed = storage.canonical_headers {
  ["Host"] = "s3.example.com",
  ["X-Amz-Date"] = "  20130524T000000Z  ",
  ["Content-Type"] = "text/plain",
}
assert(signed == "content-type;host;x-amz-date")
assert(block == "content-type:text/plain\nhost:s3.example.com\nx-amz-date:20130524T000000Z\n")
```

## storage.canonical_query(query)

A string de query canônica.

| `query` | resultado |
|---|---|
| `nil` | `""` |
| uma string | retornada sem alterações, por conta de quem chamou |
| uma tabela de `[key] = value` | cada lado codificado com as barras escapadas, ordenado pela chave codificada e depois pelo valor codificado |
| uma lista de pares `{name, value}` | o mesmo, e a forma de expressar chaves duplicadas ou uma ordem fixa |

Uma tabela pode misturar os dois formatos: uma chave numérica cujo valor é
uma tabela é lida como um par; qualquer outra coisa, como uma chave e um
valor.

Todo parâmetro carrega um `=`, mesmo quando seu valor é vazio. Um parâmetro
escrito sem o `=` assina de forma diferente de um escrito como `name=`.

```lua
local storage = require "akkar.storage"

assert(storage.canonical_query { b = "2", a = "" } == "a=&b=2")
assert(storage.canonical_query { { "x", "1" }, { "x", "2" } } == "x=1&x=2")
assert(storage.canonical_query "already=canonical" == "already=canonical")
assert(storage.canonical_query(nil) == "")
```

## storage.canonical_request(request)

A requisição canônica, como a AWS a define: método, caminho, query canônica,
bloco canônico de cabeçalhos, lista de cabeçalhos assinados e hash do
payload, unidos por quebras de linha.

| campo | tipo | significado |
|---|---|---|
| `method` | string | usado ao pé da letra, e não é convertido para maiúsculas aqui |
| `path` | string | usado ao pé da letra. Codificado, mas nunca normalizado |
| `query` | tabela, string ou `nil` | passado para `storage.canonical_query` |
| `headers` | tabela | passado para `storage.canonical_headers` |
| `payload_hash` | string | o hash em hexadecimal dos bytes que trafegam, ou `storage.UNSIGNED` |

**Retorna** a requisição canônica e a lista de cabeçalhos assinados.

**Levanta um erro** se `headers` estiver ausente, por indexar `nil` dentro de
`canonical_headers`.

## storage.connect(config)

Constrói um `Store` e retorna uma fábrica que o devolve, no mesmo padrão de
`db.connect`, `redis.connect` e `http.connect`.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `endpoint` | string | obrigatório | `scheme://host[:port][/prefix]` |
| `bucket` | string | obrigatório | o nome do bucket |
| `access_key` | string | obrigatório | |
| `secret_key` | string | obrigatório | |
| `region` | string | `"us-east-1"` | entra no escopo da credencial |
| `service` | string | `"s3"` | entra no escopo da credencial |
| `session_token` | string | nenhum | enviado como `x-amz-security-token`, e como `X-Amz-Security-Token` em uma URL pré-assinada |
| `path_style` | boolean | `true` | `false` seleciona o endereçamento por virtual-host |
| `http` | cliente | um novo | um cliente `akkar.http` conectado, compartilhado entre todas as chamadas |
| `timeout` | number | `30` | segundos, usado somente ao construir o cliente padrão |
| `max_body` | number | `67108864` | bytes, usado somente ao construir o cliente padrão |

O estilo de path é o padrão porque é a única coisa em que todo servidor
compatível com S3 concorda. O estilo virtual-host precisa de entradas DNS que
ninguém criou, e quebra a correspondência do nome de host do TLS para um
bucket cujo nome contém um ponto.

O cliente é compartilhado porque é nele que vive o pool de conexões, e é
injetável porque uma spec precisa de um transporte que ela possa observar.

**Retorna** uma função sem argumentos que retorna o mesmo `Store` todas as
vezes.

**Levanta um erro** `akkar.storage: an endpoint is required`,
`akkar.storage: a bucket is required`,
`akkar.storage: access_key and secret_key are required`, e o que quer que
`storage.parse_endpoint` tenha usado para recusar.

```lua
local storage = require "akkar.storage"

local connect = storage.connect {
  endpoint = "https://s3.amazonaws.com",
  bucket = "examplebucket",
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}
local store = connect()
assert(connect() == store)          -- o mesmo store, todas as vezes
assert(store.region == "us-east-1")
assert(store.path_style == true)
```

## storage.encode_key(key)

Codifica uma chave de objeto como um caminho S3 canônico: cada segmento entre
barras é percent-encoded, as barras não.

**Retorna** uma string.

Não normalizado. `a//b` e `a/./b` são objetos diferentes para o S3, então
colapsá-los, algo que toda biblioteca genérica de URL faz, assinaria um
caminho diferente do que foi solicitado.

```lua
local storage = require "akkar.storage"

assert(storage.encode_key "/test$file.text" == "/test%24file.text")
assert(storage.encode_key "photos/my cat.jpg" == "photos/my%20cat.jpg")
assert(storage.encode_key "a//b" == "a//b")
```

## storage.hex_sha256(data)

O SHA-256 em hexadecimal de `data`. `nil` tem seu hash calculado como se
fosse a string vazia.

**Retorna** uma string hexadecimal em minúsculas de 64 caracteres.

```lua
local storage = require "akkar.storage"
assert(storage.hex_sha256 "" == storage.EMPTY_SHA256)
assert(storage.hex_sha256(nil) == storage.EMPTY_SHA256)
assert(#storage.hex_sha256 "hello" == 64)
```

## storage.parse_endpoint(endpoint)

Separa `scheme://host[:port][/prefix]` em suas partes.

**Retorna** `{ scheme = ..., host = ..., port = ..., prefix = ... }`. A porta
assume o padrão 443 para `https` e 80 para qualquer outro caso. Um `prefix`
que seja exatamente `/` vira a string vazia; qualquer outro caminho é
mantido como escrito, incluindo a barra inicial.

**Retorna `nil` e um motivo** para `the endpoint needs a scheme: <endpoint>`.

```lua
local storage = require "akkar.storage"

local parsed = storage.parse_endpoint "https://s3.example.com/base"
assert(parsed.scheme == "https")
assert(parsed.host == "s3.example.com")
assert(parsed.port == 443)
assert(parsed.prefix == "/base")

assert(storage.parse_endpoint("s3.example.com") == nil)
local _, why = storage.parse_endpoint "s3.example.com"
assert(why == "the endpoint needs a scheme: s3.example.com")
```

## storage.presign_query(request, credentials)

Os parâmetros de query de uma URL pré-assinada, assinatura incluída. Não faz
nenhuma requisição.

Recebe os mesmos campos de `request` que `storage.sign`, sem `payload_hash`,
que é sempre `storage.UNSIGNED`, mais:

| campo | tipo | padrão | significado |
|---|---|---|---|
| `expires` | number | `3600` | segundos, escrito em `X-Amz-Expires` |

O `request.query` de quem chamou é copiado, e então são adicionados
`X-Amz-Algorithm`, `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires`,
`X-Amz-SignedHeaders` e, quando há um `session_token`,
`X-Amz-Security-Token`. O resultado é assinado, e `X-Amz-Signature` é
adicionado à mesma tabela em seguida.

Note que o padrão aqui é 3600 segundos, enquanto o de `Store:presign` é 900.
Quem chama esta função diretamente não recebe o valor mais curto.

**Retorna** a tabela de query e o resultado completo de assinatura de
`storage.sign`. Passe a tabela para `storage.canonical_query` para construir
a URL.

```lua
local storage = require "akkar.storage"

local query = storage.presign_query({
  method = "GET",
  path = "/examplebucket/test.txt",
  headers = { host = "s3.amazonaws.com" },
  expires = 86400,
  amzdate = "20130524T000000Z",
}, {
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
})

assert(query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256")
assert(query["X-Amz-Expires"] == "86400")
assert(query["X-Amz-SignedHeaders"] == "host")
assert(#query["X-Amz-Signature"] == 64)
```

## storage.sign(request, credentials)

Assina uma requisição. Não toca em nada na rede.

| campo de `request` | tipo | padrão | significado |
|---|---|---|---|
| `method` | string | obrigatório | |
| `path` | string | obrigatório | já codificado, nunca normalizado |
| `query` | tabela ou string | `nil` | |
| `headers` | tabela | obrigatório | |
| `payload_hash` | string | obrigatório | |
| `amzdate` | string | agora, no formato `!%Y%m%dT%H%M%SZ` | aceito diretamente para que um teste possa fixar o relógio |
| `timestamp` | number | `time.now()` | usado somente quando `amzdate` está ausente |

| campo de `credentials` | tipo | padrão |
|---|---|---|
| `access_key` | string | obrigatório |
| `secret_key` | string | obrigatório |
| `region` | string | `"us-east-1"` |
| `service` | string | `"s3"` |

**Retorna** uma tabela:

| campo | significado |
|---|---|
| `amzdate` | o timestamp usado, que é o que deve ir no cabeçalho `x-amz-date` |
| `scope` | `<date>/<region>/<service>/aws4_request` |
| `signed_headers` | a lista unida por ponto e vírgula |
| `canonical_request` | a requisição canônica completa |
| `string_to_sign` | a string completa a ser assinada |
| `signature` | 64 caracteres hexadecimais |
| `credential` | `<access_key>/<scope>` |
| `authorization` | o valor completo do cabeçalho `Authorization` |

`canonical_request` e `string_to_sign` são retornados porque uma assinatura
incompatível só diz "errado", e esses dois dizem onde.

```lua
local storage = require "akkar.storage"

-- O próprio exemplo publicado pela AWS de GET Object, credenciais incluídas.
local signed = storage.sign({
  method = "GET",
  path = "/test.txt",
  headers = {
    ["host"] = "examplebucket.s3.amazonaws.com",
    ["range"] = "bytes=0-9",
    ["x-amz-content-sha256"] = storage.EMPTY_SHA256,
    ["x-amz-date"] = "20130524T000000Z",
  },
  payload_hash = storage.EMPTY_SHA256,
  amzdate = "20130524T000000Z",
}, {
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  region = "us-east-1",
  service = "s3",
})

assert(signed.signature ==
  "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
assert(signed.scope == "20130524/us-east-1/s3/aws4_request")
assert(signed.signed_headers == "host;range;x-amz-content-sha256;x-amz-date")
```

## storage.signing_key(secret, date, region, service)

A chave de assinatura SigV4 de quatro etapas. A saída de cada etapa é a
chave da próxima, começando em `"AWS4" .. secret` e terminando em
`"aws4_request"`.

**Retorna** bytes brutos, não hexadecimal.

O prefixo literal `AWS4` faz parte disso e não é um erro de digitação. É
essa cadeia que torna uma assinatura vazada inútil amanhã, em outra região,
para outro serviço.

```lua
local storage = require "akkar.storage"
local crypto  = require "akkar.crypto"

local key = storage.signing_key(
  "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "20130524", "us-east-1", "s3")
assert(#key == 32)                         -- saída bruta do HMAC-SHA256
assert(#crypto.to_hex(key) == 64)
```

## storage.uri_encode(text, encode_slash)

Percent-encoding conforme a RFC 3986, do jeito que o SigV4 o define: um
espaço é `%20` e nunca `+`, `~` não é tocado, e os dígitos hexadecimais
ficam em maiúsculas. `encode_slash` é falso por padrão, então `/` sobrevive.

**Retorna** uma string. `text` passa por `tostring`, então um número também
é aceito.

Hexadecimal em minúsculas produz uma assinatura incompatível e nenhuma
explicação. O mesmo vale para escapar `~`.

```lua
local storage = require "akkar.storage"

assert(storage.uri_encode "a b~c/d" == "a%20b~c/d")
assert(storage.uri_encode("a b~c/d", true) == "a%20b~c%2Fd")
assert(storage.uri_encode "$" == "%24")
```

## Store

O que `storage.connect(config)()` retorna. Exportado como `storage.Store`
para quem quiser estendê-lo. Todo método retorna um valor e um motivo, em
vez de levantar um erro, exceto onde indicado.

### Store:address(key)

Onde um objeto mora.

**Retorna** três valores: o host a ser assinado, o caminho canônico e a URL
completa. O caminho sempre tem exatamente uma barra inicial, não importa
como as peças se encaixaram: `//bucket` é uma requisição canônica diferente
de `/bucket`, e como o caminho é assinado sem normalização, a diferença
resulta em um 403 em vez de um redirecionamento.

Com `path_style` (o padrão), o host é a autoridade do endpoint e o bucket é
o primeiro segmento do caminho. Sem ele, o host é `<bucket>.<authority>` e o
bucket não aparece no caminho.

```lua
local storage = require "akkar.storage"

local store = storage.connect {
  endpoint = "https://s3.amazonaws.com",
  bucket = "examplebucket",
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}()

local host, path, url = store:address "photos/cat.jpg"
assert(host == "s3.amazonaws.com")
assert(path == "/examplebucket/photos/cat.jpg")
assert(url == "https://s3.amazonaws.com/examplebucket/photos/cat.jpg")

local virtual = storage.connect {
  endpoint = "https://s3.amazonaws.com",
  bucket = "examplebucket",
  path_style = false,
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}()
local vhost, vpath = virtual:address "photos/cat.jpg"
assert(vhost == "examplebucket.s3.amazonaws.com")
assert(vpath == "/photos/cat.jpg")
```

### Store:call(method, key, options)

Assina uma requisição e a envia. Todo outro método passa por aqui.

| campo de `options` | tipo | padrão | significado |
|---|---|---|---|
| `body` | string | nenhum | tem seu hash calculado e é assinado, e define `content-length` |
| `headers` | tabela | `{}` | os nomes são convertidos para minúsculas, os valores passam por `tostring` |
| `query` | tabela ou string | nenhum | assinado, e anexado à URL em forma canônica |
| `timeout` | number | o do cliente | segundos |
| `max_body` | number | o do cliente | bytes |

`host` e `x-amz-content-sha256` são definidos antes da assinatura.
`x-amz-date` e `authorization` são definidos depois. Em seguida, `host` é
removido do que é enviado, e mantido apenas no que foi assinado: o lua-http
escreve a autoridade por conta própria a partir da URL, e um segundo
cabeçalho `host` no tráfego é algo que a maioria dos servidores rejeita.

**Retorna** a resposta (response), ou `nil` e o motivo dado pelo transporte.
Um status que não seja 2xx é uma resposta retornada, não um erro: interpretar
isso é tarefa de cada método.

### Store:delete(key, options)

Apaga um objeto. `options` é passado diretamente para `Store:call`.

**Retorna** `true`, ou `nil`, uma mensagem e uma tabela de detalhes.

Idempotente, porque o S3 é: apagar o que não está lá responde 204.

### Store:get(key, options)

Busca um objeto. `options` é passado diretamente para `Store:call`, então
`headers` (um `range`, por exemplo) e `timeout` chegam até ele.

**Retorna** o corpo e a resposta inteira, ou `nil`, uma mensagem e uma
tabela de detalhes.

Um objeto ausente é um valor de erro, e não um corpo vazio: `no such
object: <key>` com `{ status = 404 }`. Um objeto vazio é uma coisa que
existe, e distinguir os dois é exatamente a pergunta que um `get` precisa
responder.

### Store:head(key, options)

**Retorna** `true` e os cabeçalhos da resposta quando o objeto existe,
`false` e nada quando o status é 404, e `nil`, uma mensagem e uma tabela de
detalhes para qualquer outro status que não seja 2xx.

Três formatos, e o do 404 retorna um único valor. `if store:head(key) then`
se lê corretamente; `local ok, headers = store:head(key)` deixa `headers`
como `nil` quando não encontra, o que é igual a um acerto sem cabeçalhos.

### Store:presign(method, key, options)

Uma URL que funciona sozinha por `expires` segundos. Não faz nenhuma
requisição, e pode ser chamada em uma máquina sem nenhuma rota até o store.

| campo de `options` | tipo | padrão | significado |
|---|---|---|---|
| `expires` | number | `900` | segundos |
| `query` | tabela | nenhum | parâmetros extras, assinados junto com o resto |
| `timestamp` | number | agora | |
| `amzdate` | string | derivado de `timestamp` | fixa o relógio |

`method` é convertido para maiúsculas, e assume `GET` por padrão quando é
`nil`.

**Retorna** a URL, como uma única string.

O padrão de quinze minutos é curto de propósito. Uma URL pré-assinada é uma
credencial do tipo bearer dentro de uma string que acaba parando em um log,
em um cabeçalho referrer e no histórico de chat de alguém. O teto da
própria AWS é de sete dias; nada aqui usa um padrão nem perto disso.

```lua
local storage = require "akkar.storage"

local store = storage.connect {
  endpoint = "https://s3.amazonaws.com",
  bucket = "examplebucket",
  access_key = "AKIAIOSFODNN7EXAMPLE",
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}()

local url = store:presign("PUT", "uploads/report.pdf", {
  expires = 300,
  amzdate = "20130524T000000Z",
})

assert(url:find("https://s3.amazonaws.com/examplebucket/uploads/report.pdf?", 1, true) == 1)
assert(url:find("X-Amz-Expires=300", 1, true))
assert(url:find("X-Amz-Signature=", 1, true))
```

### Store:put(key, body, options)

Armazena um objeto.

| campo de `options` | tipo | padrão | significado |
|---|---|---|---|
| `content_type` | string | `"application/octet-stream"` | prevalece sobre um `content-type` em `headers` |
| `headers` | tabela | `{}` | copiado, e então o content type é aplicado |
| `timeout` | number | o do cliente | segundos |

**Retorna** `true` e o `etag` da resposta, ou `nil`, uma mensagem e uma
tabela de detalhes.

**Levanta um erro** `akkar.storage: a body must be a string`. Este é o
único método aqui que levanta um erro por causa de um argumento inválido.

Note que `options.query` e `options.max_body` não são repassados: `put`
constrói sua própria tabela de options para `Store:call` a partir apenas de
`headers`, `body` e `timeout`.

### O valor de erro

Todo status que não seja 2xx, e que não seja um 404 respondido por `get` ou
`head`, volta da mesma forma: `nil`, uma mensagem e uma tabela de detalhes.

| campo de details | significado |
|---|---|
| `status` | o status HTTP |
| `code` | o elemento `<Code>` do documento de erro do S3, ou `nil` |
| `message` | o elemento `<Message>`, ou `nil` |
| `body` | o corpo inteiro, sem alterações |

A mensagem tem a forma `<Code>: <Message>`, recorrendo a `HTTP <status>:
the store refused the request` quando isso falta.

Os dois elementos são extraídos com um padrão (pattern), e não com um
parser. Adicionar um parser de XML para ler um elemento seria uma
dependência só para ler um elemento, e o corpo completo está em
`details.body` para qualquer coisa que o padrão não cubra.

## O que não está aqui

**Listar um bucket.** Quatro operações de objeto e uma URL pré-assinada. Não
existe um `list`.

**Multipart upload, e assinatura de upload em chunks.** Não implementado. Um
objeto grande vai em uma única requisição ou não vai.

**Retries.** O que quer que o cliente `akkar.http` injetado faça, e nada
além disso.

**Um `new`.** `storage.connect` é o único construtor, e ele devolve uma
fábrica em vez do store.

**Verificação contra um store real.** O assinador é conferido contra os
três exemplos resolvidos publicados pela AWS, na requisição canônica, na
string a ser assinada e na assinatura. O que isso não alcança é o TLS, o
endereçamento por virtual-host contra um DNS real, e o redirecionamento que
uma região incompatível produz.

## Veja também

- [akkar.http](http.md), que é o transporte, e cujo cliente pode ser
  injetado aqui
- [akkar.crypto](crypto.md), para `sha256`, `hmac` e `to_hex`, que são a
  aritmética
- `spec/storage_spec.lua`, para os três vetores da AWS verificados em três
  profundidades cada
- o código-fonte do módulo, `akkar/storage.lua`, para as regras de
  codificação mais fáceis de errar
