# akkar.email

> **Português (Brasil)** | [Original em inglês](../../reference/email.md)

Envia e-mail através da API HTTP de um provedor. Um transporte é uma função que recebe
uma mensagem normalizada; um deles é fornecido para o formato JSON que Resend, Postmark,
Loops, Plunk e vários outros já têm.

**Quando você precisa disso.** Sua aplicação precisa enviar um e-mail de boas-vindas, uma
redefinição de senha ou um recibo, e há uma conta de provedor por trás disso. O envio fica
sob o que a aplicação já usa para trabalho que não pode falhar a requisição (request), que
geralmente é `akkar.jobs`.

```lua no-run
local email = require "akkar.email"
```

## Um envio que falha é um valor retornado, sempre

Nada neste módulo levanta uma exceção ao enviar. Nem em um argumento inválido, nem em um
transporte que lança um erro, nem em um provedor que retorna um documento que ninguém
esperava. `Mailer:send` responde `id, nil, details` ou `nil, reason, details`, e o
transporte roda dentro de um `pcall` para que uma função de terceiros que lance um erro
volte como o mesmo erro retornado que qualquer outro caso.

O corolário é que ignorar o resultado é silencioso. `Mailer:send_or_log` existe para o
caso comum.

Os dois construtores levantam exceção, de propósito. Eles rodam uma vez, a partir do código
de configuração, e uma URL ausente é uma implantação que deveria se recusar a iniciar, em
vez de uma requisição que falha às três da manhã.

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`email.Mailer`](#emailmailer) | metatabela |
| [`email.address_list`](#emailaddress_listvalue) | função |
| [`email.connect`](#emailconnectconfig) | função |
| [`email.json_api`](#emailjson_apiconfig) | transporte |
| [`email.new`](#emailnewconfig) | função |
| [`email.plausible`](#emailplausibleaddress) | função |
| [`email.resend`](#emailresendconfig) | transporte |
| [`email.validate`](#emailvalidatemessage-defaults) | função |
| [`Mailer:send`](#mailersendmessage) | método |
| [`Mailer:send_or_log`](#mailersend_or_logmessage-log) | método |

## email.Mailer

A metatabela que `email.new` define, exportada para que quem chama possa estendê-la.
`__index` é ela mesma.

## email.address_list(value)

Um endereço ou vários, sempre como uma lista de strings.

**Retorna** uma lista, ou `nil` quando o valor não pode ser uma: não é uma string
e não é uma tabela, é uma tabela contendo um valor que não é string, ou é uma tabela que
não produziu nenhuma entrada. `nil` na entrada gera `nil` na saída.

Aceitar ambos não é açúcar sintático. `to = "a@b.c"` é o que quem chama escreve nove
vezes em dez.

```lua
local email = require "akkar.email"

assert(email.address_list("a@b.c")[1] == "a@b.c")
assert(#email.address_list { "a@b.c", "d@e.f" } == 2)
assert(email.address_list(nil) == nil)
assert(email.address_list {} == nil)
assert(email.address_list { 42 } == nil)
assert(email.address_list(42) == nil)
```

## email.connect(config)

`email.new`, envolvido em uma fábrica, para que isso se leia da mesma forma que `db.connect`
e `http.connect`, onde é conectado como uma capability.

**Retorna** uma função sem argumentos que responde sempre o mesmo mailer.

**Levanta** o que quer que `email.new` levante.

```lua
local email = require "akkar.email"

local connect = email.connect {
  from = "hello@example.com",
  transport = function() return "id_1" end,
}
local mailer = connect()
assert(connect() == mailer)
assert(mailer:send { to = "ada@example.com", subject = "Hi", text = "there" }
       == "id_1")
```

## email.json_api(config)

Um transporte para o formato que a maioria das APIs de e-mail em JSON tem: fazer um POST
de um objeto JSON para uma URL com um token bearer, e receber de volta um objeto com um id.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `url` | string | obrigatório | para onde o POST vai |
| `token` | string | nenhum | a credencial. Nada é enviado quando ela está ausente |
| `token_header` | string | `"authorization"` | em qual cabeçalho o token vai |
| `token_prefix` | string | `"Bearer "` | prefixado ao token. O espaço no final faz parte dele |
| `headers` | table | `{}` | copiado para toda requisição antes do token |
| `fields` | table | `{}` | renomeia campos do corpo: `[nome canônico] = nome do provedor` |
| `extra` | table | `{}` | copiado em todo corpo depois dos campos da própria mensagem |
| `idempotency_header` | string | `"idempotency-key"` | para onde vai o `idempotency_key` de uma mensagem |
| `http` | client | um novo | um cliente `akkar.http` já conectado |
| `timeout` | number | `15` | segundos, usado apenas ao construir o cliente padrão |

O cliente padrão é construído com `retries = 0`. `akkar.http` já se recusa a repetir
um POST; isso declara a intenção no único ponto de chamada em que uma duplicata é um
e-mail duplicado na caixa de entrada de alguém.

O corpo carrega `from`, `to` e `subject` sempre, e `text`, `html`, `cc`, `bcc`,
`reply_to`, `headers` e `tags` quando a mensagem os tem. Cada nome passa por `fields`.
`extra` é aplicado por último, então prevalece sobre todos eles.

**Retorna** uma função de transporte. Ela responde:

| resposta | quando |
|---|---|
| `nil, why` | o cliente não conseguiu fazer a requisição |
| `nil, "the email provider refused it (<status>): <said>", { status, body, decoded }` | um status não 2xx. `said` é o `message`, `error` ou `Message` decodificado, recorrendo ao corpo bruto |
| `<id>, nil, { status, decoded }` | um 2xx com um `id`, `MessageID` ou `message_id` decodificável |
| `true, nil, { status, decoded }` | um 2xx sem nenhum id nele. O envio foi bem-sucedido, e `nil` deixaria o sucesso indistinguível da falha |

**Levanta** `akkar.email: a transport needs a url` quando `url` está ausente. Isso
acontece na construção, não no momento do envio.

Um provedor que não se encaixa não é um problema que isso precise resolver. Um transporte
é uma função, então um provedor fora do padrão é quinze linhas na aplicação.

```lua
local email = require "akkar.email"

-- Um cliente akkar.http entra aqui no lugar, então nada saí do processo.
local seen = {}
local fake = {
  post = function(_, url, options)
    seen.url, seen.headers, seen.body = url, options.headers, options.body
    return { status = 200, body = '{"id":"re_abc"}' }
  end,
}

local transport = email.json_api {
  url = "https://api.example.com/emails",
  token = "a-secret",
  http = fake,
  fields = { text = "TextBody" },
}

local mailer = email.new { transport = transport, from = "hello@example.com" }
local id, why = mailer:send {
  to = "ada@example.com", subject = "Welcome", text = "Glad you are here.",
}

assert(id == "re_abc", why)
assert(seen.url == "https://api.example.com/emails")
assert(seen.headers.authorization == "Bearer a-secret")
assert(seen.body.TextBody == "Glad you are here.")
assert(seen.body.to[1] == "ada@example.com")
```

## email.new(config)

Constrói um mailer.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `transport` | function | obrigatório | chamada com uma mensagem normalizada |
| `from` | string | nenhum | o `from` padrão para toda mensagem |
| `reply_to` | string | nenhum | o `reply_to` padrão para toda mensagem |

**Retorna** o próprio mailer, não uma fábrica, a despeito do que a docstring acima dele
no código-fonte diz. `email.connect` é quem retorna uma fábrica.

**Levanta** `akkar.email: a transport function is required` quando `transport` está
ausente ou não é uma função.

```lua
local email = require "akkar.email"

local sent = {}
local mailer = email.new {
  from = "hello@example.com",
  reply_to = "support@example.com",
  transport = function(message)
    sent[#sent + 1] = message
    return "msg_1"
  end,
}

assert(mailer:send { to = "ada@example.com", subject = "Hi", text = "there" }
       == "msg_1")
assert(sent[1].from == "hello@example.com")
assert(sent[1].reply_to == "support@example.com")

local ok, why = pcall(email.new, { from = "a@b.c" })
assert(ok == false)
assert(why:find("a transport function is required", 1, true))
```

## email.plausible(address)

Uma verificação de sanidade bem frouxa.

**Retorna** `true` quando o endereço tem um `@` na posição 2 ou depois, esse `@`
não é o último caractere, e não há nenhum espaço em branco em nenhum lugar dele. `false`
nos demais casos.

Frouxa de propósito. Validar corretamente significa RFC 5322, e toda expressão regular
de e-mail na internet erra na direção de rejeitar endereços válidos, o que significa que
um usuário real não conseguiria se cadastrar. Isso é muito pior do que enviar uma
mensagem que retorna (bounce), então isso captura apenas os formatos que não podem de
forma alguma ser um endereço, e o provedor decide o resto.

```lua
local email = require "akkar.email"

assert(email.plausible "ada@example.com" == true)
assert(email.plausible "a@b" == true)             -- deliberadamente permitido
assert(email.plausible "nope" == false)
assert(email.plausible "@example.com" == false)   -- nada antes do @
assert(email.plausible "ada@" == false)
assert(email.plausible "ada @example.com" == false)
```

## email.resend(config)

Resend, já pré-conectado. Um provedor concreto, para que a interface tenha um exemplo
prático e ninguém precise adivinhar os nomes dos campos.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `api_key` | string | obrigatório | se torna o token bearer |
| `url` | string | `"https://api.resend.com/emails"` | |
| `http` | client | um novo | passado adiante para `email.json_api` |
| `timeout` | number | `15` | passado adiante |

**Retorna** uma função de transporte, igual a `email.json_api`.

**Levanta** `akkar.email: resend needs an api_key` quando a chave está ausente.

```lua
local email = require "akkar.email"

-- Sem rede: um cliente substituto, para que o transporte seja construído e exercitado
-- sem uma conta Resend.
local fake = {
  post = function() return { status = 200, body = '{"id":"re_1"}' } end,
}
local transport = email.resend { api_key = "re_test_key", http = fake }
local mailer = email.new { transport = transport, from = "hello@example.com" }

assert(mailer:send { to = "ada@example.com", subject = "Hi", text = "there" }
       == "re_1")

local ok, why = pcall(email.resend, {})
assert(ok == false)
assert(why:find("resend needs an api_key", 1, true))
```

## email.validate(message, defaults)

Verifica uma mensagem e a retorna normalizada. Chamada por `Mailer:send`, e exportada
para que quem chama possa verificar uma mensagem antes de colocá-la em uma fila.

`defaults` fornece `from` e `reply_to` onde a mensagem não tem nenhum.

**Retorna** a mensagem normalizada, ou `nil` e um motivo:

| motivo | quando |
|---|---|
| ``a message must be a table`` | `message` não é uma tabela |
| ``a message needs at least one `to` address`` | `address_list(message.to)` respondeu `nil` |
| ``not an email address: <address>`` | qualquer endereço em `to` falha em `email.plausible` |
| ``a message needs a `from` address`` | nem a mensagem nem `defaults` tem uma string não vazia |
| ``a message needs a `subject``` | ausente, não é uma string, ou vazio |
| ``a message needs `text`, `html`, or both`` | ambos são `nil`. Uma mensagem sem nenhum dos dois é um e-mail vazio, o que alguns provedores aceitam silenciosamente |

Apenas os endereços em `to` são verificados quanto à plausibilidade. `cc`, `bcc`, `from`
e `reply_to` não são.

**Levanta** nada.

```lua
local email = require "akkar.email"

local valid = email.validate({
  to = "ada@example.com", subject = "Hi", html = "<p>there</p>",
}, { from = "hello@example.com" })

assert(valid.to[1] == "ada@example.com")
assert(valid.from == "hello@example.com")
assert(valid.text == nil)

assert(select(2, email.validate { subject = "Hi", text = "x" })
       == "a message needs at least one `to` address")
assert(select(2, email.validate({ to = "a@b.c", subject = "Hi" }, { from = "x@y.z" }))
       == "a message needs `text`, `html`, or both")
assert(select(2, email.validate({ to = "nope", subject = "Hi", text = "x" }, { from = "x@y.z" }))
       == "not an email address: nope")
```

## Mailer

O que `email.new(config)` retorna.

### Mailer:send(message)

Valida e envia.

**Retorna** `id, nil, details` no sucesso e `nil, reason, details` na falha. `details`
é o que quer que o transporte tenha retornado em sua terceira posição, e é `nil` quando
a validação falhou ou quando o transporte lançou um erro.

| resposta | quando |
|---|---|
| `nil, <motivo da validação>` | `email.validate` recusou. Sem `details` |
| `nil, "the email transport raised: <error>"` | o transporte lançou um erro. Sem `details` |
| `nil, <motivo do transporte>, <details>` | o transporte respondeu um primeiro valor falso. O motivo recorre a `the email was not sent` |
| `<id>, nil, <details>` | qualquer outra coisa que o transporte tenha retornado |

**Levanta** nada, nunca. Um e-mail de boas-vindas falhando não pode desfazer a criação
da conta.

```lua
local email = require "akkar.email"

local raising = email.new {
  from = "hello@example.com",
  transport = function() error "the provider SDK blew up" end,
}
local id, why = raising:send { to = "a@b.c", subject = "Hi", text = "x" }
assert(id == nil)
assert(why:find("the email transport raised:", 1, true) == 1)

local refusing = email.new {
  from = "hello@example.com",
  transport = function() return nil end,
}
assert(select(2, refusing:send { to = "a@b.c", subject = "Hi", text = "x" })
       == "the email was not sent")
```

### Mailer:send_or_log(message, log)

O mesmo envio, com a falha já registrada em log. `log` é qualquer coisa com um método
`warn`; nada é registrado quando ele está ausente.

A linha de log é `email failed`, com os campos `reason`, `to` (o próprio `to` da
mensagem, antes da normalização) e `status` (a partir de `details`, então `nil` a menos
que o transporte tenha fornecido um).

**Retorna** `id, why`. Dois valores, não os três que `Mailer:send` retorna: `details`
é descartado.

```lua
local email = require "akkar.email"

local warned = {}
local log = { warn = function(_, message, fields)
  warned[#warned + 1] = { message = message, fields = fields }
end }

local mailer = email.new {
  from = "hello@example.com",
  transport = function() return nil, "the provider is down" end,
}

local id, why = mailer:send_or_log({
  to = "ada@example.com", subject = "Hi", text = "x",
}, log)

assert(id == nil)
assert(why == "the provider is down")
assert(warned[1].message == "email failed")
assert(warned[1].fields.reason == "the provider is down")
assert(warned[1].fields.to == "ada@example.com")
```

## A mensagem

O que `Mailer:send` aceita, e o que um transporte recebe após a normalização.

| campo | tipo | obrigatório | notas |
|---|---|---|---|
| `to` | string ou lista | sim | sempre uma lista quando um transporte a recebe |
| `from` | string | sim, ou um padrão no mailer | |
| `subject` | string | sim, não vazio | |
| `text` | string | um entre `text` e `html` | |
| `html` | string | um entre `text` e `html` | |
| `cc` | string ou lista | não | uma lista, ou `nil`, após a normalização |
| `bcc` | string ou lista | não | o mesmo |
| `reply_to` | string | não | recorre ao padrão do mailer |
| `headers` | table | não | passado adiante para o transporte sem alteração |
| `tags` | qualquer coisa | não | passado adiante sem alteração |
| `idempotency_key` | string | não | passado adiante. `email.json_api` o coloca em um cabeçalho |

Nada além disso sobrevive à normalização. Um campo de que o transporte precisa e que não
está nesta lista precisa chegar até ele de outra forma, como o `extra` de `email.json_api`.

## O que não está aqui

**SMTP.** Deliberadamente. Negociação ESMTP, STARTTLS, AUTH em três mecanismos,
dot-stuffing, montagem de MIME e análise de endereços da RFC 5322, e nada disso entrega
e-mail sem SPF, DKIM e um IP de envio aquecido. Se algum dia isso for desejado, pertence
a `akkar/smtp.lua` como um transporte que este módulo pode receber. A costura já está
aqui.

**Repetições (retries).** Um envio que expira pode ter sido entregue, e não há como saber
a partir daqui. Quem chama e quer uma repetição precisa declarar isso com o próprio
`idempotency_key` do provedor, que é o único mecanismo capaz de tornar isso seguro.

**Anexos.** Nenhum campo para eles, e nada é passado adiante que possa carregar um,
exceto um `extra` específico do transporte.

**Templates.** A mensagem carrega `text` e `html` como strings.

**Um substituto (fake) embutido para testes.** Um transporte é uma função, então um
teste escreve `transport = function(message) recorded = message return "id" end` e não
precisa de nada deste módulo. Todo exemplo nesta página faz exatamente isso.

## Veja também

- [akkar.http](http.md), cujo cliente `email.json_api` usa e aceita
- [akkar.jobs](jobs.md), que é onde pertence uma fila de repetições
- `spec/email_spec.lua`
- o código-fonte do módulo, `akkar/email.lua`, para entender por que um envio que falha
  é um valor retornado
