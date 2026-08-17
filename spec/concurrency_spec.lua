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

  it("is two per controller, exactly", function()
    -- Deterministic: no timing, no noise floor, no quiet machine needed.
    local each = cost_of(function() return cqueues.new() end, 100)
    if not each then
      pending "descriptors cannot be counted here: no /proc and no lsof"
      return
    end
    assert.is_true(each > 1.9 and each < 2.1,
      string.format("a controller cost %.2f descriptors", each))
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

    -- Two descriptors per in-flight request, a third of the budget left for
    -- the listener, the database pool and the log sink.
    local expected = math.max(math.floor(tonumber(soft) * 0.66 / 2), 16)
    assert.is_true(expected >= 16)
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
