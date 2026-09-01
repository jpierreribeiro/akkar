--[[
akkar.openapi — documenting a schema that is more than one level deep.

The module's promise is that ONE declaration serves validation and
documentation both, so the document can never describe something different
from what is enforced. A nested declaration broke that promise quietly: an
object inside an object came out as `{}`, and an array came out as a STRING
carrying `minimum`/`maximum` -- keywords OpenAPI does not apply to arrays.
A generated client reading that document sends a string where the server
requires a list, and the mismatch is invisible on both sides until a request
fails in production.

The rules here are written as the plain tables a rule IS -- `{ kind = "array",
items = ... }` -- rather than through `akkar.v`, so these tests pin
`akkar.openapi` and nothing else.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local openapi = require "akkar.openapi"

local item = { kind = "object", fields = {
  sku      = { kind = "string", min = 2 },
  quantity = { kind = "integer", min = 1, max = 10 },
  note     = { kind = "string", optional = true },
} }

local function document(opts)
  local app = akkar.new()
  app:post("/orders", opts, function() return {} end)
  return openapi.document(app).paths["/orders"].post
end

describe("a schema deeper than one level", function()
  it("documents an array as an array, with its element schema", function()
    local schema = document { body = { items = { kind = "array", items = item } } }
      .requestBody.content["application/json"].schema

    assert.equal("object", schema.type)
    assert.equal("array", schema.properties.items.type)
    assert.equal("object", schema.properties.items.items.type)
    assert.equal("integer",
      schema.properties.items.items.properties.quantity.type)
    assert.equal("string", schema.properties.items.items.properties.sku.type)
  end)

  it("puts an array's bounds on minItems, not on minimum", function()
    -- `minimum` on an array constrains nothing. Reporting it there left the
    -- one bound the validator DOES enforce -- element count -- undocumented,
    -- and put a bound nothing enforces in its place.
    local schema = document { body = { items = { kind = "array", min = 1, max = 5,
                                                 items = item } } }
      .requestBody.content["application/json"].schema.properties.items

    assert.equal(1, schema.minItems)
    assert.equal(5, schema.maxItems)
    assert.is_nil(schema.minimum)
    assert.is_nil(schema.maximum)
  end)

  it("keeps a scalar's bounds where they belong", function()
    -- The same change must not move an integer's or a string's bounds: the
    -- element schema below is reached through two levels of nesting.
    local element = document { body = { items = { kind = "array", items = item } } }
      .requestBody.content["application/json"].schema.properties.items.items

    assert.equal(1, element.properties.quantity.minimum)
    assert.equal(10, element.properties.quantity.maximum)
    assert.equal(2, element.properties.sku.minLength)
    assert.is_nil(element.properties.sku.minimum)
  end)

  it("carries required and optional down every level", function()
    local element = document { body = { items = { kind = "array", items = item } } }
      .requestBody.content["application/json"].schema.properties.items.items

    assert.same({ "quantity", "sku" }, element.required)
  end)

  it("documents an object field as an object rather than as nothing", function()
    local schema = document { body = { customer = { kind = "object", fields = {
      name = "string", email = "string?",
    } } } }.requestBody.content["application/json"].schema.properties.customer

    assert.equal("object", schema.type)
    assert.equal("string", schema.properties.name.type)
    assert.same({ "name" }, schema.required)
  end)

  it("describes an array with no element rule without inventing one", function()
    local schema = document { body = { tags = { kind = "array" } } }
      .requestBody.content["application/json"].schema.properties.tags

    assert.equal("array", schema.type)
    assert.equal("object", schema.items.type)   -- `table`, the widest rule
  end)

  it("applies the same nesting to a documented response", function()
    local schema = document {
      response = { items = { kind = "array", min = 1, items = item } },
    }.responses["200"].content["application/json"].schema

    assert.equal("array", schema.properties.items.type)
    assert.equal(1, schema.properties.items.minItems)
    assert.equal("integer", schema.properties.items.items.properties.quantity.type)
  end)
end)

describe("the original spelling still reads as it did", function()
  it("takes a bare map of field name to rule", function()
    -- `object_schema` is the entry point for a body, and making it recursive
    -- must not change what it does at the top level.
    local schema = document { body = { id = "string", size = "integer?" } }
      .requestBody.content["application/json"].schema

    assert.equal("object", schema.type)
    assert.equal("string", schema.properties.id.type)
    assert.equal("integer", schema.properties.size.type)
    assert.same({ "id" }, schema.required)
  end)
end)
