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

app:handle_signals()
app:run { port = %d, check_capabilities = false, timeout = 1,
          %s
          log = akkar.log.new { level = "error", sink = function() end } }
]==]

--- True when a Lua interpreter can be spawned at all.
function M.available()
  for _, binary in ipairs { "lua5.4", "lua" } do
    local pipe = io.popen(binary .. " -v 2>&1")
    if pipe then
      local out = pipe:read "a"
      pipe:close()
      if out and out:find "Lua" then M.binary = binary return true end
    end
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
--- a server configured differently -- `repair_substrate = false`, say, which
--- is how `spec/substrate_repair_spec.lua` shows that the repair is what
--- keeps the server alive rather than something else in the stack.
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
    ("%s %q"):format(M.binary or portable.lua, path), log))

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

return M
