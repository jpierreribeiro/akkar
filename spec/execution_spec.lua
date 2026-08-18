--[[
The execution machinery, with no app and no HTTP anywhere in this file.

That is the point of it. `akkar/execution.lua` was extracted from
`handle(app, input)` in `akkar/init.lua`, where identity, deadline, lazily
acquired capabilities and guaranteed release existed only as local state inside
one function reachable only by an HTTP request. The measured consequence was
that `app:task` receives `{ name, stopping, app }` and nothing else, so anyone
writing a worker closes over their own connection -- outside the closed
capability set that is half the framework's argument.

A test that needed `akkar.new()` to exercise any of this would prove the
extraction had not happened. Nothing below requires `akkar`.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues   = require "cqueues"
local execution = require "akkar.execution"
local log       = require "akkar.log"

-- Every execution needs somewhere to fall back to for `log`, which `App:run`
-- normally supplies. Set once here so these tests do not depend on init.lua
-- having been loaded.
execution.default_log(log.new { level = "error", sink = function() end })

--- A carrier and a record, which is all an execution is made of.
---
--- The record is a table the caller already has -- in HTTP it is the server's
--- `input`. There is deliberately no scope object: one costs 152 bytes
--- against 169 of headroom under the allocation ceiling.
local function new_execution(capabilities)
  local record  = { capabilities = capabilities }
  local carrier = setmetatable({ id = "test-1" }, {
    __index = function(self, key)
      return execution.acquire(self, record, key)
    end,
  })
  return carrier, record
end

describe("capabilities", function()
  it("are acquired on first read, not before", function()
    local opened = 0
    local carrier = new_execution {
      db = function() opened = opened + 1 return { one = function() end } end,
    }
    assert.equal(0, opened, "a capability was opened before anything read it")
    local _ = carrier.db
    assert.equal(1, opened)
  end)

  it("are acquired once, however many times they are read", function()
    local opened = 0
    local carrier = new_execution {
      db = function() opened = opened + 1 return { n = opened } end,
    }
    local a, b, c = carrier.db, carrier.db, carrier.db
    assert.equal(1, opened, "the factory ran more than once")
    assert.equal(a, b)
    assert.equal(b, c)
  end)

  it("read as a guard when they were never configured", function()
    local carrier = new_execution {}
    local db = carrier.db
    assert.is_not_nil(db, "an unconfigured capability read as nil")

    -- The guard's whole job: say what is missing instead of "attempt to index
    -- a nil value".
    local ok, err = pcall(function() return db:one "select 1" end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("req.db is not configured", 1, true),
      "the guard did not name the missing capability: " .. tostring(err))
  end)

  it("refuse a write onto a guard, because guards are shared", function()
    -- Without `__newindex`, `req.user.id = 1` on an unauthenticated request
    -- would write into an object every other request also holds.
    local carrier = new_execution {}
    local ok = pcall(function() carrier.cache.anything = 1 end)
    assert.is_false(ok)
  end)

  it("leave anything outside the closed set alone", function()
    local carrier = new_execution { db = function() return {} end }
    assert.is_nil(carrier.mailer)
    assert.is_nil(carrier.payments)
  end)

  it("pass a non-callable capability through untouched", function()
    local fake = { one = function() return { n = 1 } end }
    local carrier = new_execution { db = fake }
    assert.equal(fake, carrier.db)
  end)
end)

describe("release", function()
  it("frees what was acquired", function()
    local freed = 0
    local carrier, record = new_execution {
      db = function() return { release = function() freed = freed + 1 end } end,
    }
    local _ = carrier.db
    execution.release(record)
    assert.equal(1, freed)
  end)

  it("is idempotent, which a worker loop needs and a request never did", function()
    -- `handle` called this from exactly one place, so a double release could
    -- not happen. A worker calling it per job can.
    local freed = 0
    local carrier, record = new_execution {
      db = function() return { release = function() freed = freed + 1 end } end,
    }
    local _ = carrier.db
    execution.release(record)
    execution.release(record)
    execution.release(record)
    assert.equal(1, freed, "released more than once")
  end)

  it("allocates nothing for an execution that acquires nothing", function()
    -- The release list is built lazily, and this is why: every `/ping` reads
    -- no releasable capability, and the allocation ceiling is 169 bytes of
    -- headroom.
    local _, record = new_execution {}
    assert.is_nil(record.released)
  end)

  it("allocates nothing for a capability with no release method", function()
    local carrier, record = new_execution { clock = function() return { now = 1 } end }
    local _ = carrier.clock
    assert.is_nil(record.released)
  end)

  it("survives a resource whose release raises", function()
    -- One bad release must not strand the others.
    local freed = 0
    local carrier, record = new_execution {
      db    = function() return { release = function() error "boom" end } end,
      cache = function() return { release = function() freed = freed + 1 end } end,
    }
    local _, _ = carrier.db, carrier.cache
    execution.release(record)
    assert.equal(1, freed, "a raising release stopped the others")
  end)
end)

describe("deferred release", function()
  it("composes rather than overwriting", function()
    -- Overwriting cost a leaked pool slot, a connection closed while idle in
    -- the pool, and a 500 to an innocent request, per occurrence.
    local order = {}
    local carrier, record = new_execution {
      db = function()
        return { release = function() order[#order + 1] = "capability" end }
      end,
    }
    local _ = carrier.db

    local previous = function() order[#order + 1] = "middleware" end
    local release = execution.deferred(record, previous)
    release()

    assert.equal(2, #order, "one of the two releases did not run")
    assert.equal("middleware", order[1])
    assert.equal("capability", order[2])
  end)

  it("still releases when the previous one raises", function()
    local freed = false
    local carrier, record = new_execution {
      db = function() return { release = function() freed = true end } end,
    }
    local _ = carrier.db
    execution.deferred(record, function() error "middleware blew up" end)()
    assert.is_true(freed)
  end)

  it("works with no previous release at all", function()
    local freed = false
    local carrier, record = new_execution {
      db = function() return { release = function() freed = true end } end,
    }
    local _ = carrier.db
    execution.deferred(record, nil)()
    assert.is_true(freed)
  end)
end)

describe("identity", function()
  it("is unique within a process", function()
    local seen = {}
    for _ = 1, 1000 do
      local id = execution.id()
      assert.is_nil(seen[id], "id collided: " .. id)
      seen[id] = true
    end
  end)
end)

describe("the budget", function()
  it("bounds a capability's own timeout to what is left", function()
    local left
    local cq = cqueues.new()
    cq:wrap(function()
      execution.begin(0.25)
      left = execution.bounded(30)
    end)
    assert(cq:loop(5))
    assert.is_true(left <= 0.25,
      ("bounded returned %s against a 0.25 budget"):format(tostring(left)))
  end)

  it("does not let a caller widen a budget it did not set", function()
    local got
    local cq = cqueues.new()
    cq:wrap(function()
      execution.begin(1)
      got = execution.bounded(60)
    end)
    assert(cq:loop(5))
    assert.is_true(got <= 1)
  end)
end)

describe("the deadline", function()
  it("reports COMPLETION for work that finishes in time", function()
    local cq = cqueues.new()
    local outcome, value
    cq:wrap(function()
      outcome, value = execution.with_deadline(5, function() return "done" end)
    end)
    assert(cq:loop(10))
    assert.equal("COMPLETION", outcome)
    assert.equal("done", value)
  end)

  it("reports TIMEOUT for work that overruns", function()
    local cq = cqueues.new()
    local outcome
    cq:wrap(function()
      outcome = execution.with_deadline(0.05, function() cqueues.sleep(2) end)
    end)
    assert(cq:loop(10))
    assert.equal("TIMEOUT", outcome)
  end)

  it("raises what the work raised", function()
    local cq = cqueues.new()
    local ok, err
    cq:wrap(function()
      ok, err = pcall(execution.with_deadline, 5, function() error("boom", 0) end)
    end)
    assert(cq:loop(10))
    assert.is_false(ok)
    assert.equal("boom", err)
  end)

  it("runs the work with no budget at all", function()
    -- `timeout = 0` means "no deadline", and `0` being truthy in Lua is how
    -- this framework once answered 408 to every request.
    local outcome, value = execution.with_deadline(0, function() return 42 end)
    assert.equal("COMPLETION", outcome)
    assert.equal(42, value)
  end)
end)
