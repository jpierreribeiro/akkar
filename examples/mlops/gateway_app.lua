local akkar = require "akkar"
local auth = require "akkar.auth"
local json = require "akkar.json"
local M = {}

function M.credentials(path)
  local file = assert(io.open(path, "rb"), "cannot open ML_CLIENT_KEYS_FILE")
  local raw = file:read(1024 * 1024 + 1)
  file:close()
  assert(#raw <= 1024 * 1024, "credential file too large")
  local entries = json.decode(raw)
  assert(type(entries) == "table" and #entries > 0 and #entries <= 1000,
         "expected 1..1000 credentials")
  for _, entry in ipairs(entries) do
    assert(type(entry.hash) == "string" and #entry.hash == 64 and
           entry.hash:match("^[a-f0-9]+$"), "expected SHA-256 key hash")
    assert(type(entry.tenant_id) == "string" and #entry.tenant_id <= 128 and
           entry.tenant_id:match("^[A-Za-z0-9][A-Za-z0-9._-]*$"), "invalid tenant")
    assert(type(entry.permissions) == "table" and type(entry.models) == "table",
           "permissions and models are required")
  end
  return entries
end

local function contains(values, want)
  for _, value in ipairs(values) do if value == want then return true end end
  return false
end

function M.new(options)
  assert(options.service and options.token and options.credentials and options.model_name)
  local app = akkar.new()
  app:use(auth.middleware { keys = function(_, key)
    for _, entry in ipairs(options.credentials) do
      if auth.compare_key(key, entry.hash) then return entry end
    end
  end })
  local function forward(req, method, path, permission, body)
    local principal = req.auth
    if not contains(principal.permissions, permission) then
      return akkar.response(403, { error = "forbidden" })
    end
    if body then
      if body.tenant_id ~= nil then
        return akkar.response(422, { error = "tenant_id is derived from credentials" })
      end
      local name = body.model_name or options.model_name
      if not contains(principal.models, name) then
        return akkar.response(403, { error = "model forbidden" })
      end
      body.model_name = name
    end
    -- Never copy caller-controlled identity or service authorization headers.
    local headers = {
      authorization = "Bearer " .. options.token,
      ["x-tenant-id"] = principal.tenant_id,
      ["x-request-id"] = req.id,
      ["idempotency-key"] = req.headers["idempotency-key"],
    }
    local result, res = req.http:json(method, options.service .. path, {
      body = body, headers = headers, traceparent = req.headers.traceparent,
    })
    if not result then
      req.log:error("ML service unavailable")
      return akkar.response(503, { error = "model service unavailable" },
                            { ["retry-after"] = "1" })
    end
    return akkar.response(res.status, result)
  end
  app:post("/v1/predictions", function(req)
    if type(req.body) ~= "table" or type(req.body.inputs) ~= "table" then
      return akkar.response(422, { error = "inputs must be an array" })
    end
    return forward(req, "POST", "/internal/v1/predictions", "predict", req.body)
  end)
  app:post("/v1/batches", function(req)
    if type(req.body) ~= "table" then
      return akkar.response(422, { error = "body must be an object" })
    end
    if not req.headers["idempotency-key"] or req.headers["idempotency-key"] == "" then
      return akkar.response(400, { error = "idempotency-key is required" })
    end
    return forward(req, "POST", "/internal/v1/batches", "batch:submit", req.body)
  end)
  app:get("/v1/batches/:id", function(req)
    return forward(req, "GET", "/internal/v1/batches/" .. req.params.id, "batch:read")
  end)
  return app
end
return M
