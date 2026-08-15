--[[
Apps built from data, and swapped while running — readiness item 2.

Two properties carry the weight. A spec must never be able to introduce code,
because the specs that most want this shape are the ones arriving from
outside. And a swap must not drop a request, because the whole point of a hot
swap is that a customer clicking publish is not an outage.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local cjson = require "cjson"

local handlers = {
  ["users.show"] = function(req) return { id = req.params.id, name = "ada" } end,
  ["users.list"] = function() return { users = {} } end,
}

describe("building an app from a table", function()
  it("routes, validates and answers", function()
    local app = akkar.from_spec({
      routes = {
        { method = "GET", path = "/users/:id",
          params = { id = { kind = "integer", min = 1 } },
          handler = "users.show" },
        { method = "GET", path = "/users", handler = "users.list" },
      },
    }, { handlers = handlers })

    local client = app:test()
    assert.equal(7, client:get("/users/7").body.id)
    assert.same({}, client:get("/users").body.users)
    assert.equal(422, client:get("/users/0").status, "the spec's validation must apply")
  end)

  it("survives a round trip through JSON", function()
    -- The claim is that a spec is data.  If it does not survive encoding, it
    -- is not data, it is Lua that happens to look like it.
    local spec = {
      routes = {
        { method = "GET", path = "/users/:id",
          params = { id = "integer" },
          response = { id = "integer", name = "string" },
          handler = "users.show" },
      },
    }
    local app = akkar.from_spec(cjson.decode(cjson.encode(spec)), { handlers = handlers })
    assert.equal(200, app:test():get("/users/3").status)
  end)

  it("applies middleware named in the spec", function()
    local seen = {}
    local app = akkar.from_spec({
      middleware = { "trace" },
      routes = { { path = "/", handler = "users.list" } },
    }, {
      handlers = handlers,
      middleware = { trace = function(req, nxt) seen[#seen + 1] = req.path; return nxt() end },
    })

    app:test():get("/")
    assert.same({ "/" }, seen)
  end)

  it("applies route-scoped middleware named in the spec", function()
    local hits = 0
    local app = akkar.from_spec({
      routes = { { path = "/guarded", handler = "users.list", before = { "count" } },
                 { path = "/open", handler = "users.list" } },
    }, {
      handlers = handlers,
      middleware = { count = function(req, nxt) hits = hits + 1; return nxt() end },
    })

    app:test():get("/guarded")
    app:test():get("/open")
    assert.equal(1, hits)
  end)
end)

describe("a spec cannot introduce code", function()
  it("resolves handlers by name against what the caller supplied", function()
    local ok, err = pcall(function()
      akkar.from_spec({ routes = { { path = "/", handler = "not.provided" } } },
                      { handlers = handlers })
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "no handler named 'not.provided'")
  end)

  it("names the route that was wrong, because a spec is usually generated", function()
    local ok, err = pcall(function()
      akkar.from_spec({
        routes = {
          { path = "/a", handler = "users.list" },
          { path = "/b", handler = "users.list" },
          { method = "TELEPORT", path = "/c", handler = "users.list" },
        },
      }, { handlers = handlers })
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "route 3 %(TELEPORT /c%)")
  end)

  it("rejects a path that is not one", function()
    for _, bad in ipairs { "users", 42, true } do
      local ok = pcall(function()
        akkar.from_spec({ routes = { { path = bad, handler = "users.list" } } },
                        { handlers = handlers })
      end)
      assert.is_false(ok, "accepted a bad path: " .. tostring(bad))
    end
  end)

  it("ignores keys that are not declarative route options", function()
    -- A spec able to set arbitrary options would be a second, undocumented
    -- API surface, reachable by whoever writes the spec.
    local app = akkar.from_spec({
      routes = { { path = "/", handler = "users.list",
                   timeout = 0.001, strict = false, nonsense = true } },
    }, { handlers = handlers })
    assert.equal(200, app:test():get("/").status)
  end)
end)

describe("swapping a host's app while running", function()
  it("replaces the app and returns the previous one", function()
    local v1 = akkar.new(); v1:get("/v", function() return { version = 1 } end)
    local v2 = akkar.new(); v2:get("/v", function() return { version = 2 } end)

    local main = akkar.new()
    main:get("/v", function() return { version = "main" } end)
    main:host("acme.example.com", v1)

    local client = main:test()
    local function version()
      return client:get("/v", { headers = { host = "acme.example.com" } }).body.version
    end

    assert.equal(1, version())
    local previous = main:swap_host("acme.example.com", v2)
    assert.equal(2, version())
    assert.equal(v1, previous)
  end)

  it("adds the host when it was not routed yet", function()
    -- The first publish of a tenant looks exactly like this, and making the
    -- caller track which case they are in would be busywork.
    local main = akkar.new()
    main:get("/v", function() return { version = "main" } end)

    local tenant = akkar.new()
    tenant:get("/v", function() return { version = "tenant" } end)

    assert.is_nil(main:swap_host("new.example.com", tenant))
    assert.equal("tenant",
      main:test():get("/v", { headers = { host = "new.example.com" } }).body.version)
  end)

  it("does not disturb the other hosts", function()
    local a = akkar.new(); a:get("/v", function() return { v = "a" } end)
    local b = akkar.new(); b:get("/v", function() return { v = "b" } end)
    local c = akkar.new(); c:get("/v", function() return { v = "c" } end)

    local main = akkar.new()
    main:host("a.example.com", a)
    main:host("b.example.com", b)
    main:swap_host("a.example.com", c)

    local client = main:test()
    assert.equal("c", client:get("/v", { headers = { host = "a.example.com" } }).body.v)
    assert.equal("b", client:get("/v", { headers = { host = "b.example.com" } }).body.v)
  end)

  it("lets a request in flight finish against the app it was routed to", function()
    -- Swapping an application out from under a handler halfway through would
    -- be worse than letting the last few requests finish on the old one.
    local cqueues = require "cqueues"

    local old = akkar.new()
    old:get("/slow", function()
      cqueues.sleep(0.05)
      return { version = "old" }
    end)
    local new = akkar.new()
    new:get("/slow", function() return { version = "new" } end)

    local main = akkar.new()
    main:host("t.example.com", old)
    local client = main:test()

    local in_flight, after_swap
    local cq = cqueues.new()
    cq:wrap(function()
      in_flight = client:get("/slow", { headers = { host = "t.example.com" } }).body.version
    end)
    cq:wrap(function()
      cqueues.sleep(0.01)                    -- while the first is sleeping
      main:swap_host("t.example.com", new)
      after_swap = client:get("/slow", { headers = { host = "t.example.com" } }).body.version
    end)
    assert(cq:loop(5))

    assert.equal("old", in_flight, "a request in flight was moved to the new app")
    assert.equal("new", after_swap)
  end)
end)
