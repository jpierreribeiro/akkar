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
| `info` | table | `{}` | `title`, `version` and `description` |

| `info` field | type | default |
|---|---|---|
| `title` | string | `"akkar API"` |
| `version` | string | `"0.0.0"` |
| `description` | string | none, and the key is then absent |

**Returns** a table with three keys: `openapi` (always `"3.1.0"`), `info` and
`paths`. An app with no routes gets an empty `paths`.

**Raises** nothing of its own. It reads `app.routes` and `app.mounts`, so a
table that is not an akkar application raises where those are indexed.

What ends up in each operation:

- `operationId`, built from the method and the path with every run of
  non-alphanumeric characters replaced by `_` and a trailing `_` removed:
  `GET /tasks/:id` becomes `get_tasks_id`
- `parameters` from `options.params` (in `path`) and `options.query` (in
  `query`), sorted by name. A route with `:id` and no `params` schema still gets
  a required `string` path parameter, because OpenAPI requires every template
  variable to be declared
- `requestBody` from `options.body`, `required = true`, under
  `application/json`
- `responses`: `200` always, carrying `options.response` as its schema when one
  was declared; `422` when the route declares any of `params`, `query` or
  `body`; `500` always

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
| `default = value` | `default` |
| `{ kind = "object", fields = {...} }` | `{ type = "object", properties = ... }` |
| `{ kind = "array", items = rule }` | `{ type = "array", items = ... }` |
| `{ kind = "array", min = N }` | `minItems = N` |
| `{ kind = "array", max = N }` | `maxItems = N` |

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

Two things this mapping does not do. `match` is copied through unchanged, and
akkar's `match` is a Lua pattern while OpenAPI's `pattern` is an ECMA-262
regular expression, so a rule like `match = "^%d+$"` produces a `pattern` no
JSON Schema validator will read the way akkar does. And a rule this module does
not recognise becomes an empty schema `{}` rather than an error, where a route
declaring it raises `unknown schema type` at the line that declares it — so in
practice a bad rule fails the boot long before this module sees it.

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

- **Response schemas beyond `200`.** `422` and `500` are described but not
  shaped, and no other status is described at all. Declare
  `options.response` for the success body.
- **Tags, security schemes, servers, examples or `components`.** The document
  has `openapi`, `info` and `paths` and nothing else. Add keys to the table
  `document` returns if you need them.
- **A UI.** `serve` answers JSON. Point Swagger UI or Redoc at it.
- **Anything read from a comment.** The only source is the `options` table on
  the route.

## See also

- [akkar](akkar.md) for `app:get(path, options, handler)`, whose `params`,
  `query`, `body` and `response` are the whole input to this module, and for
  `app:mount`, which decides the prefix a sub-app is documented at
- [akkar.json](json.md) for `json.encode`, which turns the returned table into
  the document a client fetches
- the module source, `akkar/openapi.lua`, for why one declaration is reused
  rather than written twice
