--[[
The disk filling while logs are being written — `docs/UNKNOWNS.md` §3.

This lens originally found two defects. `io.stderr:write` reports ENOSPC as
`nil, reason, errno`, but the default sink discarded those returns. A custom
sink that raised did get noticed, but could turn a request into a 500 and stop
`App:stop` on its first diagnostic line, leaving the process permanently in
`STOP_ACCEPTING`.

The sink boundary is now guarded. A returned failure or a raise increments a
counter shared by the root logger and every request-bound logger; it cannot
escape into the request or shutdown. On the first later successful write the
logger emits `log sink recovered` with the dropped count and clears it.
`spec/log_delivery_spec.lua` proves those rules without a platform device;
this file proves them against the kernel's real `/dev/full` and through a real
shutdown listener.

One limit remains and is stated rather than hidden: a user-supplied BUFFERED
file sink can report success and encounter ENOSPC only on a later `flush`.
An opaque callback gives akkar no handle to flush, so a file sink must itself
flush and return or raise its failure. The default stderr sink is unbuffered
and preserves all three return values.
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

  it("counts a line refused with ENOSPC without raising", function()
    local logger = log.new {
      sink = function(line) return FULL:write(line) end,
    }

    local ok, err = pcall(function()
      logger:info("charged", { account_id = 7, amount = 10 })
    end)
    assert.is_true(ok, "the write failing raised: " .. tostring(err))
    assert.is_nil(err)

    assert.equal(1, logger:stats().dropped)
    assert.is_truthy(logger:stats().last_error:lower():find("no space", 1, true))

    -- Delivery state lives beside the shared sink rather than making every
    -- request-bound logger larger.
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

  it("keeps answering requests and exposes how many lines were lost", function()
    local logger = log.new {
      sink = function(line) return FULL:write(line) end,
    }
    local app = akkar.new()
    app:get("/charge", function(req)
      req.log:info("charged", { amount = 10 })
      return { ok = true }
    end)

    local res = app:test { log = logger } :get "/charge"
    assert.equal(200, res.status)
    assert.is_true(res.body.ok)
    assert.equal(1, logger:stats().dropped)
  end)
end)

describe("a log sink that reports ENOSPC instead of swallowing it", function()
  -- `assert(f:write(line))` is the only sink that can notice a full disk, so
  -- it is the sink this section is about. What akkar does with a sink that
  -- raises is the same question whatever made it raise.

  it("is contained inside a handler without changing the response",
     function()
    local logger = log.new { sink = function(line) assert(FULL:write(line)) end }
    local app = akkar.new()
    app:get("/charge", function(req)
      req.log:info "charged"
      return { ok = true }
    end)

    local res = app:test { log = logger } :get "/charge"
    assert.equal(200, res.status)
    assert.equal(1, logger:stats().dropped)

    -- And the next request still works, which is what "contained" has to
    -- mean. Verified non-issue.
    local again = app:test { log = log.new { sink = function() end } } :get "/charge"
    assert.equal(200, again.status)
  end)

  it("cannot take shutdown down from App:stop's own log lines", function()
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

    assert.is_true(seen.stopped, tostring(seen.raised))
    assert.equal("STOPPED", seen.raised)
    assert.equal("STOPPED", seen.state_after)

    -- A repeated stop stays idempotent after the disk is writable again.
    assert.equal("STOPPED", seen.second)
    assert.equal("STOPPED", seen.state_final)
    assert.is_true(logger:stats().dropped > 0)
  end)
end)
