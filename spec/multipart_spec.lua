--[[
multipart/form-data parsing.

The tests build wire bytes by hand rather than through a client, because what
is under test is the framing: a browser's boundary is chosen by the browser
and may contain characters Lua patterns treat as magic, and a file's contents
may contain the boundary's own text.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local multipart = require "akkar.multipart"
local akkar = require "akkar"

local function wire(boundary, parts)
  local out = {}
  for _, part in ipairs(parts) do
    out[#out + 1] = "--" .. boundary .. "\r\n"
    out[#out + 1] = part.disposition .. "\r\n"
    if part.type then out[#out + 1] = "Content-Type: " .. part.type .. "\r\n" end
    out[#out + 1] = "\r\n" .. part.body .. "\r\n"
  end
  out[#out + 1] = "--" .. boundary .. "--\r\n"
  return table.concat(out)
end

describe("multipart boundary extraction", function()
  it("reads an unquoted boundary", function()
    assert.equal("----abc123",
      multipart.boundary "multipart/form-data; boundary=----abc123")
  end)

  it("reads a quoted boundary", function()
    -- RFC 2046 allows quoting and browsers differ on whether they use it.
    assert.equal("a b c",
      multipart.boundary 'multipart/form-data; boundary="a b c"')
  end)

  it("returns nil when there is none", function()
    assert.is_nil(multipart.boundary "multipart/form-data")
  end)
end)

describe("multipart parsing", function()
  it("reads a plain form field", function()
    local body = wire("X", {
      { disposition = 'Content-Disposition: form-data; name="title"', body = "hello" },
    })
    local fields = multipart.parse(body, "X")
    assert.equal("hello", fields.title)
  end)

  it("reads a file part with its filename and type", function()
    local body = wire("X", {
      { disposition = 'Content-Disposition: form-data; name="avatar"; filename="cat.png"',
        type = "image/png", body = "\137PNG\r\n\026\n binary" },
    })
    local fields = multipart.parse(body, "X")
    assert.equal("cat.png", fields.avatar.filename)
    assert.equal("image/png", fields.avatar.content_type)
    assert.equal("\137PNG\r\n\026\n binary", fields.avatar.data)
    assert.equal(#"\137PNG\r\n\026\n binary", fields.avatar.size)
  end)

  it("reads several parts at once", function()
    local body = wire("X", {
      { disposition = 'Content-Disposition: form-data; name="title"', body = "a report" },
      { disposition = 'Content-Disposition: form-data; name="file"; filename="r.csv"',
        type = "text/csv", body = "a,b\n1,2" },
    })
    local fields = multipart.parse(body, "X")
    assert.equal("a report", fields.title)
    assert.equal("r.csv", fields.file.filename)
  end)

  it("survives a boundary containing pattern magic characters", function()
    -- Browsers really do produce boundaries with these in them.
    local boundary = "----Web+Kit(Form).Boundary-%d*"
    local body = wire(boundary, {
      { disposition = 'Content-Disposition: form-data; name="x"', body = "ok" },
    })
    assert.equal("ok", multipart.parse(body, boundary).x)
  end)

  it("keeps content that contains CRLF", function()
    local body = wire("X", {
      { disposition = 'Content-Disposition: form-data; name="notes"',
        body = "line one\r\nline two" },
    })
    assert.equal("line one\r\nline two", multipart.parse(body, "X").notes)
  end)

  it("keeps an empty field rather than dropping it", function()
    local body = wire("X", {
      { disposition = 'Content-Disposition: form-data; name="empty"', body = "" },
    })
    assert.equal("", multipart.parse(body, "X").empty)
  end)

  it("reports a missing boundary instead of guessing", function()
    local fields, err = multipart.parse("whatever", nil)
    assert.is_nil(fields)
    assert.is_truthy(tostring(err):match "no boundary")
  end)

  it("reports a body that is not terminated", function()
    local truncated = "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nvalue"
    local fields, err = multipart.parse(truncated, "X")
    assert.is_nil(fields)
    assert.is_truthy(tostring(err):match "not terminated")
  end)
end)

describe("multipart through a request", function()
  it("reaches the handler as an ordinary table, validated like any other", function()
    local app = akkar.new()
    app:post("/upload", {
      body = { title = "string", avatar = "table" },
    }, function(req)
      return {
        title = req.body.title,
        filename = req.body.avatar.filename,
        bytes = req.body.avatar.size,
      }
    end)

    -- Handlers and schemas do not learn a new shape for multipart.
    local res = app:test():post("/upload", {
      body = {
        title = "my cat",
        avatar = { filename = "cat.png", content_type = "image/png",
                   data = "bytes", size = 5 },
      },
    })
    assert.equal(200, res.status)
    assert.equal("cat.png", res.body.filename)
    assert.equal(5, res.body.bytes)
  end)
end)
