--[[
The disk filling while logs are being written — `docs/UNKNOWNS.md` §3.

`akkar/log.lua` is 175 lines and the whole of its output is one of them:

    self.sink(line .. "\n")                                   -- log.lua:138

with the default sink two lines further down:

    sink = options.sink or function(line) io.stderr:write(line) end

Nothing reads what `write` returned, and nothing guards what the sink did. So
this file asks the two questions that follow from those two lines, and they
have opposite answers.

## ENOSPC is induced with `/dev/full`, and it needs no privileges

Every write to `/dev/full` returns `ENOSPC`. No mount, no `sudo`, no loopback
image, and it is the same errno a real full filesystem produces:

    f:write("hello\n")  ->  nil  "No space left on device"  28

## 1. The default sink loses the line, silently and completely — a defect

`io.stderr:write` does not raise; it returns `nil, err, errno`, and
`log.lua:138` discards all three. On a full disk akkar keeps answering
requests at 200 with every log line going nowhere, and there is no counter, no
flag, no fallback and no line on any other stream saying so. The logger's
fields after the loss are `bound, format, level, sink` — exactly what they
were before.

The module's own comment two dozen lines up says

    -- ... because a log line that quietly loses a field is worse than an
    -- ugly one.

and the module quietly loses the whole line. This is the incident where the
logs matter most — §8 of `docs/UNKNOWNS.md` is "observability during an
incident" — and it is the incident where there are none.

Buffering makes it worse and akkar does not set any: `io.stderr` is unbuffered
by C convention, so the default sink at least *could* have noticed. A file
sink — `sink = function(l) f:write(l) end` over an opened log file — is FULLY
buffered, because it is not a tty. Measured below: the write returns the file
handle, success, and `ENOSPC` surfaces at a `flush` that `akkar/log.lua`
never calls and that the caller cannot associate with any line.

## 2. A sink that REPORTS the failure wedges the shutdown — a defect

Checking the write is the only way to notice a full disk, so it is what
anybody who reads §3 of `UNKNOWNS.md` would write:

    sink = function(line) assert(file:write(line)) end

Inside a handler that is contained: `akkar/init.lua` xpcalls the chain, so the
raise becomes a 500 and the server carries on. Asserted below, and a verified
non-issue.

`App:stop` is not contained. Its first statement is

    internal:info("shutdown: no longer accepting connections")     -- 2924

and it is the ONLY statement in that function that is not wrapped: `pcall`
guards `server:pause()`, every websocket close, every closer, and
`server:close()`. So the log line raises, and the shutdown never happens —
measured:

    state before app:stop  RUNNING
    app:stop raised        ENOSPC: no space left on device
    state after            STOP_ACCEPTING
    app:stop again         STOP_ACCEPTING   (did nothing)
    state final            STOP_ACCEPTING

The listener was never paused, the drain never ran, `self.closers` never ran
so the database and Redis pools were never closed, and the server socket was
never closed. And it is PERMANENT: `App:stop` opens with
`if self.state ~= "RUNNING" then return self.state end`, so calling it again
— even after the disk is emptied — returns immediately. One log line on a
full disk turns a graceful shutdown into a server that is neither serving nor
stopping.

`App:handle_signals` is the same shape and is the path a container actually
takes:

    listener:wait()
    internal:info("signal received")     -- unguarded, raises here
    app:stop()                           -- never reached

so on a full disk SIGTERM does not drain; it kills the coroutine before
`App:stop` is even called.

## What a fix looks like

`log.lua:138` guarding the sink and counting what it dropped — the process
notices, the request path is unchanged, and `App:stop` cannot be taken down by
its own logging. The count is the part that matters: "dropped 41 200 lines"
on the first line that gets through is the difference between an outage that
explains itself and one that does not.

Not carried here: this branch is shared and green, and `log.lua` swallowing a
sink's error is a contract change other files assert against. The assertions
below therefore state the CURRENT behaviour, each one marked, so that when the
guard lands they invert into the regression test.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local akkar   = require "akkar"
local log     = require "akkar.log"

--- A real ENOSPC, or nil where the kernel does not offer one.
---
--- `/dev/full` is Linux. Checked by WRITING rather than by `uname`, for the
--- reason `spec/support/portable.lua` gives at length: the question is
--- whether the write fails, and asking it directly is cheaper and truer than
--- guessing from the platform name.
local function open_full()
  local file = io.open("/dev/full", "w")
  if not file then return nil end
  file:setvbuf "no"
  local ok = file:write "probe\n"
  if ok then file:close(); return nil end     -- writable: not a /dev/full
  return file
end

local FULL = open_full()

if not FULL then
  describe("akkar.log on a full disk", function()
    pending "/dev/full is not available here; skipping"
  end)
  return
end

describe("akkar.log on a full disk", function()
  it("gets ENOSPC from the write, unbuffered", function()
    -- The premise, checked rather than assumed. Everything below is only
    -- about a full disk if this errno is the one a full disk gives.
    local ok, why, errno = FULL:write "one line\n"
    assert.is_nil(ok)
    assert.equal(28, errno)
    assert.is_truthy(tostring(why):lower():find("no space", 1, true))
  end)

  -- THE DEFECT. `log.lua:138` discards the return, so the line is gone and
  -- nothing anywhere records that it was.
  --
  -- INVERT THIS WHEN THE SINK IS GUARDED: `logger.dropped` becomes 1.
  it("loses the line without raising and without counting it", function()
    local logger = log.new { sink = function(line) FULL:write(line) end }

    local ok, err = pcall(function()
      logger:info("charged", { account_id = 7, amount = 10 })
    end)
    assert.is_true(ok, "the write failing raised: " .. tostring(err))
    assert.is_nil(err)

    -- Nothing on the logger changed, so nothing downstream can tell.
    local fields = {}
    for key in pairs(logger) do fields[#fields + 1] = key end
    table.sort(fields)
    assert.equal("bound,format,level,sink", table.concat(fields, ","))
  end)

  -- Point 4 of the brief, and the worse half of it: with a FILE sink the
  -- write does not even fail. It succeeds into a buffer that will never
  -- reach the disk, and the errno arrives at a `flush` nobody calls.
  it("does not even see ENOSPC through a buffered file sink", function()
    local buffered = assert(io.open("/dev/full", "w"))   -- default: full buffering

    local seen
    local logger = log.new { sink = function(line) seen = { buffered:write(line) } end }
    logger:info "this line is already lost"

    -- The sink was told the write succeeded.
    assert.is_truthy(seen[1], "expected the buffered write to report success")

    -- And here is where it actually failed -- at a call `akkar/log.lua` never
    -- makes, with no line to attach the failure to.
    local ok, why, errno = buffered:flush()
    assert.is_nil(ok)
    assert.equal(28, errno)
    assert.is_truthy(tostring(why):lower():find("no space", 1, true))
    buffered:close()
  end)

  it("keeps answering requests at 200 while every line goes nowhere", function()
    -- The shape of the outage: nothing is broken, nothing is slow, and there
    -- is no record of any of it.
    local logger = log.new { sink = function(line) FULL:write(line) end }
    local app = akkar.new()
    app:get("/charge", function(req)
      req.log:info("charged", { amount = 10 })
      return { ok = true }
    end)

    local res = app:test { log = logger } :get "/charge"
    assert.equal(200, res.status)
    assert.is_true(res.body.ok)
  end)
end)

describe("a log sink that reports ENOSPC instead of swallowing it", function()
  -- `assert(f:write(line))` is the only sink that can notice a full disk, so
  -- it is the sink this section is about. What akkar does with a sink that
  -- raises is the same question whatever made it raise.

  it("is contained inside a handler: the request 500s, the server lives",
     function()
    local logger = log.new { sink = function(line) assert(FULL:write(line)) end }
    local app = akkar.new()
    app:get("/charge", function(req)
      req.log:info "charged"
      return { ok = true }
    end)

    local res = app:test { log = logger } :get "/charge"
    assert.equal(500, res.status)

    -- And the next request still works, which is what "contained" has to
    -- mean. Verified non-issue.
    local again = app:test { log = log.new { sink = function() end } } :get "/charge"
    assert.equal(200, again.status)
  end)

  -- THE DEFECT. `App:stop` pcalls everything except the line that talks.
  --
  -- INVERT THIS WHEN `log.lua:138` IS GUARDED: `stopped` becomes true and
  -- `state_after` becomes "STOPPED".
  it("takes the whole shutdown down from App:stop's first statement", function()
    local armed = false
    -- Disarmed it writes to stderr, so replacing akkar's `internal` voice for
    -- the rest of this process does not silence anything.
    local logger = log.new { sink = function(line)
      if armed then error("ENOSPC: no space left on device", 0) end
      io.stderr:write(line)
    end }

    local app = akkar.new()
    app:get("/", function() return { ok = true } end)

    local seen = {}
    local cq = cqueues.new()

    cq:wrap(function()
      pcall(function()
        app:run { port = 18993, check_capabilities = false, shutdown_grace = 1,
                  log = logger }
      end)
    end)

    cq:wrap(function()
      while app.state ~= "RUNNING" do cqueues.sleep(0.01) end
      seen.state_before = app.state

      armed = true                                   -- the disk fills here
      seen.stopped, seen.raised = pcall(function() return app:stop(1) end)
      seen.state_after = app.state

      armed = false                                  -- the disk is emptied
      -- Asking again is what an operator, or a supervisor, would do next.
      seen.second = select(2, pcall(function() return app:stop(1) end))
      seen.state_final = app.state
    end)

    assert(cq:loop(20))

    assert.equal("RUNNING", seen.state_before)

    -- The shutdown raised, out of its own first line.
    assert.is_false(seen.stopped)
    assert.is_truthy(tostring(seen.raised):find("ENOSPC", 1, true))

    -- It got no further than setting the state. The listener was never
    -- paused, nothing was drained, and `self.closers` -- the database and
    -- Redis pools -- were never closed.
    assert.equal("STOP_ACCEPTING", seen.state_after)

    -- AND IT IS PERMANENT. `App:stop` returns early on any state that is not
    -- RUNNING, so the retry after the disk was emptied did nothing at all.
    assert.equal("STOP_ACCEPTING", seen.second)
    assert.equal("STOP_ACCEPTING", seen.state_final)
  end)
end)
