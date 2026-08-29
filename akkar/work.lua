--[[
akkar.work — two answers to CPU-bound work, and an honest account of what
neither of them fixes.

The problem is structural.  One process runs one Lua VM on one core with a
cooperative scheduler.  A handler that computes for 250 ms stalls every other
request for 250 ms.  The watchdog reports this; it does not solve it.

`yielding` handles the case you control: a Lua loop over rows, a CSV being
built, a large table being walked.  Yielding periodically turns one long stall
into many short ones, so other requests interleave.

The trade is real and it is not free.  Measured on a ~200 ms loop:

    budget            the task itself      worst neighbour wait
    no yielding                202 ms                  200.5 ms
    every 50000                520 ms                   28.7 ms
    every 2000                 557 ms                    0.9 ms

Neighbour latency falls by two orders of magnitude and the task gets roughly
2.7x SLOWER, because each yield costs a trip through the scheduler.  Pick the
budget accordingly: coarse when the task matters more than the neighbours,
fine when the opposite.  A claim that this is free would be wrong, and the
first person to benchmark it would find out.

For work that should not be in the request at all -- a report, a resized
image, an email -- see `akkar.jobs`.  The handler enqueues and answers
immediately; a separate process does the work on a separate core.

**Neither fixes bcrypt.**  A C function that runs for 250 ms without returning
to Lua cannot be yielded, because there is no point at which Lua regains
control.  The real answers there are: run N processes so one blocked worker
is 1/N of capacity, lower the cost factor knowingly, or move authentication
behind the queue and change what the endpoint promises.  Saying so is worth
more than a helper that appears to solve it.
]]

local cqueues = require "cqueues"
local cjson   = require "cjson"

local M = {}

--- Runs `fn(yield)` where calling `yield()` gives the scheduler a turn once
--- every `every` calls.
---
--- The counter is inside the helper so the caller writes `yield()` in the
--- loop body and does not maintain a modulo.
---
---     akkar.work.yielding(500, function(yield)
---       for _, row in ipairs(rows) do
---         out[#out + 1] = render(row)
---         yield()
---       end
---     end)
function M.yielding(every, fn)
  every = every or 500
  local count = 0
  return fn(function()
    count = count + 1
    if count % every == 0 then cqueues.poll(0) end
  end)
end

--- Wraps a handler so it is HANDED a yield, as a trailing argument, without
--- having to build the counter itself.
---
---     app:get("/report", akkar.work.chunked(500)(function(req, yield)
---       for _, row in ipairs(rows) do
---         out[#out + 1] = render(row)
---         yield()
---       end
---       return out
---     end))
---
--- It used to be an identity wrapper. The inner closure took no argument and
--- so never called the yield function `yielding` handed it, which made
--- `chunked(10)` over a million iterations produce **zero** scheduler trips
--- while documenting itself as "wraps a handler so its whole body runs with a
--- yield budget". A wrapper that measurably does nothing is worse than no
--- wrapper: someone reads the call site and stops looking.
---
--- The old claim -- a yield budget over a body that does not cooperate --
--- cannot be honoured, and this module already says why: there is no point at
--- which Lua regains control inside a C call that does not return. So the
--- handler is given the yield and decides where a turn is safe to take.
function M.chunked(every)
  return function(fn)
    return function(...)
      local args = table.pack(...)
      return M.yielding(every, function(yield)
        args[args.n + 1] = yield
        args.n = args.n + 1
        return fn(table.unpack(args, 1, args.n))
      end)
    end
  end
end

-- ====================================================================== queue
-- The queue moved to `akkar.jobs`, where the semantics are separated from the
-- storage: `akkar.jobs.redis` and `akkar.jobs.memory` are stores, and the
-- rules about what a job is and what happens when one fails live in one place
-- that both share.
--
-- `work.queue(cache, name)` still works and forwards, so nothing written
-- against it breaks.
function M.queue(cache, name)
  return require("akkar.jobs.redis").new(cache, name)
end

return M
