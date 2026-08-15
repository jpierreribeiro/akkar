--[[
akkar.jobs — the semantics of a job queue, with no storage in it.

The split follows `druse-crystals`, where `jobs` holds the logic and
`jobs_postgres` holds only persistence. Reading that code, the shape is
explicit: "a store reads it, hands it to `settle`, and writes back what it
gets."

`akkar.work.queue` had the two fused. The semantics of a job -- what one is,
what happens when a handler fails, what a worker loop does -- are logic, and
Redis was only where they happened to live. Fused, a Postgres-backed queue
could not exist without reimplementing the semantics alongside it, and the two
would then be free to disagree.

## What a store must provide

    store:enqueue(key, encoded)   -- append; returns the new depth
    store:dequeue(key, timeout)   -- oldest entry, or nil on timeout
    store:depth(key)              -- how many are waiting

Three methods, deliberately. Anything a job queue needs beyond that -- retries,
scheduling, dead letters -- is semantics and belongs here, not in a backend.

## What is deliberately absent

No retries with backoff, no scheduled jobs, no dead-letter queue, no
dashboard. Those are real needs and they are a different project. A failing
job is logged and dropped, because a retry policy nobody chose is worse than
none: it hides the failure and repeats whatever side effects already
happened.
]]

local cjson = require "cjson"

local Queue = {}
Queue.__index = Queue

local M = {}

--- Wraps a store with the queue semantics.
function M.new(store, name)
  for _, method in ipairs { "enqueue", "dequeue", "depth" } do
    if type(store[method]) ~= "function" then
      error("akkar.jobs: store does not satisfy the contract; missing :" ..
            method, 2)
    end
  end
  return setmetatable({
    store = store,
    key = "akkar:queue:" .. (name or "default"),
  }, Queue)
end

--- Enqueues a job.  Returns the depth after the push.
function Queue:push(kind, payload)
  return self.store:enqueue(self.key, cjson.encode {
    kind = kind,
    payload = payload,
    queued_at = os.time(),
  })
end

--- Waits for one job, up to `timeout` seconds.  Returns nil on timeout.
function Queue:pop(timeout)
  local encoded = self.store:dequeue(self.key, timeout or 5)
  if not encoded then return nil end
  local ok, job = pcall(cjson.decode, encoded)
  -- A job that cannot be decoded cannot be handled or retried, and leaving it
  -- at the head of the queue would stall every worker behind it forever.
  if not ok then return nil, "akkar.jobs: undecodable job discarded" end
  return job
end

function Queue:depth()
  return self.store:depth(self.key)
end

--- Consumes until `should_stop()` returns true.
function Queue:consume(handlers, options)
  options = options or {}
  local log = options.log
  local should_stop = options.should_stop or function() return false end
  local handled, failed = 0, 0

  while not should_stop() do
    local job, decode_error = self:pop(options.timeout or 1)
    if decode_error and log then
      log:warn("jobs: discarded an undecodable job")
    elseif job then
      local handler = handlers[job.kind]
      if not handler then
        if log then log:warn("jobs: no handler", { kind = job.kind }) end
      else
        local ok, err = pcall(handler, job.payload, job)
        if ok then
          handled = handled + 1
        else
          failed = failed + 1
          -- Logged and dropped.  A retry policy nobody chose hides the
          -- failure and repeats the side effects already committed.
          if log then
            log:error("jobs: job failed", { kind = job.kind, detail = tostring(err) })
          end
        end
      end
    end
  end

  return { handled = handled, failed = failed }
end

M.Queue = Queue
return M
