--[[
akkar.work: cooperative yielding and the Redis-backed queue.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local akkar   = require "akkar"
local work    = require "akkar.work"
local redis   = require "akkar.redis"

describe("cooperative yielding", function()
  it("lets another coroutine interleave with a long loop", function()
    local order = {}
    local cq = cqueues.new()

    cq:wrap(function()
      work.yielding(100, function(yield)
        for i = 1, 1000 do
          if i == 1 then order[#order + 1] = "long started" end
          yield()
        end
      end)
      order[#order + 1] = "long finished"
    end)

    cq:wrap(function()
      cqueues.poll(0)
      order[#order + 1] = "short ran"
    end)

    assert(cq:loop(5))
    -- Without the yield the short coroutine would only run after the loop.
    assert.same({ "long started", "short ran", "long finished" }, order)
  end)

  it("returns whatever the wrapped function returns", function()
    local total = work.yielding(10, function(yield)
      local sum = 0
      for i = 1, 100 do sum = sum + i yield() end
      return sum
    end)
    assert.equal(5050, total)
  end)

  it("yields on a budget, not on every iteration", function()
    -- Counting cqueues.poll calls directly would be measuring the library:
    -- one poll re-enters through the module table and registers twice.  What
    -- matters is observable anyway -- how often other work gets a turn.
    local function turns_given(every, iterations)
      local turns = 0
      local cq = cqueues.new()
      local done = false
      cq:wrap(function()
        work.yielding(every, function(yield)
          for _ = 1, iterations do yield() end
        end)
        done = true
      end)
      cq:wrap(function()
        while not done do turns = turns + 1 cqueues.poll(0) end
      end)
      assert(cq:loop(10))
      return turns
    end

    local coarse = turns_given(100, 1000)
    local fine   = turns_given(10,  1000)

    -- A tighter budget hands out more turns; both are far below one per item,
    -- which would cost more than the work itself.
    assert.is_true(fine > coarse)
    assert.is_true(coarse < 100)
  end)
end)

-- ---------------------------------------------------------------------------

local function redis_reachable()
  -- PING, not merely connect. `cqueues.socket.connect` builds the socket
  -- lazily and touches the network on first use, so `pcall` around the
  -- factory returns TRUE with nothing listening -- every Redis skip guard in
  -- this suite was decorative, and only looked correct because a developer's
  -- machine always had Redis running. CI's no-services job found it on its
  -- first run.
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if not ok then return false end
  local alive = pcall(function() return conn:ping() end)
  conn:close()
  return alive
end

if not redis_reachable() then
  describe("akkar.work queue (integration)", function()
    pending("Redis is not reachable on 127.0.0.1:6379; skipping")
  end)
  return
end

describe("the job queue", function()
  local cache, queue

  before_each(function()
    cache = redis.connect { pool_size = 0 }()
    queue = work.queue(cache, "spec")
    cache:del "akkar:queue:spec"
  end)
  after_each(function()
    if cache then cache:del "akkar:queue:spec" cache:close() end
  end)

  it("round-trips a job through Redis", function()
    queue:push("send_email", { to = "ada@example.com", subject = "hi" })
    assert.equal(1, queue:depth())

    local job = queue:pop(1)
    assert.equal("send_email", job.kind)
    assert.equal("ada@example.com", job.payload.to)
    assert.is_number(job.queued_at)
    assert.equal(0, queue:depth())
  end)

  it("returns nil on timeout rather than hanging", function()
    assert.is_nil(queue:pop(1))
  end)

  it("consumes in FIFO order", function()
    for i = 1, 3 do queue:push("n", { i = i }) end
    local seen = {}
    for _ = 1, 3 do seen[#seen + 1] = queue:pop(1).payload.i end
    assert.same({ 1, 2, 3 }, seen)
  end)

  it("runs the matching handler and keeps going after one fails", function()
    queue:push("boom", {})
    queue:push("ok", { value = 7 })

    local got, failures = nil, {}
    local handlers = {
      boom = function() error "handler exploded" end,
      ok   = function(payload) got = payload.value end,
    }
    local remaining = 2
    queue:consume(handlers, {
      timeout = 1,
      log = { warn = function() end,
              error = function(_, _, fields) failures[#failures + 1] = fields end },
      should_stop = function()
        remaining = remaining - 1
        return remaining < 0
      end,
    })

    -- A failing job must not take the worker down with it.
    assert.equal(7, got)
    assert.equal(1, #failures)
  end)
end)

describe("offloading from a handler", function()
  it("answers immediately and leaves the work on the queue", function()
    -- The shape a handler uses: enqueue, return 202, let a worker do it.
    local pushed = {}
    local fake_cache = {
      get = function() end, set = function() end, del = function() end,
      command = function(_, _, _, encoded) pushed[#pushed + 1] = encoded return 1 end,
    }

    local app = akkar.new()
    app:post("/reports", function(req)
      work.queue(req.cache, "reports"):push("build_report", { user = 1 })
      return akkar.response(202, { status = "queued" })
    end)

    local res = app:test { cache = fake_cache }:post("/reports", { body = {} })
    assert.equal(202, res.status)
    assert.equal(1, #pushed)
  end)
end)
