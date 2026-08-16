# akkar

The top level module. It builds applications, declares routes, describes
responses, and runs the server.

**When you need it.** Every akkar program requires this module. Nothing else in
the reference is reachable without it.

```lua no-run
local akkar = require "akkar"
```

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`akkar.array`](#akkararray) | JSON value |
| [`akkar.bad_request`](#status-helpers) | response |
| [`akkar.check_capabilities`](#akkarcheck_capabilitiesconfig) | function |
| [`akkar.client_ip`](#akkarclient_ippeer-forwarded-trusted) | function |
| [`akkar.conflict`](#status-helpers) | response |
| [`akkar.cors`](#akkarcorsoptions) | middleware |
| [`akkar.created`](#status-helpers) | response |
| [`akkar.defaults`](#akkardefaults) | table |
| [`akkar.empty_array`](#akkarempty_array) | JSON value |
| [`akkar.etag`](#re-exports) | re-export |
| [`akkar.etag_of`](#re-exports) | re-export |
| [`akkar.forbidden`](#status-helpers) | response |
| [`akkar.from_spec`](#akkarfrom_specspec-options) | function |
| [`akkar.guard`](#akkarguardname-hint) | function |
| [`akkar.idempotency`](#re-exports) | re-export |
| [`akkar.in_cidr`](#akkarin_cidraddress-cidr) | function |
| [`akkar.is_response`](#akkaris_responsevalue) | function |
| [`akkar.json`](#re-exports) | re-export |
| [`akkar.limit`](#re-exports) | re-export |
| [`akkar.log`](#re-exports) | re-export |
| [`akkar.method_not_allowed`](#akkarmethod_not_allowedallowed) | response |
| [`akkar.metrics`](#re-exports) | re-export |
| [`akkar.new`](#akkarnew) | function |
| [`akkar.no_content`](#status-helpers) | response |
| [`akkar.normalize_host`](#akkarnormalize_hosthost) | function |
| [`akkar.not_found`](#status-helpers) | response |
| [`akkar.null`](#akkarnull) | JSON value |
| [`akkar.ok`](#status-helpers) | response |
| [`akkar.parse_query`](#akkarparse_queryquery_string) | function |
| [`akkar.raw`](#akkarrawbody-content_type-status) | response |
| [`akkar.response`](#akkarresponsestatus-body-headers) | response |
| [`akkar.Response`](#akkarresponse-metatable) | table |
| [`akkar.stream`](#akkarstreamproducer-options) | response |
| [`akkar.strict`](#re-exports) | re-export |
| [`akkar.too_large`](#status-helpers) | response |
| [`akkar.trace_context`](#akkartrace_contextheaders) | function |
| [`akkar.unauthorized`](#status-helpers) | response |
| [`akkar.unavailable`](#status-helpers) | response |
| [`akkar.v`](#akkarv) | table |
| [`akkar.validate`](#akkarvalidateinput-schema-coerce) | function |
| [`akkar.work`](#re-exports) | re-export |
| [`app:delete`](#appget-apppost-appput-apppatch-appdelete) | method |
| [`app:for_host`](#appfor_hosthost) | method |
| [`app:get`](#appget-apppost-appput-apppatch-appdelete) | method |
| [`app:handle_signals`](#apphandle_signalssignals) | method |
| [`app:host`](#apphostpattern-sub) | method |
| [`app:match`](#appmatchmethod-path) | method |
| [`app:methods_for`](#appmethods_forpath) | method |
| [`app:mount`](#appmountprefix-sub) | method |
| [`app:on_error`](#appon_errorfn) | method |
| [`app:patch`](#appget-apppost-appput-apppatch-appdelete) | method |
| [`app:post`](#appget-apppost-appput-apppatch-appdelete) | method |
| [`app:put`](#appget-apppost-appput-apppatch-appdelete) | method |
| [`app:run`](#apprunconfig) | method |
| [`app:stop`](#appstopgrace) | method |
| [`app:stopping`](#appstopping) | method |
| [`app:swap_host`](#appswap_hostpattern-sub) | method |
| [`app:task`](#apptaskname-fn) | method |
| [`app:test`](#apptestconfig) | method |
| [`app:use`](#appusefn) | method |
| [`req`](#the-request-table) | table |

## Building an application

### akkar.new()

Creates an empty application. It has no routes and no middleware.

**Returns** an `App`.

**Raises** never.

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/health", function() return { ok = true } end)

local client = app:test {}
assert(client:get("/health").status == 200)
```

### akkar.from_spec(spec, options)

Builds an application from a table instead of from calls, so an application can
be described by data that arrives from outside the process.

| `spec` field | type | meaning |
|---|---|---|
| `middleware` | list of strings | names resolved against `options.middleware`, installed in order |
| `routes` | list of tables | one route each, described below |
| `mounts` | map of prefix to spec or app | mounted with `app:mount` |

| `route` field | type | default | meaning |
|---|---|---|---|
| `method` | string | `"GET"` | one of `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` |
| `path` | string | required | must begin with `/` |
| `handler` | string or function | required | a name resolved against `options.handlers` |
| `params`, `query`, `body`, `response` | schema | none | the same schemas [`app:get`](#appget-apppost-appput-apppatch-appdelete) takes |
| `before` | list of strings | none | names resolved against `options.middleware` |

| `options` field | type | meaning |
|---|---|---|
| `handlers` | table | what handler names resolve against |
| `middleware` | table | what middleware names resolve against |

Handlers are named, not carried. A spec that carried a function would let anyone
who can publish a spec run code in the process. A function is still accepted in
place of a name, for a caller that built the spec itself.

**Returns** an `App`.

**Raises** `akkar.from_spec needs a table` when `spec` is not one, and
`akkar.from_spec: route N (METHOD /path): ...` for every problem inside a route:
an unknown method, a path that does not begin with `/`, a name that resolves to
nothing, and any error the underlying route registration raises.

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

## Declaring routes

### app:get, app:post, app:put, app:patch, app:delete

    app:get(path, handler)
    app:get(path, options, handler)

Registers one route. `options` may be omitted.

| argument | type | meaning |
|---|---|---|
| `path` | string | `/tasks`, or `/tasks/:id` where `:id` captures one path segment |
| `options` | table | validation and route middleware, below |
| `handler` | function | called with the request table, returns the response |

| `options` field | type | meaning |
|---|---|---|
| `params` | schema | checked against the captured path parameters, with coercion |
| `query` | schema | checked against the query string, with coercion |
| `body` | schema | checked against the decoded body, without coercion |
| `response` | schema | checked against what the handler returned |
| `before` | list of functions | route scoped middleware, run after the global chain |

A request that fails `params`, `query` or `body` answers `422` with
`{ error = "validation failed", fields = { ... } }` before the handler runs. The
field names are prefixed with where they came from: `params.id`, `query.page`,
`body.title`. A validated table replaces the raw one, so `req.params.id` is a
number after `params = { id = "integer" }` rather than the string that arrived.

Coercion is on for `params` and `query` because those arrive as text, and off
for `body` because JSON already carries types.

**Returns** the app, so calls chain.

**Raises** `handler for GET /path is not a function` when the last argument is
not callable; `unknown GET /path option 'bdy'; did you mean 'body'?` for an
option that is not in the list above; and `duplicate route: GET /path`, naming
the file and line of both registrations, when the same method and path are
registered twice.

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

Mounts another application under a path prefix. A sub-application is an ordinary
app, so it stays testable on its own.

| argument | type | meaning |
|---|---|---|
| `prefix` | string | the path the sub-application is reached under |
| `sub` | App | any application |

**Returns** the app.

**Raises** never at registration time.

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

Adds middleware to the global chain, run in registration order.

`fn` is called as `fn(req, next)`. It returns a response, or calls `next(req)`
and returns what comes back, possibly changed.

**Returns** the app.

**Raises** never. Registering after `app:test{}` or `app:run` is allowed: the
memoised chain is discarded so late middleware still takes effect.

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

Registers what to do when akkar is about to answer 500.

`fn` is called as `fn(err, req)`. `err` is whatever was raised, untouched. `req`
is the request, and may be absent for a failure that happened before one
existed. The return value goes through the same normalisation as any handler
result, so a string or a number becomes the default 500. If `fn` itself raises,
the default 500 takes over.

**Returns** the app.

**Raises** `app:on_error needs a function(err, req)` when `fn` is not a function.

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

## Host routing

### app:for_host(host)

The application registered for `host`, or `nil` when this application answers
for it.

**Returns** an App or `nil`.

**Raises** never.

### app:host(pattern, sub)

Routes a whole application to a host name. The host selects the entire
application: its middleware, its error handler and its routes, not only the
routes. A host matching nothing falls through to this application's own routes.

| argument | type | meaning |
|---|---|---|
| `pattern` | string | an exact host, or `*.example.com` for exactly one label |
| `sub` | App | the application that answers for it |

Exact patterns beat wildcards. Ports and a trailing dot are stripped before
matching, and matching is case insensitive.

**Returns** the app.

**Raises** `akkar: host 'x' is already routed` when the same pattern is
registered twice, because the second registration would silently never match.

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

Replaces the application answering for a host without dropping a request. One
Lua state runs one coroutine at a time and assigning a field yields nowhere, so
no request can observe the moment between the old application and the new one. A
request already in flight finishes against the application it was routed to.

**Returns** the application that was there before, or `nil` when the pattern was
not registered and this call added it. Note that this differs from
[`app:host`](#apphostpattern-sub), which returns the app so calls can chain.

**Raises** never for an unknown pattern: adding through swap is allowed,
because that is what the first publish of a tenant looks like.

```lua
local akkar = require "akkar"

local one, two = akkar.new(), akkar.new()
one:get("/v", function() return { v = 1 } end)
two:get("/v", function() return { v = 2 } end)

local app = akkar.new()
assert(app:swap_host("t.example.com", one) == nil)     -- added
assert(app:test{}:get("/v", { headers = { host = "t.example.com" } }).body.v == 1)

assert(app:swap_host("t.example.com", two) == one)     -- replaced
assert(app:test{}:get("/v", { headers = { host = "t.example.com" } }).body.v == 2)
```

### akkar.normalize_host(host)

The form `app:host` and the router compare against: lower case, without a
trailing dot, without a port. An IPv6 literal keeps its brackets and loses only
its port.

**Returns** a string, or `nil` when `host` is `nil`.

```lua
local akkar = require "akkar"

assert(akkar.normalize_host "Example.COM:8080." == "example.com")
assert(akkar.normalize_host "[::1]:8080" == "[::1]")
assert(akkar.normalize_host(nil) == nil)
```

## Inspecting the router

### app:match(method, path)

Finds the route that would serve this request.

**Returns** the route table and a table of captured path parameters, or `nil`.

**Raises** never.

### app:methods_for(path)

Which methods this path accepts. This is what the `405` response and the `allow`
header are built from.

**Returns** a list of verb strings, empty when no route matches the path.

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

## The request table

The handler receives one table, `req`. It carries two different kinds of thing
and only one of them is open to extension.

**Request data**, always present.

| field | type | meaning |
|---|---|---|
| `req.method` | string | the verb, upper case |
| `req.path` | string | the path, normalised |
| `req.route` | string | the pattern that matched, `"/tasks/:id"` |
| `req.params` | table | captured path segments, validated when the route declares `params` |
| `req.query` | table | the parsed query string, validated when the route declares `query` |
| `req.body` | table or `nil` | the decoded body. `nil` when the request carried none |
| `req.headers` | table | lower case header names to values |
| `req.host` | string or `nil` | normalised, from `:authority` or `host` |
| `req.id` | string | the request id, also sent back as `x-request-id` |
| `req.user` | guard | raises until something sets it. See the note below |

**Capabilities**, injected from `app:run{}` and acquired on first read. The set
is closed: `db`, `cache`, `log`, `clock`, `http`. Anything belonging to the
application, a mailer or a payment gateway, is closed over by the handler
instead.

| field | acquired |
|---|---|
| `req.db` | on first read, released by the framework on every exit path |
| `req.cache` | on first read |
| `req.log` | always available, already bound to `req.id` |
| `req.clock` | on first read |
| `req.http` | on first read |
| `req.ip` | on first read, from the peer address and `x-forwarded-for` |
| `req.trace` | on first read, from `traceparent`, `nil` when the header is absent |

A capability that was never configured reads as a guard, so touching it raises
`req.db is not configured; pass db = ... to app:run{}` rather than indexing a
nil.

**`req.user` is a slot for the application, not one akkar fills.** Reading it
raises `req.user is not set; this route is missing the authentication
middleware`, and no module in akkar assigns it:
[`akkar.auth`](auth.md) sets `req.auth` and `req.auth_scheme` instead. So an
application using the shipped authentication middleware still finds a guard at
`req.user` unless its own middleware writes one. `akkar.limit` reads `req.user`
through a `pcall` for exactly this reason and falls back to `req.ip`. If you
want `req.user`, set it yourself:

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

## Responses

A handler returns a table, which becomes a JSON object with status 200, or `nil`
for 204, or one of the values below. Anything else is a 500 with
`handler returned string; return a table, nil, or akkar.*()` in the log.

### akkar.response(status, body, headers)

The general form. Every helper below is this function with a status filled in.

| argument | type | meaning |
|---|---|---|
| `status` | number | the HTTP status |
| `body` | table or `nil` | encoded as JSON |
| `headers` | table or `nil` | extra response headers |

**Returns** a response.

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

| call | status | body |
|---|---|---|
| `akkar.ok(body)` | 200 | `body` |
| `akkar.created(body)` | 201 | `body` |
| `akkar.no_content()` | 204 | none |
| `akkar.bad_request(message)` | 400 | `{ error = message or "bad request" }` |
| `akkar.unauthorized(message)` | 401 | `{ error = message or "unauthorized" }` |
| `akkar.forbidden(message)` | 403 | `{ error = message or "forbidden" }` |
| `akkar.not_found(message)` | 404 | `{ error = message or "not found" }` |
| `akkar.conflict(message)` | 409 | `{ error = message or "conflict" }` |
| `akkar.too_large(message)` | 413 | `{ error = message or "payload too large" }` |
| `akkar.unavailable(message)` | 503 | `{ error = message or "service unavailable" }` |

There is no helper for 500. A 500 is what akkar answers when something raised,
and the body stays deliberately bare because a Lua error carries file paths and
sometimes SQL. Use [`app:on_error`](#appon_errorfn) to shape it.

```lua
local akkar = require "akkar"

local app = akkar.new()
app:get("/missing", function() return akkar.not_found "no such task" end)

local res = app:test{}:get "/missing"
assert(res.status == 404)
assert(res.body.error == "no such task")
```

### akkar.method_not_allowed(allowed)

A 405 carrying the `allow` header, built from a list of verbs. akkar answers
this itself when a path exists with another method, so a handler rarely calls
it.

**Returns** a response with body `{ error = "method not allowed", allowed = allowed }`.

### akkar.raw(body, content_type, status)

A response that is not JSON: Prometheus text, a CSV export, an SVG. The body is
written exactly as given.

| argument | type | default | meaning |
|---|---|---|---|
| `body` | any | required | passed through `tostring` |
| `content_type` | string | `"text/plain; charset=utf-8"` | |
| `status` | number | `200` | |

**Returns** a response whose `raw` field holds the body.

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

A response whose body is produced as it is written, for an export nobody wants
to hold in memory. The handler still returns a value: it never receives a
connection and cannot answer twice.

| argument | type | default | meaning |
|---|---|---|---|
| `producer` | function | required | called with one argument, `write` |
| `options.status` | number | `200` | |
| `options.content_type` | string | `"application/json"` | |
| `options.headers` | table | none | |

Three consequences, each real. The status is committed with the first byte, so a
producer that raises after writing cannot become a 500: validate before the
first `write`. Capabilities stay alive until the body is finished, so a slow
client holds a database connection for as long as it reads. The deadline covers
the handler, not the body.

Under [`app:test`](#apptestconfig) the whole body is produced into memory and
handed back as `raw`, and a producer that raises makes the test client raise
too.

**Returns** a response.

**Raises** `akkar.stream needs a function(write); got table` when `producer` is
not a function.

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

Whether `value` is one of the responses above. Middleware needs this to tell a
thrown response from a raised error, and the alternative was comparing
metatables.

**Returns** a boolean.

```lua
local akkar = require "akkar"

assert(akkar.is_response(akkar.ok { a = 1 }))
assert(not akkar.is_response { a = 1 })
```

### akkar.Response (metatable)

The metatable every response carries. Exposed for code that has to recognise
one; prefer [`akkar.is_response`](#akkaris_responsevalue).

## Validation

### akkar.v

Builders for schema rules, one per type: `v.string`, `v.integer`, `v.number`,
`v.boolean`, `v.table`. Each takes a table of constraints and returns a rule.

| constraint | applies to | meaning |
|---|---|---|
| `optional` | all | the field may be absent |
| `default` | all | used when the field is absent |
| `min`, `max` | number, integer | value bounds |
| `min`, `max` | string | length bounds |
| `match` | string | a Lua pattern the value must match |
| `one_of` | string | a list of permitted values |

There is a short spelling for the common case. `"string"` is the same rule as
`v.string {}`, and a trailing `?` makes it optional: `"integer?"` is
`v.integer { optional = true }`. The five type names are the only ones accepted.

```lua no-run
{ title = "string", page = akkar.v.integer { min = 1, default = 1 } }
```

### akkar.validate(input, schema, coerce)

Checks a table against a schema. This is what route validation calls.

| argument | type | meaning |
|---|---|---|
| `input` | table | anything that is not a table is treated as absent |
| `schema` | table | field names to rules |
| `coerce` | boolean | convert strings to numbers and booleans, and numbers to strings |

Only fields named in the schema appear in the result. Anything else in `input`
is dropped.

**Returns** the cleaned table and `nil`, or `nil` and a table of field names to
failure strings: `"required"`, `"expected integer"`, `"min length 3"`,
`"must be one of: a, b"`.

**Raises** `unknown schema type: 'strng'` for a shorthand that is not one of the
five types, and `invalid schema rule: number` when a rule is neither a string
nor a table.

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

## JSON values

### akkar.array

Marks a table as a JSON array, so an empty one encodes as `[]` and not `{}`. An
empty Lua table is both an empty list and an empty object, and the encoder has
to guess.

**Returns** the same table, marked.

### akkar.empty_array

A value that always encodes as `[]`.

### akkar.null

The sentinel that encodes as JSON `null`. Reached through akkar rather than
lifted out of the JSON library, so swapping that library does not change the
identity of a value applications are holding.

It is captured once, when `akkar` loads. [`json.use`](json.md#jsonusereplacement)
re-points `json.null` and does not re-point this one, so a serializer swapped in
after that leaves the two spellings holding different values. Swap at boot.

```lua
local akkar = require "akkar"
local json  = require "akkar.json"

assert(json.encode { rows = akkar.array {} } == '{"rows":[]}')
assert(json.encode { rows = {} } == '{"rows":{}}')
assert(json.encode { seen = akkar.null } == '{"seen":null}')
```

## Middleware

### akkar.cors(options)

Middleware that answers browser preflight and stamps the cross origin headers.
It is middleware rather than core because only the application knows which
origins it trusts.

| field | type | default | meaning |
|---|---|---|---|
| `origin` | string | `"*"` | value of `access-control-allow-origin` |
| `headers` | string | `"content-type, authorization"` | value of `access-control-allow-headers` |
| `max_age` | number | `600` | seconds a preflight may be cached |
| `credentials` | boolean | `false` | sets `access-control-allow-credentials` |

On an `OPTIONS` request the allowed methods come from the router's own `allow`
header where there is one, so the browser is told what the router actually
accepts.

**Returns** middleware, for [`app:use`](#appusefn).

```lua
local akkar = require "akkar"

local app = akkar.new()
app:use(akkar.cors { origin = "https://example.com", credentials = true })
app:get("/tasks", function() return { tasks = akkar.array {} } end)

local res = app:test{}:get "/tasks"
assert(res.headers["access-control-allow-origin"] == "https://example.com")
assert(res.headers["access-control-allow-credentials"] == "true")
```

## Running

### akkar.defaults

The settings applied unless `app:run{}` overrides them, so `app:run()` with no
arguments is already production shaped.

| field | value |
|---|---|
| `body_limit` | `1048576` (1 MB) |
| `timeout` | `30` seconds |
| `shutdown_grace` | `10` seconds |

### app:run(config)

Binds a socket and serves. This call does not return until the server stops.

| field | type | default | meaning |
|---|---|---|---|
| `host` | string | `"127.0.0.1"` | address to bind |
| `port` | number | `8080` | port to bind |
| `tls` | table | none | `{ certificate = ..., key = ..., protocol = ... }`, each a PEM string or a path |
| `ctx` | userdata | none | a luaossl context, the escape hatch past `tls` |
| `body_limit` | number | `1048576` | bytes, above which the answer is 413 |
| `timeout` | number | `30` | seconds of wall clock per request, above which the answer is 503 |
| `shutdown_grace` | number | `10` | seconds to drain on stop |
| `check_capabilities` | boolean | `true` | acquire each capability once at boot and check its contract |
| `reuseport` | boolean | none | let several processes share the port |
| `strict` | boolean | `false` | turn on `akkar.strict`, making a global an error |
| `max_concurrent` | number | derived | in flight ceiling, default about a third of the descriptor limit |
| `trusted_proxies` | list of strings | none | CIDRs whose `x-forwarded-for` is believed |
| `repair_substrate` | boolean | `true` | patch the known lua-http defects before binding |
| `db`, `cache`, `log`, `clock`, `http` | table or function | none | capabilities. A function is called once per request that reads it |

A capability given as a function is called per request, and if what it returns
has a `release` method the framework calls it on every exit path.

**Returns** nothing. It does not return.

**Raises** `unknown app:run{} option 'timout'; did you mean 'timeout'?` for a
key that is not in the list above, and the contract failure from
`check_capabilities` when an adapter cannot answer its methods. A missing method
names both the capability and the method.

```lua no-run
app:run {
  port = 3000,
  db = open,
  timeout = 15,
  trusted_proxies = { "10.0.0.0/8" },
}
```

### app:handle_signals(signals)

Installs handlers that call [`app:stop`](#appstopgrace). Not automatic, because
a library that installs signal handlers behind an application's back fights with
whatever else the process is doing.

| argument | type | default |
|---|---|---|
| `signals` | list | `{ SIGTERM, SIGINT }` |

**Returns** the app. When `cqueues.signal` is unavailable it logs
`cqueues.signal unavailable; signals not handled` and returns without raising.

### app:stop(grace)

Stops accepting, drains in flight requests, asks tasks to finish, then closes
pools and the socket.

Tasks stop after the drain, not before it, because a request still in flight can
enqueue work. Nothing is forced: an expired grace period is a warning, and
unacknowledged jobs come back on the next reap.

| argument | type | default |
|---|---|---|
| `grace` | number | `shutdown_grace` from `app:run{}`, else 10 |

**Returns** the state string, `"STOPPED"`, or the current state when the app was
not running.

### app:stopping()

True once the server has drained and tasks are being asked to finish.
Deliberately not true during the drain.

**Returns** a boolean.

### app:task(name, fn)

Runs `fn` in the server's own event loop for the life of the process. `fn`
receives a table with `stopping`, a function, which can be handed straight to a
queue consumer's `should_stop`.

This is not parallelism. One Lua state runs one coroutine at a time, so a task
that computes without yielding stops the server for exactly as long as it
computes. Tasks are for work that waits.

**Returns** the app.

```lua no-run
app:task("emails", function(task)
  queue:consume(handlers, { should_stop = task.stopping })
end)
```

## Testing

### app:test(config)

An in-process client. It travels the same path a real request does, including
middleware, validation and error handling, without binding a socket.

| field | type | meaning |
|---|---|---|
| `db`, `cache`, `log`, `clock`, `http` | any | capabilities, usually fakes |
| `timeout` | number | the deadline for every request from this client |
| `peer` | string | the address requests appear to come from |
| `trusted_proxies` | list of strings | CIDRs whose `x-forwarded-for` is believed |

The client has one method per verb: `get`, `post`, `put`, `patch`, `delete`,
`head`, `options`. Each takes `(path, options)`, where `path` may carry a query
string and `options` holds `body`, `headers` and `timeout`.

**Returns** a client. Each call returns
`{ status = number, body = table, raw = string, headers = table }`. `headers` is
a fresh table carrying what the wire would have carried, including
`x-request-id`.

**Raises** `unknown app:test{} option 'databse'` for an unknown key, and
`akkar: stream producer failed after N chunk(s)` when a streamed body raises
part way.

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

## Utilities

### akkar.check_capabilities(config)

Acquires each configured capability once, checks it answers its contract, and
lets it go again. `app:run{}` calls this at boot unless
`check_capabilities = false`. Exposed so the check can be tested without binding
a socket.

The contracts are `db`: `one`, `many`, `exec`, `transaction`. `cache`: `get`,
`set`, `del`. `log`: `debug`, `info`, `warn`, `error`, `with`. `http`:
`request`, `get`, `post`. `clock` has no contract.

**Raises** naming the capability and the missing method.

### akkar.client_ip(peer, forwarded, trusted)

The client address, given the socket's peer and the `x-forwarded-for` header.

The header is consulted only when the peer itself is in `trusted`. When it is,
the walk takes the rightmost entry that is not itself a trusted proxy, and falls
back to the peer when every hop is one. Taking the leftmost, which is what most
implementations do, is the spoofable version, because the leftmost entry is
whatever the client typed.

**Returns** a string, or `nil`.

```lua
local akkar = require "akkar"

assert(akkar.client_ip("10.0.0.1", "203.0.113.9, 10.0.0.1", { "10.0.0.0/8" })
       == "203.0.113.9")
assert(akkar.client_ip("198.51.100.4", "203.0.113.9", nil) == "198.51.100.4")
```

### akkar.guard(name, hint)

A placeholder that raises `hint` on any read, call or write. This is what
`req.user` and an unconfigured capability are before they are set, so the error
names the mistake instead of saying `attempt to index a nil value`. Guards with
the same name are shared.

**Returns** a guard table.

```lua
local akkar = require "akkar"

local g = akkar.guard("req.user", "req.user is not set")
assert(tostring(g) == "<req.user missing>")
assert(not pcall(function() return g.id end))
```

### akkar.in_cidr(address, cidr)

Whether an IPv4 address is inside a CIDR block. IPv6 never matches, which fails
closed: a forwarded header is ignored rather than believed.

**Returns** a boolean.

```lua
local akkar = require "akkar"

assert(akkar.in_cidr("10.1.2.3", "10.0.0.0/8"))
assert(not akkar.in_cidr("11.1.2.3", "10.0.0.0/8"))
```

### akkar.parse_query(query_string)

Parses a query string into a table, decoding percent escapes.

**Returns** a table.

```lua
local akkar = require "akkar"

local q = akkar.parse_query "page=2&q=buy%20milk"
assert(q.page == "2")
assert(q.q == "buy milk")
```

### akkar.trace_context(headers)

Parses W3C trace context out of a header table.

**Returns** a table with the trace fields, or `nil` when there is no usable
`traceparent`. See [akkar.trace](trace.md).

## Re-exports

Reached through `akkar` for convenience. Each has its own page.

| symbol | is | page |
|---|---|---|
| `akkar.etag` | `require("akkar.etag").new` | [etag](etag.md) |
| `akkar.etag_of` | `require("akkar.etag").of` | [etag](etag.md) |
| `akkar.idempotency` | `require("akkar.idempotency").new` | [idempotency](idempotency.md) |
| `akkar.json` | the JSON module | [json](json.md) |
| `akkar.limit` | the module | [limit](limit.md) |
| `akkar.log` | the module | [log](log.md) |
| `akkar.metrics` | the module | [metrics](metrics.md) |
| `akkar.strict` | the module | [strict](strict.md) |
| `akkar.work` | the module | [work](work.md) |

Note the two shapes, because they are not spelled alike. `akkar.limit`,
`akkar.log`, `akkar.metrics`, `akkar.strict`, `akkar.work` and `akkar.json` are
modules, so you reach a function on them: `akkar.limit.rate {...}`.
`akkar.idempotency`, `akkar.etag` and `akkar.etag_of` are already functions, so
they are called directly: `akkar.idempotency {...}`.

```lua
local akkar = require "akkar"

assert(type(akkar.limit) == "table" and type(akkar.limit.rate) == "function")
assert(type(akkar.idempotency) == "function")
assert(type(akkar.etag) == "function")
```

## Not here

**No `app:head` or `app:options`.** `HEAD` is served by the `GET` handler, and
`OPTIONS` is answered from the routing table itself, so neither needs a route.

**No 500 helper.** See [Status helpers](#status-helpers).

**No `res:write`, no `res:send`, no context object.** A handler returns a value
and akkar writes it. That is the invariant the whole framework is built on:
answering twice is not something you can express. For a body that cannot be held
in memory, see [`akkar.stream`](#akkarstreamproducer-options).

**No route for a wildcard path.** `:name` captures exactly one segment. To serve
a tree of files, see [akkar.static](static.md).

**No open `req` extension point.** The capability set is closed, and application
services are closed over by the handler.

## See also

- [The beginner guide](../guide/00-quickstart.md) if this is the first akkar you
  have read
- [akkar.db](db.md), [akkar.cache](cache.md), [akkar.http](http.md) for the
  capabilities `app:run{}` injects
- [akkar.auth](auth.md) and [akkar.session](session.md) for what sets
  `req.auth`, which is where the shipped middleware puts the caller
- the module source, `akkar/init.lua`, for why each of these is shaped the way
  it is
