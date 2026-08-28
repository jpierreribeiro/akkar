package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local metrics = require "akkar.metrics"
local openapi = require "akkar.openapi"
local sql = require "akkar.sql"
local v = akkar.v

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
    assert.equal("integer", request.properties.items.items.properties.quantity.type)
    assert.equal("object", operation.responses["201"].content["application/json"].schema.type)
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
