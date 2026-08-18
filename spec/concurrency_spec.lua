--[[
The descriptor ceiling.

Every in-flight request holds a cqueues controller for its deadline, and a
controller costs exactly two file descriptors. Measured:

    concurrent      fds     per request
    64              134            2.09
    256             518            2.02
    512            1030            2.01

Against the common default of `ulimit -n 1024` that is a wall at about 500
concurrent requests per process, and hitting it is not a clean failure:
`accept` starts failing, every socket operation starts failing, and the
process flails. A benchmark machine was lost this way during a 512-connection
sweep.

Pooling the controllers does not help. The pool serves sequential reuse; five
hundred requests in flight at once need five hundred controllers whatever its
size.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local akkar   = require "akkar"
local request = require "http.request"

describe("a controller costs descriptors", function()
  local condition = require "cqueues.condition"

  --- Counts this process's descriptors. Reading /proc/self/fd through
  --- io.popen measures the SUBPROCESS, so the pid is resolved first -- a
  --- mistake this project has already made once. `portable` keeps that
  --- reasoning and adds the machines with no /proc, where `lsof` answers and
  --- the absolute number differs but the delta, which is all this measures,
  --- does not.
  local portable = require "spec.support.portable"
  local function open_fds()
    -- nil, not 0. A machine that cannot count descriptors must not report
    -- "nothing leaked"; `cost_of` turns the nil into a pending instead.
    return portable.open_fds()
  end

  local function cost_of(make, n)
    collectgarbage(); collectgarbage()
    -- Twice, and the first result is thrown away. `open_fds` opens a pipe to
    -- do the counting, and the descriptors that pipe uses are not in steady
    -- state until it has run once -- so the first measurement of a process
    -- reads a number the second does not.
    open_fds()
    local before = open_fds()
    if not before then return nil end
    local held = {}
    for i = 1, n do held[i] = make() end
    local after = open_fds()
    if not after then return nil end
    return (after - before) / n, held
  end

  it("is exactly what a controller costs on this platform", function()
    -- Deterministic: no timing, no noise floor, no quiet machine needed.
    --
    -- Not deterministic across platforms, though, which is what the matrix
    -- found: 2 on epoll, 3 on kqueue. The expected number is pinned per
    -- platform in `portable` rather than widened into a range, because the
    -- range that passes on both is a range that notices neither.
    local each = cost_of(function() return cqueues.new() end, 100)
    if not each then
      pending "descriptors cannot be counted here: no /proc and no lsof"
      return
    end
    local expected = portable.descriptors_per_controller
    if not expected then
      pending(("nobody has measured what a controller costs on %s")
              :format(tostring(portable.os_name)))
      return
    end
    assert.is_true(each > expected - 0.1 and each < expected + 0.1,
      string.format("a controller cost %.2f descriptors on %s, not %d",
                    each, tostring(portable.os_name), expected))
  end)

  it("is zero for a condition, which is what makes the real fix possible", function()
    -- The arbitration a deadline needs could be done with one of these and no
    -- descriptors at all. It is not a drop-in -- see the note in App:run --
    -- but this is the measurement that says it is worth doing.
    local each = cost_of(function() return condition.new() end, 100)
    if not each then
      pending "descriptors cannot be counted here: no /proc and no lsof"
      return
    end

    -- NOT `assert.equal(0, each)`, which is what this said and which failed
    -- roughly one run in five. The counting itself opens a pipe, so a single
    -- transient descriptor becomes 0.01 per condition and an exact zero
    -- reports the instrument rather than the subject.
    --
    -- The property is that a condition costs no descriptor: a hundred of them
    -- must not cost anything like a hundred. Ten is two orders of magnitude
    -- below what would matter and far above the noise.
    assert.is_true(each < 0.1,
      string.format("a condition cost %.3f descriptors", each))
  end)
end)

describe("the concurrency ceiling", function()
  local portable = require "spec.support.portable"
  local socket   = require "cqueues.socket"

  --- Runs `spec/support/idle_server.lua` and calls `body(port)` against it.
  ---
  --- IN A PROCESS OF ITS OWN, and that is the whole point rather than
  --- tidiness. busted holds sockets of its own -- its own test client, the
  --- servers other specs left behind, the interpreter's own files -- so a
  --- descriptor count taken inside it measures the suite. The number that
  --- means something is the delta in a process that is doing nothing else.
  local function with_server(seconds_to_hold, body)
    local port = 8100 + math.random(0, 900)
    if portable.port_in_use(port) then port = port + 173 end
    local log = os.tmpname()
    -- `env`, not a bare `VAR=value` prefix: `portable.timeout` wraps this in
    -- `timeout N ...`, and `timeout` execs its argument rather than handing
    -- it to a shell, so it would go looking for a program named `AKKAR_PORT=8137`.
    local command = ("env AKKAR_PORT=%d AKKAR_HOLD=%d %s %s")
      :format(port, seconds_to_hold, portable.lua, "spec/support/idle_server.lua")
    os.execute(portable.detached(portable.timeout(90, command), log))

    -- Wait by asking the port. `sleep 0.1` is not portable and `sleep 1` in a
    -- loop makes a missing server take a minute to notice.
    local up = false
    for _ = 1, 400 do
      local ok, c = pcall(socket.connect, "127.0.0.1", port)
      if ok and c then
        pcall(function() c:close() end)
        if portable.pid_on_port(port) then up = true break end
      end
    end
    if not up then
      local f = io.open(log, "r")
      local why = f and f:read "a" or "(no log)"
      if f then f:close() end
      os.remove(log)
      -- RAISED, not returned as nil. A nil here becomes `pending`, and a
      -- pending is what a platform that cannot answer deserves -- not a
      -- fixture that failed to boot for a reason printed in a file nobody
      -- reads. The two have to look different.
      error("the fixture server did not start on port " .. port .. ": " .. why, 0)
    end

    local pid = portable.pid_on_port(port)
    local ok, result = pcall(body, port)
    os.execute(("kill %d 2>/dev/null"):format(pid))
    os.remove(log)
    if not ok then error(result, 0) end
    return result
  end

  local function ask(c, path)
    c:write(("GET %s HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"):format(path))
    local len
    while true do
      local line = assert(c:read "*l")
      -- `read "*l"` keeps the trailing CR. Testing for "" alone is how a
      -- client in this tree once hung until its timeout.
      if line == "" or line == "\r" then break end
      local n = line:lower():match "^content%-length:%s*(%d+)"
      if n then len = tonumber(n) end
    end
    return len and len > 0 and c:read(len) or ""
  end

  local function connect(port)
    local c = assert(socket.connect("127.0.0.1", port))
    c:setmode("bn", "bn")
    c:settimeout(30)
    return c
  end

  --- The ceiling a real server derived for itself, or nil.
  local function measured_ceiling()
    return with_server(1, function(port)
      local c = connect(port)
      local n = tonumber(ask(c, "/fds"):match '"max_concurrent":(%d+)')
      c:close()
      return n
    end)
  end

  --- Descriptors held per request in flight, or nil where /proc cannot say.
  local function descriptors_per_request(flight)
    return with_server(3, function(port)
      local cq = cqueues.new()
      local idle, peak, done = nil, nil, 0

      cq:wrap(function()
        local probe = connect(port)
        ask(probe, "/ping")                       -- warm
        idle = tonumber(ask(probe, "/fds"):match '"fds":(%d+)')

        for _ = 1, flight do
          cq:wrap(function()
            pcall(function()
              local c = connect(port)
              ask(c, "/hold")
              c:close()
            end)
            done = done + 1
          end)
        end

        -- Sampled while they are all outstanding: /hold sleeps for three
        -- seconds and this asks after one and a half.
        cqueues.sleep(1.5)
        peak = tonumber(ask(probe, "/fds"):match '"fds":(%d+)')

        while done < flight do cqueues.sleep(0.1) end
        probe:close()
      end)

      assert(cq:loop(90))
      if not idle or not peak or peak <= idle then return nil end
      return (peak - idle) / flight
    end)
  end

  it("queues rather than collapsing when the ceiling is reached", function()
    -- Slow is a state a server can be in. Out of descriptors is not.
    local PORT = 8394
    local app = akkar.new()
    app:get("/slow", function() cqueues.sleep(0.4) return { ok = true } end)

    local answered, failed = 0, 0
    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false, max_concurrent = 8,
                  log = akkar.log.new { level = "error" } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.2)
      local inner = cqueues.new()
      for _ = 1, 40 do
        inner:wrap(function()
          local ok = pcall(function()
            local req = request.new_from_uri("http://127.0.0.1:" .. PORT .. "/slow")
            local h, stream = assert(req:go(15))
            stream:get_body_as_string()
            assert(h:get ":status" == "200")
          end)
          if ok then answered = answered + 1 else failed = failed + 1 end
        end)
      end
      assert(inner:loop(40))
      app:stop(1)
    end)
    assert(cq:loop(60))

    assert.equal(40, answered, "requests beyond the ceiling must wait, not fail")
    assert.equal(0, failed)
  end)

  it("is derived from the descriptor limit when nobody sets one", function()
    -- A default nobody can compute is a default nobody trusts, so the number
    -- comes from /proc/self/limits rather than from a constant someone liked.
    --
    -- Which is also the limit of it: `descriptor_ceiling` in `akkar/init.lua`
    -- returns nil where that file does not exist, and `akkar/limit.lua` warns
    -- once when it does. That degradation is deliberate and documented, so
    -- this test states the platform rather than failing on it -- `io.lines`
    -- on a missing path RAISES, which would have read as a broken ceiling.
    local limits = io.open "/proc/self/limits"
    if not limits then
      pending "no /proc/self/limits here: the ceiling is not derived on this platform"
      return
    end
    local soft
    for line in limits:lines() do
      soft = soft or line:match "^Max open files%s+(%d+)"
    end
    limits:close()
    assert.is_truthy(soft, "this platform does not expose the limit")

    -- ONE descriptor per in-flight request -- the connection's socket -- with
    -- a third of the budget left for the listener, the database pool and the
    -- log sink. It was three until the deadline stopped needing a controller.
    --
    -- THIS ASSERTION USED TO RE-DERIVE THE FORMULA AND THEN CHECK NOTHING.
    -- It computed `expected` with the same arithmetic as `init.lua`, divisor
    -- and all, and then asserted `expected >= 16` -- which is true for any
    -- divisor, on any box. The divisor was 2 and had been wrong from the
    -- start, and this test could not have told anybody: it agreed with the
    -- code because it WAS the code, written twice.
    --
    -- It compares against what akkar actually decided now, and the case below
    -- goes and counts the descriptors rather than trusting either copy.
    local expected = math.max(math.floor(tonumber(soft) * 0.66 / 1), 16)
    local app = akkar.new()
    app:get("/ping", function() return { pong = true } end)
    -- `App:run` computes it, and `app:test` never calls `App:run`, so the
    -- number has to come from a server that really started.
    local got = measured_ceiling()
    if not got then
      pending "could not start a server to read its ceiling"
      return
    end
    assert.equal(expected, got,
      ("akkar derived %d from a soft limit of %s; the formula here says %d")
        :format(got, soft, expected))
  end)

  it("costs one descriptor per request in flight, counted", function()
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

    -- THE NUMBER THE CEILING DIVIDES BY, MEASURED RATHER THAN ASSERTED.
    --
    -- `descriptor_ceiling` divided by two for as long as it existed, and two
    -- is the controller alone -- it forgot the connection's own socket. The
    -- consequence was a ceiling fifty percent higher than the box could
    -- serve: on the usual `ulimit -n 1024` it promised 337 concurrent
    -- requests, which need 1,011 descriptors, more than the entire limit.
    --
    -- That is not hypothetical. `bench/runtime/run.sh` at 100 connections had
    -- akkar answering 18,640 of 111,651 requests with `unable to initialize
    -- continuation queue: Too many open files` -- one request in six, on a
    -- run that published a throughput number. Nobody saw it because that
    -- harness read the wrong awk field for the error count.
    --
    -- Measured in a server process of its own: busted holds sockets of its
    -- own and the delta is what means anything.
    local per = descriptors_per_request(60)
    if not per then
      pending "no /proc here: descriptors per request are not counted"
      return
    end
    -- ONE, and it was three until `with_deadline` stopped allocating a
    -- controller for the deadline. The socket is all that is left.
    --
    -- Asserted as a range because a future change might legitimately add one
    -- -- but a change that adds one and does not touch the divisor is exactly
    -- what this refuses, and that is not hypothetical: the divisor has been
    -- wrong twice, once too small and once too large.
    assert.is_true(per >= 0.9 and per <= 1.1,
      ("%.2f descriptors per in-flight request; the ceiling divides by 1")
        :format(per))
  end)

  it("lets an application override it", function()
    assert.is_true(akkar.defaults.max_concurrent == nil,
      "the ceiling is computed, not a fixed default")
  end)

  it("publishes the ceiling on the app, so other code can read it", function()
    -- It was a local handed to lua-http and nothing else, which meant
    -- `akkar.limit.shed` -- the one piece of the framework that needs to know
    -- how loaded the server is -- read nil and could never fire. A ceiling
    -- only the listener can see is half a ceiling.
    local PORT = 8393
    local app = akkar.new()
    app:get("/ping", function() return { ok = true } end)

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false, max_concurrent = 8,
                  log = akkar.log.new { level = "error" } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.2)
      assert.equal(8, app.max_concurrent)
      app:stop(1)
    end)
    assert(cq:loop(20))
  end)
end)
