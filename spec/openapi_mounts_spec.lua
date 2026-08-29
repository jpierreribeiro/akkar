--[[
akkar.openapi — walking a mount graph that is not a tree.

`App:mount` accepts a cycle without a word, so two feature apps that mount
each other boot and serve traffic normally. The document walk had no notion of
where it had been, so the first `GET /openapi.json` -- one unauthenticated
request -- recursed until the process died.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local openapi = require "akkar.openapi"

describe("a mount graph that is not a tree", function()
  it("refuses a cycle instead of recursing until the process dies", function()
    local a, b = akkar.new(), akkar.new()
    a:get("/a", function() return {} end)
    b:get("/b", function() return {} end)
    a:mount("/b", b)
    b:mount("/a", a)

    local ok, err = pcall(openapi.document, a)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("cycle", 1, true))
  end)

  it("refuses an app mounted directly inside itself", function()
    local app = akkar.new()
    app:get("/x", function() return {} end)
    app:mount("/self", app)
    assert.is_false((pcall(openapi.document, app)))
  end)

  it("still documents a diamond, which is not a cycle", function()
    -- One sub-app under two prefixes is a legitimate shape, and a visited set
    -- over everything ever seen would have called it a cycle.
    local root, leaf = akkar.new(), akkar.new()
    leaf:get("/ping", function() return {} end)
    root:mount("/one", leaf)
    root:mount("/two", leaf)

    local document = openapi.document(root)
    assert.is_truthy(document.paths["/one/ping"])
    assert.is_truthy(document.paths["/two/ping"])
  end)

  it("still documents an ordinary nested mount", function()
    local root, feature = akkar.new(), akkar.new()
    feature:get("/health", function() return {} end)
    root:mount("/internal", feature)
    assert.is_truthy(openapi.document(root).paths["/internal/health"])
  end)
end)
