-- What does akkar's own per-request coroutine cost?
--
-- `bench/study/COST-OF-A-REQUEST.md` puts the two per-request coroutines at
-- 6,283 bytes, 55% of a request's allocation and the largest single item left.
-- There are exactly two, and they are in different trees:
--
--   akkar/vendor/http/server.lua:476   cq:wrap(handle_stream, self, stream)
--   akkar/execution.lua                cq:wrap(...) inside `with_deadline`
--
-- This prices the SECOND one, which is the only one akkar owns. It is the
-- cheaper experiment by far, because `with_deadline` already has a branch
-- that skips the wrap entirely -- `seconds` nil or <= 0 runs the handler
-- inline and returns -- so the two arms differ by one number in the config
-- and nothing else in the tree.
--
-- WHAT THE INLINE ARM GIVES UP, so the number is read with it in view. The
-- wrap is what lets `cqueues.poll(finished, seconds)` arbitrate: with it, a
-- handler parked on I/O past its deadline is reported TIMEOUT while it is
-- still parked. Without it, the budget is still published -- `M.begin` runs
-- on both paths, and every capability refuses once it is negative -- but
-- nothing reports the timeout until the handler returns on its own.
--
-- So this is not a free saving on offer. It is the price of a feature,
-- measured, so the trade can be argued with a number on both sides.
--
-- Method is `spec/allocation_spec.lua`'s: collector stopped, a real server on
-- a real socket, keep-alive on one connection, warmed before counting.
package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local socket  = require "cqueues.socket"
local akkar   = require "akkar"

local N       = tonumber(os.getenv "N") or 600
local SAMPLES = tonumber(os.getenv "SAMPLES") or 3

local REQUEST = "GET /ping HTTP/1.1\r\nhost: x\r\nconnection: keep-alive\r\n\r\n"

--- Bytes per request through a real server, with `timeout` as given.
local function measure(port, timeout)
  local app = akkar.new()
  app:get("/ping", function() return { pong = true } end)

  local bytes
  local cq = cqueues.new()
  cq:wrap(function()
    pcall(function()
      app:run { port = port, check_capabilities = false, timeout = timeout,
                log = akkar.log.new { level = "error", sink = function() end } }
    end)
  end)
  cq:wrap(function()
    cqueues.sleep(0.2)
    local conn = assert(socket.connect("127.0.0.1", port))
    conn:setmode("bn", "bn")
    conn:onerror(function(_, _, why) return why end)

    local function round_trip()
      conn:write(REQUEST)
      conn:flush()
      repeat
        local line = conn:read "*l"
      until not line or line == "" or line == "\r"
      return conn:read(13)
    end

    -- Proves the arm actually served, rather than measuring a silent failure
    -- at zero cost per request. A harness that cannot fail is the mistake
    -- this study has made more than once.
    assert(round_trip() == '{"pong":true}', "the server did not answer")
    for _ = 1, 50 do round_trip() end

    collectgarbage(); collectgarbage()
    collectgarbage "stop"
    local before = collectgarbage "count"
    for _ = 1, N do round_trip() end
    local after = collectgarbage "count"
    collectgarbage "restart"
    bytes = (after - before) * 1024 / N

    conn:close()
    cqueues.sleep(0.1)
    app:stop(2)
  end)
  assert(cq:loop(60))
  return bytes
end

print(("akkar's per-request coroutine, %d requests per sample, %d samples")
  :format(N, SAMPLES))
print()

local port = 18700
local with, without = {}, {}
for i = 1, SAMPLES do
  -- ALTERNATED, not one arm then the other, so anything that drifts with time
  -- -- a growing heap, a warming cache -- lands on both arms rather than on
  -- whichever ran second.
  with[i]    = measure(port, 5); port = port + 1
  without[i] = measure(port, 0); port = port + 1
  print(("  sample %d   with deadline %8.0f B   inline %8.0f B   delta %+.0f")
    :format(i, with[i], without[i], with[i] - without[i]))
end

local function mean(t)
  local sum = 0
  for _, v in ipairs(t) do sum = sum + v end
  return sum / #t
end

local a, b = mean(with), mean(without)
print()
print(("  with the deadline coroutine   %8.0f B/request"):format(a))
print(("  handler inline, no wrap       %8.0f B/request"):format(b))
print(("  the coroutine costs           %8.0f B/request  (%.1f%%)")
  :format(a - b, (a - b) / a * 100))
