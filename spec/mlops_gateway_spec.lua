local gateway = require "examples.mlops.gateway_app"
local auth = require "akkar.auth"

describe("MLOps public gateway", function()
  local function client(permissions, models)
    local calls = {}
    local app = gateway.new {
      service = "http://private", token = "internal-secret", model_name = "demo",
      credentials = {
        { hash = auth.hash_key("acme-key"), tenant_id = "acme",
          permissions = permissions or { "predict", "batch:submit", "batch:read" },
          models = models or { "demo" } },
        { hash = auth.hash_key("other-key"), tenant_id = "other",
          permissions = { "predict" }, models = { "demo" } },
      },
    }
    local http = { json = function(_, method, url, options)
      calls[#calls + 1] = options
      return { ok = true }, { status = 200 }
    end }
    return app:test { http = function() return http end }, calls
  end

  it("rejects missing and revoked credentials before forwarding", function()
    local api, calls = client()
    for _, key in ipairs { "", "revoked" } do
      assert.equal(401, api:post("/v1/predictions", {
        headers = { ["x-api-key"] = key }, body = { inputs = { { x = 1 } } },
      }).status)
    end
    assert.equal(0, #calls)
  end)

  it("derives identity for both tenants and overwrites forged headers", function()
    local api, calls = client()
    for _, tenant in ipairs { "acme", "other" } do
      assert.equal(200, api:post("/v1/predictions", {
        headers = { ["x-api-key"] = tenant .. "-key", ["x-tenant-id"] = "forged",
                    authorization = "Bearer attacker" },
        body = { inputs = { { x = 1 } } },
      }).status)
      assert.equal(tenant, calls[#calls].headers["x-tenant-id"])
      assert.equal("Bearer internal-secret", calls[#calls].headers.authorization)
    end
  end)

  it("rejects tenant in payload", function()
    local api, calls = client()
    assert.equal(422, api:post("/v1/predictions", {
      headers = { ["x-api-key"] = "acme-key" },
      body = { tenant_id = "other", inputs = { { x = 1 } } },
    }).status)
    assert.equal(0, #calls)
  end)

  it("requires permissions and model allowlisting", function()
    for _, pair in ipairs { { {}, { "demo" } }, { { "predict" }, {} } } do
      local api, calls = client(pair[1], pair[2])
      assert.equal(403, api:post("/v1/predictions", {
        headers = { ["x-api-key"] = "acme-key" }, body = { inputs = { { x = 1 } } },
      }).status)
      assert.equal(0, #calls)
    end
  end)
end)
