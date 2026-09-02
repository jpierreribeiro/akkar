# akkar.auth

> **Português (Brasil)** | [Original em inglês](../../reference/auth.md)

Decide quem é o chamador, uma vez, antes do handler rodar, e coloca a resposta em
`req.auth`. Três esquemas: um cookie de sessão, um token bearer e uma chave de API.

**Quando você precisa dele.** Qualquer rota que precise saber qual conta está
perguntando. Ele responde apenas autenticação; se essa conta pode fazer essa
coisa específica é o seu `if`, no seu handler.

```lua no-run
local auth = require "akkar.auth"
```

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`auth.api_key`](#authapi_keyreq-header_name) | função |
| [`auth.bearer`](#authbearerreq) | função |
| [`auth.compare_key`](#authcompare_keypresented-stored_hash) | função |
| [`auth.generate_key`](#authgenerate_keyprefix) | função |
| [`auth.hash_key`](#authhash_keykey) | função |
| [`auth.login`](#authloginreq-user_id-extra) | função |
| [`auth.logout`](#authlogoutreq) | função |
| [`auth.middleware`](#authmiddlewareoptions) | middleware |
| [`auth.unauthorized`](#authunauthorizedscheme-message) | resposta |
| [`req.auth`](#o-que-chega-na-requisição) | campo da requisição |
| [`req.auth_scheme`](#o-que-chega-na-requisição) | campo da requisição |
| [`req.session`](#o-que-chega-na-requisição) | campo da requisição |

## auth.api_key(req, header_name)

Extrai uma chave de API de uma requisição (request). Procura primeiro em
`header_name`, depois aceita `Authorization: ApiKey <key>`, porque metade dos
clientes no mundo põem tudo nesse header.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `req` | table | obrigatório | qualquer coisa com uma table `headers`, ou um objeto de headers com um método `get` |
| `header_name` | string | `"x-api-key"` | o header a ser lido |

**Retorna** a chave como uma string, ou `nil`. Um valor de header vazio é `nil`.

```lua
local auth = require "akkar.auth"

print(auth.api_key { headers = { ["x-api-key"] = "sk_abc" } })
print(auth.api_key { headers = { authorization = "ApiKey sk_abc" } })
print(auth.api_key { headers = { authorization = "Bearer t" } })   --> nil
print(auth.api_key({ headers = { ["x-tenant-key"] = "sk_abc" } }, "x-tenant-key"))
```

## auth.bearer(req)

Extrai um token bearer de um header `Authorization`. O esquema é comparado sem
diferenciar maiúsculas de minúsculas, porque a RFC 7235 diz que deve ser assim
e os clientes enviam `bearer`, `Bearer` e ocasionalmente `BEARER`.

**Retorna** o token como uma string, ou `nil` quando o header está ausente ou
seu esquema não é bearer. O token é retornado exatamente como foi enviado;
nada é cortado ou decodificado.

```lua
local auth = require "akkar.auth"

print(auth.bearer { headers = { authorization = "BEARER abc123" } })
print(auth.bearer { headers = { authorization = "Basic dXNlcjpwdw==" } })  --> nil
print(auth.bearer { headers = {} })                                        --> nil
```

## auth.compare_key(presented, stored_hash)

Faz o hash de `presented` e compara com `stored_hash` através de
`akkar.crypto.equal`, em tempo constante.

**Retorna** `true` ou `false`. Qualquer um dos argumentos não sendo uma string
resulta em `false`, não um erro, então um header ausente não precisa ser
validado antes.

```lua
local auth = require "akkar.auth"

local key, hash = auth.generate_key "sk"
print(auth.compare_key(key, hash))          --> true
print(auth.compare_key(key .. "x", hash))   --> false
print(auth.compare_key(nil, hash))          --> false
```

## auth.generate_key(prefix)

Gera uma chave de API e o hash que você armazena para ela. A chave é 24 bytes
de saída CSPRNG em hexadecimal, atrás de `prefix .. "_"`.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `prefix` | string | `"ak"` | o marcador visível na frente da chave |

**Retorna** dois valores, `key` e `hash`, nessa ordem. Mostre a chave para o
chamador uma vez e armazene o hash. Eles são retornados como um par para que
quem escrever `local key, hash = auth.generate_key()` tenha os dois nomes à
frente e não possa armazenar o valor errado por acidente.

O prefixo é um recurso de segurança tanto quanto uma conveniência: scanners de
segredos, incluindo o do GitHub, encontram credenciais vazadas por padrão, e
uma chave que parece qualquer outra string hexadecimal é uma chave que
ninguém consegue detectar em um repositório público.

```lua
local auth = require "akkar.auth"

local key, hash = auth.generate_key "myapp"
print(key:match "^myapp_%x+$" ~= nil)     --> true
print(#key)                               --> 54
print(key == hash)                        --> false
```

## auth.hash_key(key)

A forma armazenada de uma chave de API: SHA-256, codificado em hexadecimal.

Um único SHA-256 em vez de PBKDF2, e isso é deliberado. Uma chave é 24 bytes
aleatórios, então não existe dicionário para rodar contra ela, e colocar
600.000 iterações no caminho quente de uma requisição seria pagar por uma
defesa desnecessária. Uma senha não tem alta entropia, e é por isso que
[`crypto.hash_password`](crypto.md#cryptohash_passwordpassword-options) é uma
função diferente.

**Retorna** uma string hexadecimal de 64 caracteres.

```lua
local auth = require "akkar.auth"
print(auth.hash_key "sk_example")
print(#auth.hash_key "sk_example")        --> 64
```

## auth.login(req, user_id, extra)

Faz o login de um principal: primeiro rotaciona o id de sessão, depois o
registra.

A rotação não é um detalhe. Um atacante que plantou um cookie antes do login
sabe o id depois, a menos que ele mude exatamente nesse momento, e fazer isso
em uma única chamada é o que garante que isso não seja esquecido.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `req` | table | obrigatório | a requisição, que precisa carregar `req.session` |
| `user_id` | any | obrigatório | armazenado sob a chave `user_id` |
| `extra` | table | `{}` | outros pares chave/valor gravados na sessão |

**Retorna** `req.session`. Também define `req.auth = { user_id = user_id }`
para o restante desta requisição, sem esperar pelo armazenamento (store).

**Lança** `akkar.auth: login needs a session; configure `sessions` in the
middleware` quando `req.session` é nil.

## auth.logout(req)

Destrói a sessão no servidor, se houver uma, e limpa `req.auth`. O cookie é
limpo pelo `commit` que o middleware faz na saída.

**Retorna** nada. Uma requisição sem sessão não é um erro.

```lua
local akkar   = require "akkar"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local crypto  = require "akkar.crypto"
local cache   = require "akkar.cache.memory"

local sessions = session.new { secret = crypto.token(32) }

local app = akkar.new()
app:use(auth.middleware { sessions = sessions, optional = true })

app:post("/login", function(req)
  auth.login(req, 1, { email = "ada@example.com" })
  return { ok = true }
end)

app:get("/me", function(req)
  if not req.auth then return akkar.unauthorized "log in first" end
  return { user_id = req.auth.user_id }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return { ok = true }
end)

local client = app:test { cache = cache.factory() }

print("anonymous:", client:get("/me").status)                --> 401

local login = client:post "/login"
local cookie = login.headers["set-cookie"]:match "^([^;]*)"
print("me:", client:get("/me", { headers = { cookie = cookie } }).status)

client:post("/logout", { headers = { cookie = cookie } })
print("after logout:", client:get("/me", { headers = { cookie = cookie } }).status)
```

## auth.middleware(options)

Constrói o middleware. Todo esquema é opcional; os que você configurar são os
que rodam, na ordem sessão, bearer, chave. O primeiro que produzir um
principal vence e os demais não são tentados, porque uma requisição
carregando tanto um cookie quanto uma chave é ambígua, e escolher uma de
forma determinística é melhor do que misturá-las.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `sessions` | manager | nenhum | um gerenciador [`akkar.session`](session.md). Aberto somente quando `req.cache` está presente |
| `load_session` | função | nenhum | `f(req, session)` retornando o principal. Substitui a leitura embutida de `user_id` |
| `bearer` | função | nenhum | `f(req, token)` retornando um principal, ou nil |
| `keys` | função | nenhum | `f(req, key)` retornando um principal, ou nil |
| `key_header` | string | `"x-api-key"` | passado para `auth.api_key` |
| `optional` | boolean | `false` | true permite que uma requisição não autenticada passe com `req.auth` nil |
| `message` | string | `"unauthorized"` | o campo `error` do corpo 401 |

Um resolvedor retorna qualquer valor truthy como o principal, ou `nil` para
recusar. Com `sessions` e sem `load_session`, o principal é `{ user_id =
session:get "user_id" }` quando a sessão contém um.

**Retorna** uma função middleware para `app:use`.

Quando nada produziu um principal e `optional` não é true, ele responde 401
sem chamar o handler. O header `WWW-Authenticate` anuncia o esquema mais forte
configurado: `Cookie` quando `sessions` está definido, senão `Bearer`, para
que um navegador não seja instruído a enviar um token bearer que não possui.

Na saída, se uma sessão foi aberta e ela mudou, `Session:commit` é chamado e o
`Set-Cookie` é anexado a uma **cópia** da resposta (response). Nunca à table
que o handler retornou: uma resposta hoisted ou memoizada é compartilhada
entre requisições, então escrever nela entregaria a sessão de um usuário para
outro.

```lua
local akkar = require "akkar"
local auth  = require "akkar.auth"
local cache = require "akkar.cache.memory"

local KEYS = {}
local key, hash = auth.generate_key "sk"
KEYS[hash] = { account = "acme" }

local app = akkar.new()
app:use(auth.middleware {
  bearer = function(_, token)
    if token == "a-good-token" then return { user_id = 7 } end
  end,
  keys = function(_, presented)
    for stored, principal in pairs(KEYS) do
      if auth.compare_key(presented, stored) then return principal end
    end
  end,
})
app:get("/who", function(req)
  return { scheme = req.auth_scheme, account = req.auth.account or req.auth.user_id }
end)

local client = app:test { cache = cache.factory() }

local refused = client:get "/who"
print(refused.status, refused.headers["www-authenticate"])

print(client:get("/who", { headers = { authorization = "Bearer a-good-token" } }).body.scheme)
print(client:get("/who", { headers = { ["x-api-key"] = key } }).body.account)
print(client:get("/who", { headers = { ["x-api-key"] = "sk_wrong" } }).status)
```

## auth.unauthorized(scheme, message)

O 401 com o qual este módulo responde. Note a ordem dos argumentos: o
**esquema vem primeiro**, diferente de `akkar.unauthorized(message)`, que
recebe apenas uma mensagem.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `scheme` | string | `"Bearer"` | o valor de `WWW-Authenticate` |
| `message` | string | `"unauthorized"` | o campo `error` do corpo |

**Retorna** uma `akkar.response` de verdade, marcada `__response`. Isso
importa mais do que parece: uma table simples `{ status = 401, ... }` é
tratada pelo akkar como um corpo JSON, então ela se torna uma **resposta 200
cujo corpo é a palavra "401"**, e um teste de integração checando `if
res.status == 200` lê uma requisição recusada como uma aceita. A primeira
versão deste módulo tinha esse bug.

`WWW-Authenticate` não é decoração. É o que diz a um cliente qual esquema
tentar, e omiti-lo é o motivo de tantas integrações ficarem chutando.

```lua
local auth = require "akkar.auth"

local res = auth.unauthorized("Bearer", "token expired")
print(res.status, res.body.error, res.headers["www-authenticate"])
print(auth.unauthorized().headers["www-authenticate"])   --> Bearer
```

## O que chega na requisição

| campo | definido quando | valor |
|---|---|---|
| `req.auth` | um resolvedor produziu um principal | o que quer que tenha sido retornado |
| `req.auth_scheme` | o mesmo caso acima | `"session"`, `"bearer"` ou `"api_key"` |
| `req.session` | `sessions` está configurado e `req.cache` está presente | a Session, esteja alguém logado ou não |

`req.session` existe também para um visitante anônimo. É uma sessão vazia com
um id novo que nunca é escrito, porque nada a marcou como suja (dirty).

Se `sessions` está configurado e `cache` não é passado para `app:run{}` ou
`app:test{}`, o bloco de sessão ainda roda, porque o `req.cache` não
configurado é um objeto de guarda em vez de nil. Nada falha até que o
armazenamento seja de fato tocado, o que acontece no primeiro login ou
logout, e então ele lança `req.cache is not configured; pass cache = ... to
app:run{}`.

## O que não está aqui

**Nenhuma autorização: sem papéis, sem permissões, sem linguagem de política,
sem `require_admin`.** Segundo a própria docstring do módulo, autorização "é
lógica de aplicação, depende dos seus recursos e das suas regras, e um
framework que tenta adivinhar isso produz um modelo de permissão que ninguém
consegue ler". O que o akkar te dá é `req.auth`, populado e confiável, e o
`if` é seu. Para a metade do problema referente a tenant, que é mecânica o
suficiente para ser automatizada, veja [akkar.scope](scope.md).

**Nenhum tratamento de senha.** Cadastro, verificação de senha e limitação de
taxa de login são código de aplicação. Veja
[`crypto.hash_password`](crypto.md#cryptohash_passwordpassword-options) e
[akkar.limit](limit.md).

## Veja também

- [akkar.session](session.md), para o cookie e o armazenamento que este
  módulo abre
- [akkar.scope](scope.md), para manter as linhas de uma conta longe das de
  outra depois que você sabe quem está perguntando
- [akkar.csrf](csrf.md), que é o que uma escrita autenticada por cookie ainda
  precisa
- o código-fonte do módulo, `akkar/auth.lua`, para entender por que uma chave
  de API é o esquema que a maioria das integrações de fato usa
