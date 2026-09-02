--[[
A schema table that is not a rule is refused where the route is declared.

WHAT HAPPENED. Building the typed client, a route was written as

    app:get("/x", { response = { users = { { id = "string" } } } }, handler)

-- an array spelled as a bare nested table instead of `v.array { items = ... }`.
It registered. `expand` hands any table back untouched, so the field's rule was
a table with no `kind`; `check_one` matches a nil kind against nothing and
returns the value unchanged, so the response was never validated and the 200
went out unchecked. `akkar.openapi` then wrote the field down as `type: string`
-- its fallthrough for a kind it did not know -- and `akkar gen` typed it as a
string, so a caller's `page.users[0].name` was a type error against a server
that sends a list. Three readers of one declaration, each wrong in silence.

THE RULE. Below a slot, a table is a rule, and a rule names its kind: a
shorthand string, a `v.*` builder, or a hand-written `{ kind = ... }`. The
field-map shorthand -- `body = { to = "string" }` -- is the SLOT's spelling and
nothing below it. Nothing in the tree or the documentation wrote a nested bare
table, and one never validated anything, so no working declaration is affected.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local openapi = require "akkar.openapi"
local v       = akkar.v

local function registering(verb, path, opts)
  local app = akkar.new()
  local ok, why = pcall(function()
    app[verb](app, path, opts, function() return {} end)
  end)
  return ok, tostring(why)
end

local function assert_refused(ok, why, ...)
  assert.is_false(ok, "expected registration to raise")
  for _, needle in ipairs { ... } do
    assert.is_truthy(why:find(needle, 1, true),
      ("expected %q in the message, got: %s"):format(needle, why))
  end
end

describe("a table that is not a rule", function()
  it("is refused at registration, naming the route, the path and the spelling", function()
    local ok, why = registering("get", "/x", {
      response = { users = { { id = "string" } } },
    })
    assert_refused(ok, why,
      "GET /x: response.users: a table with a positional entry is not a rule",
      "an array is v.array { items = ... }")
  end)

  it("never becomes a running server", function()
    -- The half that matters: before the fix the route served a 200 nobody
    -- validated. A refused registration leaves nothing to serve.
    local app = akkar.new()
    pcall(function()
      app:get("/x", { response = { users = { { id = "string" } } } },
              function() return { users = { { id = "a" } } } end)
    end)
    assert.equal(0, #app.routes)
    assert.equal(404, app:test():get("/x").status)
  end)

  it("names a bare object one level down, and the spelling for one", function()
    local ok, why = registering("post", "/p", {
      body = { user = { name = "string" } },
    })
    assert_refused(ok, why,
      "POST /p: body.user: a bare table of fields is not a rule",
      "a nested object is v.object { fields = { ... } }")
  end)

  it("names the element rule of an array as `.items`", function()
    local ok, why = registering("post", "/p", {
      body = v.array { items = { id = "string" } },
    })
    assert_refused(ok, why, "POST /p: body.items: a bare table of fields is not a rule")
  end)

  it("carries the dotted path down every level, like a 422 does", function()
    local ok, why = registering("get", "/x", {
      response = v.object { fields = {
        order = v.object { fields = { lines = { { sku = "string" } } } },
      } },
    })
    assert_refused(ok, why, "GET /x: response.order.lines: a table with a positional entry")
  end)

  it("covers a per-status response too", function()
    local ok, why = registering("post", "/p", {
      responses = { [201] = { users = { { id = "string" } } } },
    })
    assert_refused(ok, why, "POST /p: responses[201].users: a table with a positional entry")
  end)

  it("refuses an empty table, which validated nothing either", function()
    local ok, why = registering("get", "/x", { query = { n = {} } })
    assert_refused(ok, why, "GET /x: query.n: an empty table is not a rule", '"table"')
  end)

  it("refuses a hand-written rule whose kind is not a type", function()
    -- `{ kind = "intger" }` bypasses `v.integer` and used to pass with the
    -- same nil-branch silence as a table with no kind at all.
    local ok, why = registering("get", "/x", { query = { n = { kind = "intger" } } })
    assert_refused(ok, why, "GET /x: query.n: unknown schema type: 'intger'")
  end)
end)

describe("every spelling that is a rule still registers", function()
  local function serves(opts, reply)
    local app = akkar.new()
    app:post("/p", opts, function() return reply end)
    return app
  end

  it("the field map at the slot", function()
    local app = serves({ body = { to = "string" } }, { ok = true })
    assert.equal(200, app:test():post("/p", { body = { to = "x" } }).status)
    assert.equal(422, app:test():post("/p", { body = {} }).status)
  end)

  it("v.object and v.array nested to any depth, and they VALIDATE", function()
    local app = serves({
      response = { users = v.array { items = v.object { fields = { id = "string" } } } },
    }, { users = { { id = 1 } } })
    -- An id that is not a string is the server breaking its own contract.
    assert.equal(500, app:test():post("/p").status)
  end)

  it("a hand-written { kind = ... } tree, the form a spec round-trips through JSON", function()
    local app = serves({
      response = { users = { kind = "array", items = { kind = "object",
                     fields = { id = { kind = "string" } } } } },
    }, { users = { { id = "a", extra = true } } })
    local res = app:test():post("/p")
    assert.equal(200, res.status)
    assert.equal("a", res.body.users[1].id)
    assert.is_nil(res.body.users[1].extra)
  end)

  it("a field genuinely called `kind` beside other fields is still a field map", function()
    local app = serves({ body = { kind = "string", name = "string" } }, { ok = true })
    assert.equal(200, app:test():post("/p", { body = { kind = "k", name = "n" } }).status)
  end)
end)

describe("akkar.openapi on a rule it cannot expand", function()
  -- Registration refuses these, so a declared route can never carry one. The
  -- document still has to say so rather than fall back to `type: string`:
  -- a route table assembled by hand, bypassing `app:get`, is the one way such a
  -- rule reaches the document, and a quiet default is exactly the lie the
  -- generated client was built on.
  local function bypassing(opts)
    local app = akkar.new()
    app.routes[#app.routes + 1] = { method = "GET", path = "/x", names = {},
                                    opts = opts, handler = function() end }
    return pcall(openapi.document, app)
  end

  it("raises, naming the route and the path, instead of documenting a string", function()
    local ok, why = bypassing { response = { users = { { id = "string" } } } }
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("GET /x: response.users", 1, true),
      "expected the path in the message, got: " .. tostring(why))
    assert.is_truthy(tostring(why):find("no schema kind", 1, true), tostring(why))
  end)

  it("raises for an unknown shorthand rather than describing nothing", function()
    local ok, why = bypassing { query = { q = "strng" } }
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("GET /x: query.q: unknown schema type 'strng'", 1, true),
      tostring(why))
  end)

  it("documents the declared array as an array, so the client types a list", function()
    local app = akkar.new()
    app:get("/x", {
      response = { users = v.array { items = v.object { fields = { id = "string" } } } },
    }, function() return { users = {} } end)
    local schema = openapi.document(app).paths["/x"].get.responses["200"]
                     .content["application/json"].schema
    assert.equal("array", schema.properties.users.type)
    assert.equal("object", schema.properties.users.items.type)
    assert.equal("string", schema.properties.users.items.properties.id.type)
  end)
end)
