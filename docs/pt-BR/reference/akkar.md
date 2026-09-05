# akkar

> **Português (Brasil)** | [Original em inglês](../../reference/akkar.md)

O módulo de nível superior. Ele constrói aplicações, declara rotas, descreve
respostas e executa o servidor.

**Quando você precisa dele.** Todo programa akkar exige este módulo. Nada mais
na referência é alcançável sem ele.

```lua no-run
local akkar = require "akkar"
```

## Índice

Todos os símbolos públicos desta página, em ordem alfabética.

| símbolo | tipo |
|---|---|
| [`akkar.array`](#akkararray) | valor JSON |
| [`akkar.bad_request`](#status-helpers) | resposta |
| [`akkar.check_capabilities`](#akkarcheck_capabilitiesconfig) | função |
| [`akkar.client_ip`](#akkarclient_ippeer-forwarded-trusted) | função |
| [`akkar.conflict`](#status-helpers) | resposta |
| [`akkar.cors`](#akkarcorsoptions) | middleware |
| [`akkar.created`](#status-helpers) | resposta |
| [`akkar.defaults`](#akkardefaults) | tabela |
| [`akkar.empty_array`](#akkarempty_array) | valor JSON |
| [`akkar.etag`](#reexportações) | reexportação |
| [`akkar.etag_of`](#reexportações) | reexportação |
| [`akkar.forbidden`](#status-helpers) | resposta |
| [`akkar.from_spec`](#akkarfrom_specspec-options) | função |
| [`akkar.guard`](#akkarguardname-hint) | função |
| [`akkar.idempotency`](#reexportações) | reexportação |
| [`akkar.in_cidr`](#akkarin_cidraddress-cidr) | função |
| [`akkar.is_response`](#akkaris_responsevalue) | função |
| [`akkar.json`](#reexportações) | reexportação |
| [`akkar.limit`](#reexportações) | reexportação |
| [`akkar.log`](#reexportações) | reexportação |
| [`akkar.method_not_allowed`](#akkarmethod_not_allowedallowed) | resposta |
| [`akkar.metrics`](#reexportações) | reexportação |
| [`akkar.new`](#akkarnew) | função |
| [`akkar.no_content`](#status-helpers) | resposta |
| [`akkar.normalize_host`](#akkarnormalize_hosthost) | função |
| [`akkar.not_found`](#status-helpers) | resposta |
| [`akkar.null`](#akkarnull) | valor JSON |
| [`akkar.ok`](#status-helpers) | resposta |
| [`akkar.parse_query`](#akkarparse_queryquery_string) | função |
| [`akkar.raw`](#akkarrawbody-content_type-status) | resposta |
| [`akkar.response`](#akkarresponsestatus-body-headers) | resposta |
| [`akkar.Response`](#akkarresponse-metatabela) | tabela |
| [`akkar.stream`](#akkarstreamproducer-options) | resposta |
| [`akkar.strict`](#reexportações) | reexportação |
| [`akkar.too_large`](#status-helpers) | resposta |
| [`akkar.trace_context`](#akkartrace_contextheaders) | função |
| [`akkar.unauthorized`](#status-helpers) | resposta |
| [`akkar.unavailable`](#status-helpers) | resposta |
| [`akkar.v`](#akkarv) | tabela |
| [`akkar.validate`](#akkarvalidateinput-schema-coerce) | função |
| [`akkar.work`](#reexportações) | reexportação |
| [`app:delete`](#appget-apppost-appput-apppatch-appdelete) | método |
| [`app:for_host`](#appfor_hosthost) | método |
| [`app:get`](#appget-apppost-appput-apppatch-appdelete) | método |
| [`app:handle_signals`](#apphandle_signalssignals) | método |
| [`app:host`](#apphostpattern-sub) | método |
| [`app:match`](#appmatchmethod-path) | método |
| [`app:methods_for`](#appmethods_forpath) | método |
| [`app:mount`](#appmountprefix-sub) | método |
| [`app:on_error`](#appon_errorfn) | método |
| [`app:patch`](#appget-apppost-appput-apppatch-appdelete) | método |
| [`app:post`](#appget-apppost-appput-apppatch-appdelete) | método |
| [`app:put`](#appget-apppost-appput-apppatch-appdelete) | método |
| [`app:run`](#apprunconfig) | método |
| [`app:stop`](#appstopgrace) | método |
| [`app:stopping`](#appstopping) | método |
| [`app:swap_host`](#appswap_hostpattern-sub) | método |
| [`app:task`](#apptaskname-fn) | método |
| [`app:test`](#apptestconfig) | método |
| [`app:use`](#appusefn) | método |
| [`req`](#a-tabela-da-requisição) | tabela |

## Construindo uma aplicação

### akkar.new()

Cria uma aplicação vazia. Ela não tem rotas nem middleware.

**Retorna** um `App`.

**Levanta erro** nunca.

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/health", function() return { ok = true } end)

local client = app:test {}
assert(client:get("/health").status == 200)
```

### akkar.from_spec(spec, options)

Constrói uma aplicação a partir de uma tabela em vez de chamadas, de modo que
uma aplicação possa ser descrita por dados vindos de fora do processo.

| campo de `spec` | tipo | significado |
|---|---|---|
| `middleware` | lista de strings | nomes resolvidos contra `options.middleware`, instalados em ordem |
| `routes` | lista de tabelas | uma rota cada, descrita abaixo |
| `mounts` | mapa de prefixo para spec ou app | montado com `app:mount` |

| campo de `route` | tipo | padrão | significado |
|---|---|---|---|
| `method` | string | `"GET"` | um de `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` |
| `path` | string | obrigatório | precisa começar com `/` |
| `handler` | string ou função | obrigatório | um nome resolvido contra `options.handlers` |
| `params`, `query`, `body`, `response` | schema | nenhum | os mesmos schemas que [`app:get`](#appget-apppost-appput-apppatch-appdelete) recebe |
| `before` | lista de strings | nenhum | nomes resolvidos contra `options.middleware` |

| campo de `options` | tipo | significado |
|---|---|---|
| `handlers` | tabela | contra o que os nomes de handler são resolvidos |
| `middleware` | tabela | contra o que os nomes de middleware são resolvidos |

Os handlers são nomeados, não carregados diretamente. Um spec que carregasse
uma função deixaria qualquer um que publicasse um spec executar código no
processo. Uma função ainda é aceita no lugar de um nome, para um chamador que
construiu o próprio spec.

**Retorna** um `App`.

**Levanta erro** `akkar.from_spec needs a table` quando `spec` não é uma
tabela, e `akkar.from_spec: route N (METHOD /path): ...` para cada problema
dentro de uma rota: um método desconhecido, um caminho que não começa com `/`,
um nome que não resolve para nada, e qualquer erro que o registro de rota
subjacente levante.

```lua
local akkar = require "akkar"

local handlers = {
  ["users.show"] = function(req) return { id = req.params.id } end,
}

local app = akkar.from_spec({
  routes = {
    { method = "GET", path = "/users/:id",
      params = { id = "integer" }, handler = "users.show" },
  },
}, { handlers = handlers })

local client = app:test {}
assert(client:get("/users/7").body.id == 7)
```

## Declarando rotas

### app:get, app:post, app:put, app:patch, app:delete

    app:get(path, handler)
    app:get(path, options, handler)

Registra uma rota. `options` pode ser omitido.

| argumento | tipo | significado |
|---|---|---|
| `path` | string | `/tasks`, ou `/tasks/:id` onde `:id` captura um segmento do caminho |
| `options` | tabela | validação e middleware de rota, abaixo |
| `handler` | função | chamada com a tabela da requisição (request), retorna a resposta |

| campo de `options` | tipo | significado |
|---|---|---|
| `params` | schema | verificado contra os parâmetros de caminho capturados, com coerção |
| `query` | schema | verificado contra a query string, com coerção |
| `body` | schema | verificado contra o corpo decodificado, sem coerção |
| `response` | schema | verificado contra o que o handler retornou |
| `responses` | tabela de status para schema | verificado contra o que o handler retornou, selecionado pelo status com que respondeu |
| `before` | lista de funções | middleware com escopo de rota, executado depois da cadeia global |
| `openapi` | tabela | apenas documentação: `summary`, `description`, `security`, `headers` |

Uma requisição que falha em `params`, `query` ou `body` responde `422` com
`{ error = "validation failed", fields = { ... } }` antes do handler rodar. Os
nomes dos campos são prefixados com a origem: `params.id`, `query.page`,
`body.title`. Uma tabela validada substitui a bruta, então `req.params.id` é
um número depois de `params = { id = "integer" }`, em vez da string que
chegou.

Um schema aninhado continua nomeando o valor exato: um `sku` inválido no
terceiro elemento de `items` é `body.items.3.sku`, não `body.items`. Um erro
que o cliente não consegue localizar é pouco melhor que nenhum erro, porque um
formulário ainda não consegue dizer qual campo marcar.

`responses` é `response` declarado por status, para a rota cujo `201` tem um
formato que o `200` não tem. O status que o handler respondeu escolhe o
schema, um status sem entrada cai de volta para `response`, e a mesma tabela é
o que `akkar.openapi` documenta, portanto o que é validado e o que é
documentado não podem divergir. `openapi` carrega o que um schema não carrega,
porque não é validação: prosa, um requisito de `security` e `headers` que o
cliente precisa enviar. Nada nele é aplicado, e `akkar.openapi` é seu único
leitor.

A coerção fica ligada para `params` e `query` porque eles chegam como texto, e
desligada para `body` porque o JSON já carrega os tipos.

**Retorna** o app, para que as chamadas se encadeiem.

**Levanta erro** `handler for GET /path is not a function` quando o último
argumento não é chamável; `unknown GET /path option 'bdy'; did you mean
'body'?` para uma opção que não está na lista acima; e
`duplicate route: GET /path`, nomeando o arquivo e a linha dos dois registros,
quando o mesmo método e caminho são registrados duas vezes.

```lua
local akkar = require "akkar"

local app = akkar.new()

app:get("/tasks/:id", { params = { id = "integer" } }, function(req)
  return { id = req.params.id }
end)

app:post("/tasks", { body = { title = "string", done = "boolean?" } },
  function(req) return akkar.created { title = req.body.title } end)

local client = app:test {}

assert(client:get("/tasks/12").body.id == 12)

local bad = client:post("/tasks", { body = { done = true } })
assert(bad.status == 422)
assert(bad.body.fields["body.title"] == "required")
```

### app:mount(prefix, sub)

Monta outra aplicação sob um prefixo de caminho. Uma sub-aplicação é um app
comum, então ela continua testável por conta própria.

| argumento | tipo | significado |
|---|---|---|
| `prefix` | string | o caminho sob o qual a sub-aplicação é alcançada |
| `sub` | App | qualquer aplicação |

**Retorna** o app.

**Levanta erro** nunca, no momento do registro.

```lua
local akkar = require "akkar"

local admin = akkar.new()
admin:get("/stats", function() return { users = 3 } end)

local app = akkar.new()
app:mount("/admin", admin)

local client = app:test {}
assert(client:get("/admin/stats").body.users == 3)
```

### app:use(fn)

Adiciona middleware à cadeia global, executado na ordem de registro.

`fn` é chamada como `fn(req, next)`. Ela retorna uma resposta, ou chama
`next(req)` e retorna o que voltar, possivelmente alterado.

**Retorna** o app.

**Levanta erro** nunca. Registrar depois de `app:test{}` ou `app:run` é
permitido: a cadeia memorizada é descartada, então um middleware tardio ainda
passa a valer.

```lua
local akkar = require "akkar"

local app = akkar.new()

app:use(function(req, next)
  local res = next(req)
  res.headers = res.headers or {}
  res.headers["x-served-by"] = "akkar"
  return res
end)

app:get("/", function() return { ok = true } end)

local client = app:test {}
assert(client:get("/").headers["x-served-by"] == "akkar")
```

### app:on_error(fn)

Registra o que fazer quando akkar está prestes a responder 500.

`fn` é chamada como `fn(err, req)`. `err` é o que foi levantado, sem
alterações. `req` é a requisição, e pode estar ausente para uma falha que
aconteceu antes de ela existir. O valor de retorno passa pela mesma
normalização que o resultado de qualquer handler, então uma string ou um
número viram o 500 padrão. Se a própria `fn` levantar erro, o 500 padrão
assume o controle.

**Retorna** o app.

**Levanta erro** `app:on_error needs a function(err, req)` quando `fn` não é
uma função.

```lua
local akkar = require "akkar"

local app = akkar.new()
local seen

app:on_error(function(err, req)
  seen = tostring(err)
  return akkar.response(500, { instance = req.id })
end)

app:get("/boom", function() error "no" end)

local client = app:test {}
local res = client:get "/boom"

assert(res.status == 500)
assert(res.body.instance ~= nil)
assert(seen:find("no", 1, true))
```

## Roteamento por host

### app:for_host(host)

A aplicação registrada para `host`, ou `nil` quando esta aplicação responde
por ele.

**Retorna** um App ou `nil`.

**Levanta erro** nunca.

### app:host(pattern, sub)

Roteia uma aplicação inteira para um nome de host. O host seleciona a
aplicação inteira: seu middleware, seu tratador de erros e suas rotas, não
apenas as rotas. Um host que não bate com nada cai de volta para as próprias
rotas desta aplicação.

| argumento | tipo | significado |
|---|---|---|
| `pattern` | string | um host exato, ou `*.example.com` para exatamente um rótulo |
| `sub` | App | a aplicação que responde por ele |

Padrões exatos vencem curingas. Portas e um ponto final são removidos antes da
comparação, e a comparação não diferencia maiúsculas de minúsculas.

**Retorna** o app.

**Levanta erro** `akkar: host 'x' is already routed` quando o mesmo padrão é
registrado duas vezes, porque o segundo registro nunca bateria silenciosamente.

```lua
local akkar = require "akkar"

local acme = akkar.new()
acme:get("/who", function() return { tenant = "acme" } end)

local app = akkar.new()
app:get("/who", function() return { tenant = "default" } end)
app:host("acme.example.com", acme)

local client = app:test {}
assert(client:get("/who", { headers = { host = "acme.example.com" } })
       .body.tenant == "acme")
assert(client:get("/who").body.tenant == "default")
```

### app:swap_host(pattern, sub)

Substitui a aplicação que responde por um host sem descartar uma requisição.
Um estado Lua executa uma corrotina por vez e atribuir um campo não cede
controle em nenhum ponto, então nenhuma requisição consegue observar o momento
entre a aplicação antiga e a nova. Uma requisição já em andamento termina
contra a aplicação para a qual foi roteada.

**Retorna** a aplicação que estava ali antes, ou `nil` quando o padrão não
estava registrado e esta chamada o adicionou. Note que isso difere de
[`app:host`](#apphostpattern-sub), que retorna o app para que as chamadas se
encadeiem.

**Levanta erro** nunca para um padrão desconhecido: adicionar por meio de swap
é permitido, porque é assim que a primeira publicação de um tenant se parece.

```lua
local akkar = require "akkar"

local one, two = akkar.new(), akkar.new()
one:get("/v", function() return { v = 1 } end)
two:get("/v", function() return { v = 2 } end)

local app = akkar.new()
assert(app:swap_host("t.example.com", one) == nil)     -- adicionado
assert(app:test{}:get("/v", { headers = { host = "t.example.com" } }).body.v == 1)

assert(app:swap_host("t.example.com", two) == one)     -- substituído
assert(app:test{}:get("/v", { headers = { host = "t.example.com" } }).body.v == 2)
```

### akkar.normalize_host(host)

A forma contra a qual `app:host` e o roteador comparam: minúsculas, sem ponto
final, sem porta. Um literal IPv6 mantém seus colchetes e perde apenas sua
porta.

**Retorna** uma string, ou `nil` quando `host` é `nil`.

```lua
local akkar = require "akkar"

assert(akkar.normalize_host "Example.COM:8080." == "example.com")
assert(akkar.normalize_host "[::1]:8080" == "[::1]")
assert(akkar.normalize_host(nil) == nil)
```

## Inspecionando o roteador

### app:match(method, path)

Encontra a rota que atenderia esta requisição.

**Retorna** a tabela da rota e uma tabela dos parâmetros de caminho
capturados, ou `nil`.

**Levanta erro** nunca.

### app:methods_for(path)

Quais métodos este caminho aceita. É isso que a resposta `405` e o cabeçalho
`allow` são construídos a partir de.

**Retorna** uma lista de strings de verbo, vazia quando nenhuma rota bate com
o caminho.

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/tasks", function() return {} end)
app:post("/tasks", function() return {} end)

local allowed = app:methods_for "/tasks"
table.sort(allowed)
assert(table.concat(allowed, ",") == "GET,POST")

local route, params = app:match("GET", "/tasks")
assert(route.path == "/tasks")
assert(next(params) == nil)
assert(app:match("GET", "/nothing") == nil)
```

## A tabela da requisição

O handler recebe uma tabela, `req`. Ela carrega dois tipos diferentes de
coisa, e apenas um deles é aberto a extensão.

**Dados da requisição**, sempre presentes.

| campo | tipo | significado |
|---|---|---|
| `req.method` | string | o verbo, em maiúsculas |
| `req.path` | string | o caminho, normalizado |
| `req.route` | string | o padrão que deu match, `"/tasks/:id"` |
| `req.params` | tabela | segmentos de caminho capturados, validados quando a rota declara `params` |
| `req.query` | tabela | a query string interpretada, validada quando a rota declara `query` |
| `req.body` | tabela ou `nil` | o corpo decodificado. `nil` quando a requisição não trouxe nenhum |
| `req.raw_body` | string ou nil | o corpo exatamente como chegou, antes da decodificação. `nil` quando a requisição não trouxe nenhum. É sobre isso que um HMAC de assinatura de webhook é calculado: um digest sobre `req.body` recodificado é um digest diferente |
| `req.headers` | tabela | nomes de cabeçalho em minúsculas para valores |
| `req.host` | string ou `nil` | normalizado, a partir de `:authority` ou `host` |
| `req.id` | string | o id da requisição, também enviado de volta como `x-request-id` |
| `req.user` | guard | levanta erro até que algo o defina. Veja a observação abaixo |

**Capabilities**, injetadas a partir de `app:run{}` e adquiridas na primeira
leitura. O conjunto é fechado: `db`, `cache`, `log`, `clock`, `http`. Qualquer
coisa pertencente à aplicação, um serviço de e-mail ou um gateway de
pagamento, é capturada por closure pelo handler em vez disso.

| campo | adquirido |
|---|---|
| `req.db` | na primeira leitura, liberado pelo framework em todo caminho de saída |
| `req.cache` | na primeira leitura |
| `req.log` | sempre disponível, já vinculado a `req.id` |
| `req.clock` | na primeira leitura |
| `req.http` | na primeira leitura |
| `req.ip` | na primeira leitura, a partir do endereço do peer e de `x-forwarded-for` |
| `req.trace` | na primeira leitura, a partir de `traceparent`, `nil` quando o cabeçalho está ausente |

Uma capability que nunca foi configurada é lida como um guard, então tocá-la
levanta `req.db is not configured; pass db = ... to app:run{}` em vez de
indexar um nil.

**`req.user` é um slot para a aplicação, não algo que akkar preenche.** Lê-lo
levanta `req.user is not set; this route is missing the authentication
middleware`, e nenhum módulo do akkar atribui a ele:
[`akkar.auth`](auth.md) define `req.auth` e `req.auth_scheme` em vez disso.
Então uma aplicação usando o middleware de autenticação fornecido ainda
encontra um guard em `req.user`, a menos que seu próprio middleware escreva um.
`akkar.limit` lê `req.user` através de um `pcall` exatamente por esse motivo e
recorre a `req.ip`. Se você quiser `req.user`, defina-o você mesmo:

```lua
local akkar = require "akkar"

local app = akkar.new()

app:use(function(req, next)
  req.user = { id = 1, project_id = 42 }
  return next(req)
end)

app:get("/me", function(req) return { id = req.user.id } end)
assert(app:test{}:get("/me").body.id == 1)
```

## Respostas

Um handler retorna uma tabela, que vira um objeto JSON com status 200, ou
`nil` para 204, ou um dos valores abaixo. Qualquer outra coisa é um 500 com
`handler returned string; return a table, nil, or akkar.*()` no log.

### akkar.response(status, body, headers)

A forma geral. Todo helper abaixo é essa função com um status preenchido.

| argumento | tipo | significado |
|---|---|---|
| `status` | número | o status HTTP |
| `body` | tabela ou `nil` | codificado como JSON |
| `headers` | tabela ou `nil` | cabeçalhos extras de resposta |

**Retorna** uma resposta.

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/teapot", function()
  return akkar.response(418, { error = "no coffee" }, { ["x-pot"] = "short" })
end)

local res = app:test{}:get "/teapot"
assert(res.status == 418)
assert(res.headers["x-pot"] == "short")
```

### Status helpers

| chamada | status | corpo |
|---|---|---|
| `akkar.ok(body)` | 200 | `body` |
| `akkar.created(body)` | 201 | `body` |
| `akkar.no_content()` | 204 | nenhum |
| `akkar.bad_request(message)` | 400 | `{ error = message or "bad request" }` |
| `akkar.unauthorized(message)` | 401 | `{ error = message or "unauthorized" }` |
| `akkar.forbidden(message)` | 403 | `{ error = message or "forbidden" }` |
| `akkar.not_found(message)` | 404 | `{ error = message or "not found" }` |
| `akkar.conflict(message)` | 409 | `{ error = message or "conflict" }` |
| `akkar.too_large(message)` | 413 | `{ error = message or "payload too large" }` |
| `akkar.unavailable(message)` | 503 | `{ error = message or "service unavailable" }` |

Não existe helper para 500. Um 500 é o que akkar responde quando algo levanta
erro, e o corpo permanece deliberadamente vazio porque um erro Lua carrega
caminhos de arquivo e às vezes SQL. Use [`app:on_error`](#appon_errorfn) para
moldá-lo.

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/missing", function() return akkar.not_found "no such task" end)

local res = app:test{}:get "/missing"
assert(res.status == 404)
assert(res.body.error == "no such task")
```

### akkar.method_not_allowed(allowed)

Um 405 carregando o cabeçalho `allow`, construído a partir de uma lista de
verbos. akkar responde isso sozinho quando um caminho existe com outro
método, então um handler raramente o chama.

**Retorna** uma resposta com corpo `{ error = "method not allowed", allowed = allowed }`.

### akkar.raw(body, content_type, status)

Uma resposta que não é JSON: texto Prometheus, uma exportação CSV, um SVG. O
corpo é escrito exatamente como fornecido.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `body` | qualquer | obrigatório | passado por `tostring` |
| `content_type` | string | `"text/plain; charset=utf-8"` | |
| `status` | número | `200` | |

**Retorna** uma resposta cujo campo `raw` guarda o corpo.

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/export.csv", function()
  return akkar.raw("id,title\n1,buy milk\n", "text/csv")
end)

local res = app:test{}:get "/export.csv"
assert(res.raw == "id,title\n1,buy milk\n")
```

### akkar.stream(producer, options)

Uma resposta cujo corpo é produzido conforme é escrito, para uma exportação
que ninguém quer manter em memória. O handler ainda retorna um valor: ele
nunca recebe uma conexão e não pode responder duas vezes.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `producer` | função | obrigatório | chamada com um argumento, `write` |
| `options.status` | número | `200` | |
| `options.content_type` | string | `"application/json"` | |
| `options.headers` | tabela | nenhum | |

Três consequências, cada uma real. O status é confirmado com o primeiro byte,
então um producer que levanta erro depois de escrever não pode virar um 500:
valide antes do primeiro `write`. As capabilities permanecem vivas até o corpo
terminar, então um cliente lento mantém uma conexão de banco de dados por
todo o tempo que ele lê. O deadline cobre o handler, não o corpo.

Sob [`app:test`](#apptestconfig) o corpo inteiro é produzido em memória e
entregue de volta como `raw`, e um producer que levanta erro faz o cliente de
teste levantar erro também.

**Retorna** uma resposta.

**Levanta erro** `akkar.stream needs a function(write); got table` quando
`producer` não é uma função.

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/rows", function()
  return akkar.stream(function(write)
    write "["
    for i = 1, 3 do
      if i > 1 then write "," end
      write(tostring(i))
    end
    write "]"
  end)
end)

assert(app:test{}:get("/rows").raw == "[1,2,3]")
```

### akkar.is_response(value)

Se `value` é uma das respostas acima. O middleware precisa disso para
distinguir uma resposta lançada de um erro levantado, e a alternativa era
comparar metatabelas.

**Retorna** um booleano.

```lua
local akkar = require "akkar"

assert(akkar.is_response(akkar.ok { a = 1 }))
assert(not akkar.is_response { a = 1 })
```

### akkar.Response (metatabela)

A metatabela que toda resposta carrega. Exposta para código que precisa
reconhecer uma; prefira [`akkar.is_response`](#akkaris_responsevalue).

## Validação

### akkar.v

Construtores para regras de schema, um por tipo: `v.string`, `v.integer`,
`v.number`, `v.boolean`, `v.table`, `v.object`, `v.array`. Cada um recebe uma
tabela de restrições e retorna uma regra.

`v.table` é "qualquer tabela, sem exame". `v.object` e `v.array` são os dois
formatos que uma tabela pode de fato ter, e cada um carrega o schema do que
está dentro dela, então um valor aninhado é validado e **filtrado**, em vez de
simplesmente aceito. Isso importa mais em `response`: um handler fazendo
`select *` vaza tudo que a linha contém, e um objeto aninhado que ninguém
filtrou é esse buraco um nível abaixo.

| restrição | aplica-se a | significado |
|---|---|---|
| `optional` | todos | o campo pode estar ausente |
| `default` | todos | usado quando o campo está ausente |
| `min`, `max` | number, integer | limites do valor |
| `min`, `max` | string | limites de comprimento |
| `min`, `max` | array | limites de contagem de elementos |
| `match` | string | um padrão Lua que o valor precisa bater |
| `openapi_pattern` | string | a mesma restrição escrita como uma expressão regular ECMA-262, apenas para `akkar.openapi` |
| `one_of` | string | uma lista de valores permitidos |
| `fields` | object | um schema para os campos do objeto, obrigatório |
| `items` | array | a regra que cada elemento precisa bater, `"table"` quando ausente |

Uma restrição que não está nesta tabela levanta erro onde a regra é escrita,
então `v.string { pattern = "@" }` (`match` é o nome real) falha na linha que
a escreveu, em vez de aceitar toda string em silêncio. `fields` e `items` são
aceitos apenas pelo tipo que os tem: `v.string { fields = ... }` também
levanta erro.

`openapi_pattern` é documentação. `match` é o que de fato roda, então os dois
podem diferir em sintaxe sem diferir em significado, e esse é o ponto, porque
`^%x+$` é um padrão Lua que nenhum validador de JSON Schema vai ler do jeito
que akkar lê.

Existe uma grafia curta para o caso comum. `"string"` é a mesma regra que
`v.string {}`, e um `?` no final a torna opcional: `"integer?"` é
`v.integer { optional = true }`. Os sete nomes de tipo são os únicos aceitos,
e `"object"` levanta erro: uma regra de objeto sem `fields` filtra todo campo
do valor, então isso esvaziaria silenciosamente um corpo em vez de recusar
um. Escreva `v.object { fields = { ... } }`.

Abaixo de um slot, uma tabela é uma regra, e uma regra diz o seu tipo. A grafia
curta de mapa de campos — `body = { to = "string" }` — é a grafia do próprio
slot e de nada abaixo dele: um array escrito como tabela aninhada nua, `users =
{ { id = "string" } }`, ou um objeto um nível abaixo escrito como `user = { name
= "string" }` sem `v.object`, é uma tabela sem `kind`. Uma regra assim não
validava nada, e `akkar.openapi` só conseguia documentá-la errado, então uma
rota que declara uma levanta erro onde é declarada, nomeando a rota, o caminho
e a grafia que funciona: `GET /x: response.users: a table with a positional
entry is not a rule; an array is v.array { items = ... }`. Uma tabela vazia e um
`{ kind = ... }` escrito à mão cujo tipo não é um dos sete são recusados do
mesmo jeito.

```lua no-run
{ title = "string", page = akkar.v.integer { min = 1, default = 1 } }
```

```lua
local akkar = require "akkar"
local v     = akkar.v

local item = v.object { fields = {
  sku      = v.string { min = 2 },
  quantity = v.integer { min = 1, max = 10 },
} }

local app = akkar.new()
app:post("/orders", {
  body = v.object { fields = {
    note  = "string?",
    items = v.array { min = 1, max = 5, items = item },
  } },
}, function(req) return { items = req.body.items } end)

local client = app:test {}

-- Tudo que o schema não nomeia é descartado, em todos os níveis.
local ok = client:post("/orders", { body = {
  ignored = "outside the contract",
  items   = { { sku = "CR-1", quantity = 2, cost_price = 1 } },
} })
assert(ok.status == 200)
assert(ok.body.items[1].sku == "CR-1")
assert(ok.body.items[1].cost_price == nil)

-- Uma falha nomeia o elemento em que aconteceu.
local bad = client:post("/orders", { body = {
  items = { { sku = "x", quantity = 0 }, { sku = "ok" } },
} })
assert(bad.status == 422)
assert(bad.body.fields["body.items.1.sku"] == "min length 2")
assert(bad.body.fields["body.items.1.quantity"] == "min is 1")
assert(bad.body.fields["body.items.2.quantity"] == "required")
```

### akkar.validate(input, schema, coerce)

Verifica uma tabela contra um schema. É isso que a validação de rota chama.

| argumento | tipo | significado |
|---|---|---|
| `input` | tabela | qualquer coisa que não seja uma tabela é tratada como ausente |
| `schema` | tabela | nomes de campo para regras, ou uma regra descrevendo o valor inteiro |
| `coerce` | booleano | converte strings em números e booleanos, e números em strings |

Apenas os campos nomeados no schema aparecem no resultado. Qualquer outra
coisa em `input` é descartada.

Um schema é um **mapa de nome de campo para regra** (`{ id = "integer" }`,
que descreve um objeto) ou **uma regra** descrevendo o valor inteiro, que é o
que `v.object { fields = ... }` e `v.array { items = ... }` são. Uma regra é
reconhecida pelo seu `kind`, então um mapa de campos com um campo genuinamente
chamado `kind` deveria ser escrito por meio de `v.string {}` em vez da forma
abreviada, e uma rota que declara seu schema nunca fica ambígua de jeito
nenhum.

**Retorna** a tabela limpa e `nil`, ou `nil` e uma tabela de caminhos para
strings de falha: `"required"`, `"expected integer"`, `"min length 3"`,
`"must be one of: a, b"`, `"expected array"`, `"min items 1"`. Um caminho
nomeia o valor exato (`items.3.sku`), e uma falha do valor inteiro, em vez de
um campo dele, é reportada sob o caminho vazio `""`.

**Levanta erro** `unknown schema type: 'strng'` para uma forma abreviada que
não é um dos sete tipos, e `invalid schema rule: number` quando uma regra não
é nem uma string nem uma tabela.

Um schema anexado a uma rota nunca chega a esta função nesse estado: as rotas
expandem seus schemas uma vez, onde são declaradas, então o mesmo erro falha
em `app:get(...)` com a rota e o campo nomeados (`GET /users/:id: params.id:
unknown schema type: 'strng'`), em vez de na primeira requisição a ela.

```lua
local akkar = require "akkar"

local clean, failed = akkar.validate(
  { title = "buy milk", extra = "dropped" },
  { title = "string", done = "boolean?" })

assert(clean.title == "buy milk")
assert(clean.extra == nil)
assert(failed == nil)

local _, why = akkar.validate({}, { title = "string" })
assert(why.title == "required")

local coerced = akkar.validate({ page = "2" }, { page = "integer" }, true)
assert(coerced.page == 2)
```

## Valores JSON

### akkar.array

Marca uma tabela como um array JSON, para que uma vazia seja codificada como
`[]` e não `{}`. Uma tabela Lua vazia é ao mesmo tempo uma lista vazia e um
objeto vazio, e o codificador tem de adivinhar.

**Retorna** a mesma tabela, marcada.

### akkar.empty_array

Um valor que sempre é codificado como `[]`.

### akkar.null

O sentinela que é codificado como `null` em JSON. Alcançado através de akkar
em vez de retirado diretamente da biblioteca JSON, então trocar essa
biblioteca não muda a identidade de um valor que as aplicações estão
segurando.

Ele é capturado uma vez, quando `akkar` carrega. [`json.use`](json.md#jsonusereplacement)
reaponta `json.null` e não reaponta este, então um serializador trocado
depois disso deixa as duas grafias segurando valores diferentes. Troque no
boot.

```lua
local akkar = require "akkar"
local json  = require "akkar.json"

assert(json.encode { rows = akkar.array {} } == '{"rows":[]}')
assert(json.encode { rows = {} } == '{"rows":{}}')
assert(json.encode { seen = akkar.null } == '{"seen":null}')
```

## Middleware

### akkar.cors(options)

Middleware que responde ao preflight do navegador e carimba os cabeçalhos de
origem cruzada. É middleware em vez de núcleo porque só a aplicação sabe em
quais origens confia.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `origin` | string | `"*"` | valor de `access-control-allow-origin` |
| `headers` | string | `"content-type, authorization"` | valor de `access-control-allow-headers` |
| `max_age` | número | `600` | segundos que um preflight pode ficar em cache |
| `credentials` | booleano | `false` | define `access-control-allow-credentials` |

Em uma requisição `OPTIONS` os métodos permitidos vêm do próprio cabeçalho
`allow` do roteador quando existe um, então o navegador é informado do que o
roteador de fato aceita.

**Retorna** middleware, para [`app:use`](#appusefn).

```lua
local akkar = require "akkar"

local app = akkar.new()
app:use(akkar.cors { origin = "https://example.com", credentials = true })
app:get("/tasks", function() return { tasks = akkar.array {} } end)

local res = app:test{}:get "/tasks"
assert(res.headers["access-control-allow-origin"] == "https://example.com")
assert(res.headers["access-control-allow-credentials"] == "true")
```

## Executando

### akkar.defaults

As configurações aplicadas a menos que `app:run{}` as sobrescreva, então
`app:run()` sem argumentos já vem no formato de produção.

| campo | valor |
|---|---|
| `body_limit` | `1048576` (1 MB) |
| `header_limit` | `32768` (32 KiB) |
| `header_count_limit` | `100` campos |
| `json_depth_limit` | `64` níveis |
| `timeout` | `30` segundos |
| `read_timeout` | `30` segundos |
| `write_timeout` | `30` segundos |
| `shutdown_grace` | `10` segundos |

### app:run(config)

Vincula um socket e atende. Esta chamada não retorna até o servidor parar.

| campo | tipo | padrão | significado |
|---|---|---|---|
| `host` | string | `"127.0.0.1"` | endereço a ser vinculado |
| `port` | número | `8080` | porta a ser vinculada |
| `tls` | tabela | nenhum | `{ certificate = ..., key = ..., protocol = ... }`, cada um uma string PEM ou um caminho |
| `ctx` | userdata | nenhum | um contexto luaossl, a via de escape além de `tls` |
| `body_limit` | número | `1048576` | bytes, acima dos quais a resposta é 413 |
| `header_limit` | inteiro positivo | `32768` | bytes agregados no fio em HTTP/1 ou de nomes/valores decodificados em HTTP/2; acima disso a requisição é recusada |
| `header_count_limit` | inteiro positivo | `100` | campos de header, incluindo nomes repetidos |
| `json_depth_limit` | inteiro positivo | `64` | arrays/objetos JSON aninhados, verificados antes da decodificação |
| `timeout` | número | `30` | segundos de relógio de parede por requisição, acima dos quais a resposta é 503. **`0` desliga o deadline** |
| `read_timeout` | número positivo | `30` | segundos totais para o peer terminar headers/corpo; enviar aos poucos não reinicia o prazo |
| `write_timeout` | número positivo | `30` | segundos permitidos para uma escrita da resposta, incluindo espera por flow control HTTP/2 |
| `shutdown_grace` | número | `10` | segundos para drenar ao parar |
| `check_capabilities` | booleano | `true` | adquire cada capability uma vez no boot e verifica seu contrato |
| `reuseport` | booleano | nenhum | permite que vários processos compartilhem a porta |
| `strict` | booleano | `false` | liga `akkar.strict`, tornando uma global um erro |
| `max_concurrent` | número | derivado | teto de requisições em andamento, padrão de cerca de um terço do limite de descritores |
| `trusted_proxies` | lista de strings | nenhum | CIDRs cujo `x-forwarded-for` é confiável |
| `db`, `cache`, `log`, `clock`, `http` | tabela ou função | nenhum | capabilities. Uma função é chamada uma vez por requisição que a lê |

Uma capability fornecida como função é chamada por requisição. Se o que ela
retorna tem um método `release`, o framework entrega ao handler uma lease
vinculada à execução e chama `release` no recurso real em todo caminho de
saída. A lease recusa campos e métodos depois que a execução termina, então um
handler que estourou o deadline não pode usar um objeto que talvez já tenha
voltado ao pool. Uma capability fornecida diretamente como tabela pertence ao
processo: ela não é embrulhada, sua identidade e metatable não mudam e o akkar
não a libera a cada requisição.

**Retorna** nada. Ela não retorna.

**Levanta erro** `unknown app:run{} option 'timout'; did you mean 'timeout'?`
para uma chave que não está na lista acima, e a falha de contrato de
`check_capabilities` quando um adaptador não consegue responder a seus
métodos. Um método ausente nomeia tanto a capability quanto o método.

```lua no-run
app:run {
  port = 3000,
  db = open,
  timeout = 15,
  trusted_proxies = { "10.0.0.0/8" },
}
```

### app:handle_signals(signals)

Instala tratadores que chamam [`app:stop`](#appstopgrace). Não é automático,
porque uma biblioteca que instala tratadores de sinal por trás das costas de
uma aplicação briga com o que mais o processo estiver fazendo.

| argumento | tipo | padrão |
|---|---|---|
| `signals` | lista | `{ SIGTERM, SIGINT }` |

**Retorna** o app. Quando `cqueues.signal` está indisponível, registra
`cqueues.signal unavailable; signals not handled` no log e retorna sem
levantar erro.

### app:stop(grace)

Para de aceitar, drena as requisições em andamento, pede que as tasks
terminem, e então fecha os pools e o socket.

As tasks param depois da drenagem, não antes dela, porque uma requisição
ainda em andamento pode enfileirar trabalho. Nada é forçado: um período de
graça expirado é apenas um aviso, e jobs não confirmados voltam na próxima
coleta.

| argumento | tipo | padrão |
|---|---|---|
| `grace` | número | `shutdown_grace` de `app:run{}`, senão 10 |

**Retorna** a string de estado, `"STOPPED"`, ou o estado atual quando o app
não estava rodando.

### app:stopping()

Verdadeiro assim que o servidor drenou e as tasks estão sendo solicitadas a
terminar. Deliberadamente não verdadeiro durante a drenagem.

**Retorna** um booleano.

### app:task(name, fn)

Executa `fn` no próprio event loop do servidor pela vida do processo. `fn`
recebe uma tabela com `stopping`, uma função, que pode ser passada
diretamente ao `should_stop` de um consumidor de fila.

Isso não é paralelismo. Um estado Lua executa uma corrotina por vez, então
uma task que computa sem ceder controle para o servidor por exatamente o
tempo que ela computa. Tasks são para trabalho que espera.

**Retorna** o app.

```lua no-run
app:task("emails", function(task)
  queue:consume(handlers, { should_stop = task.stopping })
end)
```

## Testes

### app:test(config)

Um cliente dentro do processo. Ele percorre o mesmo caminho que uma
requisição real percorre, incluindo middleware, validação e tratamento de
erros, sem vincular um socket.

| campo | tipo | significado |
|---|---|---|
| `db`, `cache`, `log`, `clock`, `http` | qualquer | capabilities, geralmente fakes |
| `timeout` | número | o deadline para toda requisição deste cliente |
| `peer` | string | o endereço de onde as requisições parecem vir |
| `trusted_proxies` | lista de strings | CIDRs cujo `x-forwarded-for` é confiável |

O cliente tem um método por verbo: `get`, `post`, `put`, `patch`, `delete`,
`head`, `options`. Cada um recebe `(path, options)`, onde `path` pode carregar
uma query string e `options` guarda `body`, `headers` e `timeout`.

**Retorna** um cliente. Cada chamada retorna
`{ status = number, body = table, raw = string, headers = table }`.
`headers` é uma tabela nova carregando o que a rede teria carregado,
incluindo `x-request-id`.

**Levanta erro** `unknown app:test{} option 'databse'` para uma chave
desconhecida, e `akkar: stream producer failed after N chunk(s)` quando um
corpo em streaming levanta erro no meio do caminho.

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/whoami", function(req) return { ip = req.ip } end)

local client = app:test { peer = "203.0.113.9" }
local res = client:get "/whoami"

assert(res.status == 200)
assert(res.body.ip == "203.0.113.9")
assert(res.headers["x-request-id"] ~= nil)
```

## Utilitários

### akkar.check_capabilities(config)

Adquire cada capability configurada uma vez, verifica se ela responde ao seu
contrato, e a libera de novo. `app:run{}` chama isso no boot a menos que
`check_capabilities = false`. Exposta para que a verificação possa ser
testada sem vincular um socket.

Os contratos são `db`: `one`, `many`, `exec`, `transaction`. `cache`: `get`,
`set`, `del`. `log`: `debug`, `info`, `warn`, `error`, `with`. `http`:
`request`, `get`, `post`. `clock` não tem contrato.

**Levanta erro** nomeando a capability e o método ausente.

### akkar.client_ip(peer, forwarded, trusted)

O endereço do cliente, dados o peer do socket e o cabeçalho
`x-forwarded-for`.

O cabeçalho só é consultado quando o próprio peer está em `trusted`. Quando
está, a varredura pega a entrada mais à direita que não é ela mesma um proxy
confiável, e recorre ao peer quando todo salto é um deles. Pegar a mais à
esquerda, que é o que a maioria das implementações faz, é a versão
falsificável, porque a entrada mais à esquerda é o que o cliente digitou.

**Retorna** uma string, ou `nil`.

```lua
local akkar = require "akkar"

assert(akkar.client_ip("10.0.0.1", "203.0.113.9, 10.0.0.1", { "10.0.0.0/8" })
       == "203.0.113.9")
assert(akkar.client_ip("198.51.100.4", "203.0.113.9", nil) == "198.51.100.4")
```

### akkar.guard(name, hint)

Um placeholder que levanta `hint` em qualquer leitura, chamada ou escrita. É
isso que `req.user` e uma capability não configurada são antes de serem
definidos, então o erro nomeia o engano em vez de dizer `attempt to index a
nil value`. Guards com o mesmo nome são compartilhados.

**Retorna** uma tabela guard.

```lua
local akkar = require "akkar"

local g = akkar.guard("req.user", "req.user is not set")
assert(tostring(g) == "<req.user missing>")
assert(not pcall(function() return g.id end))
```

### akkar.in_cidr(address, cidr)

Se um endereço IPv4 está dentro de um bloco CIDR. IPv6 nunca bate, o que
falha de forma segura: um cabeçalho encaminhado é ignorado em vez de
acreditado.

**Retorna** um booleano.

```lua
local akkar = require "akkar"

assert(akkar.in_cidr("10.1.2.3", "10.0.0.0/8"))
assert(not akkar.in_cidr("11.1.2.3", "10.0.0.0/8"))
```

### akkar.parse_query(query_string)

Interpreta uma query string em uma tabela, decodificando escapes percentuais.

**Retorna** uma tabela.

```lua
local akkar = require "akkar"

local q = akkar.parse_query "page=2&q=buy%20milk"
assert(q.page == "2")
assert(q.q == "buy milk")
```

### akkar.trace_context(headers)

Interpreta o trace context W3C a partir de uma tabela de cabeçalhos.

**Retorna** uma tabela com os campos de trace, ou `nil` quando não há um
`traceparent` utilizável. Veja [akkar.trace](trace.md).

## Reexportações

Alcançadas através de `akkar` por conveniência. Cada uma tem sua própria
página.

| símbolo | é | página |
|---|---|---|
| `akkar.etag` | `require("akkar.etag").new` | [etag](etag.md) |
| `akkar.etag_of` | `require("akkar.etag").of` | [etag](etag.md) |
| `akkar.idempotency` | `require("akkar.idempotency").new` | [idempotency](idempotency.md) |
| `akkar.json` | o módulo JSON | [json](json.md) |
| `akkar.limit` | o módulo | [limit](limit.md) |
| `akkar.log` | o módulo | [log](log.md) |
| `akkar.metrics` | o módulo | [metrics](metrics.md) |
| `akkar.strict` | o módulo | [strict](strict.md) |
| `akkar.work` | o módulo | [work](work.md) |

Note os dois formatos, porque não são escritos da mesma forma. `akkar.limit`,
`akkar.log`, `akkar.metrics`, `akkar.strict`, `akkar.work` e `akkar.json` são
módulos, então você alcança uma função sobre eles: `akkar.limit.rate {...}`.
`akkar.idempotency`, `akkar.etag` e `akkar.etag_of` já são funções, então são
chamadas diretamente: `akkar.idempotency {...}`.

```lua
local akkar = require "akkar"

assert(type(akkar.limit) == "table" and type(akkar.limit.rate) == "function")
assert(type(akkar.idempotency) == "function")
assert(type(akkar.etag) == "function")
```

## Não está aqui

**Sem `app:head` ou `app:options`.** `HEAD` é atendido pelo handler de `GET`,
e `OPTIONS` é respondido a partir da própria tabela de roteamento, então
nenhum dos dois precisa de rota.

**Sem helper para 500.** Veja [Status helpers](#status-helpers).

**Sem `res:write`, sem `res:send`, sem objeto de contexto.** Um handler
retorna um valor e akkar o escreve. Esse é o invariante sobre o qual todo o
framework é construído: responder duas vezes não é algo que você consegue
expressar. Para um corpo que não cabe em memória, veja
[`akkar.stream`](#akkarstreamproducer-options).

**Sem rota para um caminho curinga.** `:name` captura exatamente um segmento.
Para servir uma árvore de arquivos, veja [akkar.static](static.md).

**Sem ponto de extensão aberto em `req`.** O conjunto de capabilities é
fechado, e os serviços da aplicação são capturados por closure pelo handler.

## Veja também

- [O guia para iniciantes](../guide/00-quickstart.md) se este for o primeiro
  material do akkar que você lê
- [akkar.db](db.md), [akkar.cache](cache.md), [akkar.http](http.md) para as
  capabilities que `app:run{}` injeta
- [akkar.auth](auth.md) e [akkar.session](session.md) para o que define
  `req.auth`, que é onde o middleware fornecido coloca quem chamou
- o código-fonte do módulo, `akkar/init.lua`, para saber por que cada um
  desses pontos é moldado do jeito que é
