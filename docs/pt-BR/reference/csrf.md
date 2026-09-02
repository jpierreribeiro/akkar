# akkar.csrf

> **Português (Brasil)** | [Original em inglês](../../reference/csrf.md)

Middleware que recusa uma escrita autenticada por cookie que não carregou um token que a página chamadora precisava ler antes. Double submit, com o token vinculado à sessão por um HMAC.

**Quando você precisa disso.** Um navegador envia um POST para sua API com um cookie de sessão. Requisições (requests) que carregam `Authorization` ou uma chave de API são isentas, e isso é um requisito de correção, não uma conveniência: a página de um atacante não consegue fazer o `curl` da vítima adicionar um cabeçalho, então não há credencial ambiente para aproveitar.

```lua no-run
local csrf = require "akkar.csrf"
```

## Índice

Todos os símbolos públicos desta página, em ordem alfabética.

| symbol | kind |
|---|---|
| [`csrf.DEFAULTS`](#csrfdefaults) | tabela |
| [`csrf.issue`](#csrfissuesecret-binding) | função |
| [`csrf.new`](#csrfnewoptions) | middleware |
| [`csrf.SAFE`](#csrfsafe) | tabela |
| [`csrf.valid`](#csrfvalidsecret-token-binding) | função |
| [`req.csrf_token`](#csrfnewoptions) | campo da requisição |

## csrf.DEFAULTS

Os nomes padrão e o tempo de vida padrão do cookie, como uma tabela: `cookie`, `header`, `field`, `session_cookie`, `ttl`. Exportado para que um teste ou um build de frontend possa ler os nomes em vez de repeti-los.

`session_cookie` precisa corresponder ao nome do cookie de [`akkar.session`](session.md), porque é isso que informa a este módulo que uma requisição é autenticada por cookie.

**Retorna** uma tabela.

```lua
local csrf = require "akkar.csrf"

for _, name in ipairs { "cookie", "header", "field", "session_cookie", "ttl" } do
  print(name, csrf.DEFAULTS[name])
end
```

## csrf.issue(secret, binding)

Gera um token vinculado a `binding`. O token é `nonce . HMAC(secret, nonce .. "|" .. binding)`, em que o nonce é 16 bytes em hexadecimal.

`binding` é o que quer que identifique o chamador para quem este token é destinado. O middleware passa o valor do cookie de sessão da vítima, e é isso que torna um token plantado inútil: o token de um atacante está vinculado à sessão do atacante, então não é validado contra a da vítima.

| argument | type | default | meaning |
|---|---|---|---|
| `secret` | string | obrigatório | a chave HMAC |
| `binding` | string | `""` | a que o token está vinculado. `nil` é tratado como `""` |

**Retorna** o token como uma string. Ele não carrega expiração própria: veja `ttl` em `csrf.new`.

```lua
local csrf   = require "akkar.csrf"
local crypto = require "akkar.crypto"

local token = csrf.issue(crypto.token(32), "session-abc")
print(token:match "^%x+%.%x+$" ~= nil)     --> true
print(#token)                              --> 97
```

## csrf.valid(secret, token, binding)

Verdadeiro quando `token` foi emitido por `issue` sob o mesmo `secret` e `binding`. A comparação passa por `akkar.crypto.equal`, em tempo constante, porque um token CSRF é comparado em toda requisição não segura, e um atacante pode tentar novamente livremente.

**Retorna** `true` ou `false`. Um `token` que não é uma string, ou que não corresponde a `^(%x+)%.(%x+)$`, resulta em `false` em vez de um erro.

Não há verificação de tempo aqui. Um token permanece válido enquanto seu binding permanecer, o que na prática significa até o id da sessão rotacionar.

```lua
local csrf   = require "akkar.csrf"
local crypto = require "akkar.crypto"

local SECRET = crypto.token(32)

local token = csrf.issue(SECRET, "session-abc")
print(csrf.valid(SECRET, token, "session-abc"))     --> true

-- Vinculado a uma sessão, inútil contra outra. Esta é a linha que
-- torna isso mais que um double submit simples.
print(csrf.valid(SECRET, token, "session-xyz"))     --> false
print(csrf.valid(crypto.token(32), token, "session-abc"))   --> false
print(csrf.valid(SECRET, "not a token", "session-abc"))     --> false
```

## csrf.new(options)

Constrói o middleware.

| field | type | default | meaning |
|---|---|---|---|
| `secret` | string | obrigatório | a chave HMAC, com pelo menos 32 bytes |
| `cookie` | string | `"akkar_csrf"` | o cookie em que o token é entregue |
| `header` | string | `"x-csrf-token"` | o cabeçalho em que a página o ecoa. Em minúsculas |
| `field` | string | `"_csrf"` | o campo do corpo que um formulário HTML simples usa em vez disso |
| `session_cookie` | string | `"akkar_session"` | o cookie cuja presença significa "autenticado por cookie", e cujo valor é o binding |
| `key_header` | string | `"x-api-key"` | uma requisição que carrega isso é isenta. Em minúsculas |
| `ttl` | number | `43200` (12 horas) | o `Max-Age` do cookie. Não é um tempo de vida do token |
| `applies` | function | nenhum | `f(req)` substituindo o teste embutido. Retornar false isenta a requisição por completo |
| `bind` | function | nenhum | `f(req)` retornando o binding, para uma aplicação cuja sessão não é a do akkar |
| `path` | string | nenhum | passado para o cookie |
| `domain` | string | nenhum | passado para o cookie |
| `secure` | boolean | `true` | `Secure` a menos que seja exatamente `false` |
| `same_site` | string | `"Strict"` | Strict em vez de Lax: por definição, este cookie nunca é necessário em uma requisição que chega de outro lugar |

**Retorna** uma função de middleware para `app:use`.

**Levanta** `akkar.csrf: `secret` must be a string of at least 32 bytes; generate one with akkar.crypto.token(32) and keep it out of the source` quando o secret é curto ou está ausente. Uma chave adivinhável aqui permite que um atacante gere tokens vinculados à sessão da vítima, que é exatamente o que o binding existe para impedir.

Duas coisas que ele define em toda requisição, recusada ou não:

- **`req.csrf_token`**, para que um template possa renderizá-lo em um input oculto e um handler possa repassá-lo a uma single page application no corpo de uma resposta (response) de login. O valor do cookie existente é reaproveitado quando ainda é válido para este binding; caso contrário, um novo é gerado.
- **o cookie `akkar_csrf`**, mas somente em uma resposta a um método seguro, e somente quando a resposta ainda não carrega um `set-cookie`. O akkar escreve um `Set-Cookie` por resposta, e [`akkar.auth`](auth.md) é o dono desse espaço em qualquer resposta que confirma uma sessão. Assim, um POST de login mantém seu cookie de sessão, e o GET seguinte a ele coleta um token CSRF.

O cookie deliberadamente **não** é `HttpOnly`. O próprio script da página precisa ler o valor e ecoá-lo em um cabeçalho, e esse é todo o mecanismo. Um token CSRF não autentica ninguém sozinho, e um XSS capaz de lê-lo já venceu por outros meios.

```lua
local akkar  = require "akkar"
local csrf   = require "akkar.csrf"
local crypto = require "akkar.crypto"

local SECRET = crypto.token(32)

local app = akkar.new()
app:use(csrf.new { secret = SECRET })
app:get("/page", function(req) return { token = req.csrf_token } end)
app:post("/transfer", function() return { moved = true } end)

local client = app:test {}

-- Uma requisição segura coleta o cookie. O token está vinculado ao cookie
-- de sessão que o navegador já estava carregando, então envie isso aqui também.
local session_cookie = "akkar_session=abc"
local page = client:get("/page", { headers = { cookie = session_cookie } })
local cookie = page.headers["set-cookie"]:match "^akkar_csrf=([^;]*)"
print("issued:", cookie == page.body.token)

-- Uma escrita autenticada por cookie sem token é recusada.
local refused = client:post("/transfer", {
  headers = { cookie = session_cookie .. "; akkar_csrf=" .. cookie },
  body = {},
})
print("no header:", refused.status, refused.body.error)

-- A mesma escrita, ecoando o cookie no cabeçalho, é permitida.
local allowed = client:post("/transfer", {
  headers = {
    cookie = session_cookie .. "; akkar_csrf=" .. cookie,
    ["x-csrf-token"] = cookie,
  },
  body = {},
})
print("with header:", allowed.status)

-- Uma requisição com chave de API é isenta: nada ambiente a autentica.
print("api key:", client:post("/transfer", {
  headers = { ["x-api-key"] = "sk_whatever" }, body = {},
}).status)
```

## csrf.SAFE

Os métodos que nunca são verificados, como um set: `GET`, `HEAD`, `OPTIONS`.

`OPTIONS` está na lista porque um preflight de CORS é enviado pelo navegador antes da requisição real e não pode carregar um token; rejeitá-lo quebraria justamente a requisição que o preflight estava liberando.

Um handler que altera estado em um `GET` está fora do que isso pode proteger, e esse é um defeito do handler: essa rota também é armazenada em cache, pré-carregada e reenviada por coisas que não têm nada a ver com segurança.

**Retorna** uma tabela.

```lua
local csrf = require "akkar.csrf"

local methods = {}
for name in pairs(csrf.SAFE) do methods[#methods + 1] = name end
table.sort(methods)
print(table.concat(methods, " "))     --> GET HEAD OPTIONS
```

## Quando o middleware se aplica

Uma requisição é verificada quando **ambas** as condições são verdadeiras: o método não está em `csrf.SAFE`, e a requisição parece autenticada por cookie. A segunda é três perguntas, respondidas a partir dos próprios cabeçalhos da requisição:

1. nenhum cabeçalho `Authorization`, e
2. nenhum `key_header`, e
3. um `session_cookie` está presente.

O teste é feito deliberadamente sobre os cabeçalhos, e nunca sobre `req.auth_scheme`. Ler o que `akkar.auth` decidiu faria essa proteção depender da ordem dos middlewares, e o CSRF se desligando silenciosamente porque alguém reordenou duas linhas de `app:use` seria a pior falha que este arquivo poderia ter.

A pergunta 3 também é o que impede que um POST não autenticado, um cadastro ou um formulário de contato, seja recusado por falta de um token que nunca lhe foi dado.

`options.applies(req)` substitui as três. Ele é lido como um `if`, e não como uma cadeia de `and`/`or`, então retornar `false` isenta genuinamente a requisição em vez de cair no teste embutido.

O token lê primeiro o cabeçalho e depois o campo do corpo. O cabeçalho é o caso que importa, porque só um script same-origin consegue defini-lo. O campo do corpo é para um formulário HTML simples, que não tem script, e sua validade depende apenas de o formulário ser same-origin, o que ele é, porque o token nele foi renderizado por você.

## As três recusas

Todas são `403` com um `akkar.response` de verdade.

| body | when |
|---|---|
| `this request needs a csrf token` (com um `hint` nomeando o cookie e o cabeçalho) | o cookie ou o valor apresentado está ausente |
| `the csrf token does not match the one in the cookie` | eles são diferentes. A metade do double submit |
| `the csrf token is not valid for this session` (com um `hint`) | o HMAC não valida contra este binding. A metade que sobrevive a um cookie plantado |

As duas verificações são executadas, porque falham de forma independente. A igualdade cobre o caso em que ainda não há sessão e o binding está vazio; a assinatura cobre um cookie que um atacante plantou no domínio pai, onde ele escolheu os dois valores e a igualdade passa trivialmente.

A terceira recusa tem uma consequência que vale a pena planejar. `Session:regenerate()` emite um novo id no login, o que **muda o binding**, então um token gerado antes do login deixa de validar depois dele. Um cliente que faz login e imediatamente envia um POST, sem navegação no meio, é recusado uma vez. Um navegador navega, e um script que usa uma chave de API é isento.

## O que não está aqui

**Nenhum synchronizer token.** Nada é armazenado no lado do servidor, e não há uma lista de tokens pendentes para checar ou revogar. Da própria docstring do módulo: o armazenamento de sessão do akkar é um cache que pode ser esvaziado, "esvaziá-lo invalidaria todo formulário pendente, assim como toda sessão, e isso adiciona uma ida e volta ao armazenamento em cada renderização de página". O binding com HMAC oferece a propriedade que a cópia armazenada teria, por um hash e nenhuma consulta.

**Nenhuma expiração de token.** `ttl` é o `Max-Age` do cookie e nada mais; `csrf.valid` não olha para o relógio. O que encerra a vida de um token é o binding mudar, o que acontece no login.

**Nenhuma verificação de Origin ou Referer.** O binding é aquilo em que este módulo se apoia. Uma verificação de cabeçalho seria um segundo mecanismo com sua própria lista de navegadores que omitem o cabeçalho, e `applies` é onde uma aplicação adiciona uma, se quiser.

## Veja também

- [akkar.session](session.md), cujo valor do cookie é o binding e cujo `regenerate` invalida tokens pendentes
- [akkar.auth](auth.md), para entender por que uma requisição com chave de API é isenta, e sobre o único espaço de `Set-Cookie` que os dois módulos compartilham
- o código-fonte do módulo, `akkar/csrf.lua`, para o ataque e para entender por que um double submit simples não é suficiente
