--[[
What an idle connection costs, and the knob that changes it.

`bench/runtime/RESULTS.md` records the one number in that comparison where
akkar came last: 19.50 KB of resident memory per idle keep-alive connection,
against OpenResty's 0.42 KB. The plan in `docs/PLAN.md` attributed roughly
15 KB of that to lua-http and 4 KB to akkar, by subtracting Lapis's figure from
akkar's on the study box.

That attribution was wrong, and this file is where it was corrected. Measured
in-process rather than by subtraction:

    Lua heap, bare cqueues socket server   2,568 bytes/connection
    Lua heap, akkar on vendored lua-http   3,415 bytes/connection

So everything akkar and lua-http hold above the cqueues floor is 847 bytes.
The rest is cqueues -- specifically an input and an output buffer of
LSO_BUFSIZ (4096) bytes each, malloc'd EAGERLY when the socket is created
(`socket.c`, `lso_prepsocket` -> `lso_adjbufs` -> `fifo_realloc`). Eight
kilobytes per connection, held whether or not the connection carries a byte,
and invisible to `collectgarbage "count"` because it is C memory -- which is
why no allocation ceiling in this suite ever saw it.

`app:run { socket_buffer = n }` writes cqueues' socket PROTOTYPE, which every
later socket is copied from. The buffers still grow on demand; only the eager
preallocation goes.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues  = require "cqueues"
local socket   = require "cqueues.socket"
local akkar    = require "akkar"
local portable = require "spec.support.portable"

local QUIET = function() return akkar.log.new { level = "error", sink = function() end } end

--- Runs `app:run` with the given config against a free port, calls `body` with
--- the port, and stops.
---
--- The prototype is a process-wide setting and this file changes it, so every
--- case restores what it found. Without that, a case that shrinks the buffer
--- silently changes the arithmetic of every spec that runs after it in the
--- same busted process.
local function with_server(config, body)
  local before_r, before_w = socket.setbufsiz()
  local port = 8300 + math.random(0, 900)
  local app = akkar.new()
  app:get("/ping", function() return { pong = true } end)

  local cq = cqueues.new()
  local err
  cq:wrap(function()
    local ok, why = pcall(function()
      config.port = port
      config.check_capabilities = false
      config.log = QUIET()
      app:run(config)
    end)
    if not ok then err = why end
  end)
  cq:wrap(function()
    cqueues.sleep(0.3)
    local ok, why = pcall(body, port)
    app:stop(1)
    if not ok then err = err or why end
  end)
  assert(cq:loop(60))
  socket.setbufsiz(before_r, before_w)
  if err then error(err, 0) end
end

describe("socket_buffer", function()
  it("shrinks cqueues' eager per-socket preallocation", function()
    with_server({ socket_buffer = 1024 }, function()
      local r, w = socket.setbufsiz()
      assert.equal(1024, r)
      assert.equal(1024, w)
    end)
  end)

  it("defaults to 1024 rather than cqueues' 4096", function()
    -- The default is a DECISION, not an inherited value, and it is the
    -- decision that gives back 5.4 KB per idle connection. If someone
    -- removes the default this reports it.
    with_server({}, function()
      local r = socket.setbufsiz()
      assert.equal(1024, r)
    end)
  end)

  it("leaves cqueues alone when asked to", function()
    -- The escape hatch has to actually escape: an application serving large
    -- uploads may want the bigger preallocation back, and `false` must not
    -- be read as "use the default".
    local was = socket.setbufsiz()
    with_server({ socket_buffer = false }, function()
      assert.equal(was, socket.setbufsiz())
    end)
  end)

  it("refuses a value that is not a positive whole number of bytes", function()
    for _, bad in ipairs { 0, -1, 1.5, "1024" } do
      local ok, why = pcall(function()
        with_server({ socket_buffer = bad }, function() end)
      end)
      assert.is_false(ok, ("socket_buffer = %s was accepted"):format(tostring(bad)))
      assert.is_truthy(tostring(why):find("socket_buffer", 1, true))
    end
  end)

  it("is a known setting, so a typo is still an error", function()
    -- `app:run { socket_bufer = 512 }` must not run a server with 4096-byte
    -- buffers while its author believes otherwise. That is the whole reason
    -- SETTINGS exists.
    local app = akkar.new()
    local ok, why = pcall(function()
      app:run { socket_bufer = 512, check_capabilities = false }
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("socket_bufer", 1, true))
  end)
end)

describe("the cost of an idle connection", function()
  -- IN A PROCESS OF ITS OWN, and the reason is a failure rather than a
  -- preference. The first version of this measured inside busted and answered
  -- ZERO bytes per connection at BOTH buffer sizes -- not a wrong number, no
  -- number: this process already has a heap with room to spare, so three
  -- hundred more sockets fit in pages it already owns and VmRSS does not
  -- move. An instrument that cannot see the effect reports "no difference",
  -- which reads exactly like a regression.
  local HOLD = 300

  --- Starts `spec/support/idle_server.lua` with the given buffer, holds HOLD
  --- keep-alive connections against it, and answers what that cost its
  --- resident memory, in bytes per connection.
  ---
  --- nil means the platform could not answer, which the caller must report as
  --- pending rather than as a result.
  local function cost_of_holding(buffer)
    local port = 8300 + math.random(0, 900)
    if portable.port_in_use(port) then port = port + 137 end

    local log = os.tmpname()
    -- `env`, not a bare `VAR=value` prefix: `portable.timeout` wraps the
    -- command in `timeout 60 ...`, and `timeout` execs its argument rather
    -- than handing it to a shell -- so it went looking for a program called
    -- `AKKAR_PORT=8876` and reported it missing.
    local command = ("env AKKAR_PORT=%d AKKAR_BUFSIZ=%s %s %s")
      :format(port, tostring(buffer), portable.lua, "spec/support/idle_server.lua")
    os.execute(portable.detached(portable.timeout(60, command), log))

    -- Wait by ASKING THE PORT, not by sleeping. `sleep 0.1` is not portable
    -- and `sleep 1` in a loop makes a two-arm measurement take a minute to
    -- decide the server is missing; a connect attempt costs nothing when the
    -- answer is no and returns the instant the answer is yes.
    local pid
    for _ = 1, 400 do
      local ok, c = pcall(socket.connect, "127.0.0.1", port)
      if ok and c then
        local reached = pcall(function() c:settimeout(0.05) c:write "" end)
        pcall(function() c:close() end)
        if reached then pid = portable.pid_on_port(port) end
        if pid then break end
      end
    end
    if not pid then
      local f = io.open(log, "r")
      local why = f and f:read "a" or "(no log)"
      if f then f:close() end
      os.remove(log)
      error("the idle server did not start on port " .. port .. ":\n" .. why, 0)
    end

    local held, cost = {}, nil
    local function open()
      local c = assert(socket.connect("127.0.0.1", port))
      c:setmode("bn", "bn")
      c:settimeout(20)
      return c
    end
    local function ping(c)
      c:write "GET /ping HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
      local len
      while true do
        local line = assert(c:read "*l")
        -- `read "*l"` keeps the trailing CR. Testing for "" alone is how a
        -- client in this tree once hung until its timeout.
        if line == "" or line == "\r" then break end
        local n = line:lower():match "^content%-length:%s*(%d+)"
        if n then len = tonumber(n) end
      end
      if len and len > 0 then c:read(len) end
    end

    local ok, why = pcall(function()
      -- One connection first, so the server is past whatever it initialises
      -- lazily on its very first request before anything is counted.
      local warm = open()
      ping(warm)
      held[#held + 1] = warm
      local before = portable.rss_kb(pid)

      for _ = 1, HOLD do
        local c = open()
        ping(c)
        held[#held + 1] = c
      end

      local after = portable.rss_kb(pid)
      if before and after then cost = (after - before) * 1024 / HOLD end
    end)

    for _, c in ipairs(held) do pcall(function() c:close() end) end
    os.execute(("kill %d 2>/dev/null"):format(pid))
    os.remove(log)
    if not ok then error(why, 0) end
    return cost
  end

  it("falls by kilobytes when the preallocation does", function()
    -- SKIPPED WHERE THE INSTRUMENT DOES NOT EXIST, and named as that rather
    -- than as a failure. Everything below reads `/proc`; macOS has none, and
    -- uses kqueue rather than epoll, so there is not even an eventpoll to
    -- count. A test that cannot be run on a platform is pending there, not
    -- red -- red would say akkar is broken on macOS, which this does not
    -- know.
    if not io.open "/proc/self/stat" then
      pending "descriptor counting needs /proc; this platform has none"
      return
    end

    local big   = cost_of_holding(4096)
    local small = cost_of_holding(1024)

    if not big or not small or big <= 0 then
      -- Zero is "the instrument saw nothing", not "the two are equal".
      pending "no usable resident-memory instrument on this platform"
      return
    end

    -- MEASURED, holding 800 connections against a server process of its own:
    --
    --     bufsiz 4096  14,582 bytes/connection   <- cqueues' default
    --     bufsiz 2048  10,977
    --     bufsiz 1024   9,175                    <- what akkar picks
    --     bufsiz  512   7,864
    --     bufsiz  256   7,864                    <- floor
    --
    -- A 37% fall from the default. The assertion asks for 15%, and the gap is
    -- deliberate: this holds 300 rather than 800, and page granularity is
    -- coarse at that size. A test that demanded the full 37% would fail for
    -- reasons that have nothing to do with what it is testing.
    assert.is_true(small < big * 0.85,
      ("holding %d connections cost %.0f bytes each at bufsiz 1024 and %.0f "
       .. "at 4096; the eager preallocation is not being reduced")
        :format(HOLD, small, big))
  end)
end)
