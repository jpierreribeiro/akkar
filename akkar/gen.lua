--- `akkar gen` — typed clients, generated from the routes.
---
--- Three projections of one document: `M.typescript` (a `.ts` client for a
--- frontend), `M.teal` (a `.tl` client for a Teal or plain-Lua caller) and
--- `M.luals` (a `---@meta` file that types that client for the language
--- server). The TypeScript one is described first because it is the one the
--- tRPC comparison is about; the Lua-side pair is introduced further down.
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

  if #names == 0 then
    -- No fixed properties: a map. Its value type is whatever
    -- `additionalProperties` says (the 422 `fields` map is `string`), or
    -- unknown when the schema left that open too.
    local extra = schema.additionalProperties
    if type(extra) == "table" then
      return "Record<string, " .. ts_type(extra, indent) .. ">"
    end
    return "Record<string, unknown>"
  end

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
  -- THE ERROR HALF OF THE CONTRACT. A non-2xx answer is thrown as one class
  -- carrying the status and the parsed body, and the body is typed PER ROUTE as
  -- the union of every error response the document declares for it -- the 422
  -- and 500 akkar itself produces, plus any `responses[4xx]` the route added.
  -- So `catch (e) { if (e instanceof AkkarError && e.body.error === \"validation
  -- failed\") e.body.fields[\"body.amount\"] }` narrows without a cast, which is
  -- what makes an error a typed value rather than a string to grep.
  w("export class AkkarError<TBody = unknown> extends Error {")
  w("  constructor(public readonly status: number, public readonly body: TBody, operation: string) {")
  w("    super(operation + \" failed: HTTP \" + status);")
  w("    this.name = \"AkkarError\";")
  w("  }")
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

      -- Every non-2xx response that carries a body, in status order, becomes
      -- one member of this route's error union.
      local error_members = {}
      do
        local codes = {}
        for code in pairs(op.responses) do
          local n = tonumber(code)
          if n and n >= 400 and json_schema(op.responses[code].content) then
            codes[#codes + 1] = code
          end
        end
        table.sort(codes)
        for _, code in ipairs(codes) do
          error_members[#error_members + 1] =
            ts_type(json_schema(op.responses[code].content), "")
        end
      end

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
      if #error_members > 0 then
        w(("export type %sError = %s;"):format(Name, table.concat(error_members, " | ")))
      else
        w(("export type %sError = unknown;"):format(Name))
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
      w(("    throw new AkkarError<%sError>(res.status, (await res.json().catch(() => undefined)) as %sError, %q);")
        :format(Name, Name, op.operationId))
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

-- ============================================================ the Lua side
--
-- The TypeScript client above is for the frontend. These two are for the
-- other caller of an akkar API that has no compiler: another Lua program. They
-- project the SAME document into the two ways a Lua codebase gets static
-- checking today --
--
--   * Teal (`M.teal`): a `.tl` module with one `record` per declared shape and
--     a typed client, which `tl check` verifies and `tl gen` turns into plain
--     Lua. The records are also what a Teal HANDLER casts `req.body` to, so
--     the same file types both ends of one route.
--   * LuaLS (`M.luals`): a `---@meta` file of `---@class`/`---@field`
--     annotations and stub signatures. Comments only, no runtime, no dialect:
--     a plain-Lua caller gets the editor's red squiggle and ships nothing new.
--
-- Both read the OpenAPI document for the reason the TS generator does: it is
-- the one projection the validator already guarantees. What each checker can
-- and cannot catch differs, and each generated file says which in its header,
-- because a type file that oversells itself is worse than none.

--- Every non-2xx response with a body, sorted by status, as `{code, schema}`.
local function error_schemas(responses)
  local codes = {}
  for code in pairs(responses) do
    local n = tonumber(code)
    if n and n >= 400 and json_schema(responses[code].content) then
      codes[#codes + 1] = code
    end
  end
  table.sort(codes)
  local out = {}
  for _, code in ipairs(codes) do
    out[#out + 1] = { code = code, schema = json_schema(responses[code].content) }
  end
  return out
end

--- One object schema standing for the union of several error bodies.
---
--- Teal cannot union record types (a union may hold at most one table type),
--- and LuaLS cannot narrow a union on a literal field, so neither Lua
--- projection can carry the per-status union TypeScript gets. What both CAN
--- carry is the merge: every field of every member, required only where every
--- member requires it, and the discriminator (`error`) as the union of the
--- members' literal values. `fields` therefore reads as "present on the 422,
--- nil on the 500", which is what the server sends.
local function merge_error_schemas(errors)
  if #errors == 0 then return nil end
  local properties, seen_in = {}, {}
  for _, e in ipairs(errors) do
    for name, prop in pairs(e.schema.properties or {}) do
      local have = properties[name]
      if not have then
        local copy = {}
        for k, v in pairs(prop) do copy[k] = v end
        if copy.enum then
          local values = {}
          for i, v in ipairs(copy.enum) do values[i] = v end
          copy.enum = values
        end
        properties[name] = copy
      elseif have.type == prop.type then
        if have.enum and prop.enum then
          local present = {}
          for _, v in ipairs(have.enum) do present[v] = true end
          for _, v in ipairs(prop.enum) do
            if not present[v] then have.enum[#have.enum + 1] = v; present[v] = true end
          end
        else
          have.enum = nil   -- one member widened it to the plain type
        end
      else
        properties[name] = {}  -- the members disagree: unknown
      end
    end
    for _, name in ipairs(e.schema.required or {}) do
      seen_in[name] = (seen_in[name] or 0) + 1
    end
  end
  local required = {}
  for name, count in pairs(seen_in) do
    if count == #errors then required[#required + 1] = name end
  end
  table.sort(required)
  return { type = "object", properties = properties, required = required }
end

--- Everything the Lua emitters need about one operation, gathered once so the
--- two projections cannot read the document differently.
local function operation_shapes(op, method, template)
  local path_schema, query_schema = param_schemas(op.parameters)
  local body_schema = op.requestBody and json_schema(op.requestBody.content)
  local resp_schema = success_schema(op.responses)
  local errors = error_schemas(op.responses)

  local uncheckable = {}
  uncheckable_of(body_schema, "body.", uncheckable)
  uncheckable_of(path_schema, "params.", uncheckable)
  uncheckable_of(query_schema, "query.", uncheckable)
  table.sort(uncheckable)

  return {
    id = op.operationId, Name = pascal(op.operationId), summary = op.summary,
    method = method:upper(), template = template,
    params = path_schema, query = query_schema, body = body_schema,
    response = resp_schema, error = merge_error_schemas(errors),
    -- The call takes an argument table when the route has any input, and
    -- that table is optional when everything in it is (a query-only route).
    has_args = (path_schema or query_schema or body_schema) and true or false,
    args_optional = not path_schema and not body_schema,
    uncheckable = uncheckable,
  }
end

--- Walks `doc.paths` in stable order, calling `visit(shapes)` per operation.
local function each_operation(doc, visit)
  local templates = {}
  for template in pairs(doc.paths) do templates[#templates + 1] = template end
  table.sort(templates)
  for _, template in ipairs(templates) do
    local methods = {}
    for method in pairs(doc.paths[template]) do methods[#methods + 1] = method end
    table.sort(methods)
    for _, method in ipairs(methods) do
      visit(operation_shapes(doc.paths[template][method], method, template))
    end
  end
end

--- Sorted property names of an object schema, and its required set.
local function fields_of(schema)
  local required = {}
  for _, name in ipairs(schema.required or {}) do required[name] = true end
  local names = {}
  for name in pairs(schema.properties or {}) do names[#names + 1] = name end
  table.sort(names)
  return names, required
end

local LUA_KEYWORDS = {}
for word in ("and break do else elseif end false for function goto if in local nil "
          .. "not or repeat return then true until while"):gmatch "%S+" do
  LUA_KEYWORDS[word] = true
end

--- Is `name` usable bare as a Lua field name? A JSON key is any string; a
--- Lua identifier is not, and a key that is a keyword is not either.
local function plain_key(name)
  return name:match("^[%a_][%w_]*$") ~= nil and not LUA_KEYWORDS[name]
end

--- Is every enum value a string? Only those become a Teal `enum` or a LuaLS
--- literal union; a numeric enum falls back to its base type.
local function string_enum(schema)
  if type(schema.enum) ~= "table" or #schema.enum == 0 then return false end
  for _, v in ipairs(schema.enum) do
    if type(v) ~= "string" then return false end
  end
  return true
end

--- The base `type` of a schema, with OpenAPI 3.1's `["string", "null"]` list
--- form reduced to its non-null member. Nil-ness is not carried: in Lua every
--- table field may be nil, and in Teal every type admits nil.
local function base_type(schema)
  local t = schema.type
  if type(t) ~= "table" then return t end
  for _, one in ipairs(t) do
    if one ~= "null" then return one end
  end
  return "null"
end

-- ------------------------------------------------------------------ Teal

--- Renders one schema as a Teal type expression, emitting any nested
--- `record`/`enum` it needs into `out` at `indent` FIRST (Teal has no
--- anonymous record types, so an object-valued field needs a named record,
--- and a record nested inside its parent keeps the name scoped). `hint` is
--- the PascalCase name that nested definition takes.
local teal_type

local function teal_record(name, schema, indent, out)
  out[#out + 1] = indent .. "record " .. name
  local names, required = fields_of(schema)
  -- Nested definitions before the fields that reference them, so a reader
  -- (and the compiler) meets the type before its use.
  local rendered = {}
  for _, field in ipairs(names) do
    rendered[field] = teal_type(schema.properties[field], pascal(field), indent .. "  ", out)
  end
  for _, field in ipairs(names) do
    local key = plain_key(field) and field or ("[%q]"):format(field)
    out[#out + 1] = ("%s  %s: %s%s"):format(indent, key, rendered[field],
                                            required[field] and "" or "   -- optional")
  end
  out[#out + 1] = indent .. "end"
end

teal_type = function(schema, hint, indent, out)
  if type(schema) ~= "table" then return "any" end

  if string_enum(schema) then
    -- A Teal `enum` is exactly a set of string literals, so a `one_of` on a
    -- string field is checked at the call: a literal outside the set is a
    -- compile error. Nested inside the record so its name cannot collide.
    out[#out + 1] = indent .. "enum " .. hint
    for _, v in ipairs(schema.enum) do out[#out + 1] = indent .. "  " .. ("%q"):format(v) end
    out[#out + 1] = indent .. "end"
    return hint
  end

  -- A `oneOf`/`anyOf` of tables is a union Teal refuses (at most one table
  -- type per union), so the honest rendering is `any`, said in the header.
  if schema.oneOf or schema.anyOf then return "any" end

  local t = base_type(schema)
  if t == "string"  then return "string"  end
  if t == "integer" then return "integer" end  -- Teal has one; TS does not
  if t == "number"  then return "number"  end
  if t == "boolean" then return "boolean" end
  if t == "null"    then return "nil"     end
  if t == "array"   then
    return "{" .. teal_type(schema.items, hint .. "Item", indent, out) .. "}"
  end
  if t == "object" then
    if next(schema.properties or {}) then
      teal_record(hint, schema, indent, out)
      return hint
    end
    local extra = schema.additionalProperties
    if type(extra) == "table" then
      return "{string: " .. teal_type(extra, hint .. "Value", indent, out) .. "}"
    end
    return "{string: any}"
  end
  return "any"
end

--- Generates a Teal module: the per-route records and a typed client.
---
--- `info.module` names the record the file returns (default `client`); it is
--- the name a caller `require`s the file by.
function M.teal(app, info)
  info = info or {}
  local doc = openapi.document(app, info)
  local mod = info.module or "client"

  local out = {}
  local function w(s) out[#out + 1] = s or "" end

  w("-- AUTO-GENERATED by `akkar gen --lang teal` from the route schemas. DO NOT EDIT.")
  w("-- Regenerate after any schema change:  akkar gen <app.lua> --lang teal -o <this file>")
  w("-- A green `tl check` means this client matches the LAST GENERATED contract,")
  w("-- not necessarily the running server -- keep it honest with a CI step that")
  w("-- regenerates and fails on a diff (`akkar gen --check`).")
  w("--")
  w("-- What `tl check` catches against these records: a wrong type, a field the")
  w("-- route does not declare (at any depth), a literal outside a declared enum,")
  w("-- an integer field given a non-integer. What it does NOT catch, because Teal")
  w("-- cannot express it: a MISSING required field -- every record field admits")
  w("-- nil. To have the compiler demand every field, declare the value `<total>`:")
  w("--     local body <total>: " .. mod .. ".PostXBody = { ... }")
  w("-- and write `= nil` for the optionals you leave out. Value constraints")
  w("-- (min/max/length/pattern) are listed per route and enforced only by the")
  w("-- server's 422. A route without a declared `response` returns `any`.")
  w("--")
  w("-- The error half is ONE record per route, the merge of every error body the")
  w("-- document declares (Teal cannot union records): `error` is an enum of the")
  w("-- declared literals, and `fields` is present on the 422 and nil otherwise.")
  w("--")
  w("-- This file is the CLIENT side and the SHAPES. It declares no `Request` or")
  w("-- `App`; those live in akkar's own declarations (`types/akkar.d.tl`). A Teal")
  w("-- handler uses these records for the other end of the same route:")
  w("--     local body = req.body as " .. mod .. ".PostXBody")
  w("--")
  w("-- Runtime: `tl gen` this file to get plain Lua. The client speaks HTTP through")
  w("-- the `transport` you hand `new` -- a function from a request to (status,")
  w("-- decoded JSON body) -- so it depends on no HTTP library and runs unchanged")
  w("-- over a socket or over `app:test()`.")
  w("")
  w(("local record %s"):format(mod))
  w("  record TransportRequest")
  w("    method: string")
  w("    path: string               -- base_url, path with params filled, and the query string")
  w("    body: any                  -- a table to send as JSON, or nil")
  w("    headers: {string: string}")
  w("  end")
  w("  -- Returns the HTTP status and the JSON-decoded body.")
  w("  type Transport = function(TransportRequest): integer, any")
  w("")
  w("  record Options")
  w("    transport: Transport")
  w("    base_url: string           -- optional")
  w("    headers: {string: string}  -- optional")
  w("  end")
  w("")

  -- The per-route shapes first, then the Client record that references them.
  local ops = {}
  each_operation(doc, function(shapes) ops[#ops + 1] = shapes end)

  for _, o in ipairs(ops) do
    w(("  -- ---- %s %s  (%s)"):format(o.method, o.template, o.id))
    if o.summary then w("  -- " .. o.summary) end
    if #o.uncheckable > 0 then
      w("  -- Enforced by the server, NOT by these types: " .. table.concat(o.uncheckable, ", "))
    end
    if o.params then teal_record(o.Name .. "Params", o.params, "  ", out) end
    if o.query  then teal_record(o.Name .. "Query",  o.query,  "  ", out) end
    if o.body   then teal_record(o.Name .. "Body",   o.body,   "  ", out) end
    if o.response then
      -- A response that is not an object (an array, say) is a type alias.
      if o.response.type == "object" and next(o.response.properties or {}) then
        teal_record(o.Name .. "Response", o.response, "  ", out)
      else
        local nested = {}
        local rendered = teal_type(o.response, o.Name .. "Response", "  ", nested)
        if rendered == o.Name .. "Response" then
          for _, line in ipairs(nested) do w(line) end
        else
          w(("  type %sResponse = %s"):format(o.Name, rendered))
        end
      end
    else
      w(("  type %sResponse = any   -- the route declares no response"):format(o.Name))
    end
    if o.error then
      teal_record(o.Name .. "ErrorBody", o.error, "  ", out)
    else
      w(("  type %sErrorBody = any"):format(o.Name))
    end
    w(("  record %sError"):format(o.Name))
    w("    status: integer")
    w(("    body: %sErrorBody"):format(o.Name))
    w("  end")
    if o.has_args then
      w(("  record %sArgs"):format(o.Name))
      if o.params then w(("    params: %sParams"):format(o.Name)) end
      if o.query  then w(("    query: %sQuery   -- optional"):format(o.Name)) end
      if o.body   then w(("    body: %sBody"):format(o.Name)) end
      w("  end")
    end
    w("")
  end

  w("  record Client")
  w("    options: Options")
  for _, o in ipairs(ops) do
    local arg = ""
    if o.has_args then
      arg = (o.args_optional and ", ?%sArgs" or ", %sArgs"):format(o.Name)
    end
    w(("    %s: function(Client%s): %sResponse, %sError"):format(o.id, arg, o.Name, o.Name))
  end
  w("  end")
  w("end")
  w("")

  -- The runtime. Small on purpose: fill the path, build the query string, hand
  -- the transport a request, split the answer into (result) or (nil, error).
  w("local function encode_component(s: string): string")
  w("  return (s:gsub(\"[^%w%-_%.~]\", function(c: string): string")
  w("    return (\"%%%02X\"):format(c:byte())")
  w("  end))")
  w("end")
  w("")
  w("local function fill(path: string, name: string, value: any): string")
  w("  local start, stop = path:find(\"{\" .. name .. \"}\", 1, true)")
  w("  if not start then return path end")
  w("  return path:sub(1, start - 1) .. encode_component(tostring(value)) .. path:sub(stop + 1)")
  w("end")
  w("")
  w("local function build_query(query: {string: any}): string")
  w("  if query == nil then return \"\" end")
  w("  local keys: {string} = {}")
  w("  for k in pairs(query) do keys[#keys + 1] = k end")
  w("  table.sort(keys)")
  w("  local parts: {string} = {}")
  w("  for _, k in ipairs(keys) do")
  w("    parts[#parts + 1] = encode_component(k) .. \"=\" .. encode_component(tostring(query[k]))")
  w("  end")
  w("  if #parts == 0 then return \"\" end")
  w("  return \"?\" .. table.concat(parts, \"&\")")
  w("end")
  w("")
  w(("local function send(options: %s.Options, method: string, path: string, body: any): integer, any")
    :format(mod))
  w("  return options.transport({")
  w("    method = method,")
  w("    path = (options.base_url or \"\") .. path,")
  w("    body = body,")
  w("    headers = options.headers or {},")
  w("  })")
  w("end")
  w("")
  w(("function %s.new(options: %s.Options): %s.Client"):format(mod, mod, mod))
  w(("  assert(options and options.transport, \"%s.new needs options.transport\")"):format(mod))
  w(("  return setmetatable({ options = options } as %s.Client, { __index = %s.Client })")
    :format(mod, mod))
  w("end")
  w("")

  for _, o in ipairs(ops) do
    local arg = ""
    if o.has_args then
      arg = (o.args_optional and "args?: %s.%sArgs" or "args: %s.%sArgs"):format(mod, o.Name)
    end
    w(("function %s.Client:%s(%s): %s.%sResponse, %s.%sError")
      :format(mod, o.id, arg, mod, o.Name, mod, o.Name))
    w(("  local path = %q"):format(o.template))
    if o.params then
      local names = fields_of(o.params)
      for _, name in ipairs(names) do
        w(("  path = fill(path, %q, args.params.%s)"):format(name, name))
      end
    end
    if o.query then
      w("  local query: {string: any}")
      w("  if args and args.query then query = args.query as {string: any} end")
      w("  path = path .. build_query(query)")
    end
    w(("  local status, body = send(self.options, %q, path, %s)")
      :format(o.method, o.body and "args.body" or "nil"))
    w("  if status < 200 or status >= 300 then")
    w(("    return nil, { status = status, body = body as %s.%sErrorBody }"):format(mod, o.Name))
    w("  end")
    w(("  return body as %s.%sResponse"):format(mod, o.Name))
    w("end")
    w("")
  end

  w(("return %s"):format(mod))
  return table.concat(out, "\n") .. "\n"
end

-- ----------------------------------------------------------------- LuaLS

--- Renders one schema as a LuaLS type expression, appending any class an
--- object-valued field needs to `classes` (a list of line lists). Classes are
--- top-level in LuaLS, so a nested object is named by its path:
--- `client.GetUsersResponse.UsersItem`.
local luals_type

local function luals_class(name, schema, classes)
  local lines = { "---@class " .. name }
  local names, required = fields_of(schema)
  for _, field in ipairs(names) do
    local rendered = luals_type(schema.properties[field], name .. "." .. pascal(field), classes)
    local key = plain_key(field) and field or ("[%q]"):format(field)
    lines[#lines + 1] = ("---@field %s%s %s"):format(key, required[field] and "" or "?", rendered)
  end
  classes[#classes + 1] = lines
end

luals_type = function(schema, hint, classes)
  if type(schema) ~= "table" then return "any" end
  if string_enum(schema) then
    local parts = {}
    for _, v in ipairs(schema.enum) do parts[#parts + 1] = ("%q"):format(v) end
    return table.concat(parts, "|")
  end
  if schema.oneOf or schema.anyOf then return "any" end
  local t = base_type(schema)
  if t == "string"  then return "string"  end
  if t == "integer" then return "integer" end
  if t == "number"  then return "number"  end
  if t == "boolean" then return "boolean" end
  if t == "null"    then return "nil"     end
  if t == "array"   then return luals_type(schema.items, hint .. "Item", classes) .. "[]" end
  if t == "object" then
    if next(schema.properties or {}) then
      luals_class(hint, schema, classes)
      return hint
    end
    local extra = schema.additionalProperties
    if type(extra) == "table" then
      return "table<string, " .. luals_type(extra, hint .. "Value", classes) .. ">"
    end
    return "table<string, any>"
  end
  return "any"
end

--- Generates a LuaLS `---@meta` file: classes for every shape, and stub
--- signatures for the client API the Teal projection implements.
---
--- Inert by construction: the only statements are empty tables, empty
--- functions and a `return`, so `require`-ing it by accident does nothing.
--- `info.module` (default `client`) is the `---@meta` name, which is what makes
--- `require("client")` resolve to this file in the editor even when it is
--- saved as `client.d.lua` -- an extension the Lua runtime never loads, so the
--- stubs cannot shadow the real module.
function M.luals(app, info)
  info = info or {}
  local doc = openapi.document(app, info)
  local mod = info.module or "client"

  local out = {}
  local function w(s) out[#out + 1] = s or "" end

  w(("---@meta %s"):format(mod))
  w("--")
  w("-- AUTO-GENERATED by `akkar gen --lang luals` from the route schemas. DO NOT EDIT.")
  w("-- Regenerate after any schema change:  akkar gen <app.lua> --lang luals -o <this file>")
  w("-- Annotations only: this file has no runtime and the Lua VM never loads it.")
  w("-- It types the module `" .. mod .. "` (the client `akkar gen --lang teal` emits,")
  w("-- compiled with `tl gen`) for the language server, so a plain-Lua caller")
  w("-- gets checked in the editor and ships nothing new.")
  w("--")
  w("-- What LuaLS catches against these classes: a wrong type, a MISSING required")
  w("-- field (`missing-fields`), a field read that the shape does not declare")
  w("-- (`undefined-field`). What it does NOT catch: an EXTRA field in a table")
  w("-- literal (LuaLS has no excess-property check), and a comparison against a")
  w("-- string literal outside a declared enum. Value constraints (min/max/length/")
  w("-- pattern) are listed per route and enforced only by the server's 422.")
  w("--")
  w("-- The error half is ONE class per route, the merge of every error body the")
  w("-- document declares: `error` is the union of the declared literals, and")
  w("-- `fields` is present on the 422 and nil otherwise.")
  w("")
  w(("---@class %s.TransportRequest"):format(mod))
  w("---@field method string")
  w("---@field path string base_url, path with params filled, and the query string")
  w("---@field body any a table to send as JSON, or nil")
  w("---@field headers table<string, string>")
  w("")
  w(("---Returns the HTTP status and the JSON-decoded body."):format(mod))
  w(("---@alias %s.Transport fun(request: %s.TransportRequest): integer, any"):format(mod, mod))
  w("")
  w(("---@class %s.Options"):format(mod))
  w(("---@field transport %s.Transport"):format(mod))
  w("---@field base_url? string")
  w("---@field headers? table<string, string>")
  w("")

  local ops = {}
  each_operation(doc, function(shapes) ops[#ops + 1] = shapes end)

  for _, o in ipairs(ops) do
    w(("-- ---- %s %s  (%s)"):format(o.method, o.template, o.id))
    local classes = {}
    local function shape(suffix, schema)
      luals_class(("%s.%s%s"):format(mod, o.Name, suffix), schema, classes)
    end
    if o.params then shape("Params", o.params) end
    if o.query  then shape("Query",  o.query)  end
    if o.body   then shape("Body",   o.body)   end
    if o.response then
      if o.response.type == "object" and next(o.response.properties or {}) then
        shape("Response", o.response)
      else
        local rendered = luals_type(o.response, ("%s.%sResponse"):format(mod, o.Name), classes)
        if rendered ~= ("%s.%sResponse"):format(mod, o.Name) then
          classes[#classes + 1] = { ("---@alias %s.%sResponse %s"):format(mod, o.Name, rendered) }
        end
      end
    else
      classes[#classes + 1] = { ("---@alias %s.%sResponse any the route declares no response")
                                  :format(mod, o.Name) }
    end
    if o.error then
      shape("ErrorBody", o.error)
    else
      classes[#classes + 1] = { ("---@alias %s.%sErrorBody any"):format(mod, o.Name) }
    end
    classes[#classes + 1] = {
      ("---@class %s.%sError"):format(mod, o.Name),
      "---@field status integer",
      ("---@field body %s.%sErrorBody"):format(mod, o.Name),
    }
    if o.has_args then
      local lines = { ("---@class %s.%sArgs"):format(mod, o.Name) }
      if o.params then lines[#lines + 1] = ("---@field params %s.%sParams"):format(mod, o.Name) end
      if o.query  then lines[#lines + 1] = ("---@field query? %s.%sQuery"):format(mod, o.Name) end
      if o.body   then lines[#lines + 1] = ("---@field body %s.%sBody"):format(mod, o.Name) end
      classes[#classes + 1] = lines
    end
    for _, lines in ipairs(classes) do
      for _, line in ipairs(lines) do w(line) end
      w("")
    end
  end

  w(("---@class %s.Client"):format(mod))
  w(("---@field options %s.Options"):format(mod))
  w("local Client = {}")
  w("")
  for _, o in ipairs(ops) do
    w(("---%s %s"):format(o.method, o.template))
    if o.summary then w("---" .. o.summary) end
    if #o.uncheckable > 0 then
      w("---Enforced by the server, NOT by these types: " .. table.concat(o.uncheckable, ", "))
    end
    if o.has_args then
      w(("---@param args%s %s.%sArgs"):format(o.args_optional and "?" or "", mod, o.Name))
    end
    w(("---@return %s.%sResponse? result nil exactly when `err` is set"):format(mod, o.Name))
    w(("---@return %s.%sError? err the status and the typed error body"):format(mod, o.Name))
    w(("function Client:%s(%s) end"):format(o.id, o.has_args and "args" or ""))
    w("")
  end

  w(("---@class %s"):format(mod))
  w(("local %s = {}"):format(mod))
  w("")
  w(("---@param options %s.Options"):format(mod))
  w(("---@return %s.Client"):format(mod))
  w(("function %s.new(options) end"):format(mod))
  w("")
  w(("return %s"):format(mod))
  return table.concat(out, "\n") .. "\n"
end

return M
