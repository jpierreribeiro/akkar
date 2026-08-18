--[[
The read-ahead chunk queue on a vendored h1 stream.

`chunk_fifo` is built lazily now -- `queue_chunk` creates it on the first
chunk that is actually read ahead, because a GET with no body never queues
one and that is most of what this runtime serves. Measured: a fifo is 265
bytes, and the whole stream object is 962.

THE PATHS THAT CREATE IT ARE THE ONES NOTHING ELSE TESTS. `step` queues a
chunk when a body arrives ahead of the reader, and `stream_common`'s
`get_body_chars` and `get_body_until` call `unget` to hand back the surplus
after reading past what they wanted. Neither is on akkar's own request path --
akkar asks for the whole body -- so the suite would have stayed green with
`chunk_fifo` nil and a `nil value` waiting for the first application that
streams a request body.

These drive the vendored client against the vendored server, which is the
only way to reach those methods from a test.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local request = require "akkar.vendor.http.request"
local server  = require "akkar.vendor.http.server"
local headers = require "akkar.vendor.http.headers"

--- Runs `body(port)` against a server that answers `payload` on every request.
local function with_server(payload, body)
  local port = 8200 + math.random(0, 900)
  local err

  local s = assert(server.listen {
    host = "127.0.0.1", port = port,
    onstream = function(_, stream)
      local ok, why = pcall(function()
        assert(stream:get_headers())
        local h = headers.new()
        h:append(":status", "200")
        h:append("content-type", "text/plain")
        h:append("content-length", tostring(#payload))
        assert(stream:write_headers(h, false))
        assert(stream:write_chunk(payload, true))
      end)
      if not ok then err = err or why end
      stream:shutdown()
    end,
  })
  assert(s:listen(5))

  local cq = cqueues.new()
  cq:wrap(function()
    local ok, why = pcall(s.loop, s)
    if not ok and not tostring(why):find("closed", 1, true) then
      err = err or why
    end
  end)
  cq:wrap(function()
    local ok, why = pcall(body, port)
    s:close()
    if not ok then err = err or why end
  end)
  assert(cq:loop(30))
  if err then error(err, 0) end
end

--- A response stream, opened against the server above.
local function response_stream(port)
  local req = request.new_from_uri(("http://127.0.0.1:%d/"):format(port))
  -- `go` answers HEADERS FIRST and the stream second. Taking one return value
  -- gets the headers object, which has no `get_headers` -- an error that reads
  -- like the stream is broken.
  local response_headers, stream = req:go(10)
  assert(response_headers, tostring(stream))
  assert.equal("200", response_headers:get ":status")
  return stream
end

describe("the stream's read-ahead queue", function()
  it("hands back the whole body when nothing is read ahead", function()
    -- The baseline: `chunk_fifo` is never created on this path, and the body
    -- still arrives whole. If laziness broke the ordinary case, this is the
    -- case it breaks.
    local payload = string.rep("abcdefghij", 100)
    with_server(payload, function(port)
      local stream = response_stream(port)
      assert.equal(payload, assert(stream:get_body_as_string(10)))
      stream:shutdown()
    end)
  end)

  it("ungets the surplus after a short read, and reads it back in order", function()
    -- `get_body_chars` reads whole chunks and then puts back whatever it did
    -- not want. That `unget` is the first thing to touch `chunk_fifo` on this
    -- path, so before it the field is nil -- and afterwards the SAME bytes
    -- must come back, in the same order.
    local payload = string.rep("0123456789", 200)   -- 2,000 bytes
    with_server(payload, function(port)
      local stream = response_stream(port)

      local head = assert(stream:get_body_chars(10, 10))
      assert.equal(10, #head)
      assert.equal(payload:sub(1, 10), head)

      local rest = assert(stream:get_body_as_string(10))
      assert.equal(payload:sub(11), rest,
        "the ungot surplus did not come back whole")
      stream:shutdown()
    end)
  end)

  it("ungets twice in a row without losing the middle", function()
    -- Two successive short reads means `unget` runs against a queue that
    -- already exists, which is the branch the first case cannot reach.
    local payload = string.rep("abcdefghij", 200)
    with_server(payload, function(port)
      local stream = response_stream(port)
      local a = assert(stream:get_body_chars(5, 10))
      local b = assert(stream:get_body_chars(5, 10))
      local rest = assert(stream:get_body_as_string(10))
      assert.equal(payload:sub(1, 5), a)
      assert.equal(payload:sub(6, 10), b)
      assert.equal(payload:sub(11), rest)
      stream:shutdown()
    end)
  end)

  it("reads up to a pattern and keeps what follows it", function()
    -- `get_body_until` is the other `unget` caller, and it puts back
    -- everything after the match.
    with_server("first line\nsecond line\nthird", function(port)
      local stream = response_stream(port)
      assert.equal("first line", assert(stream:get_body_until("\n", true, false, 10)))
      assert.equal("second line\nthird", assert(stream:get_body_as_string(10)))
      stream:shutdown()
    end)
  end)
end)
