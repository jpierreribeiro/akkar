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

local SHORTHAND = { string = true, integer = true, number = true,
                    boolean = true, table = true, object = true, array = true }

-- Same expansion `akkar.validate` performs, kept in one shape so the document
-- can never describe something different from what is enforced.
local function expand(rule)
  if type(rule) == "table" then return rule end
  local optional = rule:sub(-1) == "?"
  local kind = optional and rule:sub(1, -2) or rule
  if not SHORTHAND[kind] then return nil end
  return { kind = kind, optional = optional }
end

local object_schema

local function to_schema(rule)
  local expanded = expand(rule)
  if not expanded then return { } end
  local schema = {}
  for key, value in pairs(KIND_TO_JSON[expanded.kind] or { type = "string" }) do
    schema[key] = value
  end
  -- The constraints validation enforces are the constraints the document
  -- promises.  Reporting a `max` that is not applied would be a lie.
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
  if expanded.openapi_pattern then schema.pattern = expanded.openapi_pattern
  elseif expanded.match then schema.pattern = expanded.match end
  if expanded.default ~= nil then schema.default = expanded.default end
  if expanded.kind == "object" then
    schema = object_schema(expanded.fields or {})
  elseif expanded.kind == "array" then
    schema.items = to_schema(expanded.items or "table")
    if expanded.min then schema.minItems = expanded.min end
    if expanded.max then schema.maxItems = expanded.max end
  end
  return schema
end

object_schema = function(fields)
  local properties, required = {}, {}
  for name, rule in pairs(fields) do
    properties[name] = to_schema(rule)
    local expanded = expand(rule)
    if expanded and not expanded.optional then required[#required + 1] = name end
  end
  table.sort(required)
  local schema = { type = "object", properties = properties }
  if #required > 0 then schema.required = required end
  return schema
end

local function schema_of(declaration)
  if type(declaration) == "table" and declaration.kind then
    return to_schema(declaration)
  end
  return object_schema(declaration)
end

local function parameters(where, fields)
  local list = {}
  for name, rule in pairs(fields) do
    local expanded = expand(rule)
    list[#list + 1] = {
      name = name,
      ["in"] = where,
      required = where == "path" or not (expanded and expanded.optional),
      schema = to_schema(rule),
    }
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- `/users/:id` in Lua is `/users/{id}` in OpenAPI.
local function to_template(path)
  return (path:gsub(":([^/]+)", "{%1}"))
end

-- Walks an app and every sub-app mounted under it, so a mounted health app is
-- documented at the prefix it actually answers on.
local function collect(app, prefix, out)
  for _, route in ipairs(app.routes) do
    out[#out + 1] = { route = route, path = prefix .. route.path }
  end
  for _, mount in ipairs(app.mounts) do
    collect(mount.app, prefix .. mount.prefix, out)
  end
  return out
end

--- Builds the OpenAPI document for an app.
-- @param app   an akkar application
-- @param info  optional { title = ..., version = ..., description = ... }
function M.document(app, info)
  info = info or {}
  local paths = {}

  for _, entry in ipairs(collect(app, "", {})) do
    local route, opts = entry.route, entry.route.opts or {}
    local template = to_template(entry.path)
    paths[template] = paths[template] or {}

    local operation = {
      operationId = (route.method:lower() .. entry.path:gsub("[^%w]+", "_")):gsub("_$", ""),
      responses = {},
    }
    local metadata = opts.openapi or {}
    operation.summary = metadata.summary
    operation.description = metadata.description
    operation.security = metadata.security

    local params = {}
    if opts.params then
      for _, p in ipairs(parameters("path", opts.params)) do params[#params + 1] = p end
    else
      -- A route with `:id` but no schema still has a path parameter, and
      -- OpenAPI requires every template variable to be declared.
      for _, name in ipairs(route.names) do
        params[#params + 1] = { name = name, ["in"] = "path", required = true,
                                schema = { type = "string" } }
      end
    end
    if opts.query then
      for _, p in ipairs(parameters("query", opts.query)) do params[#params + 1] = p end
    end
    if metadata.headers then
      for name, declaration in pairs(metadata.headers) do
        params[#params + 1] = {
          name = name, ["in"] = "header", required = declaration.required == true,
          description = declaration.description, schema = declaration.schema or { type = "string" },
        }
      end
      table.sort(params, function(a, b)
        if a["in"] == b["in"] then return a.name < b.name end
        return a["in"] < b["in"]
      end)
    end
    if #params > 0 then operation.parameters = params end

    if opts.body then
      operation.requestBody = {
        required = true,
        content = { ["application/json"] = { schema = schema_of(opts.body) } },
      }
    end

    -- `response` is optional and describes the success body.  Without it the
    -- document says a response exists but not its shape, which is honest.
    if opts.responses then
      for status, declaration in pairs(opts.responses) do
        operation.responses[tostring(status)] = {
          description = tonumber(status) == 201 and "Created" or
                        tonumber(status) == 204 and "No Content" or "Response",
          content = tonumber(status) == 204 and nil or
                    { ["application/json"] = { schema = schema_of(declaration) } },
        }
      end
    elseif opts.response then
      operation.responses["200"] = {
        description = "OK",
        content = { ["application/json"] = { schema = schema_of(opts.response) } },
      }
    else
      operation.responses["200"] = { description = "OK" }
    end

    -- Statuses akkar produces on its own are documented without anyone
    -- declaring them, because akkar is the one that produces them.
    if opts.params or opts.query or opts.body then
      operation.responses["422"] = { description = "validation failed" }
    end
    operation.responses["500"] = { description = "internal server error" }

    paths[template][route.method:lower()] = operation
  end

  return {
    openapi = "3.1.0",
    info = {
      title = info.title or "akkar API",
      version = info.version or "0.0.0",
      description = info.description,
    },
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
