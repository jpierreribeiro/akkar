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

-- ONE NAME, DEFINED ONCE. The smuggling assertion below selects its case by
-- label, and the label used to be a string literal duplicated between the
-- corpus and the check: renaming the corpus entry -- an edit nobody would
-- think twice about -- left the loop matching nothing and the suite's only
-- request-smuggling assertion silently not running.
local SMUGGLE = "a body pretending to be a second request"

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
    { SMUGGLE,
      post("Content-Type: application/json\r\nContent-Length: 14\r\n",
           BODY .. "GET /admin HTTP/1.1\r\nHost: localhost\r\n\r\n") },
  }
end

describe("framing", function()
  local results = {}

  setup(function()
    -- ONE SERVER FOR THE WHOLE CORPUS, restarted only when a case kills it.
    --
    -- It used to be a fresh process per case, and the reason was the finding
    -- this file made: `Content-Length: banana` stopped lua-http accepting
    -- connections for ever, so a single server died on the fourth input and
    -- every later verdict was about a corpse. That cost twenty-two process
    -- starts and about ten minutes a run.
    --
    -- akkar's vendored `h1_stream` repairs the wedge, so the corpus can share
    -- a server
    -- -- and sharing one is a STRONGER test, not merely a faster one. Each
    -- case now runs against a server that has already survived every case
    -- before it, which is the property a corpus of hostile inputs should be
    -- asserting and could not while one input was fatal.
    --
    -- The restart is kept for attribution rather than for survival. If some
    -- future input does kill the server, `killed_the_server` names the exact
    -- case instead of leaving every later result to be read as a consequence.
    local stop, port = raw.start(8300)
    local probe = "GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n"

    for _, case in ipairs(corpus()) do
      if not stop then
        stop, port = raw.start(8300)
      end

      if not stop then
        results[#results + 1] = { label = case[1], outcome = "server-failed",
                                  waiting = case[3] == "wait", why = port }
      else
        local waiting = case[3] == "wait"
        local outcome = raw.send(port, case[2], waiting and 1 or 2)
        -- Does the server still answer afterwards? That is the property the
        -- corpus is really testing.
        local after = raw.send(port, probe, 2)
        results[#results + 1] = { label = case[1], outcome = outcome,
                                  waiting = waiting, after = after,
                                  killed_the_server = after ~= "status=200" }
        if after ~= "status=200" then
          -- Dead or wedged: retire this one and let the next case start a
          -- fresh process, so one fatal input does not silently condemn the
          -- twenty that follow it.
          stop()
          stop, port = nil, nil
        end
      end
    end

    if stop then stop() end
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

  it("survives a malformed content-length, which it did not used to", function()
    -- THE SENTINEL FIRED, AND THIS IS ITS REPLACEMENT.
    --
    -- What stood here asserted the opposite: that `Content-Length: banana`
    -- and `Content-Length: -5` still took the server down, pinned as
    -- currently TRUE rather than as acceptable. Its message said the day it
    -- went red was the day to retract `docs/substrate/lua-http-wedge.md`.
    --
    -- It went red because AKKAR fixed it, not upstream -- in the drain loop
    -- of `akkar/vendor/http/h1_stream.lua`, with the measurements and the two
    -- corrections the old writeup needed, all recorded on that page.
    -- The assertion is therefore inverted rather than deleted: the property
    -- worth pinning was never "lua-http is broken", it was "we know exactly
    -- what this input does", and now what it does is survive.
    --
    -- `spec/substrate_repair_spec.lua` proves the repair is the reason, by
    -- starting a server without it and requiring that one to die. This test
    -- covers the same ground through the full framing corpus, where the
    -- malformed lengths sit alongside every other hostile input.
    local wedged = {}
    for _, result in ipairs(results) do
      local malformed = result.label:find("not a number", 1, true)
                     or result.label:find("negative", 1, true)
      if malformed and result.after ~= "status=200" then
        wedged[#wedged + 1] = result.label .. " -> " .. tostring(result.after)
      end
    end
    assert.equal(0, #wedged,
      "a malformed content-length still stops the server answering: " ..
      table.concat(wedged, "; "))
  end)

  it("did not smuggle a second request past the router", function()
    -- Request smuggling, in its simplest form: a body that continues into
    -- something that looks like another request line. `/admin` does not
    -- exist, so a 404 would prove it was routed -- and the case must not
    -- produce one.
    --
    -- TWO THINGS THIS USED TO GET WRONG, both of which made the suite's only
    -- smuggling assertion unable to fail:
    --
    --   * the case was selected by a string literal duplicated from the
    --     corpus, so a rename left the loop matching nothing and zero
    --     assertions running. `SMUGGLE` is now one name used in both places.
    --   * a harness failure sets `outcome = "server-failed"`, and
    --     `is_not.equal("status=404", "server-failed")` is TRUE -- so "the
    --     server never started" was being read as "nothing was smuggled".
    --     The case must have reached a server before its answer means
    --     anything.
    local found
    for _, result in ipairs(results) do
      if result.label == SMUGGLE then found = result end
    end
    assert.is_truthy(found,
      "no corpus entry is labelled " .. SMUGGLE .. "; the only smuggling " ..
      "assertion in this suite selected nothing and asserted nothing")
    assert.is_not.equal("server-failed", found.outcome,
      "the harness never reached a server, so this proves nothing about " ..
      "smuggling: " .. tostring(found.why))
    assert.is_truthy(found.outcome:find "status=" or found.outcome == "closed",
      "the case produced neither a status nor a close, so nothing was " ..
      "observed about the router: " .. found.outcome)
    assert.is_not.equal("status=404", found.outcome,
      "the trailing bytes were parsed as a second request")
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
