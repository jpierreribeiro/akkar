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

`queue` handles work that should not be in the request at all: a report, a
resized image, an email.  The handler enqueues and answers immediately; a
separate process does the work on a separate core.

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

--- Wraps a handler so its whole body runs with a yield budget.  Useful when
--- the expensive part is a library call you cannot thread a `yield` into but
--- which does return to Lua often.
function M.chunked(every)
  return function(fn)
    return function(...)
      local args = table.pack(...)
      return M.yielding(every, function() return fn(table.unpack(args, 1, args.n)) end)
    end
  end
end

-- ====================================================================== queue
-- A Redis list used as a job queue.  `LPUSH` to enqueue, `BRPOP` to consume,
-- which blocks server-side rather than polling -- and blocking there is free
-- for us, because the Redis adapter yields while it waits.
--
-- Deliberately not a job framework.  No retries with backoff, no scheduled
-- jobs, no dead-letter queue, no dashboard.  Those are real needs and they
-- are a separate project; what is here is the smallest thing that gets work
-- off the request path.
local Queue = {}
Queue.__index = Queue

function M.queue(cache, name)
  return setmetatable({ cache = cache, key = "akkar:queue:" .. (name or "default") }, Queue)
end

--- Enqueues a job.  Returns the queue depth after the push.
function Queue:push(kind, payload)
  return self.cache:command("LPUSH", self.key,
                            cjson.encode { kind = kind, payload = payload,
                                           queued_at = os.time() })
end

--- Waits for one job, up to `timeout` seconds.  Returns nil on timeout.
--- The wait yields, so a worker parked here does not stall its own process.
function Queue:pop(timeout)
  local reply = self.cache:command("BRPOP", self.key, timeout or 5)
  if not reply or type(reply) ~= "table" then return nil end
  local ok, job = pcall(cjson.decode, reply[2])
  if not ok then return nil, "queue: undecodable job discarded" end
  return job
end

function Queue:depth()
  return self.cache:command("LLEN", self.key)
end

--- Consumes jobs until `should_stop()` returns true.
---
--- A failing job is logged and dropped rather than retried, because a retry
--- policy nobody chose is worse than no retry policy: it hides the failure
--- and repeats the side effects.
function Queue:consume(handlers, options)
  options = options or {}
  local log = options.log
  local should_stop = options.should_stop or function() return false end

  while not should_stop() do
    local job = self:pop(options.timeout or 1)
    if job then
      local handler = handlers[job.kind]
      if not handler then
        if log then log:warn("queue: no handler", { kind = job.kind }) end
      else
        local ok, err = pcall(handler, job.payload)
        if not ok and log then
          log:error("queue: job failed", { kind = job.kind, detail = tostring(err) })
        end
      end
    end
  end
end

M.Queue = Queue
return M
