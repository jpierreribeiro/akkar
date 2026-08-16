--[[
akkar.time — the clock the framework reads.

## Why this exists

`clock` has been in akkar's capability set since the beginning, and the
framework read none of it. The deadline, the blocking watchdog, the shutdown
grace period, the metrics uptime, the job queue's due times and every log line
called `cqueues.monotime()` or `os.time()` directly. So `req.clock` was a slot
an application could fill and nothing in akkar would notice.

The cost of that is visible in the suite: every test about a deadline, a
retry backoff or a scheduled job has to SLEEP. `spec/abandoned_spec.lua` waits
2.2 seconds in one place and 1.2 in another, and it waits because there is no
other way to make time pass. Slow tests are the smaller half; the larger half
is that a behaviour you can only observe by waiting is a behaviour you cannot
assert precisely.

## What a manual clock does, and what it does NOT do

It moves **timestamps and budgets**. `monotime()` and `now()` answer whatever
`advance` has made true, so a ttl can expire, a backoff can come due and an
uptime can be a year, all without waiting.

It does **not** move the event loop. `cqueues.poll` still waits on real file
descriptors for real milliseconds, and a socket read still takes as long as
the peer takes. Making time virtual *inside* the scheduler would mean writing
a second scheduler, which is a bigger project than everything it would test.

The consequence, stated so nobody discovers it: a manual clock is a tool for
proving what happens **after** a deadline or a ttl, never for proving how two
things race. Integration specs keep the real clock, because what they test is
what a real protocol does.
]]

local cqueues = require "cqueues"

local M = {}

--- The real one: monotonic for budgets, wall-clock for timestamps.
---
--- Two clocks rather than one, because they answer different questions. A
--- deadline measured against wall time breaks when NTP steps the clock; a
--- log line stamped with monotonic time is meaningless to a reader.
local real = {
  monotime = cqueues.monotime,
  now      = os.time,
  sleep    = cqueues.sleep,
}

M.real = real

local current = real

function M.monotime() return current.monotime() end
function M.now()      return current.now()      end
function M.sleep(s)   return current.sleep(s)   end

--- Installs a clock, and returns the function that puts the previous one back.
---
--- Process-wide by design, and that is a real limitation: two tests running
--- concurrently against different clocks would see each other. The suite runs
--- one spec at a time, and the restore function is what keeps it that way.
function M.set(clock)
  local previous = current
  current = clock or real
  return function() current = previous end
end

--- A clock that only moves when told.
---
---     local clock = akkar.time.manual { now = 1755000000 }
---     local restore = akkar.time.set(clock)
---     clock:advance(3600)          -- an hour passed; nothing waited
---     restore()
function M.manual(options)
  options = options or {}
  local clock = {
    _mono = options.monotime or 0,
    _wall = options.now or 1755000000,
  }

  function clock.monotime() return clock._mono end
  function clock.now()      return clock._wall end

  --- Sleeping under a manual clock advances it and returns immediately.
  --- Anything that genuinely needs to wait for I/O must not be using this.
  function clock.sleep(seconds)
    clock:advance(seconds or 0)
  end

  function clock:advance(seconds)
    seconds = seconds or 0
    self._mono = self._mono + seconds
    self._wall = self._wall + seconds
    return self
  end

  return clock
end

return M
