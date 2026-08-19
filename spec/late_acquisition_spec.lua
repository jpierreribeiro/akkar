--[[
A capability acquired after its execution was already over.

## The defect, and how it was found

`spec/simulation_spec.lua` -- the machine-checked invariant from L1 -- went red
on CI twice, on runners slower than any machine here: `live=4 idle=1
reserved=0`. Pool resources checked out and never returned, with no reservation
for `Pool:reap` to recover, because reaping recovers slots held while a
resource is being OPENED and these were already open.

It reproduced on no local machine. Thirty runs of the failing seed, deadline
budgets from 20 ms down to 0.1 ms, pool sizes down to a single slot, and the
collector stopped outright so no finaliser could run: all clean. What found it
was reading the acquisition path instead.

## The mechanism

`execution.release` is called from exactly one place -- `dispatch`, once, when
the handler is done -- and it clears `record.released`.

`M.acquire` calls `provided()`, and **`provided()` is allowed to yield**:
opening a connection, or waiting for a pool slot. If the deadline fires while
it is yielding, the 503 goes out, dispatch runs the release, and dispatch
RETURNS. The handler's coroutine is resumed later, receives its resource,
appends it to a freshly created list -- and nothing will ever call release
again.

One leaked resource per request abandoned while acquiring. Self-reinforcing in
the way `akkar/pool.lua` records from the study box: each leaked slot lengthens
the wait, and a longer wait abandons more handlers inside it.

## Why it is a spec of its own

`spec/simulation_spec.lua` finds this only when the machine is slow enough for
the race to open. Reproducing it on purpose needs no pool and no luck -- a
capability that takes longer to open than the budget allows is the whole race,
and that is deterministic on any machine.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"

local quiet = function()
  return akkar.log.new { level = "error", sink = function() end }
end

--- Drives one request whose capability takes `open_for` seconds to open,
--- against a `budget`-second deadline, and reports what was opened and what
--- came back.
local function run(open_for, budget)
  local opened, released = 0, 0

  local app = akkar.new()
  app:get("/q", function(req)
    local _ = req.db                      -- forces the acquisition
    return { ok = true }
  end)

  local client = app:test {
    db = function()
      opened = opened + 1
      cqueues.sleep(open_for)
      return {
        release = function() released = released + 1 end,
        many = function() return {} end,
      }
    end,
    log = quiet(),
  }

  local status
  local cq = cqueues.new()
  cq:wrap(function()
    local ok, res = pcall(function()
      return client:get("/q", { timeout = budget })
    end)
    status = ok and res.status or tostring(res)
  end)
  assert(cq:loop(10))

  -- The same settling the simulation spec learned to do: collect, then let
  -- the loop run once more, so this measures the defect rather than the
  -- moment. Without it a release that was merely SCHEDULED reads as a leak.
  collectgarbage(); collectgarbage()
  cq:loop(1)

  return opened, released, status
end

describe("a capability that finishes opening after the deadline", function()
  it("is released, not leaked", function()
    -- Opening takes five times the budget, so the deadline is guaranteed to
    -- fire while `provided()` is still yielding. Before the fix this was
    -- opened once and released zero times, on every machine, every run.
    local opened, released, status = run(0.1, 0.02)

    assert.equal(1, opened,
      "the capability was never opened, so nothing was staged")
    assert.equal(503, status,
      ("expected the deadline to answer 503, got %s"):format(tostring(status)))
    assert.equal(opened, released,
      ("opened %d, released %d: a resource acquired after the execution ended "
       .. "was never given back"):format(opened, released))
  end)

  it("still releases normally when it opens in time", function()
    -- The guard must not have turned every release into an early one: a
    -- capability that opens well inside its budget goes through the ordinary
    -- registered path, and this fails if `record.over` were ever set too soon.
    local opened, released, status = run(0.01, 1)

    assert.equal(1, opened)
    assert.equal(200, status)
    assert.equal(1, released)
  end)

  it("releases every capability, not only the first", function()
    -- The list is what release walks; the early path is per capability. Two
    -- releasable capabilities, both opened past the deadline, must both come
    -- back -- otherwise the fix trades a leak of many for a leak of one.
    local opened, released = 0, 0

    local app = akkar.new()
    app:get("/q", function(req)
      local _, _ = req.db, req.cache
      return { ok = true }
    end)

    local function slow_capability()
      opened = opened + 1
      cqueues.sleep(0.1)
      return {
        release = function() released = released + 1 end,
        many = function() return {} end,
        get = function() return nil end,
        set = function() return true end,
      }
    end

    local client = app:test {
      db = slow_capability, cache = slow_capability, log = quiet(),
    }

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function() return client:get("/q", { timeout = 0.02 }) end)
    end)
    assert(cq:loop(10))
    collectgarbage(); collectgarbage()
    cq:loop(1)

    assert.is_true(opened >= 1, "nothing was opened")
    assert.equal(opened, released,
      ("opened %d, released %d"):format(opened, released))
  end)
end)
