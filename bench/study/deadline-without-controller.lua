-- Can a per-request deadline be had WITHOUT a per-request controller?
--
-- The research says yes and points at the C: `cqueues.poll` takes a bare
-- number as a deadline, and `object_getinfo` has an explicit
-- `/* optimize simple timeout */` branch that never touches the descriptor
-- path. The timeout lands in a `struct timer` EMBEDDED in `struct thread`, on
-- an LLRB tree -- no malloc, no descriptor, no userdata.
--
-- If that holds, akkar's `with_deadline` is paying an entire nested epoll
-- instance (2 descriptors, an allocation and a finaliser, per request) to
-- duplicate a red-black tree node cqueues would give it for nothing.
--
-- The catch, which akkar's own comment names: the handler has to run in a
-- coroutine something can stop waiting for. `cqueues.running()` returns the
-- controller we are ALREADY in, so the handler can be wrapped onto that one
-- instead of onto a fresh one.
local cqueues   = require "cqueues"
local condition = require "cqueues.condition"

local function own_pid()
  local f = assert(io.open "/proc/self/stat")
  local pid = f:read("a"):match "^(%d+)"
  f:close()
  return pid
end
local PID = own_pid()

local function fds()
  local p = io.popen("ls /proc/" .. PID .. "/fd 2>/dev/null | wc -l")
  local n = tonumber(p:read "l") or 0
  p:close()
  return n
end

-- --------------------------------------------------------------- today
local function with_controller(seconds, fn)
  local cq = cqueues.new()
  local winner, result
  cq:wrap(function()
    local ok, res = pcall(fn)
    if winner == nil then winner, result = ok and "COMPLETION" or "ERROR", res end
  end)
  cq:step(0)
  local deadline = cqueues.monotime() + seconds
  while winner == nil do
    local left = deadline - cqueues.monotime()
    if left <= 0 then break end
    cqueues.poll(cq, left)
    cq:step(0)
  end
  return winner or "TIMEOUT", result
end

-- ------------------------------------------------------------ proposed
local function with_number(seconds, fn)
  -- The controller we are ALREADY running in. No new one.
  local cq = assert(cqueues.running(), "must run inside a controller")
  local finished = condition.new()
  local winner, result
  cq:wrap(function()
    local ok, res = pcall(fn)
    if winner == nil then winner, result = ok and "COMPLETION" or "ERROR", res end
    finished:signal()
  end)
  -- A bare number in the poll list IS the deadline. No descriptor.
  cqueues.poll(finished, seconds)
  return winner or "TIMEOUT", result
end

local function check(label, fn)
  local outcomes, before, after = {}, nil, nil
  local cq = cqueues.new()
  cq:wrap(function()
    -- completes in time
    outcomes[1] = select(1, fn(1.0, function() return "done" end))
    -- overruns
    outcomes[2] = select(1, fn(0.05, function() cqueues.sleep(2) end))
    -- raises
    local ok, why = pcall(fn, 1.0, function() error("boom", 0) end)
    outcomes[3] = ok and select(1, why) or "RAISED"

    collectgarbage(); collectgarbage()
    before = fds()
    for _ = 1, 200 do fn(1.0, function() return true end) end
    after = fds()
  end)
  assert(cq:loop(30))
  print(("%-16s in time=%-11s overrun=%-9s raised=%-10s fds %d -> %d")
    :format(label, outcomes[1], outcomes[2], outcomes[3], before, after))

  collectgarbage(); collectgarbage()
  collectgarbage "stop"
  local cq2 = cqueues.new()
  local bytes
  cq2:wrap(function()
    for _ = 1, 200 do fn(1.0, function() return true end) end
    local b = collectgarbage "count"
    for _ = 1, 2000 do fn(1.0, function() return true end) end
    bytes = (collectgarbage "count" - b) * 1024 / 2000
  end)
  assert(cq2:loop(60))
  collectgarbage "restart"
  print(("%-16s %.0f bytes per call"):format("", bytes))
end

check("controller", with_controller)
check("bare number", with_number)
