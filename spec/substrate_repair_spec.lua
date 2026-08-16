--[[
The two ways one header takes a lua-http server down, and the repair.

`docs/substrate/lua-http-wedge.md` recorded the first of these as "not
akkar's to fix". That was true of reporting it and false of surviving it:
lua-http is pure Lua, its last release is September 2024, and a server that
one request can stop is not something to ship while waiting for an upstream
that is not moving.

## What is asserted, and why it takes a subprocess

That the SERVER IS STILL THERE afterwards -- which is a claim about a process,
not about a response, so it can only be made from outside one. The server runs
in its own process (`spec/support/raw_client.lua`) and each case sends bytes,
then asks the server for something ordinary and requires an ordinary answer.

Both failure modes are checked, because they are different failures with
different symptoms and one repair:

  * `Content-Length: banana` leaves lua-http SPINNING inside `stream:shutdown`
    -- a loop that never yields, which starves the accept loop without ever
    stopping it. The port stays open and nothing is ever answered again.
  * `Content-Length: -5` RAISES out of the same call and, because
    `http/server.lua` invokes `shutdown` with no pcall, the error leaves the
    coroutine and ends `server:loop()`. The process exits and the port closes.

The last test starts a server with `repair_substrate = false` and requires it
to die, so that the three passing above are attributed to the repair rather
than to something else that happens to be true today.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local raw = require "spec.support.raw_client"

if not raw.available() then
  describe("substrate repair", function()
    pending "no Lua interpreter to spawn a server with; skipping"
  end)
  return
end

local function request(headers, payload)
  return "POST /users HTTP/1.1\r\nHost: localhost\r\n" .. headers ..
         "\r\n" .. (payload or "")
end

local WELL_FORMED =
  "GET /users HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"

describe("substrate repair", function()
  describe("with the repair in place, which is the default", function()
    local stop, port

    setup(function()
      stop, port = raw.start(8390)
      assert.is_truthy(stop, "the server did not start: " .. tostring(port))
    end)

    teardown(function() if stop then stop() end end)

    it("survives a Content-Length that is not a number", function()
      -- The spin. Unrepaired, everything after this line times out for ever.
      raw.send(port, request("Content-Length: banana\r\n", "x"), 2)

      local outcome = raw.send(port, WELL_FORMED, 3)
      assert.is_truthy(outcome:find("status=", 1, true),
        "the server stopped answering after one malformed header; got " ..
        tostring(outcome))
    end)

    it("survives a negative Content-Length", function()
      -- The raise. Unrepaired, the process is gone by the next request.
      raw.send(port, request("Content-Length: -5\r\n", "x"), 2)

      local outcome = raw.send(port, WELL_FORMED, 3)
      assert.is_truthy(outcome:find("status=", 1, true),
        "the server exited after a negative Content-Length; got " ..
        tostring(outcome))
    end)

    it("still answers correctly afterwards, not merely audibly", function()
      -- Surviving is not enough: a server that answers every request with a
      -- 500 has also survived. The route has to still work.
      local outcome = raw.send(port, WELL_FORMED, 3)
      assert.equal("status=200", outcome)
    end)

    it("blames the client for the client's header", function()
      -- akkar answers 400 rather than the 503 lua-http produces on its own.
      -- A malformed length is the caller's mistake, and 5xx would be akkar
      -- reporting its own unavailability for it.
      local outcome = raw.send(port, request("Content-Length: -5\r\n", "x"), 3)
      assert.is_falsy(outcome:find("status=5", 1, true),
        "a malformed request was answered 5xx: " .. tostring(outcome))
    end)
  end)

  describe("without the repair", function()
    it("is exactly what the repair is preventing", function()
      -- The control. Without it, the four tests above prove only that the
      -- server survives today, not that this module is why.
      local stop, port = raw.start(8420, "repair_substrate = false,")
      assert.is_truthy(stop, "the server did not start: " .. tostring(port))

      local ok_before = raw.send(port, WELL_FORMED, 3)
      assert.equal("status=200", ok_before, "the control server was not healthy")

      raw.send(port, request("Content-Length: banana\r\n", "x"), 2)

      local after = raw.send(port, WELL_FORMED, 3)
      assert.is_falsy(after:find("status=", 1, true),
        "the unrepaired server answered, so this spec is no longer testing " ..
        "anything -- check whether lua-http has fixed it upstream, and if it " ..
        "has, retire akkar.substrate rather than editing this line")

      stop()
    end)
  end)
end)
