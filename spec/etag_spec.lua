--[[
akkar.etag — the write that vanishes.

Two clients read the same record, both edit it, both save, and the second
overwrites the first with **no error anywhere**. Both saw 200. One person's
work is gone, found weeks later if ever, unreproducible.

The tests that carry the design are the refusals: 412 when the record moved,
428 when the client forgot to ask, and — the one that makes it an invariant
rather than a feature — the write must be refused BEFORE the handler runs.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local etag  = require "akkar.etag"

--- A document store, with a counter for how many times a write actually ran.
local function store_app(options)
  local doc = { id = 7, title = "first", version = 1 }
  local writes = 0

  local app = akkar.new()
  app:use(akkar.etag(setmetatable({ current = function() return doc end }, {
    __index = options or {},
  })))
  app:get("/doc", function() return doc end)
  app:put("/doc", function(req)
    writes = writes + 1
    doc = { id = 7, title = req.body.title, version = doc.version + 1 }
    return doc
  end)
  return app, function() return doc end, function() return writes end
end

describe("tagging a response", function()
  it("puts an ETag on a successful body", function()
    local app = store_app()
    local res = app:test():get "/doc"
    assert.equal(200, res.status)
    assert.is_truthy(res.headers["etag"])
    assert.is_truthy(res.headers["etag"]:match '^".+"$', "must be a quoted string")
  end)

  it("gives the same body the same tag, twice", function()
    -- `pairs()` has no defined order, so encoding a table twice can produce
    -- different bytes. A tag that varied would make every conditional request
    -- fail intermittently, on one process, for no visible reason.
    local body = { b = 2, a = 1, c = { z = 26, y = 25 }, list = { 3, 1, 2 } }
    assert.equal(etag.of(body), etag.of(body))

    local same_content_different_order = { c = { y = 25, z = 26 }, a = 1, list = { 3, 1, 2 }, b = 2 }
    assert.equal(etag.of(body), etag.of(same_content_different_order))
  end)

  it("gives different bodies different tags", function()
    assert.not_equal(etag.of { title = "a" }, etag.of { title = "b" })
    assert.not_equal(etag.of { n = 1 }, etag.of { n = 2 })
    -- Order matters inside an array, and must.
    assert.not_equal(etag.of { 1, 2, 3 }, etag.of { 3, 2, 1 })
  end)
end)

describe("refusing a stale write", function()
  it("answers 412 when the resource moved since the client read it", function()
    local app, doc, writes = store_app()
    local client = app:test()

    local read = client:get "/doc"
    local stale = read.headers["etag"]

    -- Somebody else writes first.
    client:put("/doc", { body = { title = "theirs" },
                         headers = { ["if-match"] = stale } })
    assert.equal(1, writes())

    -- Our write carries the tag we read, which is now out of date.
    local refused = client:put("/doc", { body = { title = "ours" },
                                         headers = { ["if-match"] = stale } })
    assert.equal(412, refused.status)
    assert.equal(1, writes(), "the refused write must not have run")
    assert.equal("theirs", doc().title)
  end)

  it("refuses BEFORE the handler runs, not after", function()
    -- Checking afterwards would mean the write happened and then we told the
    -- client it did not.
    local app, _, writes = store_app()
    local client = app:test()

    local res = client:put("/doc", { body = { title = "x" },
                                     headers = { ["if-match"] = '"never-was-a-tag"' } })
    assert.equal(412, res.status)
    assert.equal(0, writes())
  end)

  it("accepts the write when the tag is current", function()
    local app, doc, writes = store_app()
    local client = app:test()

    local read = client:get "/doc"
    local res = client:put("/doc", { body = { title = "updated" },
                                     headers = { ["if-match"] = read.headers["etag"] } })
    assert.equal(200, res.status)
    assert.equal(1, writes())
    assert.equal("updated", doc().title)
  end)

  it("accepts a list of tags, and the wildcard", function()
    local app = store_app()
    local client = app:test()
    local tag = client:get("/doc").headers["etag"]

    assert.equal(200, client:put("/doc", { body = { title = "a" },
      headers = { ["if-match"] = '"other", ' .. tag } }).status)

    assert.equal(200, client:put("/doc", { body = { title = "b" },
      headers = { ["if-match"] = "*" } }).status, "* means any current version")
  end)
end)

describe("the header a client forgot", function()
  it("answers 428 when the route demands a precondition", function()
    -- This is the line between a feature and an invariant. Without it, a
    -- client that simply forgets the header races silently and the whole
    -- mechanism is optional in practice.
    local app, _, writes = store_app { require_on = { "PUT" } }
    local res = app:test():put("/doc", { body = { title = "x" } })

    assert.equal(428, res.status)
    assert.equal(0, writes())
    assert.is_truthy(res.body.hint:find("etag", 1, true))
  end)

  it("lets the write through when no precondition is demanded", function()
    -- Switching this on for every existing client at once would break all of
    -- them, so demanding it is opt-in per method.
    local app, _, writes = store_app()
    assert.equal(200, app:test():put("/doc", { body = { title = "x" } }).status)
    assert.equal(1, writes())
  end)
end)

describe("the cheap half", function()
  it("answers 304 with no body when the client already has this version", function()
    local app = store_app()
    local client = app:test()

    local first = client:get "/doc"
    local again = client:get("/doc", { headers = { ["if-none-match"] = first.headers["etag"] } })

    assert.equal(304, again.status)
    assert.is_nil(again.body)
    assert.equal(first.headers["etag"], again.headers["etag"])
  end)

  it("sends the body when the client's version is stale", function()
    local app = store_app()
    local client = app:test()
    local res = client:get("/doc", { headers = { ["if-none-match"] = '"old"' } })
    assert.equal(200, res.status)
    assert.is_truthy(res.body)
  end)

  it("never turns a write into a 304", function()
    -- If-None-Match on a write means something entirely different (create
    -- only if absent), and answering 304 to a PUT would be nonsense.
    local app = store_app()
    local client = app:test()
    local tag = client:get("/doc").headers["etag"]
    local res = client:put("/doc", { body = { title = "x" },
                                     headers = { ["if-none-match"] = tag } })
    assert.equal(200, res.status)
  end)
end)

describe("a body whose keys are not all integers", function()
  -- `value[1] ~= nil` was read as "this is an array", so every other key was
  -- dropped from the tag while cjson sent all of them to the client. Two
  -- bodies differing only in `status` got one ETag: If-Match accepted a stale
  -- write, If-None-Match answered 304 for content that had changed.
  it("tags a mixed table by everything in it", function()
    local draft     = { [1] = "row", status = "draft",     owner = "alice" }
    local published = { [1] = "row", status = "PUBLISHED", owner = "mallory" }
    assert.not_equal(etag.canonical(draft), etag.canonical(published))
    assert.not_equal(etag.of(draft), etag.of(published))
  end)

  it("keeps a numeric key's value instead of writing it out as null", function()
    -- Sorting a list of tostring(k) and then indexing with it looked up the
    -- string "2" in a table holding the number 2.
    assert.equal([[{"2":"x","name":"y"}]], etag.canonical { [2] = "x", name = "y" })
    assert.not_equal(etag.of { [2] = "x", name = "y" },
                     etag.of { [2] = "z", name = "y" })
  end)

  it("still treats a real array as an array", function()
    assert.equal([=[["a","b"]]=], etag.canonical { "a", "b" })
    assert.equal("[]", etag.canonical {})
  end)
end)
