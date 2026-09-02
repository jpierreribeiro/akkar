--[[
A server in another process, and raw sockets from this one.

## Two harnesses were wrong before this one

**Client and server in one controller.** The client writes malformed bytes and
blocks reading a reply; the server cannot write that reply until the client
yields; the client only yields when it decides to wait. Neither `cqueues.poll`
nor `socket:settimeout` breaks it, because the problem is not the waiting --
it is that both halves share a scheduler. Which is the failure the client
exists to provoke, so it cannot also be the harness.

**Client in a subprocess, server here.** Worse, and for a duller reason:
`io.popen` blocks the whole OS process while the child runs, so the server
coroutine never gets scheduled and every case times out against a server that
was never listening.

So: the SERVER goes in its own process. It has its own scheduler and its own
fate, and this process is free to send bytes no client would send and wait
with a bounded loop.
]]

local cqueues  = require "cqueues"
local socket   = require "cqueues.socket"
local portable = require "spec.support.portable"

local M = {}

local SERVER = [==[
package.path = "%s"
package.cpath = "%s"
%s
local akkar = require "akkar"
local app = akkar.new()
app:get("/users", function() return { users = {} } end)
app:post("/users", { body = { name = "string" } },
         function(req) return akkar.created { name = req.body.name } end)

-- THE SMUGGLING MARKER. A route that only a request the client never framed
-- can reach, so a desync leaves a fingerprint in the byte stream instead of
-- having to be inferred from a status code.
--
-- POST, and only POST, ON PURPOSE. `spec/framing_spec.lua`'s original corpus
-- smuggles a *GET* /admin and asserts that a 404 -- proof the trailing bytes
-- were routed -- never comes back. Registering a GET handler here would make
-- that case answer 200 and quietly retire the suite's oldest smuggling
-- assertion. GET /admin therefore stays unrouted and still 404s; the POST is
-- new ground.
app:post("/admin", function() return { admin = "SMUGGLED" } end)
-- A 204, for the response-framing assertions. RFC 9110 8.6 forbids a
-- Content-Length here, and akkar synthesised one, so the route exists to put
-- the actual bytes of a bodyless response in front of a test.
app:get("/nothing", function() return akkar.response(204) end)

app:handle_signals()
app:run { port = %d, check_capabilities = false, timeout = 1,
          %s
          log = akkar.log.new { level = "error", sink = function() end } }
]==]

--- True when a Lua interpreter can be spawned at all.
---
--- It asks `portable.lua`, which resolves the interpreter RUNNING THIS SUITE
--- rather than the first plausible name on PATH. That distinction is not
--- theoretical: this function used to try `lua5.4` first, and under Lua 5.5 it
--- found one -- correctly, it was installed -- and handed it 5.5's `LUA_PATH`.
--- Every spawned server then died on its first `require`, and twenty-two
--- framing cases reported protocol failures that were nothing of the kind.
---
--- A spawned server inherits this process's module paths, so it has to be this
--- process's Lua.
function M.available()
  local pipe = io.popen(("%q -v 2>&1"):format(portable.lua))
  if pipe then
    local out = pipe:read "a"
    pipe:close()
    if out and out:find "Lua" then M.binary = portable.lua return true end
  end
  return false
end

--- Starts an akkar server in its own process and waits for it to listen.
--- Returns `stop, port`, or nil and a reason.
---
--- The port is CHOSEN HERE, by trying until one is free, rather than passed
--- in. A caller cannot know which ports are free, and on this machine that is
--- not a theoretical worry: `docs/substrate/lua-http-wedge.md` describes a
--- server that stops accepting and never exits, so every run of the framing
--- corpus leaves listening sockets behind that nothing will reclaim. A fixed
--- port would make the spec fail on its second run for a reason that has
--- nothing to do with what it tests.
--- `extra` is pasted into the server's `app:run{}` call, so a spec can start
--- a server configured differently -- a smaller `body_limit`, say -- without
--- needing a second support module per configuration.
--- `prelude` is Lua that runs BEFORE `require "akkar"`, which is the only
--- place a `package.preload` override can be installed and still be seen.
--- `spec/substrate_repair_spec.lua` uses it to swap one vendored module for
--- its upstream original, so a control can prove which copy is load-bearing.
function M.start(first_port, extra, prelude)
  for attempt = 0, 40 do
    local stop, why = M.start_on((first_port or 8300) + attempt, extra, prelude)
    if stop then return stop, (first_port or 8300) + attempt end
    if not tostring(why):find("Address already in use", 1, true) then
      return nil, why
    end
  end
  return nil, "no free port in forty tries"
end

function M.start_on(port, extra, prelude)
  local path = os.tmpname() .. ".lua"
  local file = assert(io.open(path, "w"))
  file:write(SERVER:format(package.path:gsub("%%", "%%%%"),
                           package.cpath:gsub("%%", "%%%%"),
                           (prelude or ""):gsub("%%", "%%%%"), port,
                           extra or ""))
  file:close()

  -- Backgrounded with `&` rather than `io.popen`, which would block this
  -- process for as long as the server ran -- which is for ever.
  --
  -- Its output goes to a FILE, not to /dev/null. A harness that cannot say
  -- why the server did not start is a harness that costs an afternoon.
  local log = path .. ".log"
  -- `setsid` when there is one -- a Mac has none, and `portable` falls back to
  -- a plain `&`, which detaches enough here because `os.execute`'s `sh` exits
  -- immediately and the child is reparented rather than killed.
  os.execute(portable.detached(
    ("%q %q"):format(M.binary or portable.lua, path), log))

  -- Wait for the port rather than sleeping a guessed amount: a fixed sleep is
  -- either too short on a loaded machine or wasted on an idle one.
  --
  -- EVERY ATTEMPT INSIDE A CONTROLLER WITH A BUDGET. A cqueues socket used
  -- outside one blocks the OS thread, and `connect` succeeds lazily -- so a
  -- probe against a server that has not started yet reaches `read` and waits
  -- there for ever, with nothing able to interrupt it. That is not a
  -- hypothetical: it is what made this file's first version hang the suite
  -- rather than fail it.
  for _ = 1, 60 do
    local ready = false
    local cq = cqueues.new()
    cq:wrap(function()
      local conn = socket.connect("127.0.0.1", port)
      if not conn then return end
      conn:setmode("bn", "bn")
      conn:onerror(function(_, _, why) return why end)
      local wrote = conn:write "GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n"
      local line = wrote and conn:read "*L"
      conn:close()
      ready = line ~= nil and line:find "HTTP/1.1" ~= nil
    end)
    cq:loop(0.5)

    if ready then
      return function()
        -- TERM, THEN KILL, and the escalation is not belt-and-braces.
        --
        -- A wedged akkar server cannot answer a signal. `app:handle_signals`
        -- installs the handler as a cqueues coroutine, and the whole nature of
        -- the wedge this suite provokes is that one coroutine spins and the
        -- scheduler never runs another -- so the handler that would exit
        -- politely is exactly the thing that is starved. `pkill -TERM` on it
        -- is a signal nobody is listening for.
        --
        -- Twenty-two of these accumulated across a night of test runs, each
        -- spinning on a core, five hours old, load average 23 -- underneath a
        -- benchmark that was measuring something else at the time.
        os.execute(("pkill -f %q >/dev/null 2>&1"):format(path))
        os.execute(("pkill -9 -f %q >/dev/null 2>&1"):format(path))
        os.remove(path)
      end
    end

    local pause = cqueues.new()
    pause:wrap(function() cqueues.sleep(0.1) end)
    pause:loop(0.5)
  end

  os.execute(("pkill -f %q >/dev/null 2>&1"):format(path))
  os.execute(("pkill -9 -f %q >/dev/null 2>&1"):format(path))

  local file = io.open(log, "r")
  local said = file and file:read "a" or ""
  if file then file:close() end
  os.remove(log)
  os.remove(path)

  return nil, ("the server never started listening on %d; it said: %s")
              :format(port, said ~= "" and said:gsub("%s+$", "") or "(nothing)")
end

--- Sends bytes and reports what came back: "status=N", "closed", or
--- "timeout" -- the last of which is the only one that would be a finding.
---
--- Each case runs in its own controller with a budget, so bytes that make the
--- server go quiet cost one timeout rather than the suite.
function M.send(port, bytes, timeout)
  local outcome
  local cq = cqueues.new()
  cq:wrap(function()
    local conn = socket.connect("127.0.0.1", port)
    if not conn then outcome = "closed" return end
    conn:setmode("bn", "bn")
    conn:onerror(function(_, _, why) return why end)

    conn:write(bytes)
    local line = conn:read "*L"
    conn:close()

    if line then
      local status = tonumber(line:match "HTTP/%d%.%d (%d+)")
      outcome = status and ("status=" .. status) or "closed"
    else
      outcome = "closed"
    end
  end)
  cq:loop(timeout or 2)

  return outcome or "timeout"
end

--- Sends bytes and returns EVERY byte the server writes back before it closes,
--- as one string, plus the outcome word `M.send` would have returned.
---
--- ## Why `M.send` cannot be used to test request smuggling
---
--- `M.send` reads ONE status line with `conn:read "*L"` and closes. A desync
--- IS a second response on the same connection -- the smuggled request's
--- answer, arriving after the first -- so a harness that stops reading at the
--- first status line cannot observe one BY CONSTRUCTION. Every smuggling
--- assertion written against `M.send` was therefore unfalsifiable: it saw the
--- first response, which is well-formed even when the connection has been
--- desynchronised behind it.
---
--- This reads until the peer closes or the budget runs out, so a caller can
--- count occurrences of "HTTP/1.1 " and look for a marker that only a
--- smuggled request could have produced.
---
--- Reading is a LOOP over bounded chunks rather than a single `read "*a"`.
--- `*a` returns nothing at all until EOF, so against a server that answers and
--- then holds the connection open -- which is precisely the bug being hunted,
--- since a framing error is supposed to close -- `*a` yields the empty string
--- on timeout and the test reads it as "no response". The loop keeps what
--- arrived before the budget expired, which is the evidence.
---
--- Returns `body, outcome, closed` where `closed` says the server actually
--- ended the connection rather than the budget doing it. That distinction is
--- itself an assertion target: RFC 9112 6.3 requires a close after a framing
--- error, so a test can demand it.
function M.send_raw(port, bytes, timeout)
  local parts, outcome, closed = {}, nil, false
  local cq = cqueues.new()
  cq:wrap(function()
    local conn = socket.connect("127.0.0.1", port)
    if not conn then outcome = "closed" return end
    conn:setmode("bn", "bn")
    conn:onerror(function(_, _, why) return why end)

    if not conn:write(bytes) then
      conn:close()
      outcome = "closed"
      return
    end
    conn:flush()

    -- A negative count is cqueues' "up to this many bytes", so a response
    -- shorter than the buffer does not block waiting for the rest of it.
    while true do
      local chunk = conn:read(-4096)
      if chunk == nil or chunk == "" then
        closed = chunk == nil
        break
      end
      parts[#parts + 1] = chunk
    end
    conn:close()
    outcome = #parts > 0 and "answered" or "closed"
  end)
  cq:loop(timeout or 2)

  return table.concat(parts), outcome or "timeout", closed
end

--- Splits a byte stream `M.send_raw` returned into the responses it contains.
--- Returns a sequence of `{ status = 400, headers = {...}, body = "..." }`,
--- newest last, and a reason if the stream ended mid-message.
---
--- ## Why this PARSES rather than counting "HTTP/1.1 "
---
--- Two failure modes, in opposite directions, and a `string.find` count has
--- both:
---
---   * FALSE NEGATIVE, which is the one that matters. akkar frames its
---     responses with `Content-Length`, so the smuggled request's answer
---     begins on the byte immediately after the first response's body -- e.g.
---     `...{"error":"malformed request"}HTTP/1.1 200 OK`. There is no CRLF in
---     front of it, so any boundary rule based on a preceding delimiter
---     misses exactly the desync the test exists to catch, and the test goes
---     green on a vulnerable server.
---   * FALSE POSITIVE. A bare count also counts the token inside a response
---     BODY, and akkar echoes request detail into its 400 body -- so an input
---     carrying "HTTP/1.1 200" could manufacture a second "response" and fail
---     a server that never desynchronised.
---
--- Walking the framing is the only thing that answers both: a response ends
--- where its own `Content-Length` or chunk terminator says it ends, and
--- whatever begins there is a genuinely separate message.
function M.parse_responses(stream)
  local out, at = {}, 1

  while at <= #stream do
    local line_end = stream:find("\r\n", at, true)
    if not line_end then
      return out, "no status line at byte " .. at
    end
    local status = tonumber(stream:sub(at, line_end - 1):match "^HTTP/1%.[01] (%d%d%d)")
    if not status then
      return out, "not a status line at byte " .. at .. ": " ..
                  stream:sub(at, math.min(line_end - 1, at + 60))
    end
    at = line_end + 2

    local hdrs = {}
    while true do
      local eol = stream:find("\r\n", at, true)
      if not eol then return out, "headers never ended" end
      if eol == at then at = at + 2 break end -- the blank line
      local k, v = stream:sub(at, eol - 1):match "^([^:]+):%s*(.-)%s*$"
      if k then hdrs[k:lower()] = v end
      at = eol + 2
    end

    local body
    if hdrs["transfer-encoding"] and hdrs["transfer-encoding"]:find "chunked" then
      local buf = {}
      while true do
        local eol = stream:find("\r\n", at, true)
        if not eol then return out, "chunked body truncated" end
        local size = tonumber(stream:sub(at, eol - 1):match "^(%x+)", 16)
        if not size then return out, "bad chunk size" end
        at = eol + 2
        if size == 0 then
          -- trailers, then the terminating blank line
          while true do
            local te = stream:find("\r\n", at, true)
            if not te then return out, "trailers never ended" end
            local was = at
            at = te + 2
            if te == was then break end
          end
          break
        end
        buf[#buf + 1] = stream:sub(at, at + size - 1)
        at = at + size + 2 -- the chunk's own CRLF
      end
      body = table.concat(buf)
    else
      local len = tonumber(hdrs["content-length"] or "0")
      if not len then return out, "unusable content-length" end
      body = stream:sub(at, at + len - 1)
      at = at + len
    end

    out[#out + 1] = { status = status, headers = hdrs, body = body }
  end

  return out
end

--- How many complete responses came back on one connection. More than one is
--- a desync: the server answered a request the client never framed.
function M.count_responses(stream)
  return #(M.parse_responses(stream))
end

return M
