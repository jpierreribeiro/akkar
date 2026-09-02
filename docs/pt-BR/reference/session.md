# akkar.session

> **Português (Brasil)** | [Original em inglês](../../reference/session.md)

Sessões no lado do servidor por trás de um cookie opaco e assinado. O cookie carrega
`<id>.<hmac>`; os dados ficam em `req.cache` sob `session:<id>`.

**Quando você precisa disso.** Um navegador, um humano e um login que precisa sobreviver à
próxima requisição (request) e ser revogável na seguinte. Para scripts e chamadores automatizados,
veja [akkar.auth](auth.md).

```lua no-run
local session = require "akkar.session"
```

## Índice

Todo símbolo público desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`manager:open`](#manageropencache-cookie_header) | método |
| [`session.cookie_header`](#sessioncookie_headername-value-options) | função |
| [`session.new`](#sessionnewoptions) | função |
| [`session.parse_cookies`](#sessionparse_cookiesheader) | função |
| [`session.Session`](#session) | metatabela |
| [`session.Store`](#store) | metatabela |
| [`Session:all`](#sessionall) | método |
| [`Session:commit`](#sessioncommit) | método |
| [`Session:destroy`](#sessiondestroy) | método |
| [`Session:get`](#sessiongetkey) | método |
| [`Session:regenerate`](#sessionregenerate) | método |
| [`Session:set`](#sessionsetkey-value) | método |
| [`Store.new`](#storenewcache-options) | função |
| [`Store:destroy`](#storedestroyid) | método |
| [`Store:key`](#storekeyid) | método |
| [`Store:load`](#storeloadid) | método |
| [`Store:save`](#storesaveid-data) | método |

## session.cookie_header(name, value, options)

Renderiza um valor de `Set-Cookie`. Usado por `Session:commit`, e exportado porque
[akkar.csrf](csrf.md) emite seu próprio cookie com ele.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `options.path` | string | `"/"` | `Path=` |
| `options.max_age` | number | omitido | `Max-Age=`, arredondado para baixo. `0` é escrito, não omitido |
| `options.domain` | string | omitido | `Domain=` |
| `options.http_only` | boolean | ativado | `HttpOnly` é escrito a menos que isso seja exatamente `false` |
| `options.secure` | boolean | ativado | `Secure` é escrito a menos que isso seja exatamente `false` |
| `options.same_site` | string | `"Lax"` | `SameSite=` |

**Retorna** o valor do cabeçalho como uma string. Os três atributos de proteção
vêm ativados por padrão: uma opção que ninguém define é a opção que todo mundo recebe.

```lua
local session = require "akkar.session"

print(session.cookie_header("akkar_session", "abc", { max_age = 3600 }))
print(session.cookie_header("readable", "abc", { http_only = false,
                                                same_site = "Strict" }))
```

## session.new(options)

Constrói um gerenciador de sessão. Um gerenciador é criado na inicialização e reutilizado; ele guarda
a chave secreta de assinatura e as configurações de cookie, e não guarda nenhum estado por requisição.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `secret` | string | obrigatório | a chave de assinatura HMAC, com pelo menos 32 bytes |
| `cookie` | string | `"akkar_session"` | o nome do cookie |
| `ttl` | number | `1209600` (duas semanas) | `Max-Age` do cookie e a expiração no armazenamento (store), em segundos |
| `path` | string | `"/"` | `Path` do cookie |
| `domain` | string | nenhum | `Domain` do cookie |
| `same_site` | string | `"Lax"` | `SameSite` do cookie |
| `http_only` | boolean | `true` | defina como `false` para remover `HttpOnly`, o que um cookie de sessão não deveria fazer |
| `secure` | boolean | `true` | defina como `false` para remover `Secure` |
| `prefix` | string | `"session:"` | prefixo para as chaves de cache |

**Retorna** o gerenciador, que tem um método, `manager:open`.

**Lança um erro** quando `secret` não é uma string de pelo menos 32 bytes:
`akkar.session: `secret` must be a string of at least 32 bytes; generate one
with akkar.crypto.token(32) and keep it out of the source`. O tamanho é
verificado em bytes, então `crypto.token(32)` (64 caracteres hexadecimais) passa com folga.

```lua
local session = require "akkar.session"
local crypto  = require "akkar.crypto"

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
  ttl    = 60 * 60 * 24,
}
print(type(sessions.open))

local ok, why = pcall(session.new, { secret = "hunter2" })
print(ok, why)
```

## session.parse_cookies(header)

Divide um cabeçalho de requisição `Cookie:` em uma tabela de nome para valor. Os valores não são
decodificados nem validados.

**Retorna** uma tabela. Um cabeçalho ausente ou que não seja string retorna uma tabela vazia, nunca
`nil`.

```lua
local session = require "akkar.session"

local cookies = session.parse_cookies "akkar_session=abc; theme=dark"
print(cookies.akkar_session, cookies.theme)
print(next(session.parse_cookies(nil)))     --> nil
```

## Manager

O objeto que `session.new` retorna.

### manager:open(cache, cookie_header)

Carrega a sessão de uma requisição. Chamado para você por
[`auth.middleware`](auth.md#authmiddlewareoptions) quando `sessions` está
configurado.

| argumento | tipo | significado |
|---|---|---|
| `cache` | table | uma capacidade de cache: `get`, `set(key, value, ttl)`, `del`. `req.cache` |
| `cookie_header` | string | o cabeçalho `Cookie:` bruto, ou nil |

**Retorna** uma Session, sempre. Não há caminho de falha que um chamador precise tratar:
um cookie ausente, um cookie cuja assinatura não verifica, um id sem nada
por trás dele no armazenamento, e um estado que o armazenamento não consegue decodificar produzem
uma sessão vazia nova com um id aleatório **novo**. O id apresentado nunca é reutilizado, porque
aceitar um id fornecido por um invasor para uma sessão vazia é fixação de sessão com
passos extras.

O cache não é tocado a menos que a assinatura do cookie tenha verificado, então um cookie forjado
custa um HMAC em vez de uma ida e volta ao Redis.

## Session

O objeto por requisição que `manager:open` retorna. O akkar coloca ele em `req.session`.

### Session:all()

**Retorna** a tabela de dados subjacente, por referência. Escrever nela não marca
a sessão como suja (dirty), então `commit` não vai salvá-la. Use `Session:set`.

### Session:commit()

Escreve a sessão no armazenamento e renderiza o cookie.

**Retorna** o valor de `Set-Cookie`, ou `nil` quando nada mudou. O `nil` é uma
propriedade de corretude e não uma otimização: reescrever o cookie a cada resposta reinicia sua expiração a cada consulta, e uma sessão que nunca expira enquanto
uma aba está aberta é uma sessão que sobrevive ao roubo do notebook.

Quando a sessão foi destruída, ele retorna um cookie com `Max-Age=0` e um
valor vazio, e não escreve nada no armazenamento. Quando o id foi rotacionado, a chave
antiga é apagada antes de a nova ser salva.

`auth.middleware` chama isso para você e anexa o resultado a uma **cópia** da
resposta, nunca à tabela que o handler retornou.

### Session:destroy()

Apaga a sessão do armazenamento imediatamente, incluindo o id de onde ela foi rotacionada,
esvazia os dados e marca como destruída e suja (dirty), de forma que o próximo `commit`
limpe o cookie. As duas partes importam: limpar só o cookie deixa o estado
no armazenamento, então um valor de cookie roubado continua funcionando depois que o usuário apertou "sair".

**Retorna** a Session, para encadeamento.

### Session:get(key)

**Retorna** o valor armazenado, ou `nil`.

### Session:regenerate()

Emite um novo id aleatório de 32 bytes carregando os mesmos dados, e lembra do antigo para que
`commit` possa apagá-lo. Chame isso no momento em que os privilégios mudam;
[`auth.login`](auth.md#authloginreq-user_id-extra) já faz isso.

**Retorna** a Session, para encadeamento.

### Session:set(key, value)

Define um valor e marca a sessão como suja (dirty), o que é o que faz `commit` escrever.

**Retorna** a Session, para encadeamento.

```lua
local session = require "akkar.session"
local crypto  = require "akkar.crypto"
local cache   = require "akkar.cache.memory"

local sessions = session.new { secret = crypto.token(32) }
local store = cache.new()

-- Sem cookie: uma sessão vazia nova, e nada é escrito.
local first = sessions:open(store, nil)
print("empty commit:", first:commit())     --> nil

first:set("user_id", 1)
local set_cookie = first:commit()
print(set_cookie)

-- O navegador o envia de volta na próxima requisição.
local value = set_cookie:match "^akkar_session=([^;]*)"
local second = sessions:open(store, "akkar_session=" .. value)
print("carried:", second:get "user_id")

-- Um byte da assinatura mudou: uma sessão nova e vazia.
local forged = sessions:open(store, "akkar_session=" .. value:gsub("%x$", "0"))
print("forged:", forged:get "user_id")     --> nil

second:destroy()
second:commit()
local third = sessions:open(store, "akkar_session=" .. value)
print("after destroy:", third:get "user_id")   --> nil
```

## Store

O invólucro de cache que uma Session mantém. Exportado como `session.Store` para que uma aplicação
possa alcançar uma sessão que não é a da requisição atual, por exemplo para deslogar
outra pessoa.

`cache` em vez de `db` de propósito: uma sessão é dado chave/valor com expiração, e
colocá-la no Postgres faz de toda requisição que toca uma sessão uma ida e volta ao
banco de dados. O custo é que um flush do cache desloga todo mundo, o que é irritante
e não perigoso.

### Store.new(cache, options)

| campo | tipo | padrão | significado |
|---|---|---|---|
| `options.prefix` | string | `"session:"` | prefixo da chave |
| `options.ttl` | number | `1209600` | expiração passada para `cache:set` |

**Retorna** um Store.

### Store:destroy(id)

Apaga a chave. **Retorna** o que quer que o `del` do cache retorne.

### Store:key(id)

**Retorna** `prefix .. id`, a chave do cache.

### Store:load(id)

Lê a chave e decodifica o JSON. Estado não decodificável, e estado que não
decodifica para uma tabela, é tratado como ausência de sessão em vez de lançar um erro: lançar um erro
transformaria uma chave corrompida em um usuário que não consegue nem logar nem deslogar, porque
toda requisição morreria antes de chegar a um handler.

**Retorna** a tabela de dados, ou `nil`.

### Store:save(id, data)

Codifica `data` em JSON e escreve com o ttl do armazenamento.

```lua
local session = require "akkar.session"
local cache   = require "akkar.cache.memory"

local store = session.Store.new(cache.new(), { prefix = "ref_session_", ttl = 60 })
print(store:key "abc")

store:save("abc", { user_id = 1 })
print(store:load("abc").user_id)

store:destroy "abc"
print(store:load "abc")            --> nil
```

## O que o armazenamento guarda

Os dados de sessão passam por `akkar.json` na entrada e na saída, então o que
volta na próxima requisição é o que o JSON consegue representar, não o que você colocou.
O que surpreende as pessoas: um inteiro Lua retorna como float, então `1` escrito
no login é lido de volta como `1.0`. Isso é igual a `1` em uma comparação Lua e não é
o mesmo valor em uma linha de log ou em uma resposta JSON.

Qualquer coisa que o JSON não consiga codificar também não sobrevive a uma ida e volta. Mantenha as sessões
com strings, números, booleanos e tabelas simples.

## O que não tem aqui

**Nenhum token autocontido, e nenhum JWT.** Da própria docstring do módulo: "Um
token assinado que carrega suas próprias claims não pode ser revogado antes de expirar, e
a revogação é o que uma sessão mais precisa." [akkar.jwt](jwt.md) verifica um
token emitido por outra pessoa, e ele também não tem `issue`.

**Nenhum `flash`, nenhum `csrf`, nenhum helper com escopo de sessão além de get e set.** Uma mensagem
flash é duas linhas de `set` e `get` em uma aplicação. O token CSRF é um
módulo separado, [akkar.csrf](csrf.md), porque ele se aplica a requisições que não têm
sessão nenhuma.

**Nenhuma forma de listar ou enumerar sessões ativas.** O armazenamento é um cache indexado por id,
e um cache não oferece uma varredura (scan). Para deslogar uma pessoa a partir de outro lugar, guarde o
id e chame `Store:destroy`.

## Veja também

- [akkar.auth](auth.md), que abre e faz commit da sessão para você e te dá
  `req.auth`
- [akkar.csrf](csrf.md), cujo token é vinculado ao valor deste cookie e
  portanto para de verificar quando `regenerate` roda
- [akkar.crypto](crypto.md), de onde vêm o `token`, o `hmac` e o `equal` usados aqui
- o código-fonte do módulo, `akkar/session.lua`, para o argumento contra JWT em detalhes
