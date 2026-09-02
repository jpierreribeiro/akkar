# akkar.multipart

> **Português (Brasil)** | [Original em inglês](../../reference/multipart.md)

Interpreta `multipart/form-data`, a codificação que um navegador usa para enviar um arquivo. Duas
funções, ambas puras: sem sistema de arquivos, sem rede, sem estado.

**Quando você precisa disso.** Quase nunca diretamente. `akkar/init.lua` chama as duas
funções quando uma requisição (request) chega com `content-type: multipart/form-data`, então um
handler já recebe os campos interpretados como `req.body`. Chame essas funções você mesmo
quando tiver em mãos um corpo multipart que não veio por uma rota, como um lido
de uma fila ou de um payload de webhook armazenado.

```lua no-run
local multipart = require "akkar.multipart"
```

Um corpo interpretado é uma tabela comum, então validação e handlers não aprendem uma
forma nova:

```lua no-run
local title        = req.body.title                 -- um campo simples, uma string
local filename     = req.body.avatar.filename       -- uma parte de arquivo
local content_type = req.body.avatar.content_type
local data         = req.body.avatar.data
local size         = req.body.avatar.size
```

## multipart.boundary(content_type)

Extrai o boundary de um valor de cabeçalho `Content-Type`. A RFC 2046 permite que o
boundary venha entre aspas e os navegadores divergem se ele vem ou não, então ambas as grafias
são aceitas; a forma entre aspas é tentada primeiro. O nome do parâmetro é comparado
sem diferenciar maiúsculas de minúsculas, como a RFC 2045 exige.

Ele é lido como um **parâmetro**, não como uma substring do cabeçalho. `boundary=`
costumava ser localizado em qualquer parte do valor, então
`multipart/form-data; name=xboundary=zzz` nomeava `zzz` como o boundary -- e
esse analisador então discordava de tudo à sua frente sobre onde as partes
começavam.

**Retorna** a string do boundary, ou `nil` quando `content_type` é `nil` ou não indica
nenhum boundary.

## multipart.parse(body, boundary)

Interpreta um corpo multipart inteiro que já está em memória. As partes são percorridas
delimitador a delimitador com busca de string simples (sem padrões), então um boundary
contendo caracteres que os padrões do Lua tratam como especiais é tratado literalmente.

O delimitador é `CRLF` seguido de `--boundary`, que é o que a RFC 2046
descreve, e só o delimitador de abertura pode aparecer sem um `CRLF` que o precede.
Buscar um `--boundary` isolado em qualquer lugar -- que era o que isso fazia -- deixava o
cliente plantar esses bytes no meio de uma linha dentro de uma parte e dividir o corpo ali, então um
gateway que interpretava multipart corretamente lia um formulário diferente daquele que o handler
lia.

Uma parte com um parâmetro `filename` no seu `Content-Disposition` se torna uma
tabela:

| campo | tipo | significado |
|---|---|---|
| `filename` | string | o nome como o cliente o enviou, sem sanitização |
| `content_type` | string | o `Content-Type` próprio da parte, ou `application/octet-stream` |
| `data` | string | os bytes, terminando onde começa o CRLF inicial do próximo delimitador |
| `size` | number | `#data` |

Uma parte sem `filename` se torna uma string simples. Uma parte cujo
`Content-Disposition` não nomeia um `name` é ignorada por completo.

**Duas partes sob o mesmo nome são recusadas**, em vez de a última simplesmente
vencer em silêncio. Isso é poluição de parâmetro: um formulário com dois campos
`amount` é lido de um jeito aqui e de outro por qualquer coisa que estiver na frente, e ninguém
é avisado. Não existe resposta certa para os dois lados, então o corpo é
rejeitado e quem chamou recebe um 400.

**Retorna** `fields` em caso de sucesso, ou `nil, message`. As mensagens, na íntegra:

- `multipart body has no boundary` (`boundary` é `nil` ou `""`)
- `multipart body has no opening boundary`
- `multipart part has no header block`
- `multipart part is not terminated`
- `multipart body has two parts named 'NAME'`
- `multipart body contained no named parts`

Ela nunca gera erro (raise).

```lua
local multipart = require "akkar.multipart"

local content_type = 'multipart/form-data; boundary="--------akkar42"'
local boundary = multipart.boundary(content_type)
print(boundary)                      --> --------akkar42

local CRLF = "\r\n"
local body = table.concat {
  "--", boundary, CRLF,
  'content-disposition: form-data; name="title"', CRLF, CRLF,
  "a cat", CRLF,
  "--", boundary, CRLF,
  'content-disposition: form-data; name="avatar"; filename="cat.png"', CRLF,
  "content-type: image/png", CRLF, CRLF,
  "PNGBYTES", CRLF,
  "--", boundary, "--", CRLF,
}

local fields, err = multipart.parse(body, boundary)
assert(fields, err)

print(fields.title)                  --> a cat
print(fields.avatar.filename)        --> cat.png
print(fields.avatar.content_type)    --> image/png
print(fields.avatar.size)            --> 8

local nothing, why = multipart.parse(body, nil)
print(nothing, why)                  --> nil   multipart body has no boundary
```

## Comportamento que vale a pena conhecer antes de confiar nisso

**O corpo inteiro é armazenado em buffer na memória**, limitado por `body_limit` em
`app:run{}` (1 MB por padrão). Um upload de 200 MB precisa que `body_limit` seja definido para 200 MB
e então custa 200 MB de memória residente por upload concorrente. Transmitir partes
para o disco conforme elas chegam é uma funcionalidade diferente, com uma forma diferente.

**Nomes repetidos não se acumulam.** Duas partes nomeadas `tag` deixam uma única string em
`fields.tag`, a última. Não existe forma de lista.

**Um `filename` vazio ainda gera uma parte de arquivo.** Um navegador envia
`filename=""` para um campo de arquivo que o usuário nunca tocou, e essa parte é interpretada como
uma tabela com `data = ""` e `size = 0`, em vez de um campo string simples.
Teste se `type(field) == "table"` em vez de testar se `filename` é verdadeiro.

**`filename` não é sanitizado.** É exatamente o que o cliente enviou, incluindo um
caminho ou um `..`. Nunca faça join disso com um diretório. Veja
[static](static.md) para as regras de resolução que um caminho vindo de um cliente precisa.

## O que não está aqui

- **Transmitir partes para o disco.** O corpo é sempre armazenado em buffer.
- **`Content-Transfer-Encoding`.** Uma parte `base64` é devolvida como seu texto
  em base64, sem decodificação.
- **`multipart/mixed` e multiparts aninhados.** Só a forma plana `form-data`
  é interpretada.
- **Tratamento de charset.** `data` são bytes, e o valor de um campo é bytes.
- **O `413`.** Recusar um upload grande demais acontece em `akkar/init.lua`
  antes de este módulo ser alcançado.

## Veja também

- [akkar](akkar.md) para `app:run{ body_limit = ... }` e para como `req.body` é
  produzido a partir da requisição
- o código-fonte do módulo, `akkar/multipart.lua`, para entender por que o uso de buffer é apresentado como uma
  limitação antes do código, e não depois
