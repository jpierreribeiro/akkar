--[[
Framing — the bytes an attacker reaches for first.

`spec/fuzz_spec.lua` goes through lua-http's client, so every request it sends
is well-framed by construction. A lying `Content-Length`, a duplicated one, a
bad chunk size, a body that never terminates, a missing `Host` -- none of them
can be expressed there, and the file says so rather than leaving the gap for
somebody to assume was covered.

This is that gap, closed. The SERVER runs in another process
(`spec/support/raw_client.lua`), because the version that shared a scheduler
with the client deadlocked on exactly the inputs it existed to send.

## What is asserted

Not a status code per case: a server may legitimately close a connection on a
request line it will not parse, and `spec/substrate_spec.lua` already pins
that lua-http does exactly that past a certain size. What must hold for every
input, whatever it is:

  * the server survives, and answers the next well-formed request;
  * nothing HANGS -- an answer or a close, never silence;
  * a malformed CLIENT input is never answered 5xx, which would be akkar
    blaming itself for the caller's mistake;
  * and a body that continues into something shaped like a second request
    line is not routed as one.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local raw = require "spec.support.raw_client"

if not raw.available() then
  describe("framing", function()
    pending "no Lua interpreter to spawn a server with; skipping"
  end)
  return
end

local PORT = 8374
local BODY = '{"name":"ada"}'

local function post(headers, payload)
  return "POST /users HTTP/1.1\r\nHost: localhost\r\n" .. headers ..
         "\r\n" .. (payload or "")
end

local function corpus()
  return {
    { "a body with no content-length",
      post("Content-Type: application/json\r\n", BODY) , "wait" },
    { "content-length shorter than the body",
      post("Content-Type: application/json\r\nContent-Length: 4\r\n", BODY) },
    { "content-length longer than the body",
      post("Content-Type: application/json\r\nContent-Length: 900\r\n", BODY) , "wait" },
    { "content-length that is not a number",
      post("Content-Type: application/json\r\nContent-Length: banana\r\n", BODY) },
    { "a negative content-length",
      post("Content-Type: application/json\r\nContent-Length: -5\r\n", BODY) },
    { "two content-lengths that disagree",
      post("Content-Type: application/json\r\nContent-Length: 14\r\n" ..
           "Content-Length: 99\r\n", BODY) },
    { "content-length AND chunked",
      post("Content-Type: application/json\r\nContent-Length: 14\r\n" ..
           "Transfer-Encoding: chunked\r\n", BODY) },
    { "a chunk size that is not hex",
      post("Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n",
           "zz\r\n" .. BODY .. "\r\n0\r\n\r\n") },
    { "a chunked body that never terminates",
      post("Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n",
           ("%x\r\n%s\r\n"):format(#BODY, BODY)), "wait" },
    { "a chunk longer than it declares",
      post("Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n",
           "2\r\n" .. BODY .. "\r\n0\r\n\r\n") },
    { "no Host header at all",
      "GET /users HTTP/1.1\r\n\r\n" },
    { "two Host headers",
      "GET /users HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n" },
    { "a header with no colon",
      "GET /users HTTP/1.1\r\nHost: localhost\r\nBroken\r\n\r\n" },
    { "a header line ended with LF alone",
      "GET /users HTTP/1.1\nHost: localhost\n\n" },
    { "an absent HTTP version",
      "GET /users\r\nHost: localhost\r\n\r\n" , "wait" },
    { "a version that does not exist",
      "GET /users HTTP/9.9\r\nHost: localhost\r\n\r\n" },
    { "a request line with no path",
      "GET HTTP/1.1\r\nHost: localhost\r\n\r\n" },
    { "leading whitespace before the method",
      "   GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n" },
    { "a null byte in the request line",
      "GET /users\0/x HTTP/1.1\r\nHost: localhost\r\n\r\n" },
    { "headers that never end",
      "GET /users HTTP/1.1\r\nHost: localhost\r\nX-A: 1\r\n" , "wait" },
    { "nothing but a newline",
      "\r\n" , "wait" },
    { "a body pretending to be a second request",
      post("Content-Type: application/json\r\nContent-Length: 14\r\n",
           BODY .. "GET /admin HTTP/1.1\r\nHost: localhost\r\n\r\n") },
  }
end

describe("framing", function()
  local results = {}

  setup(function()
    -- A FRESH SERVER PER CASE, and the reason is the finding this file made:
    -- `Content-Length: banana` stops lua-http accepting connections for ever
    -- (`docs/substrate/lua-http-wedge.md`). A single server would die on the
    -- fourth input and every later verdict would be about a corpse.
    --
    -- One process per case is slow and it is the only honest way to ask
    -- twenty-two independent questions of a server that one of them kills.
    for i, case in ipairs(corpus()) do
      local stop, port = raw.start(8300 + i * 3)
      local why = port
      if not stop then
        results[#results + 1] = { label = case[1], outcome = "server-failed",
                                  waiting = case[3] == "wait", why = why }
      else
        local waiting = case[3] == "wait"
        local outcome = raw.send(port, case[2], waiting and 1 or 2)
        -- Does the server still answer afterwards? That is the property the
        -- corpus is really testing.
        local after = raw.send(port, "GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n", 2)
        results[#results + 1] = { label = case[1], outcome = outcome,
                                  waiting = waiting, after = after }
        stop()
      end
    end
  end)

  it("started a server for every case", function()
    local failed = {}
    for _, result in ipairs(results) do
      if result.outcome == "server-failed" then
        failed[#failed + 1] = result.label .. ": " .. tostring(result.why):sub(1, 60)
      end
    end
    assert.equal(0, #failed, table.concat(failed, "; "))
  end)

  it("answers or closes anything that is a complete request", function()
    -- A close is a legitimate reply to something the server will not parse;
    -- silence is not. Cases tagged `wait` are excluded because a request
    -- whose headers never end is one the server is CORRECT to sit on --
    -- treating that as a hang would make the test demand a bug.
    local hung = {}
    for _, result in ipairs(results) do
      if not result.waiting and result.outcome == "timeout" then
        hung[#hung + 1] = result.label
      end
    end
    assert.equal(0, #hung, "no answer and no close for: " .. table.concat(hung, ", "))
  end)

  it("never blames itself for the caller's mistake", function()
    local blamed = {}
    for _, result in ipairs(results) do
      local status = tonumber(result.outcome:match "status=(%d+)")
      if status and status >= 500 then
        blamed[#blamed + 1] = result.label .. " -> " .. status
      end
    end
    assert.equal(0, #blamed, "answered 5xx: " .. table.concat(blamed, ", "))
  end)

  it("answers 400 to a content-length it cannot use", function()
    -- What akkar owns, as opposed to what lua-http does to itself afterwards.
    for _, result in ipairs(results) do
      if result.label:find("not a number", 1, true)
      or result.label:find("negative", 1, true) then
        assert.equal("status=400", result.outcome,
          result.label .. " was answered " .. result.outcome)
      end
    end
  end)

  -- `in_flight` is NOT asserted here, and the omission is deliberate: the
  -- server runs in another process, so this one cannot read its counter.
  -- `spec/fuzz_spec.lua` checks it in-process against a well-framed corpus;
  -- what this file can prove is that the server keeps answering, which is
  -- the observable consequence of the same property.

  it("STILL dies on a malformed content-length, which is lua-http's bug", function()
    -- Pinned as currently TRUE, not as acceptable. `Content-Length: banana`
    -- and `Content-Length: -5` stop the server accepting connections for
    -- ever: the process lives, the listening socket stays open, and `ss`
    -- shows connections piling up unaccepted, so a port check calls it
    -- healthy. Reproduced in `docs/substrate/lua-http-wedge.lua` with
    -- twenty-five lines containing no akkar, which is how it was attributed.
    --
    -- akkar answers 400 for both now, rather than the 503 that blamed the
    -- server for a header the client typed. It cannot prevent the wedge: the
    -- failure is above anything a handler reaches.
    --
    -- THIS TEST FAILS WHEN UPSTREAM FIXES IT, which is the point. The day it
    -- goes red is the day `docs/substrate/lua-http-wedge.md` gets retracted
    -- and this file can stop starting one server per case.
    local wedged = 0
    for _, result in ipairs(results) do
      local malformed = result.label:find("not a number", 1, true)
                     or result.label:find("negative", 1, true)
      if malformed and result.after ~= "status=200" then wedged = wedged + 1 end
    end
    assert.is_true(wedged > 0,
      "lua-http no longer wedges on a malformed content-length -- retract " ..
      "docs/substrate/lua-http-wedge.md and simplify this spec")
  end)

  it("did not smuggle a second request past the router", function()
    -- Request smuggling, in its simplest form: a body that continues into
    -- something that looks like another request line. `/admin` does not
    -- exist, so a 404 would prove it was routed -- and the case must not
    -- produce one.
    for _, result in ipairs(results) do
      if result.label == "a body pretending to be a second request" then
        assert.is_not.equal("status=404", result.outcome,
          "the trailing bytes were parsed as a second request")
      end
    end
  end)

  it("actually reached the server", function()
    local reached = 0
    for _, result in ipairs(results) do
      if result.outcome:find "status=" then reached = reached + 1 end
    end
    assert.is_true(reached > 5,
      "only " .. reached .. " inputs got a status; the harness is not reaching akkar")
  end)
end)
