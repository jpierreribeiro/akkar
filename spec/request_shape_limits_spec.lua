-- Request-shape ceilings are enforced by the protocol/parser path, not only
-- documented as application advice.

package.path = "./?.lua;./?/init.lua;" .. package.path

local raw = require "spec.support.raw_client"

describe("request shape limits", function()
  local stop, port

  setup(function()
    if not raw.available() then pending "no Lua interpreter for raw server" end
    stop, port = assert(raw.start(8670,
      "header_limit = 64, header_count_limit = 10, json_depth_limit = 4,"))
  end)

  teardown(function() if stop then stop() end end)

  it("refuses aggregate HTTP/1 header bytes and keeps serving", function()
    local attack = "GET /users HTTP/1.1\r\nHost: localhost\r\nX-Large: " ..
                   string.rep("a", 80) .. "\r\n\r\n"
    local outcome = raw.send(port, attack)
    assert.is_true(outcome == "status=400" or outcome == "closed", outcome)
    assert.equal("status=200", raw.send(port,
      "GET /users HTTP/1.1\r\nHost: x\r\n\r\n"))
  end)

  it("charges optional whitespace before it is trimmed", function()
    local attack = "GET /users HTTP/1.1\r\nHost: x\r\nX-Pad:" ..
                   string.rep(" ", 80) .. "ok\r\n\r\n"
    local outcome = raw.send(port, attack)
    assert.is_true(outcome == "status=400" or outcome == "closed", outcome)
    assert.equal("status=200", raw.send(port,
      "GET /users HTTP/1.1\r\nHost: x\r\n\r\n"))
  end)

  it("refuses JSON beyond the configured nesting depth", function()
    local payload = '{"name":' .. string.rep("[", 5) .. '"ada"' ..
                    string.rep("]", 5) .. "}"
    local request = "POST /users HTTP/1.1\r\nHost: x\r\n" ..
                    "Content-Type: application/json\r\nContent-Length: " ..
                    #payload .. "\r\n\r\n" .. payload
    assert.equal("status=400", raw.send(port, request))
    assert.equal("status=200", raw.send(port,
      "GET /users HTTP/1.1\r\nHost: x\r\n\r\n"))
  end)
end)
