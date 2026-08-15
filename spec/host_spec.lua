--[[
Host-based routing — readiness item 1.

The tests that matter are the ones about what must NOT match. A host router
that is slightly too generous hands one tenant's traffic to another tenant's
application, which is the same failure the tenant-scoped database exists to
prevent, one layer up.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

local function tenanted()
  local acme = akkar.new()
  acme:get("/who", function() return { tenant = "acme" } end)

  local wildcard = akkar.new()
  wildcard:get("/who", function(req) return { tenant = "wildcard", host = req.host } end)

  local main = akkar.new()
  main:get("/who", function() return { tenant = "main" } end)
  main:host("acme.example.com", acme)
  main:host("*.example.com", wildcard)
  return main
end

local function who(client, host)
  return client:get("/who", { headers = { host = host } }).body
end

describe("selecting an app by host", function()
  local client
  setup(function() client = tenanted():test() end)

  it("sends an exact host to its own app", function()
    assert.equal("acme", who(client, "acme.example.com").tenant)
  end)

  it("prefers the exact host over the wildcard", function()
    -- Registration order must not decide this; the exact one is more specific
    -- whichever way round they were declared.
    assert.equal("acme", who(client, "acme.example.com").tenant)
    assert.equal("wildcard", who(client, "globex.example.com").tenant)
  end)

  it("falls through to the main app when nothing matches", function()
    -- Adding a host must never take away an answer that already worked.
    assert.equal("main", who(client, "somewhere.else.org").tenant)
    assert.equal("main", who(client, nil).tenant)
  end)

  it("ignores the port and the case", function()
    assert.equal("acme", who(client, "ACME.Example.com:8080").tenant)
  end)

  it("ignores the fully-qualified trailing dot", function()
    assert.equal("acme", who(client, "acme.example.com.").tenant)
  end)
end)

describe("what a wildcard must not match", function()
  local client
  setup(function() client = tenanted():test() end)

  it("does not match a suffix that is not a label boundary", function()
    -- The bug this prevents: `*.example.com` treated as "ends with
    -- example.com" hands `evil-example.com` to the tenant application.
    assert.equal("main", who(client, "evil-example.com").tenant)
    assert.equal("main", who(client, "notexample.com").tenant)
  end)

  it("does not match the bare domain", function()
    assert.equal("main", who(client, "example.com").tenant)
  end)

  it("matches one label, not several", function()
    assert.equal("main", who(client, "a.b.example.com").tenant)
  end)

  it("does not let a dot in the pattern act as any character", function()
    -- `*.example.com` compiled as a Lua pattern without escaping would match
    -- `x.exampleXcom`.
    assert.equal("main", who(client, "x.exampleXcom").tenant)
  end)
end)

describe("the selected app is the whole app", function()
  it("runs the selected app's middleware, not the outer one's", function()
    -- Running the wrong app's authentication against the right app's handler
    -- is worse than having no host routing at all.
    local seen = {}

    local tenant = akkar.new()
    tenant:use(function(req, nxt) seen[#seen + 1] = "tenant"; return nxt() end)
    tenant:get("/", function() return { ok = true } end)

    local main = akkar.new()
    main:use(function(req, nxt) seen[#seen + 1] = "main"; return nxt() end)
    main:get("/", function() return { ok = true } end)
    main:host("t.example.com", tenant)

    main:test():get("/", { headers = { host = "t.example.com" } })
    assert.same({ "tenant" }, seen)

    seen = {}
    main:test():get("/", { headers = { host = "other.example.com" } })
    assert.same({ "main" }, seen)
  end)

  it("answers 404 from the selected app, not from the outer one", function()
    local tenant = akkar.new()
    tenant:get("/only-here", function() return {} end)

    local main = akkar.new()
    main:get("/only-there", function() return {} end)
    main:host("t.example.com", tenant)

    local client = main:test()
    assert.equal(200, client:get("/only-here", { headers = { host = "t.example.com" } }).status)
    assert.equal(404, client:get("/only-there", { headers = { host = "t.example.com" } }).status)
    assert.equal(200, client:get("/only-there").status)
  end)

  it("puts the normalised host on the request", function()
    local main = akkar.new()
    local tenant = akkar.new()
    tenant:get("/who", function(req) return { host = req.host } end)
    main:host("*.example.com", tenant)

    local res = main:test():get("/who", { headers = { host = "Globex.Example.com:443" } })
    assert.equal("globex.example.com", res.body.host)
  end)
end)

describe("registering hosts", function()
  it("refuses a duplicate rather than letting the second never match", function()
    local main = akkar.new()
    main:host("a.example.com", akkar.new())
    local ok, err = pcall(function() main:host("A.example.com:80", akkar.new()) end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "already routed")
  end)

  it("leaves an app with no hosts exactly as it was", function()
    local app = akkar.new()
    app:get("/", function() return { ok = true } end)
    assert.equal(200, app:test():get("/", { headers = { host = "anything" } }).status)
  end)
end)
