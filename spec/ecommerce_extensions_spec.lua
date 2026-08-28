package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local metrics = require "akkar.metrics"
local openapi = require "akkar.openapi"
local idempotency = require "akkar.idempotency"
local sql = require "akkar.sql"
local v = akkar.v
local db = require "akkar.db"

describe("nested schemas", function()
  local item = v.object { fields = {
    sku = v.string { min = 2 },
    quantity = v.integer { min = 1, max = 10 },
  } }

  it("validates and filters nested arrays of objects", function()
    local app = akkar.new()
    app:post("/orders", {
      body = v.object { fields = {
        note = "string?",
        items = v.array { min = 1, max = 5, items = item },
      } },
    }, function(req) return { items = req.body.items } end)

    local res = app:test():post("/orders", { body = {
      ignored = "outside contract",
      items = { { sku = "CR-1", quantity = 2, cost_price = 1 } },
    } })
    assert.equal(200, res.status)
    assert.same({ { sku = "CR-1", quantity = 2 } }, res.body.items)
  end)

  it("preserves empty arrays as JSON arrays", function()
    local app = akkar.new()
    app:get("/items", { response = v.object { fields = {
      items = v.array { items = "string" },
    } } }, function() return { items = setmetatable({}, require("cjson").array_mt) } end)
    local response = app:test():get "/items"
    assert.equal("[]", require("cjson").encode(response.body.items))
  end)

  it("returns paths precise enough for a form to render", function()
    local app = akkar.new()
    app:post("/orders", {
      body = v.object { fields = { items = v.array { min = 1, items = item } } },
    }, function() return { impossible = true } end)

    local res = app:test():post("/orders", { body = {
      items = { { sku = "x", quantity = 0 }, { sku = "ok" } },
    } })
    assert.equal(422, res.status)
    assert.equal("min length 2", res.body.fields["body.items.1.sku"])
    assert.equal("min is 1", res.body.fields["body.items.1.quantity"])
    assert.equal("required", res.body.fields["body.items.2.quantity"])
  end)

  it("enforces a nested response selected by status", function()
    local app = akkar.new()
    app:post("/orders", {
      responses = { [201] = v.object { fields = {
        id = "string",
        items = v.array { items = item },
      } } },
    }, function()
      return akkar.created { id = "o-1", items = { { sku = "CR-1", quantity = "two" } } }
    end)

    assert.equal(500, app:test():post("/orders", { body = {} }).status)
  end)

  it("documents recursive arrays and explicit statuses", function()
    local app = akkar.new()
    app:post("/orders", {
      body = v.object { fields = { items = v.array { min = 1, items = item } } },
      responses = { [201] = v.object { fields = { id = "string", items = v.array { items = item } } } },
    }, function() return akkar.created {} end)

    local operation = openapi.document(app).paths["/orders"].post
    local request = operation.requestBody.content["application/json"].schema
    assert.equal("array", request.properties.items.type)
    assert.equal(1, request.properties.items.minItems)
    assert.is_nil(request.properties.items.minimum)
    assert.is_nil(request.properties.items.maximum)
    assert.equal("integer", request.properties.items.items.properties.quantity.type)
    assert.equal("object", operation.responses["201"].content["application/json"].schema.type)
  end)

  it("can document an ECMAScript pattern distinct from Lua syntax", function()
    local app = akkar.new()
    app:get("/ids/:id", { params = {
      id = v.string { match = "^%x+$", openapi_pattern = "^[0-9a-fA-F]+$" },
    } }, function(req) return { id = req.params.id } end)
    local parameter = openapi.document(app).paths["/ids/{id}"].get.parameters[1]
    assert.equal("^[0-9a-fA-F]+$", parameter.schema.pattern)
    assert.equal(200, app:test():get("/ids/deadbeef").status)
    assert.equal(422, app:test():get("/ids/not-hex").status)
  end)

  it("carries explicit security and header metadata", function()
    local app = akkar.new()
    app:post("/charges", {
      openapi = {
        security = { { bearer = {} } },
        headers = { ["Idempotency-Key"] = { required = true } },
      },
    }, function() return {} end)
    local document = openapi.document(app, {
      components = { securitySchemes = { bearer = { type = "http", scheme = "bearer" } } },
    })
    local operation = document.paths["/charges"].post
    assert.same({ { bearer = {} } }, operation.security)
    assert.equal("Idempotency-Key", operation.parameters[1].name)
    assert.is_true(operation.parameters[1].required)
    assert.equal("bearer", document.components.securitySchemes.bearer.scheme)
  end)
end)

describe("idempotency fingerprints", function()
  it("hashes the full body instead of a shared prefix", function()
    local prefix = string.rep("x", 700)
    local first = idempotency.fingerprint_of {
      method = "POST", path = "/charges", body = { payload = prefix .. "a" },
    }
    local second = idempotency.fingerprint_of {
      method = "POST", path = "/charges", body = { payload = prefix .. "b" },
    }
    assert.not_equal(first, second)
  end)

  it("canonicalizes object keys but preserves array order", function()
    local first = idempotency.fingerprint_of {
      method = "POST", path = "/charges",
      body = { customer = { name = "Luz", age = 30 }, items = { "a", "b" } },
    }
    local equivalent = idempotency.fingerprint_of {
      method = "POST", path = "/charges",
      body = { items = { "a", "b" }, customer = { age = 30, name = "Luz" } },
    }
    local reordered = idempotency.fingerprint_of {
      method = "POST", path = "/charges",
      body = { items = { "b", "a" }, customer = { age = 30, name = "Luz" } },
    }
    assert.equal(first, equivalent)
    assert.not_equal(first, reordered)
  end)
end)

describe("verified PostgreSQL TLS", function()
  it("sets SNI and hostname verification for DNS hosts", function()
    local ssl = db.tls_client { host = "postgres.example.test", ssl = true, ssl_verify = true }
    assert.equal("postgres.example.test", ssl:getHostName())
  end)

  it("does not send an IP address as SNI", function()
    local ssl = db.tls_client { host = "127.0.0.1", ssl = true, ssl_verify = true }
    assert.is_nil(ssl:getHostName())
  end)
end)

describe("inventory-safe SQL", function()
  it("places FOR UPDATE after pagination", function()
    local query = sql.select("id, stock"):from("variants")
      :where("id = ?", "v-1"):limit(1):for_update()
    assert.equal("select id, stock from variants where id = $1 limit $2 for update",
                 query:to_string())
    assert.same({ "v-1", 1 }, query:values())
  end)

  it("refuses FOR UPDATE on writes", function()
    local ok, why = pcall(function() sql.update("variants"):for_update() end)
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("only valid on select", 1, true))
  end)

  it("builds a checked idempotent insert", function()
    local query = sql.insert_into("event_ids", { event_id = "e-1" })
      :on_conflict_do_nothing({ "tenant_id", "event_id" }):returning("event_id")
      :scope("tenant_id", "t-1")
    assert.equal("insert into event_ids (event_id, tenant_id) values ($1, $2) " ..
                 "on conflict (tenant_id, event_id) do nothing returning event_id",
                 query:to_string())
    assert.same({ "e-1", "t-1" }, query:values())
  end)
end)

describe("application metrics", function()
  it("renders bounded labelled counters", function()
    local registry = metrics.new()
    registry:counter("commerce_checkouts_total", 1, { { "result", "created" } })
    registry:counter("commerce_checkouts_total", 2, { { "result", "created" } })
    local rendered = registry:render()
    assert.is_truthy(rendered:find(
      'commerce_checkouts_total{result="created"} 3', 1, true))
  end)

  it("refuses invalid names and negative deltas", function()
    local registry = metrics.new()
    assert.has_error(function() registry:counter("bad-name") end)
    assert.has_error(function() registry:counter("good_name", -1) end)
  end)
end)
