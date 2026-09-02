# akkar.openapi

Builds an OpenAPI 3.1 document out of the schemas already declared on the
routes. It reads exactly the tables `akkar.validate` reads, so nothing has to be
written a second time for documentation.

**When you need it.** When a frontend, a client generator or a Swagger UI wants
a machine-readable description of the API, and you would rather not maintain one
by hand next to the validation you already wrote.

```lua no-run
local openapi = require "akkar.openapi"
```

Only this spelling. `akkar.openapi` is not re-exported from the top-level
module.

## openapi.document(app, info)

Walks the app and every sub-app mounted under it, and returns the document as a
Lua table ready for `json.encode`.

| argument | type | default | meaning |
|---|---|---|---|
| `app` | application | required | the app to describe |
| `info` | table | `{}` | `title`, `version`, `description` and `components` |

| `info` field | type | default |
|---|---|---|
| `title` | string | `"akkar API"` |
| `version` | string | `"0.0.0"` |
| `description` | string | none, and the key is then absent |
| `components` | table | none, and the key is then absent |

`components` is passed through untouched. It is where `securitySchemes` lives,
and akkar knows nothing about them — which header, which OAuth flow — so a
route declaring `security = { { bearer = {} } }` without a `components` entry
naming `bearer` produces a dangling reference in otherwise valid OpenAPI.

**Returns** a table with `openapi` (always `"3.1.0"`), `info`, `paths`, and
`components` when `info.components` was given. An app with no routes gets an
empty `paths`.

**Raises** nothing of its own. It reads `app.routes` and `app.mounts`, so a
table that is not an akkar application raises where those are indexed.

What ends up in each operation:

- `operationId`, built from the method and the path with every run of
  non-alphanumeric characters replaced by `_` and a trailing `_` removed:
  `GET /tasks/:id` becomes `get_tasks_id`
- `parameters` from `options.params` (in `path`), `options.query` (in `query`)
  and `options.openapi.headers` (in `header`), sorted by location and then by
  name. A route with `:id` and no `params` schema still gets a required
  `string` path parameter, because OpenAPI requires every template variable to
  be declared
- `requestBody` from `options.body`, `required = true`, under
  `application/json`
- `responses`: one entry per status in `options.responses` when the route
  declared them, otherwise `200`, carrying `options.response` as its schema
  when one was declared; `422` when the route declares any of `params`, `query`
  or `body`; `500` always
- `summary`, `description` and `security`, each copied from `options.openapi`
  when it is there

A route with no schema still appears, without parameters. An undocumented
endpoint is worse than a thinly documented one.

`/users/:id` in a route is `/users/{id}` in the document.

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
assert(schema.required[1] == "title")        -- `done` is optional, so not listed

-- A mounted app is documented at the prefix it answers on.
assert(doc.paths["/health/live"].get.operationId == "get_health_live")
```

### How a validation rule becomes a schema

| rule | schema |
|---|---|
| `"string"` | `{ type = "string" }` |
| `"integer"` | `{ type = "integer" }` |
| `"number"` | `{ type = "number" }` |
| `"boolean"` | `{ type = "boolean" }` |
| `"table"` | `{ type = "object" }` |
| a trailing `?` | the field is left out of `required` |
| `v.string { min = N }` | `minLength = N` |
| `v.string { max = N }` | `maxLength = N` |
| `v.integer { min = N }` | `minimum = N` |
| `v.integer { max = N }` | `maximum = N` |
| `one_of = { ... }` | `enum` |
| `match = "..."` | `pattern` |
| `openapi_pattern = "..."` | `pattern`, in place of `match` |
| `default = value` | `default` |
| `v.object { fields = {...} }` | `{ type = "object", properties = ... }` |
| `v.array { items = rule }` | `{ type = "array", items = ... }` |
| `v.array { min = N }` | `minItems = N` |
| `v.array { max = N }` | `maxItems = N` |
| `v.array {}` | `items` is `{ type = "object" }`, the widest rule |

`min` and `max` go to a DIFFERENT pair of keywords for each kind: `minLength`
and `maxLength` for a string, `minimum` and `maximum` for a number or an
integer, `minItems` and `maxItems` for an array. They used to fall through to
`minimum`/`maximum` for everything that was not a string, which put a keyword
OpenAPI does not apply to arrays on an array and left the one bound the
validator does enforce -- element count -- undocumented.

Object and array rules nest to any depth: an object's field may be an array and
an array's element may be an object, and each level is described rather than
flattened to `{}` or to a string. A path parameter is `required` whatever the
rule says, because a template variable cannot be absent.

`body`, `response` and each entry of `responses` may be a **map of field name to
rule**, which describes an object, or **one rule** describing the whole value —
`v.object { fields = ... }`, or `v.array { items = ... }` for a route whose body
or reply is a list. The validator tells the two apart the same way this module
does, by the rule's `kind`, so a body documented as an object where the route
enforces a list is not a mismatch that can happen.

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
assert(schema.required[2] == "role")         -- `age` is optional
```

A rule this module cannot expand is an error, never a fallback. It used to
become an empty schema `{}` for an unknown shorthand and `type: string` for a
table with no `kind`, so an array written as a bare nested table — `response =
{ users = { { id = "string" } } }` — was documented as a string, and a client
generated from the document typed it as one against a server that sends a
list. A route refuses that table where it is declared now, naming the route,
the path and the spelling that works, so a declared route never carries one.
A route table assembled by hand and passed to `document` raises here instead —
`akkar.openapi: GET /x: response.users is a table with no schema kind and
cannot be documented` — because a quiet default is exactly the lie the
generated client was built on.

`match` is copied to `pattern` unchanged, and akkar's `match` is a Lua pattern
while OpenAPI's `pattern` is an ECMA-262 regular expression, so `match =
"^%d+$"` produces a `pattern` no JSON Schema validator will read the way akkar
does. `openapi_pattern` on the same rule is where the author writes the
constraint for that reader, and it replaces `match` in the document. The server
still enforces `match`, so this can only ever be the more readable spelling of
the same rule — never a second, looser one.

### What a route can document that it does not validate

`options.openapi` carries the parts of an operation that are not validation at
all. Nothing in it is enforced; this module is its only reader.

| `openapi` field | type | becomes |
|---|---|---|
| `summary` | string | `operation.summary` |
| `description` | string | `operation.description` |
| `security` | list | `operation.security`, referring to `info.components.securitySchemes` |
| `headers` | map of name to declaration | `parameters` with `in = "header"` |

A header declaration takes `required` (boolean, default `false`), `description`
and `schema` (default `{ type = "string" }`). Headers are not validated — akkar
has no header schema — which is why they are declared in their own shape rather
than as rules.

```lua
local akkar   = require "akkar"
local openapi = require "akkar.openapi"
local v       = akkar.v

local app = akkar.new()

app:get("/ids/:id", { params = {
  -- `%x` is a Lua character class; the second spelling is for the client
  -- generator reading the document. Both mean "hexadecimal".
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
assert(post.responses["200"] == nil)         -- the route said which statuses it answers
assert(doc.components.securitySchemes.bearer.scheme == "bearer")

-- The document and the enforcement come from the same table.
assert(app:test {}:get("/ids/deadbeef").status == 200)
assert(app:test {}:get("/ids/not-hex").status == 422)
```

## openapi.serve(app, path, info)

Registers `GET <path>` on the app, answering with the document.

| argument | type | default | meaning |
|---|---|---|---|
| `app` | application | required | the app to describe and to register the route on |
| `path` | string | `"/openapi.json"` | where the document is served |
| `info` | table | `{}` | passed to `openapi.document` |

**Returns** the app, so the call chains.

**Raises** whatever `app:get` raises, which includes a duplicate route when
`path` is already registered.

The document is built on the **first request** and then cached for the life of
the process. Routes registered after that first request are not in it. Call
`serve` last, after every route is declared.

The route `serve` itself registers is in the document, because the document is
built after that route exists.

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
assert(res.body.paths["/openapi.json"] ~= nil)   -- it documents itself

-- The document is cached after the first request.
app:get("/late", function() return {} end)
assert(client:get("/openapi.json").body.paths["/late"] == nil)
```

## Not here

- **Shapes for the statuses akkar produces itself.** `422` and `500` are
  described but not shaped. Every status the ROUTE answers can be shaped, with
  `options.response` or `options.responses`.
- **Tags, servers or examples.** Add keys to the table `document` returns if
  you need them. `components` is passed through from `info`, and `security` is
  declared per route on `options.openapi`.
- **A UI.** `serve` answers JSON. Point Swagger UI or Redoc at it.
- **Anything read from a comment.** The only source is the `options` table on
  the route.

## See also

- [akkar](akkar.md) for `app:get(path, options, handler)`, whose `params`,
  `query`, `body`, `response`, `responses` and `openapi` are the whole input to
  this module, and for `app:mount`, which decides the prefix a sub-app is
  documented at
- [akkar.json](json.md) for `json.encode`, which turns the returned table into
  the document a client fetches
- the module source, `akkar/openapi.lua`, for why one declaration is reused
  rather than written twice
