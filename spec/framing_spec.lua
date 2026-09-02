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

--[[
Request smuggling, asserted on the BYTE STREAM rather than on a status code.

## Why the block above cannot do this job

Everything above goes through `raw.send`, which writes bytes, reads ONE status
line and closes. A desync *is* a second response on the same connection -- the
smuggled request's answer, arriving behind the first -- so a harness that stops
reading at the first status line cannot observe one BY CONSTRUCTION. The
suite's original smuggling assertion was therefore unfalsifiable in a way no
amount of care in writing it could have fixed: it inspected the first response,
which is perfectly well-formed even on a server that has just been
desynchronised.

`raw.send_raw` reads until the peer closes and `raw.parse_responses` walks the
framing, so the assertion here is the one that actually matters:

  * EXACTLY ONE response came back. Two means akkar answered a request the
    client never framed -- which, behind a CDN, means a request the CDN never
    authorised.
  * The marker is absent. `POST /admin` is registered only in the spawned
    server (`spec/support/raw_client.lua`) and answers `{"admin":"SMUGGLED"}`,
    so the string appearing anywhere in the stream is proof the trailing bytes
    were routed.
  * The connection CLOSED. RFC 9112 6.3: a framing error is unrecoverable, and
    9.6 requires the close to be announced. A server that answers 400 and then
    keeps reading is still holding unattributable bytes.

akkar is deployed behind a CDN, which makes it the back-end half of a desync
pair, and a desync pair only has to DISAGREE -- so each vector below is a case
where akkar's reading of the framing differs from a strict front end's.

## A fresh server per vector, deliberately

The corpus above shares one server on purpose. This block must not, and the
reason is a measurement: a smuggling vector leaves the connection open with
work the server still believes is in flight, so a shared server starts shedding
`503` a few vectors in and every later verdict becomes a statement about
back-pressure rather than about framing. That produced a run of confident
nonsense -- `503`s and `200`s where the fixed server plainly answers `400` --
before the servers were separated.
]]
--[[
The framing akkar puts on its OWN responses.

No spec asserted any response Content-Length before this one, so the whole
class was invisible by construction -- the same way the smuggling cases were
invisible while the harness read one status line. A client library reading
these responses is forgiving; a CDN is not.
]]
describe("framing (responses)", function()
  local server, port

  setup(function() server, port = raw.start(8390) end)
  teardown(function() if server then server() end end)

  local function response_to(path)
    local stream = raw.send_raw(port,
      ("GET %s HTTP/1.1\r\nHost: localhost\r\n\r\n"):format(path), 2)
    local responses, why = raw.parse_responses(stream)
    assert.is_nil(why, "unparsable response: " .. tostring(why))
    assert.equal(1, #responses, "expected one response, got " .. #responses)
    return responses[1], stream
  end

  it("sends no content-length on a 204", function()
    -- RFC 9110 8.6: "A server MUST NOT send a Content-Length header field in
    -- any response with a status code of 1xx (Informational) or 204 (No
    -- Content)." RFC 9112 6.3: a 204 is "always terminated by the first empty
    -- line after the header fields, regardless of the header fields present",
    -- so a Content-Length on one is framing that contradicts the framing the
    -- status has already fixed.
    --
    -- `h1_stream.lua` carries an `error("Content-Length not allowed in
    -- response with 204 status code")` that looks like it covers this and does
    -- not: it sits inside `if cl then`, so it only fires when the APPLICATION
    -- set the header. A handler that just returns 204 left `cl` nil and
    -- reached the branch that SYNTHESISES `content-length: 0` for any server
    -- response -- so the one status the file explicitly refuses to put a
    -- Content-Length on was the one reliably getting a synthesised one.
    assert.is_truthy(server, "no server: " .. tostring(port))
    local response, stream = response_to("/nothing")
    assert.equal(204, response.status)
    assert.is_nil(response.headers["content-length"],
      "a 204 carried content-length: " ..
      tostring(response.headers["content-length"]) .. " -- " ..
      stream:gsub("\r\n", "|"))
    assert.is_nil(response.headers["transfer-encoding"],
      "a 204 carried transfer-encoding")
    assert.equal("", response.body)
  end)

  it("still sends a correct content-length on an ordinary response", function()
    -- THE CONTROL. Suppressing Content-Length everywhere would satisfy the
    -- assertion above and break every response that has a body.
    assert.is_truthy(server, "no server: " .. tostring(port))
    local response = response_to("/users")
    assert.equal(200, response.status)
    assert.is_truthy(response.headers["content-length"],
      "an ordinary response lost its content-length")
    assert.equal(#response.body, tonumber(response.headers["content-length"]),
      "content-length disagrees with the body actually sent")
    assert.is_true(#response.body > 0)
  end)
end)

--[[
Response splitting -- the same disagreement, written in the other direction.

`h1_connection:write_header` carried a comment saying its asserts are "what
stops a header value from injecting CRLF into the response". They were not:
both tested for LINE FEED (`v:byte(-1) ~= 10`, `not v:find("\n[^ ]")`) and
neither looked for a bare CR, a NUL, or a leading space. A bare `\r` went into
the response verbatim, and a CDN that treats bare CR as a line terminator then
sees a header block this server never wrote.

Asserted directly against the vendored method rather than through a server,
because reaching it needs an application that reflects input into a header --
a redirect echoing a `?next=` parameter into `Location` is the ordinary case --
and building one only to test a string check would test the application
instead. The socket is a stub that RECORDS, so a test can also prove the
rejected value never reached the wire.
]]
describe("framing (response header injection)", function()
  local h1_connection = require "akkar.vendor.http.h1_connection"

  local function recorder()
    local wrote = {}
    return {
      wrote = wrote,
      socket = { xwrite = function(_, s) wrote[#wrote + 1] = s return true end },
    }
  end

  local REJECTED = {
    { "a bare CR", "/x\rContent-Length: 0" },
    { "a bare CR before a full status line",
      "/x\rHTTP/1.1 200 OK" },
    { "a NUL", "/x\0truncated" },
    { "a line feed", "/x\nContent-Length: 0" },
    { "an obs-fold continuation", "/x\n more" },
    { "a leading space", " /x" },
    { "a leading tab", "\t/x" },
  }

  for _, case in ipairs(REJECTED) do
    it("refuses to write a header value containing " .. case[1], function()
      local conn = recorder()
      local ok, err = pcall(h1_connection.methods.write_header,
                            conn, "location", case[2], 1)
      assert.is_false(ok,
        "wrote " .. case[1] .. " into a response header verbatim; a front " ..
        "end that splits on it sees a header block this server never wrote")
      assert.is_truthy(tostring(err):find("field value invalid", 1, true),
        "rejected for the wrong reason: " .. tostring(err))
      assert.equal(0, #conn.wrote,
        "the value was rejected but had already been written to the socket")
    end)
  end

  it("refuses a header NAME carrying a NUL or a newline", function()
    for _, name in ipairs { "x\0y", "x\ry", "x\ny", "x:y" } do
      local conn = recorder()
      local ok = pcall(h1_connection.methods.write_header, conn, name, "v", 1)
      assert.is_false(ok, "accepted the header name " .. string.format("%q", name))
    end
  end)

  it("still writes the ordinary header values a response is made of", function()
    -- THE CONTROL. A check that rejects everything would pass every assertion
    -- above and break every response akkar sends.
    local fine = {
      { "content-type", "application/json" },
      { "location", "/users/42?next=%2Fhome" },
      { "content-length", "29" },
      { "date", "Mon, 01 Sep 2026 00:00:00 GMT" },
      { "server", "akkar" },
      -- Internal spaces and tabs are legal in a field value; only a LEADING
      -- one is ambiguous with an obs-fold continuation.
      { "x-note", "one two\tthree" },
    }
    for _, kv in ipairs(fine) do
      local conn = recorder()
      local ok, err = pcall(h1_connection.methods.write_header,
                            conn, kv[1], kv[2], 1)
      assert.is_true(ok, ("refused a legitimate header %s: %s -- %s")
                         :format(kv[1], kv[2], tostring(err)))
      assert.equal(kv[1] .. ": " .. kv[2] .. "\r\n", conn.wrote[1])
    end
  end)
end)

describe("framing (desync)", function()
  -- `POST /admin`, and POST only. The corpus above smuggles a *GET* /admin and
  -- asserts a 404 never comes back; registering a GET handler would make that
  -- case answer 200 and quietly retire the suite's oldest smuggling assertion.
  local SMUGGLED = "POST /admin HTTP/1.1\r\nHost: localhost\r\n" ..
                   "Content-Length: 0\r\n\r\n"

  local function attack(extra_headers, body)
    return "POST /users HTTP/1.1\r\nHost: localhost\r\n" ..
           "Content-Type: application/json\r\n" .. extra_headers .. "\r\n" ..
           (body or "")
  end

  -- Each entry: label, the bytes, and the defect it pins.
  local VECTORS = {
    { "a content-length that overflows to zero",
      attack("Content-Length: 18446744073709551616\r\n", SMUGGLED),
      "tonumber(cl, 10) wraps to 0, so the body became the next request" },
    { "a content-length with a leading plus",
      attack("Content-Length: +0\r\n", SMUGGLED),
      "tonumber accepts a sign; Content-Length is 1*DIGIT" },
    { "a content-length with a leading minus",
      attack("Content-Length: -0\r\n", SMUGGLED),
      "tonumber accepts a sign; Content-Length is 1*DIGIT" },
    { "a content-length behind a vertical tab",
      attack("Content-Length: \v0\r\n", SMUGGLED),
      "tonumber skips \\v, which is not HTTP OWS" },
    { "a content-length behind a form feed",
      attack("Content-Length: \f0\r\n", SMUGGLED),
      "tonumber skips \\f, which is not HTTP OWS" },
    { "two content-lengths that disagree",
      attack("Content-Length: 0\r\nContent-Length: 40\r\n", SMUGGLED),
      "headers:get returns both and Lua truncates to the first" },
    { "content-length and transfer-encoding together",
      attack("Content-Length: 6\r\nTransfer-Encoding: chunked\r\n",
             "0\r\n\r\n" .. SMUGGLED),
      "TE silently won and CL stayed in the header set: CL.TE" },
    { "a chunk extension with no semicolon",
      attack("Transfer-Encoding: chunked\r\n", "0 junk\r\n\r\n" .. SMUGGLED),
      "CVE-2026-24880: '^(%x+) *(.-)' took arbitrary trailing text" },
  }

  local seen = {}

  setup(function()
    for i, vector in ipairs(VECTORS) do
      local stop, port = raw.start(8420 + i * 3)
      if not stop then
        seen[vector[1]] = { failed = tostring(port) }
      else
        local stream, outcome, closed = raw.send_raw(port, vector[2], 3)
        local responses, why = raw.parse_responses(stream)
        seen[vector[1]] = {
          n = #responses, responses = responses, closed = closed,
          outcome = outcome, parse_error = why,
          marker = stream:find("SMUGGLED", 1, true) ~= nil,
          stream = stream,
        }
        stop()
      end
    end
  end)

  for _, vector in ipairs(VECTORS) do
    local label, why = vector[1], vector[3]

    it("does not desync on " .. label, function()
      local got = seen[label]
      assert.is_truthy(got, "the vector never ran")
      assert.is_nil(got.failed,
        "the harness never reached a server, so this proves nothing: " ..
        tostring(got.failed))

      -- The marker first: it is the least ambiguous evidence, and it names
      -- the consequence rather than the mechanism.
      assert.is_false(got.marker,
        label .. ": the smuggled POST /admin was ROUTED -- akkar answered a " ..
        "request the client never framed (" .. why .. "). Stream: " ..
        got.stream:gsub("\r\n", "|"):sub(1, 300))

      assert.equal(1, got.n,
        label .. ": " .. got.n .. " responses came back on one connection; " ..
        "more than one is a desync (" .. why .. "). Stream: " ..
        got.stream:gsub("\r\n", "|"):sub(1, 300))
    end)

    it("announces the close when refusing " .. label, function()
      -- SAYING SO, as distinct from doing it.
      --
      -- On this tree the 400 path already closed the socket, via
      -- `pcall(stream.shutdown, stream)` -- measured, not assumed -- so the
      -- test below would pass without any change to akkar. What was missing
      -- is the ANNOUNCEMENT: the response carried no `Connection: close`, so
      -- the peer had only a FIN to infer it from.
      --
      -- That distinction is the whole point behind a CDN. RFC 9112 9.6: a
      -- server "MUST send a 'close' connection option in its final response"
      -- when it intends to close. An intermediary that does not see one is
      -- entitled to treat the connection as reusable and to race a pipelined
      -- request onto it against the FIN -- which is a desync produced by the
      -- CDN's correct behaviour and akkar's silence.
      local got = seen[label]
      assert.is_truthy(got, "the vector never ran")
      assert.is_nil(got.failed, "the harness never reached a server")
      local first = got.responses and got.responses[1]
      assert.is_truthy(first, "no parsable response: " ..
                       got.stream:gsub("\r\n", "|"):sub(1, 200))
      -- SCOPED TO THE 400 FRAMING REFUSAL, and the scope is a finding rather
      -- than a convenience.
      --
      -- A bad chunk extension is not caught while akkar is reading HEADERS --
      -- it is caught while reading the BODY, which is a different path in
      -- `akkar/init.lua` and answers **408**, after waiting out the read
      -- timeout. That answer also carries no `Connection: close`, so the same
      -- RFC 9112 9.6 gap is still open on the body-read path.
      --
      -- It is left open here deliberately: the 408 path was outside the remit
      -- of this change, and widening the assertion to cover it would make
      -- this suite red for a defect nobody has fixed yet, which is how a red
      -- suite becomes a suite people stop reading. The SECURITY property for
      -- that vector -- one response, no marker, socket closed -- is asserted
      -- unconditionally by the two tests either side of this one; what is
      -- unasserted is only the announcement.
      --
      -- When the 408 path learns to announce its close, drop the `== 400`
      -- and this becomes the stronger check it should be.
      if first.status == 400 then
        assert.equal("close", (first.headers["connection"] or ""):lower(),
          label .. ": refused with " .. first.status .. " and then closed, " ..
          "but never sent `Connection: close` -- an intermediary is entitled " ..
          "to keep the connection and pipeline onto it")
      end
    end)

    it("closes the connection after refusing " .. label, function()
      -- RFC 9112 6.3: a framing error is unrecoverable. A server that answers
      -- and keeps reading still has the attacker's trailing bytes queued, so
      -- the refusal is only half of the fix.
      local got = seen[label]
      assert.is_truthy(got, "the vector never ran")
      assert.is_nil(got.failed, "the harness never reached a server")
      assert.is_true(got.closed,
        label .. ": akkar answered but left the connection open, so the " ..
        "bytes behind the refused message are still queued to be parsed " ..
        "as a request")
    end)
  end

  it("answers a refused framing with 4xx, never 5xx", function()
    -- A malformed client input is the caller's mistake. Pinned here as well
    -- as in the corpus above because these vectors take a different path --
    -- they are refused by the new framing checks rather than by lua-http.
    local blamed = {}
    for label, got in pairs(seen) do
      local first = got.responses and got.responses[1]
      if first and first.status >= 500 then
        blamed[#blamed + 1] = label .. " -> " .. first.status
      end
    end
    assert.equal(0, #blamed, "answered 5xx: " .. table.concat(blamed, ", "))
  end)

  it("still serves a well-framed pipelined pair on one connection", function()
    -- THE CONTROL, and without it every assertion above is satisfied by a
    -- server that simply closes on everything.
    --
    -- Two complete, legitimate requests on one connection must still produce
    -- TWO responses. That is the behaviour the fixes must not have bought
    -- their result with, and it is exactly what `parse_responses` counts, so
    -- the counter is proved to be able to reach 2 at all.
    local stop, port = raw.start(8480)
    assert.is_truthy(stop, "no server: " .. tostring(port))

    local pair = "GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n" ..
                 "POST /admin HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
    local stream = raw.send_raw(port, pair, 3)
    stop()

    local responses, why = raw.parse_responses(stream)
    assert.is_nil(why, "could not parse the stream: " .. tostring(why))
    assert.equal(2, #responses,
      "keep-alive pipelining broke: " .. stream:gsub("\r\n", "|"):sub(1, 300))
    assert.equal(200, responses[1].status)
    assert.equal(200, responses[2].status)
    assert.is_truthy(responses[2].body:find("SMUGGLED", 1, true),
      "the second response is not the /admin marker, so the counter above " ..
      "is not actually distinguishing responses")
  end)
end)
