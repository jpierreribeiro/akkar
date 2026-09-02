# akkar.openapi

> **Português (Brasil)** | [Original em inglês](../../reference/openapi.md)

Constrói um documento OpenAPI 3.1 a partir dos esquemas já declarados nas
rotas. Ele lê exatamente as mesmas tabelas que `akkar.validate` lê, então nada
precisa ser escrito uma segunda vez para a documentação.

**Quando você precisa disso.** Quando um frontend, um gerador de cliente ou um
Swagger UI quer uma descrição legível por máquina da API, e você prefere não
manter uma manualmente ao lado da validação que já escreveu.

```lua no-run
local openapi = require "akkar.openapi"
```

Somente essa grafia. `akkar.openapi` não é reexportado pelo módulo de nível
superior.

## openapi.document(app, info)

Percorre o app e cada sub-app montado sob ele, e retorna o documento como uma
tabela Lua pronta para `json.encode`.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `app` | application | obrigatório | o app a descrever |
| `info` | table | `{}` | `title`, `version`, `description` e `components` |

| campo de `info` | tipo | padrão |
|---|---|---|
| `title` | string | `"akkar API"` |
| `version` | string | `"0.0.0"` |
| `description` | string | nenhum, e a chave fica então ausente |
| `components` | table | nenhum, e a chave fica então ausente |

`components` é repassado sem alterações. É onde `securitySchemes` fica, e o
akkar não sabe nada sobre eles (qual cabeçalho, qual fluxo OAuth), então uma
rota que declara `security = { { bearer = {} } }` sem uma entrada `components`
nomeando `bearer` produz uma referência solta em um OpenAPI que, fora isso,
seria válido.

**Retorna** uma tabela com `openapi` (sempre `"3.1.0"`), `info`, `paths`, e
`components` quando `info.components` foi informado. Um app sem rotas recebe
um `paths` vazio.

**Não lança** nada por conta própria. Ele lê `app.routes` e `app.mounts`,
então uma tabela que não é uma aplicação akkar lança erro no ponto em que
esses campos são indexados.

O que acaba em cada operação:

- `operationId`, construído a partir do método e do caminho, com cada
  sequência de caracteres não alfanuméricos substituída por `_` e um `_`
  final removido: `GET /tasks/:id` vira `get_tasks_id`
- `parameters` a partir de `options.params` (em `path`), `options.query` (em
  `query`) e `options.openapi.headers` (em `header`), ordenados por
  localização e depois por nome. Uma rota com `:id` e sem esquema `params`
  ainda recebe um parâmetro de caminho `string` obrigatório, porque o OpenAPI
  exige que toda variável de template seja declarada
- `requestBody` a partir de `options.body`, `required = true`, sob
  `application/json`
- `responses`: uma entrada por status em `options.responses` quando a rota os
  declarou, ou `200` caso contrário, carregando `options.response` como seu
  esquema quando um foi declarado; `422` quando a rota declara qualquer um
  entre `params`, `query` ou `body`; `500` sempre
- `summary`, `description` e `security`, cada um copiado de `options.openapi`
  quando presente

Uma rota sem esquema ainda aparece, sem parâmetros. Um endpoint não
documentado é pior do que um documentado de forma escassa.

`/users/:id` em uma rota vira `/users/{id}` no documento.

```lua
local akkar   = require "akkar"
local openapi = require "akkar.openapi"

local app = akkar.new()
app:get("/tasks/:id", {
  params   = { id = "integer" },
  query    = { verbose = "boolean?" },
  response = { id = "integer", title = "string" },
}, function() return {} end)
app:post("/tasks", { body = { title = "string", done = "boolean?" } },
         function() return {} end)

local health = akkar.new()
health:get("/live", function() return { ok = true } end)
app:mount("/health", health)

local doc = openapi.document(app, { title = "Tasks", version = "1.2.3" })

assert(doc.openapi == "3.1.0")
assert(doc.info.title == "Tasks")
assert(doc.info.version == "1.2.3")

local get = doc.paths["/tasks/{id}"].get
assert(get.operationId == "get_tasks_id")
assert(get.parameters[1].name == "id")
assert(get.parameters[1]["in"] == "path")
assert(get.parameters[1].required == true)
assert(get.parameters[2].name == "verbose")
assert(get.parameters[2]["in"] == "query")
assert(get.parameters[2].required == false)
assert(get.responses["422"].description == "validation failed")

local post = doc.paths["/tasks"].post
assert(post.requestBody.required == true)
local schema = post.requestBody.content["application/json"].schema
assert(schema.properties.title.type == "string")
assert(schema.required[1] == "title")        -- `done` é opcional, então não aparece na lista

-- Um app montado é documentado no prefixo em que ele responde.
assert(doc.paths["/health/live"].get.operationId == "get_health_live")
```

### Como uma regra de validação vira um esquema

| regra | esquema |
|---|---|
| `"string"` | `{ type = "string" }` |
| `"integer"` | `{ type = "integer" }` |
| `"number"` | `{ type = "number" }` |
| `"boolean"` | `{ type = "boolean" }` |
| `"table"` | `{ type = "object" }` |
| um `?` no final | o campo fica de fora de `required` |
| `v.string { min = N }` | `minLength = N` |
| `v.string { max = N }` | `maxLength = N` |
| `v.integer { min = N }` | `minimum = N` |
| `v.integer { max = N }` | `maximum = N` |
| `one_of = { ... }` | `enum` |
| `match = "..."` | `pattern` |
| `openapi_pattern = "..."` | `pattern`, no lugar de `match` |
| `default = value` | `default` |
| `v.object { fields = {...} }` | `{ type = "object", properties = ... }` |
| `v.array { items = rule }` | `{ type = "array", items = ... }` |
| `v.array { min = N }` | `minItems = N` |
| `v.array { max = N }` | `maxItems = N` |
| `v.array {}` | `items` é `{ type = "object" }`, a regra mais ampla |

`min` e `max` vão para um par DIFERENTE de palavras-chave conforme o tipo:
`minLength` e `maxLength` para uma string, `minimum` e `maximum` para um
número ou um inteiro, `minItems` e `maxItems` para um array. Antes eles caíam
em `minimum`/`maximum` para tudo que não fosse string, o que colocava numa
lista uma palavra-chave que o OpenAPI não aplica a arrays, e deixava sem
documentação o limite que o validador de fato aplica: a contagem de
elementos.

Regras de objeto e de array se aninham em qualquer profundidade: o campo de
um objeto pode ser um array e o elemento de um array pode ser um objeto, e
cada nível é descrito em vez de achatado para `{}` ou para uma string. Um
parâmetro de caminho é `required` seja lá o que a regra diga, porque uma
variável de template não pode estar ausente.

`body`, `response` e cada entrada de `responses` podem ser um **mapa de nome
de campo para regra**, que descreve um objeto, ou **uma regra**, que descreve
o valor inteiro: `v.object { fields = ... }`, ou `v.array { items = ... }`
para uma rota cujo corpo ou resposta é uma lista. O validador distingue os
dois casos do mesmo jeito que este módulo distingue, pelo `kind` da regra,
então um corpo documentado como objeto onde a rota aplica uma lista não é uma
inconsistência que possa acontecer.

```lua
local akkar   = require "akkar"
local openapi = require "akkar.openapi"
local v       = akkar.v

local app = akkar.new()
app:post("/users", { body = {
  name = v.string { min = 2, max = 30 },
  role = v.string { one_of = { "admin", "user" }, default = "user" },
  age  = v.integer { min = 0, max = 150, optional = true },
} }, function() return {} end)

local schema = openapi.document(app)
  .paths["/users"].post.requestBody.content["application/json"].schema

assert(schema.properties.name.minLength == 2)
assert(schema.properties.name.maxLength == 30)
assert(schema.properties.role.enum[1] == "admin")
assert(schema.properties.role.default == "user")
assert(schema.properties.age.minimum == 0)
assert(schema.properties.age.maximum == 150)
assert(schema.required[1] == "name")
assert(schema.required[2] == "role")         -- `age` é opcional
```

Uma regra que este módulo não consegue expandir é um erro, nunca um
fallback. Ela costumava virar um esquema vazio `{}` para uma grafia curta
desconhecida e `type: string` para uma tabela sem `kind`, então um array
escrito como tabela aninhada nua — `response = { users = { { id = "string" } }
}` — era documentado como string, e um cliente gerado a partir do documento o
tipava como uma, contra um servidor que envia uma lista. Uma rota recusa essa
tabela onde é declarada agora, nomeando a rota, o caminho e a grafia que
funciona, então uma rota declarada nunca carrega uma. Uma tabela de rota
montada à mão e passada a `document` levanta erro aqui em vez disso —
`akkar.openapi: GET /x: response.users is a table with no schema kind and
cannot be documented` — porque um padrão silencioso é exatamente a mentira
sobre a qual o cliente gerado foi construído.

`match` é copiado para `pattern` sem alteração, e o `match` do akkar é um
padrão Lua, enquanto o `pattern` do OpenAPI é uma expressão regular ECMA-262,
então `match = "^%d+$"` produz um `pattern` que nenhum validador de JSON
Schema vai ler do jeito que o akkar lê. `openapi_pattern` na mesma regra é
onde o autor escreve a restrição para esse leitor, e ele substitui `match` no
documento. O servidor continua aplicando `match`, então isso só pode ser uma
grafia mais legível da mesma regra, nunca uma segunda regra, mais frouxa.

### O que uma rota pode documentar sem validar

`options.openapi` carrega as partes de uma operação que não são validação
alguma. Nada nele é aplicado; este módulo é seu único leitor.

| campo de `openapi` | tipo | vira |
|---|---|---|
| `summary` | string | `operation.summary` |
| `description` | string | `operation.description` |
| `security` | list | `operation.security`, referindo-se a `info.components.securitySchemes` |
| `headers` | mapa de nome para declaração | `parameters` com `in = "header"` |

Uma declaração de cabeçalho aceita `required` (booleano, padrão `false`),
`description` e `schema` (padrão `{ type = "string" }`). Cabeçalhos não são
validados (o akkar não tem esquema de cabeçalho), e é por isso que são
declarados em uma forma própria em vez de como regras.

```lua
local akkar   = require "akkar"
local openapi = require "akkar.openapi"
local v       = akkar.v

local app = akkar.new()

app:get("/ids/:id", { params = {
  -- `%x` é uma classe de caractere Lua; a segunda grafia é para o gerador
  -- de cliente que lê o documento. Ambas significam "hexadecimal".
  id = v.string { match = "^%x+$", openapi_pattern = "^[0-9a-fA-F]+$" },
} }, function(req) return { id = req.params.id } end)

app:post("/charges", {
  responses = { [201] = v.object { fields = { id = "string" } } },
  openapi = {
    summary  = "Charge a card",
    security = { { bearer = {} } },
    headers  = { ["Idempotency-Key"] = { required = true } },
  },
}, function() return akkar.created { id = "ch-1" } end)

local doc = openapi.document(app, {
  components = { securitySchemes = { bearer = { type = "http", scheme = "bearer" } } },
})

assert(doc.paths["/ids/{id}"].get.parameters[1].schema.pattern == "^[0-9a-fA-F]+$")

local post = doc.paths["/charges"].post
assert(post.summary == "Charge a card")
assert(post.security[1].bearer ~= nil)
assert(post.parameters[1].name == "Idempotency-Key")
assert(post.parameters[1]["in"] == "header")
assert(post.parameters[1].required == true)
assert(post.responses["201"].description == "Created")
assert(post.responses["201"].content["application/json"].schema.type == "object")
assert(post.responses["200"] == nil)         -- a rota disse quais status ela responde
assert(doc.components.securitySchemes.bearer.scheme == "bearer")

-- O documento e a aplicação das regras vêm da mesma tabela.
assert(app:test {}:get("/ids/deadbeef").status == 200)
assert(app:test {}:get("/ids/not-hex").status == 422)
```

## openapi.serve(app, path, info)

Registra `GET <path>` no app, respondendo com o documento.

| argumento | tipo | padrão | significado |
|---|---|---|---|
| `app` | application | obrigatório | o app a descrever e no qual registrar a rota |
| `path` | string | `"/openapi.json"` | onde o documento é servido |
| `info` | table | `{}` | repassado para `openapi.document` |

**Retorna** o app, para que a chamada possa ser encadeada.

**Lança** o que quer que `app:get` lance, o que inclui uma rota duplicada
quando `path` já está registrado.

O documento é construído na **primeira requisição (request)** e depois fica em
cache pelo tempo de vida do processo. Rotas registradas depois dessa primeira
requisição não entram nele. Chame `serve` por último, depois que toda rota já
tiver sido declarada.

A própria rota que `serve` registra está no documento, porque o documento é
construído depois que essa rota já existe.

```lua
local akkar   = require "akkar"
local openapi = require "akkar.openapi"

local app = akkar.new()
app:get("/tasks", function() return { ok = true } end)

openapi.serve(app, "/openapi.json", { title = "Tasks", version = "1.0.0" })

local client = app:test {}
local res = client:get "/openapi.json"

assert(res.status == 200)
assert(res.body.openapi == "3.1.0")
assert(res.body.info.title == "Tasks")
assert(res.body.paths["/tasks"] ~= nil)
assert(res.body.paths["/openapi.json"] ~= nil)   -- ele documenta a si mesmo

-- O documento fica em cache depois da primeira requisição.
app:get("/late", function() return {} end)
assert(client:get("/openapi.json").body.paths["/late"] == nil)
```

## O que não está aqui

- **Formatos para os status que o próprio akkar produz.** `422` e `500` são
  descritos, mas sem formato definido. Todo status que a ROTA responde pode
  ter um formato, com `options.response` ou `options.responses`.
- **Tags, servers ou examples.** Adicione chaves à tabela que `document`
  retorna se precisar delas. `components` é repassado a partir de `info`, e
  `security` é declarado por rota em `options.openapi`.
- **Uma UI.** `serve` responde JSON. Aponte o Swagger UI ou o Redoc para ele.
- **Qualquer coisa lida de um comentário.** A única fonte é a tabela
  `options` da rota.

## Veja também

- [akkar](akkar.md) para `app:get(path, options, handler)`, cujos `params`,
  `query`, `body`, `response`, `responses` e `openapi` são toda a entrada
  deste módulo, e para `app:mount`, que decide o prefixo em que um sub-app é
  documentado
- [akkar.json](json.md) para `json.encode`, que transforma a tabela retornada
  no documento que um cliente busca
- o código-fonte do módulo, `akkar/openapi.lua`, para entender por que uma
  declaração é reaproveitada em vez de escrita duas vezes
