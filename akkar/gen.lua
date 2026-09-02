--- `akkar gen` — a typed TypeScript client, generated from the routes.
---
--- ## What this is, and the one thing it is not
---
--- This is akkar's answer to the loudest complaint about Lua for large systems:
--- no static types, so no way to catch a wrong call to your own API before it
--- runs. tRPC answers it for a TypeScript monorepo by INFERRING the client's
--- types from the server's — zero codegen, because the TypeScript compiler
--- carries one shared type across the boundary. PUC-Lua 5.4 has no such shared
--- type and no cross-boundary inference, so that mechanism is unreachable here
--- and pretending otherwise would be dishonest.
---
--- What IS reachable, and is what this does: the route already declares its
--- `body`/`params`/`query`/`response` schemas once, `akkar.openapi` already
--- turns them into an OpenAPI 3.1 document, and this reads THAT document and
--- emits a `.ts` file a frontend imports. A wrong field or a typo'd key in a
--- call is then a `tsc` error before the request is ever sent — the same
--- outcome as tRPC, reached by generating an artifact rather than inferring one.
--- The cost is the regen step: the generated file is only as current as the last
--- `akkar gen`, so a schema change that is not regenerated type-checks green
--- against a stale contract. `akkar gen --check` (and the CI recipe that runs it)
--- exists precisely to turn that silent staleness into a hard failure.
---
--- ## Why it reads the OpenAPI document rather than the route tables
---
--- `akkar.openapi` already walks the app and applies the SHORTHAND vocabulary
--- (`"string"`, `akkar.v.integer{min=1}`, nested tables) through the very helpers
--- the validator uses, so the document cannot describe a shape the server does
--- not enforce. Generating from the document reuses that guarantee for free: the
--- generated types, the served `/openapi.json`, and the runtime validator are
--- three projections of one source and cannot disagree. Re-deriving types from
--- the raw route tables here would fork that vocabulary and let them drift.
local openapi = require "akkar.openapi"

local M = {}

-- ============================================================ names
-- One `operationId` per route already exists in the document
-- (`akkar/openapi.lua`), shaped like `post_transfers` or `get_users_id`. A TS
-- interface wants PascalCase and a function wants camelCase; both are derived
-- from that one id so a reader can trace `PostTransfers`/`postTransfers` back to
-- exactly one route.

local function pascal(operation_id)
  return (operation_id:gsub("_(%w)", function(c) return c:upper() end)
                      :gsub("^%l", string.upper))
end

local function camel(operation_id)
  return (operation_id:gsub("_(%w)", function(c) return c:upper() end))
end

-- ============================================================ TS types
-- Map one OpenAPI / JSON-Schema node to a TypeScript type expression. Only the
-- shapes akkar's schemas actually produce are handled; anything else is emitted
-- as `unknown`, never silently as `any`, so a gap the generator does not cover
-- is visible in the output and in the type checker rather than checking against
-- nothing.

local ts_type

--- Emits `{ field: type; other?: type }` for an object schema, one field per
--- line at `indent`. Field order is sorted, because `pairs` over the properties
--- table is unordered and a client file that reshuffles itself between runs is a
--- diff nobody can review — the same reason the document itself sorts.
local function object_to_ts(schema, indent)
  local required = {}
  for _, name in ipairs(schema.required or {}) do required[name] = true end

  local names = {}
  for name in pairs(schema.properties or {}) do names[#names + 1] = name end
  table.sort(names)

  if #names == 0 then return "Record<string, unknown>" end

  local lines = { "{" }
  for _, name in ipairs(names) do
    local optional = required[name] and "" or "?"
    -- A property name that is not a plain identifier has to be quoted, or the
    -- emitted TS does not parse. JSON keys are arbitrary strings; TS keys are not.
    local key = name:match("^[%a_$][%w_$]*$") and name or ("%q"):format(name)
    lines[#lines + 1] = ("%s  %s%s: %s;"):format(
      indent, key, optional, ts_type(schema.properties[name], indent .. "  "))
  end
  lines[#lines + 1] = indent .. "}"
  return table.concat(lines, "\n")
end

ts_type = function(schema, indent)
  indent = indent or ""
  if type(schema) ~= "table" then return "unknown" end

  -- An `enum` is the most precise type the schema carries, so it wins over the
  -- broad `type`: a string enum becomes a union of string literals, which is
  -- exactly the checking a plain `string` would throw away.
  if schema.enum then
    local parts = {}
    for _, v in ipairs(schema.enum) do
      parts[#parts + 1] = type(v) == "string" and ("%q"):format(v) or tostring(v)
    end
    if #parts > 0 then return table.concat(parts, " | ") end
  end

  -- `oneOf`/`anyOf` become a union; the members are whatever they are.
  local union = schema.oneOf or schema.anyOf
  if union then
    local parts = {}
    for _, member in ipairs(union) do parts[#parts + 1] = ts_type(member, indent) end
    if #parts > 0 then return table.concat(parts, " | ") end
  end

  local t = schema.type
  -- OpenAPI 3.1 allows `type` to be a list to express nullability, e.g.
  -- `["string", "null"]`. Split the null out and union it back on.
  if type(t) == "table" then
    local base, nullable = nil, false
    for _, one in ipairs(t) do
      if one == "null" then nullable = true else base = one end
    end
    local rendered = ts_type({ type = base, items = schema.items,
                               properties = schema.properties,
                               required = schema.required }, indent)
    return nullable and (rendered .. " | null") or rendered
  end

  if t == "string"  then return "string"  end
  if t == "integer" then return "number"  end  -- TS has no integer type
  if t == "number"  then return "number"  end
  if t == "boolean" then return "boolean" end
  if t == "null"    then return "null"    end
  if t == "array"   then return ts_type(schema.items, indent) .. "[]" end
  if t == "object"  then return object_to_ts(schema, indent) end
  return "unknown"
end

-- ============================================================ uncheckable
-- Every `minimum`/`maxLength`/pattern the SERVER enforces but a TS type CANNOT
-- express, collected so the generated file states, in a comment, exactly what
-- the type checker will not catch. TypeScript has no integer type and no
-- value-range types, so `amount: -3` type-checks clean and only the runtime 422
-- rejects it. Saying so in the artifact is the difference between an honest tool
-- and one that oversells itself.

local function uncheckable_of(schema, prefix, out)
  if type(schema) ~= "table" then return end
  if schema.type == "object" and schema.properties then
    local names = {}
    for name in pairs(schema.properties) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      uncheckable_of(schema.properties[name], prefix .. name .. ".", out)
    end
    return
  end
  local field = prefix:gsub("%.$", "")
  if schema.minimum then out[#out + 1] = ("%s >= %s"):format(field, schema.minimum) end
  if schema.maximum then out[#out + 1] = ("%s <= %s"):format(field, schema.maximum) end
  if schema.minLength then out[#out + 1] = ("#%s >= %s"):format(field, schema.minLength) end
  if schema.maxLength then out[#out + 1] = ("#%s <= %s"):format(field, schema.maxLength) end
  if schema.pattern then out[#out + 1] = ("%s matches /%s/"):format(field, schema.pattern) end
end

-- ============================================================ the emitter

--- The `application/json` schema under an OpenAPI content map, or nil.
local function json_schema(content)
  local media = content and content["application/json"]
  return media and media.schema
end

--- The success response schema for an operation: the 2xx that carries a body,
--- preferring 200 then 201, then any other 2xx. Returns nil when the route
--- declared no `response` (the document then says a body exists but not its
--- shape), which the caller renders as `unknown` — an honest "we don't know",
--- and exactly what the `doctor` lint nudges an author to fix.
local function success_schema(responses)
  for _, code in ipairs { "200", "201" } do
    local s = responses[code] and json_schema(responses[code].content)
    if s then return s, code end
  end
  local codes = {}
  for code in pairs(responses) do
    local n = tonumber(code)
    if n and n >= 200 and n < 300 then codes[#codes + 1] = code end
  end
  table.sort(codes)
  for _, code in ipairs(codes) do
    local s = json_schema(responses[code].content)
    if s then return s, code end
  end
  return nil
end

--- Splits an operation's `parameters` list into path and query object schemas
--- (or nil when there are none of that kind), so each becomes a typed argument.
local function param_schemas(parameters)
  local path_props, path_req = {}, {}
  local query_props, query_req = {}, {}
  local has_path, has_query = false, false
  for _, p in ipairs(parameters or {}) do
    if p["in"] == "path" then
      has_path = true
      path_props[p.name] = p.schema or { type = "string" }
      if p.required ~= false then path_req[#path_req + 1] = p.name end
    elseif p["in"] == "query" then
      has_query = true
      query_props[p.name] = p.schema or { type = "string" }
      if p.required then query_req[#query_req + 1] = p.name end
    end
    -- Header parameters are documentation-only in akkar and are not part of the
    -- typed call surface, so they are deliberately skipped here.
  end
  local path = has_path
    and { type = "object", properties = path_props, required = path_req } or nil
  local query = has_query
    and { type = "object", properties = query_props, required = query_req } or nil
  return path, query
end

--- Generates the TypeScript client source for `app`. `info` is passed straight
--- to `akkar.openapi.document` ({ title, version, description }).
function M.typescript(app, info)
  info = info or {}
  local doc = openapi.document(app, info)

  local out = {}
  local function w(s) out[#out + 1] = s or "" end

  w("// AUTO-GENERATED by `akkar gen` from the route schemas. DO NOT EDIT.")
  w("// Regenerate after any schema change:  akkar gen <app.lua> -o <this file>")
  w("// The green light of `tsc` means this client matches the LAST GENERATED")
  w("// contract, not necessarily the running server -- keep it honest with a CI")
  w("// step that regenerates and fails on a diff (`akkar gen --check`).")
  w("")
  w("export interface AkkarClientOptions {")
  w("  baseUrl?: string;")
  w("  fetch?: typeof fetch;")
  w("  headers?: Record<string, string>;")
  w("}")
  w("")

  -- Stable emission order: path template, then method. `doc.paths` and each
  -- method map come out of `pairs` unordered.
  local templates = {}
  for template in pairs(doc.paths) do templates[#templates + 1] = template end
  table.sort(templates)

  for _, template in ipairs(templates) do
    local methods = {}
    for method in pairs(doc.paths[template]) do methods[#methods + 1] = method end
    table.sort(methods)

    for _, method in ipairs(methods) do
      local op = doc.paths[template][method]
      local Name = pascal(op.operationId)
      local fn   = camel(op.operationId)

      local path_schema, query_schema = param_schemas(op.parameters)
      local body_schema = op.requestBody and json_schema(op.requestBody.content)
      local resp_schema = success_schema(op.responses)

      -- The constraints the types cannot carry, gathered across every input.
      local uncheckable = {}
      uncheckable_of(body_schema, "body.", uncheckable)
      uncheckable_of(path_schema, "params.", uncheckable)
      uncheckable_of(query_schema, "query.", uncheckable)
      table.sort(uncheckable)

      w(("// ---- %s %s  (%s)"):format(method:upper(), template, op.operationId))
      if op.summary then w("// " .. op.summary) end
      if #uncheckable > 0 then
        w("// Enforced by the server, NOT by these types: "
          .. table.concat(uncheckable, ", "))
      end

      -- The interfaces. Emitting a named interface per shape (rather than
      -- inlining) is what lets a caller import the type and what makes the
      -- `tsc` error name the interface the wrong field violated.
      if path_schema then
        w(("export interface %sParams %s"):format(Name, object_to_ts(path_schema, "")))
      end
      if query_schema then
        w(("export interface %sQuery %s"):format(Name, object_to_ts(query_schema, "")))
      end
      if body_schema then
        w(("export interface %sBody %s"):format(Name, object_to_ts(body_schema, "")))
      end
      if resp_schema then
        w(("export interface %sResponse %s"):format(Name, object_to_ts(resp_schema, "")))
      else
        -- No declared response schema: the return type is honestly unknown.
        w(("export type %sResponse = unknown;"):format(Name))
      end

      -- The typed function. The argument object carries only the parts this
      -- route has; the object-literal a caller passes is checked field-by-field
      -- (including excess-property checking, which is what catches a typo'd key),
      -- so a wrong call is a compile error rather than a 422 at runtime.
      local arg_fields = {}
      if path_schema  then arg_fields[#arg_fields + 1] = ("params: %sParams;"):format(Name) end
      if query_schema then arg_fields[#arg_fields + 1] = ("query?: %sQuery;"):format(Name) end
      if body_schema  then arg_fields[#arg_fields + 1] = ("body: %sBody;"):format(Name) end

      local args_type, args_param
      if #arg_fields > 0 then
        args_type = "{ " .. table.concat(arg_fields, " ") .. " }"
        args_param = "args: " .. args_type .. ", "
      else
        args_param = ""
      end

      w(("export async function %s("):format(fn))
      w("  " .. args_param .. "opts: AkkarClientOptions = {},")
      w(("): Promise<%sResponse> {"):format(Name))
      w("  const base = opts.baseUrl ?? \"\";")

      -- Build the path, substituting `{name}` template variables from params.
      if path_schema then
        w(("  let path = %q;"):format(template))
        local names = {}
        for name in pairs(path_schema.properties) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
          w(("  path = path.replace(%q, encodeURIComponent(String(args.params.%s)));")
            :format("{" .. name .. "}", name))
        end
      else
        w(("  let path = %q;"):format(template))
      end

      if query_schema then
        w("  if (args.query) {")
        w("    const q = new URLSearchParams();")
        w("    for (const [k, v] of Object.entries(args.query)) {")
        w("      if (v !== undefined && v !== null) q.set(k, String(v));")
        w("    }")
        w("    const qs = q.toString();")
        w("    if (qs) path += \"?\" + qs;")
        w("  }")
      end

      w("  const doFetch = opts.fetch ?? fetch;")
      w("  const res = await doFetch(base + path, {")
      w(("    method: %q,"):format(method:upper()))
      w("    headers: {")
      if body_schema then w("      \"content-type\": \"application/json\",") end
      w("      ...(opts.headers ?? {}),")
      w("    },")
      if body_schema then w("    body: JSON.stringify(args.body),") end
      w("  });")
      w("  if (!res.ok) {")
      w(("    throw new Error(%q + res.status);"):format(op.operationId .. " failed: HTTP "))
      w("  }")
      if resp_schema then
        w(("  return (await res.json()) as %sResponse;"):format(Name))
      else
        w("  return (await res.json()) as unknown;")
      end
      w("}")
      w("")
    end
  end

  return table.concat(out, "\n")
end

return M
