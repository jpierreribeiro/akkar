--[[
RESP2 desync: one malformed header, and request A's reply is returned to
request B.

RESP has no request ids -- replies are matched to commands by order alone -- so
a reply that is never consumed is not lost, it is handed to whoever uses the
connection next. `read_reply` treated an unparseable `$` header as a nil reply:
the call returned successfully, `broken` was never set, `in_flight` was cleared,
the payload stayed in the socket, and the reuse predicate then saw a healthy
connection and pooled it.

    1st command: value=nil            (reads as a cache miss)
    2nd command: value=USER-A-SECRET  (request A's reply)

The same shape from the other end: `sock:read(length + 2)` was trusted to
deliver exactly that many bytes, so an EOF-truncated reply came back as a
complete value -- an `INCR` for `limit.rate` reading 4 instead of 42, and a rate
limit that silently does not fire.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local redis = require "akkar.redis"

-- A socket serving canned bytes, and running out of them at the end rather
-- than inventing more -- which is what a truncated reply looks like.
local function feeding(payload)
  local offset = 1
  return {
    read = function(_, spec)
      if spec == "*L" then
        local stop = payload:find("\n", offset, true)
        if not stop then return nil end
        local line = payload:sub(offset, stop)
        offset = stop + 1
        return line
      end
      local chunk = payload:sub(offset, offset + spec - 1)
      offset = offset + spec
      if chunk == "" then return nil end
      return chunk
    end,
    write = function() return true end,
  }
end

describe("a bulk header that does not parse", function()
  local read_reply = redis.Redis._read_reply

  it("is a protocol failure, not a nil reply", function()
    local value, err = read_reply(feeding "$xx\r\n$13\r\nUSER-A-SECRET\r\n")
    assert.is_nil(value)
    assert.is_truthy(tostring(err):match "malformed bulk length")
  end)

  it("breaks the connection instead of leaving the reply in the socket", function()
    local conn = setmetatable({ sock = feeding "$xx\r\n$13\r\nUSER-A-SECRET\r\n" },
                              redis.Redis)

    local ok = pcall(function() return conn:command("GET", "a") end)
    assert.is_false(ok, "the malformed reply was returned as a cache miss")
    assert.is_true(conn.broken)

    -- And that is what keeps it out of the pool: the reuse predicate
    -- `akkar.redis` installs is exactly `not broken and not in_flight and sock`.
    local fit = not conn.broken and not conn.in_flight and conn.sock ~= nil
    assert.is_false(fit, "the desynced connection was judged fit for reuse")
  end)

  it("still reads $-1 as a nil reply", function()
    assert.is_nil(read_reply(feeding "$-1\r\n"))
    assert.is_nil(read_reply(feeding "*-1\r\n"))
  end)

  it("refuses a malformed array header for the same reason", function()
    local value, err = read_reply(feeding "*what\r\n")
    assert.is_nil(value)
    assert.is_truthy(tostring(err):match "malformed array length")
  end)
end)

describe("a bulk reply the socket could not finish", function()
  local read_reply = redis.Redis._read_reply

  it("is reported rather than returned as a complete value", function()
    -- The wire carried `42`, EOF arrived after `4`.
    local value, err = read_reply(feeding "$2\r\n4")
    assert.is_nil(value, "a truncated reply was returned as the whole value")
    assert.is_truthy(tostring(err):match "truncated bulk reply")
  end)

  it("is reported when the trailing CRLF is not where the length says", function()
    -- If the terminator is not there, the length was not the length, and
    -- everything after it is misaligned.
    local value, err = read_reply(feeding "$2\r\n4200\r\n")
    assert.is_nil(value)
    assert.is_truthy(tostring(err):match "truncated bulk reply")
  end)

  it("leaves an honest reply alone", function()
    assert.equal("hello", read_reply(feeding "$5\r\nhello\r\n"))
    assert.equal("", read_reply(feeding "$0\r\n\r\n"))
    assert.equal("a\r\nb", read_reply(feeding "$4\r\na\r\nb\r\n"))
  end)
end)
