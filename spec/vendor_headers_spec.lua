--[[
The vendored header structure, tested directly rather than through a server.

`akkar/vendor/http/headers.lua` now stores its name index in TWO shapes: a
plain integer while a header name has appeared once, and the original
`{n=k, ...}` table once it repeats. That is the optimisation -- the
overwhelming majority of header names occur exactly once, and each of them
used to cost a table with one array slot and one hash key, per request.

It is also a semantic hazard. Four readers have to understand both shapes, and
the one that gets it wrong will not fail loudly: it will drop a `set-cookie`,
or return the first of two `via` headers, on requests nobody sends in a test
that goes through a server. The server-level suite exercises the shapes it
happens to produce; this file exercises the shapes deliberately.

Every case below is written so that it would FAIL against a reader that
handles only one of the two shapes.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local headers = require "akkar.vendor.http.headers"

describe("the header index, in both of its shapes", function()
  it("reads a name that appears once", function()
    local h = headers.new()
    h:append("host", "example.com")
    assert.equal("example.com", h:get "host")
    assert.is_true(h:has "host")
    assert.equal(1, h:len())
  end)

  it("reads every value of a name that repeats", function()
    -- `set-cookie` is the reason this structure is a list of entries rather
    -- than a map, and it is the case the integer shape must hand back.
    local h = headers.new()
    h:append("set-cookie", "a=1")
    h:append("set-cookie", "b=2")
    h:append("set-cookie", "c=3")

    local got = { h:get "set-cookie" }
    assert.same({ "a=1", "b=2", "c=3" }, got)

    local seq = h:get_as_sequence "set-cookie"
    assert.equal(3, seq.n)
    assert.same({ "a=1", "b=2", "c=3" }, { seq[1], seq[2], seq[3] })
  end)

  it("promotes on the SECOND occurrence, not the third", function()
    -- The off-by-one that would look right in every one-header test: build
    -- the table on the second append but forget to carry the first index
    -- into it, and the first value silently disappears.
    local h = headers.new()
    h:append("via", "1.1 alpha")
    h:append("via", "1.1 beta")
    assert.same({ "1.1 alpha", "1.1 beta" }, { h:get "via" })
  end)

  it("answers nil for a name it does not hold", function()
    local h = headers.new()
    h:append("host", "example.com")
    assert.is_nil(h:get "accept")
    assert.is_false(h:has "accept")
    assert.equal(0, h:get_as_sequence("accept").n)
    assert.is_nil(h:get_comma_separated "accept")
  end)

  it("joins with commas in both shapes", function()
    local one = headers.new()
    one:append("accept", "text/plain")
    assert.equal("text/plain", one:get_comma_separated "accept")

    local many = headers.new()
    many:append("accept", "text/plain")
    many:append("accept", "application/json")
    assert.equal("text/plain,application/json",
      many:get_comma_separated "accept")
  end)

  it("upserts a name held as an integer", function()
    local h = headers.new()
    h:append("content-type", "text/plain")
    h:upsert("content-type", "application/json")
    assert.equal("application/json", h:get "content-type")
    assert.equal(1, h:len(), "upsert appended instead of replacing")
  end)

  it("upserts a name that is not there yet", function()
    local h = headers.new()
    h:upsert("content-type", "application/json")
    assert.equal("application/json", h:get "content-type")
    assert.equal(1, h:len())
  end)

  it("refuses to upsert a name that repeats", function()
    local h = headers.new()
    h:append("set-cookie", "a=1")
    h:append("set-cookie", "b=2")
    assert.is_false(pcall(function() h:upsert("set-cookie", "c=3") end))
  end)

  it("deletes a name held as an integer, leaving the rest addressable", function()
    -- Deleting shifts every later entry down by one, so the index must be
    -- rebuilt. A reader that handled the integer shape but skipped the
    -- rebuild would leave `date` pointing at the wrong row -- and still
    -- return a string, which is why this asserts the VALUE.
    local h = headers.new()
    h:append("host", "example.com")
    h:append("accept", "text/plain")
    h:append("date", "Mon, 17 Aug 2026 00:00:00 GMT")

    assert.is_true(h:delete "accept")
    assert.equal(2, h:len())
    assert.is_false(h:has "accept")
    assert.equal("example.com", h:get "host")
    assert.equal("Mon, 17 Aug 2026 00:00:00 GMT", h:get "date")
  end)

  it("deletes every occurrence of a name that repeats", function()
    local h = headers.new()
    h:append("host", "example.com")
    h:append("set-cookie", "a=1")
    h:append("set-cookie", "b=2")

    assert.is_true(h:delete "set-cookie")
    assert.equal(1, h:len())
    assert.is_false(h:has "set-cookie")
    assert.equal("example.com", h:get "host")
  end)

  it("says false when there was nothing to delete", function()
    assert.is_false(headers.new():delete "accept")
  end)

  it("clones both shapes independently of the original", function()
    local h = headers.new()
    h:append("host", "example.com")
    h:append("set-cookie", "a=1")
    h:append("set-cookie", "b=2")

    local copy = h:clone()
    copy:upsert("host", "elsewhere.test")

    assert.equal("example.com", h:get "host", "the clone shares the original's entries")
    assert.equal("elsewhere.test", copy:get "host")
    assert.same({ "a=1", "b=2" }, { copy:get "set-cookie" })
  end)

  it("keeps the index right after a sort", function()
    -- `sort` reorders `_data` and rebuilds the index from scratch, which is
    -- the other path that has to produce the two shapes correctly.
    local h = headers.new()
    h:append("zeta", "1")
    h:append("alpha", "2")
    h:append("zeta", "3")

    h:sort()
    assert.equal("2", h:get "alpha")
    assert.same({ "1", "3" }, { h:get "zeta" })
  end)

  it("still walks every entry in order", function()
    local h = headers.new()
    h:append("host", "example.com")
    h:append("set-cookie", "a=1")
    h:append("set-cookie", "b=2")

    local seen = {}
    for name, value in h:each() do seen[#seen + 1] = name .. "=" .. value end
    assert.same({ "host=example.com", "set-cookie=a=1", "set-cookie=b=2" }, seen)
  end)
end)
