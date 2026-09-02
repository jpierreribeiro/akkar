--[[
akkar.openapi — generates an OpenAPI 3.1 document from the schemas already
declared on the routes.

The principle worth stealing from FastAPI is not `Depends`.  It is that **one
declaration by the programmer should be reused by the framework as many times
as possible.**  A route already says

    app:post("/users", {
      body = { name = "string", email = "string?" },
    }, handler)

for validation.  Nothing about that declaration is specific to validation, so
requiring it to be written a second time for documentation would be the
framework failing to do its job.

Nothing here is a new vocabulary: it reads exactly the tables that
`akkar.validate` already reads.  A route with no schema still appears, just
without parameters — an undocumented endpoint is worse than a thinly
documented one.
]]

local M = {}

local KIND_TO_JSON = {
  string  = { type = "string" },
  integer = { type = "integer" },
  number  = { type = "number" },
  boolean = { type = "boolean" },
  table   = { type = "object" },
  object  = { type = "object" },
  array   = { type = "array" },
}

-- The same set `akkar.validate` accepts, and it has to stay the same set: a
-- kind the validator expands and this module does not would be the document
-- describing nothing where the server enforces something.
local SHORTHAND = { string = true, integer = true, number = true,
                    boolean = true, table = true, object = true, array = true }

-- Same expansion `akkar.validate` performs, kept in one shape so the document
-- can never describe something different from what is enforced.
--
-- RAISES for a rule it cannot expand, and never writes one down as something
-- else. This used to return nil for an unknown shorthand and hand back any
-- table untouched, and `to_schema` turned a table with no `kind` into
-- `type: string`: `response = { users = { { id = "string" } } }` -- an array
-- written as a bare nested table -- was documented as a string, and the
-- client generated from the document typed it as one against a server that
-- sends a list. Routes refuse that table at registration now, so for a
-- declared route this branch is unreachable; it stays an error rather than a
-- fallback because a rule reaching the document without passing through
-- `app:get` is exactly the case in which a quiet default lies.
--
-- `where` names the route and the path to the rule, so the message reads
-- `GET /x: response.users` rather than pointing at this file.
local function expand(rule, where)
  if type(rule) == "table" then
    if type(rule.kind) == "string" and SHORTHAND[rule.kind] then return rule end
    error(("akkar.openapi: %s is a table with no schema kind and cannot be "
        .. "documented; a rule is a shorthand, v.object { fields = ... } or "
        .. "v.array { items = ... }, and app:get refuses anything else at "
        .. "registration"):format(where), 0)
  end
  if type(rule) ~= "string" then
    error(("akkar.openapi: %s is a %s, not a schema rule"):format(where, type(rule)), 0)
  end
  local optional = rule:sub(-1) == "?"
  local kind = optional and rule:sub(1, -2) or rule
  if not SHORTHAND[kind] then
    error(("akkar.openapi: %s: unknown schema type '%s'"):format(where, rule), 0)
  end
  return { kind = kind, optional = optional }
end

-- Declared ahead of `to_schema` because the two call each other: an object's
-- field may be an array, and an array's element may be an object. A schema
-- that stopped at the first level documented `{ items = v.array{...} }` as a
-- string, which is a document describing something the validator does not
-- enforce and the client cannot send.
local object_schema

local function to_schema(rule, where)
  local expanded = expand(rule, where)
  local schema = {}
  for key, value in pairs(KIND_TO_JSON[expanded.kind]) do
    schema[key] = value
  end
  -- The constraints validation enforces are the constraints the document
  -- promises.  Reporting a `max` that is not applied would be a lie.
  --
  -- `min`/`max` mean a different keyword for each kind, and the fallthrough
  -- that sent everything that was not a string to `minimum`/`maximum` sent
  -- an ARRAY's length bounds there too. `minimum: 1` on an array is not a
  -- constraint OpenAPI applies to arrays, so the one bound the validator
  -- does enforce -- element count -- went undocumented while a bound nothing
  -- enforces appeared in its place. Named explicitly, kind by kind, so a
  -- kind added later has to say where its bounds go.
  if expanded.min then
    if expanded.kind == "string" then schema.minLength = expanded.min
    elseif expanded.kind == "integer" or expanded.kind == "number" then
      schema.minimum = expanded.min
    end
  end
  if expanded.max then
    if expanded.kind == "string" then schema.maxLength = expanded.max
    elseif expanded.kind == "integer" or expanded.kind == "number" then
      schema.maximum = expanded.max
    end
  end
  if expanded.one_of then schema["enum"] = expanded.one_of end
  -- `match` is a LUA pattern, and OpenAPI's `pattern` is an ECMA-262 regular
  -- expression. The two agree often enough that publishing `match` is right
  -- by default and wrong in exactly the cases that use a Lua character class:
  -- `^%x+$` is not a regex a generated client can compile, and one that tries
  -- rejects the hex ids the server accepts. `openapi_pattern` is where the
  -- author writes the same constraint for that reader; the server still
  -- enforces `match`, so this can only ever be the more readable spelling.
  if expanded.openapi_pattern then schema.pattern = expanded.openapi_pattern
  elseif expanded.match then schema.pattern = expanded.match end
  if expanded.default ~= nil then schema.default = expanded.default end
  if expanded.kind == "object" then
    -- The whole schema is replaced rather than extended: an object's shape is
    -- its `properties` and `required`, and the scalar keywords collected
    -- above do not apply to one.
    schema = object_schema(expanded.fields or {}, where)
  elseif expanded.kind == "array" then
    schema.items = to_schema(expanded.items or "table", where .. ".items")
    if expanded.min then schema.minItems = expanded.min end
    if expanded.max then schema.maxItems = expanded.max end
  end
  return schema
end

object_schema = function(fields, where)
  local properties, required = {}, {}
  for name, rule in pairs(fields) do
    local at = where .. "." .. tostring(name)
    properties[name] = to_schema(rule, at)
    if not expand(rule, at).optional then required[#required + 1] = name end
  end
  table.sort(required)
  local schema = { type = "object", properties = properties }
  if #required > 0 then schema.required = required end
  return schema
end

-- A schema slot is either a map of field name to rule -- `{ id = "string" }`,
-- which describes an object -- or ONE rule that describes the whole value,
-- which is what `v.object { fields = ... }` and `v.array { items = ... }` are.
-- The validator tells them apart by `kind` holding a string and so does this,
-- because a body documented as an object where the route enforces a list is
-- the exact mismatch this module exists to make impossible.
local function schema_of(declaration, where)
  if type(declaration) == "table" and type(declaration.kind) == "string" then
    return to_schema(declaration, where)
  end
  return object_schema(declaration, where)
end

local function parameters(location, fields, where)
  local list = {}
  for name, rule in pairs(fields) do
    local at = where .. "." .. tostring(name)
    local expanded = expand(rule, at)
    list[#list + 1] = {
      name = name,
      ["in"] = location,
      required = location == "path" or not expanded.optional,
      schema = to_schema(rule, at),
    }
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- The reason-phrase for a status a route declares itself. Not exhaustive on
-- purpose: "Response" is honest for anything not listed, and inventing prose
-- for a status nobody named would be this module writing documentation rather
-- than reading it.
local DESCRIPTIONS = {
  [200] = "OK", [201] = "Created", [202] = "Accepted", [204] = "No Content",
}

-- `/users/:id` in Lua is `/users/{id}` in OpenAPI.
local function to_template(path)
  return (path:gsub(":([^/]+)", "{%1}"))
end

-- Walks an app and every sub-app mounted under it, so a mounted health app is
-- documented at the prefix it actually answers on.
--
-- `chain` is the apps between the root and here, and it is a CHAIN rather than
-- a set of everything seen: mounting one sub-app under two prefixes is a
-- diamond and is fine, while an app that appears twice on the way down is a
-- cycle. `App:mount` accepts a cycle without complaint, so two feature apps
-- that mount each other start and serve traffic normally -- until the first
-- `GET /openapi.json`, which recursed forever and took the process out. It is
-- one unauthenticated request.
--
-- Raised rather than quietly truncated: a document missing half an API is
-- wrong in a way its readers cannot see, and the mount graph is something the
-- application has to fix.
local function collect(app, prefix, out, chain)
  if chain[app] then
    error(("akkar.openapi: the mount graph is a cycle -- the app at '%s' is "
        .. "mounted inside itself. Two apps that mount each other serve "
        .. "traffic normally and only fail here, on the document.")
        :format(prefix == "" and "/" or prefix), 0)
  end
  chain[app] = true

  for _, route in ipairs(app.routes) do
    out[#out + 1] = { route = route, path = prefix .. route.path }
  end
  for _, mount in ipairs(app.mounts) do
    collect(mount.app, prefix .. mount.prefix, out, chain)
  end

  chain[app] = nil
  return out
end

--- The body of a 422, exactly as `akkar/init.lua` builds it: `fields` is a
--- flat map from the dotted path of the failing value (`body.amount`,
--- `params.id`, `query.limit`) to the reason. Exported so a generator and a
--- test can name the same table this document embeds.
M.VALIDATION_FAILED = {
  type = "object",
  required = { "error", "fields" },
  properties = {
    error  = { type = "string", enum = { "validation failed" } },
    fields = { type = "object", additionalProperties = { type = "string" } },
  },
}

--- The body of a 500. Deliberately nothing but the constant: the real error
--- goes to the log with the request id, never to the wire.
M.INTERNAL_ERROR = {
  type = "object",
  required = { "error" },
  properties = { error = { type = "string", enum = { "internal server error" } } },
}

--- Builds the OpenAPI document for an app.
-- @param app   an akkar application
-- @param info  optional { title = ..., version = ..., description = ... }
function M.document(app, info)
  info = info or {}
  local paths = {}

  for _, entry in ipairs(collect(app, "", {}, {})) do
    local route, opts = entry.route, entry.route.opts or {}
    local template = to_template(entry.path)
    paths[template] = paths[template] or {}

    local operation = {
      operationId = (route.method:lower() .. entry.path:gsub("[^%w]+", "_")):gsub("_$", ""),
      responses = {},
    }

    -- Everything a schema cannot say, because it is not validation: the prose
    -- a reader wants, the credential the route requires, the header a client
    -- has to send. Declared on the route beside the schemas rather than
    -- assembled somewhere else, for the reason at the top of this file.
    local metadata = opts.openapi or {}
    operation.summary     = metadata.summary
    operation.description = metadata.description
    operation.security    = metadata.security

    -- The prefix every schema error under this route carries.
    local at = route.method .. " " .. entry.path .. ": "

    local params = {}
    if opts.params then
      for _, p in ipairs(parameters("path", opts.params, at .. "params")) do params[#params + 1] = p end
    else
      -- A route with `:id` but no schema still has a path parameter, and
      -- OpenAPI requires every template variable to be declared.
      for _, name in ipairs(route.names) do
        params[#params + 1] = { name = name, ["in"] = "path", required = true,
                                schema = { type = "string" } }
      end
    end
    if opts.query then
      for _, p in ipairs(parameters("query", opts.query, at .. "query")) do params[#params + 1] = p end
    end
    -- Headers are parameters too, in OpenAPI's vocabulary. They are NOT
    -- validated -- akkar has no header schema -- so this is documentation
    -- only, and it says so by taking its own shape rather than a rule.
    if metadata.headers then
      for name, declaration in pairs(metadata.headers) do
        params[#params + 1] = {
          name = name, ["in"] = "header",
          required = declaration.required == true,
          description = declaration.description,
          schema = declaration.schema or { type = "string" },
        }
      end
      -- Sorted by location and then by name, so the list is stable whatever
      -- order `pairs` walked the headers in. A document that reorders itself
      -- between runs is a diff nobody can read.
      table.sort(params, function(a, b)
        if a["in"] == b["in"] then return a.name < b.name end
        return a["in"] < b["in"]
      end)
    end
    if #params > 0 then operation.parameters = params end

    if opts.body then
      operation.requestBody = {
        required = true,
        content = { ["application/json"] = { schema = schema_of(opts.body, at .. "body") } },
      }
    end

    -- `response` is optional and describes the success body.  Without it the
    -- document says a response exists but not its shape, which is honest.
    --
    -- `responses` is the same statement made per status, and it takes
    -- precedence: a route that declared 201 separately has said something more
    -- precise than "the success body", and the validator selects by status the
    -- same way. Documenting a 200 the route never sends would be the document
    -- describing something nothing enforces.
    if opts.responses then
      for status, declaration in pairs(opts.responses) do
        local code = tonumber(status)
        operation.responses[tostring(status)] = {
          description = DESCRIPTIONS[code] or "Response",
          -- 204 means there is no body, so a content schema for one would be
          -- a contradiction in the document itself.
          content = code == 204 and nil
                    or { ["application/json"] = { schema = schema_of(declaration,
                              at .. "responses[" .. tostring(status) .. "]") } },
        }
      end
    elseif opts.response then
      operation.responses["200"] = {
        description = "OK",
        content = { ["application/json"] = { schema = schema_of(opts.response, at .. "response") } },
      }
    else
      operation.responses["200"] = { description = "OK" }
    end

    -- Statuses akkar produces on its own are documented without anyone
    -- declaring them, because akkar is the one that produces them -- AND WITH
    -- THEIR SHAPE, because akkar is the one that fixes it. These used to be a
    -- description and nothing else, which left the error half of the contract
    -- untyped: a generated client knew what a 200 looked like and had to guess
    -- at a 422. The shapes are the literal tables `akkar/init.lua` returns --
    -- `{ error = "validation failed", fields = { ["body.amount"] = "required" } }`
    -- and `{ error = "internal server error" }` -- so a client can narrow on
    -- `error` and read `fields` by the same dotted path the validator wrote.
    if opts.params or opts.query or opts.body then
      operation.responses["422"] = {
        description = "validation failed",
        content = { ["application/json"] = { schema = M.VALIDATION_FAILED } },
      }
    end
    operation.responses["500"] = {
      description = "internal server error",
      content = { ["application/json"] = { schema = M.INTERNAL_ERROR } },
    }

    paths[template][route.method:lower()] = operation
  end

  return {
    openapi = "3.1.0",
    info = {
      title = info.title or "akkar API",
      version = info.version or "0.0.0",
      description = info.description,
    },
    -- Passed through rather than built: `securitySchemes` names credentials
    -- akkar knows nothing about -- which header, which OAuth flow -- and a
    -- `security` requirement on a route that referred to a scheme no document
    -- declared would be a dangling reference in valid-looking OpenAPI.
    components = info.components,
    paths = paths,
  }
end

--- Mounts `GET /openapi.json` on the app, generated on first request.
function M.serve(app, path, info)
  path = path or "/openapi.json"
  local cached
  app:get(path, function()
    cached = cached or M.document(app, info)
    return cached
  end)
  return app
end

return M
