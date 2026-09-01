--[[
akkar.db.memory — an in-memory database adapter.

Borrowed from a pattern in `druse-crystals`, where every capability ships a
`_memory` alongside its real backend. The point is not to fake a database: it
is that **the fake is a real, tested, shared implementation of the same
contract** rather than something each test file reinvents.

akkar's specs had been writing this inline:

    local function fake_db(rows)
      local db = {}
      function db:one(sql) ... end
      function db:many() return rows end
      ...
    end

Three problems with that. Each copy drifts. None of them is checked against the
contract, so a change to `akkar.db` can leave every fake silently wrong. And
nobody outside this repository gets one at all — a person testing their own
handlers has to write it again, badly.

## What it is not

Not a SQL engine. It does not parse the query; it matches it against
programmed responses. That is the honest shape for a fake: pretending to
execute SQL would be a second, worse database whose disagreements with Postgres
would surface as tests that pass and production that does not.

    local db = require "akkar.db.memory"

    local fake = db.new()
      :on("select id, name from users where id = $1", { id = 1, name = "ada" })
      :on("^insert into users", function(sql, ...) return { id = 42 } end)

    local app_client = app:test { db = fake }

Queries reaching it that were never programmed raise, naming the query. A test
that silently gets nil back from an unplanned query is a test asserting the
wrong thing.

## Capacity

`max_qps` and `latency_ms` are construction-time knobs of the same kind as
`:fail`, `:hang` and `:drop` -- per-adapter behaviour, set once and honoured on
every query. They model a database that is slow, or saturated, or both, without
one existing. See the block above `serve`; the same model, with the same words,
is in `akkar/cache/memory.lua`, and `spec/capacity_spec.lua` drives both from
one table of numbers so they cannot drift apart.
]]

local time  = require "akkar.time"
local Scope = require "akkar.scope"

local Memory = {}
Memory.__index = Memory

local M = {}

--- `options` may be omitted, and both of its fields are nil by default, so a
--- fake nobody configured costs exactly what it cost before either existed.
function M.new(options)
  options = options or {}
  if options.max_qps ~= nil and (tonumber(options.max_qps) or 0) <= 0 then
    error("akkar.db.memory: max_qps must be a number greater than zero; a " ..
          "capacity of zero is a database nothing can ever reach, and the " ..
          "way to say that is :drop()", 0)
  end
  if options.latency_ms ~= nil and (tonumber(options.latency_ms) or -1) < 0 then
    error("akkar.db.memory: latency_ms must be a number of milliseconds, " ..
          "not negative", 0)
  end
  return setmetatable({
    responses = {},     -- ordered: first matching pattern wins
    log = {},           -- every query received, for assertions
    depth = 0,          -- transaction nesting
    -- The capacity model. See `serve`.
    max_qps    = options.max_qps and tonumber(options.max_qps) or nil,
    latency_ms = options.latency_ms and tonumber(options.latency_ms) or nil,
  }, Memory)
end

--- THE CAPACITY MODEL, and it is a model. It says what it is:
---
--- `latency_ms` is service time -- every statement takes that long.
--- `max_qps` is throughput -- the server runs statements one after another at
--- that rate, so statement N cannot finish before `start + N/max_qps` and a
--- caller arriving into a saturated database waits for the queue ahead of it.
---
--- They are one queue and not two delays added together: WHICHEVER IS THE
--- TIGHTER CONSTRAINT IS THE ONE A CALLER FEELS. A database at 1500/s and
--- 8 ms is bounded by its service time, because 8 ms of work cannot be issued
--- 1500 times a second by one server; the same database at 50/s and 8 ms is
--- bounded by its rate. Adding the two would have invented a third database
--- that is slower than either number describes.
---
--- What it does NOT claim: that this is what Postgres under that load would
--- actually do. A real server's service time depends on the plan, the cache
--- and the locks it is waiting on. This reproduces a queue with a fixed
--- service rate -- the same model a capacity diagram is drawn from -- and the
--- point of one number configuring both is that the prediction and the real
--- run can then be compared and found to disagree. A model that presented
--- itself as truth would teach less.
---
--- It waits through `akkar.time`, never through a wall clock of its own. Under
--- `akkar.time.manual` a wait advances timestamps and returns immediately, so
--- a test of a 1500/s database at 8 ms is deterministic and finishes now.
--- Under the real clock the same numbers cost real seconds, which is what
--- makes one configuration serve a simulation and a real run alike.
---
--- Transaction control is charged like anything else, because `begin` and
--- `commit` are round trips on a real server and a transaction that came for
--- free would make the cheapest thing in the model the one that is not.
---
--- STATED TWICE ON PURPOSE, once per adapter. `spec/capacity_spec.lua` drives
--- both from the same numbers so the two cannot drift apart.
local function serve(self)
  if not self.max_qps and not self.latency_ms then return end

  local wait = 0
  if self.max_qps then
    local now  = time.monotime()
    local free = math.max(self.free_at or now, now)
    wait = free - now
    self.free_at = free + 1 / self.max_qps
  end
  wait = wait + (self.latency_ms or 0) / 1000

  if wait > 0 then time.sleep(wait) end
end

--- Programs a response.
--- `pattern` is matched against the SQL as plain text first and as a Lua
--- pattern only if that finds nothing -- so `insert into ledger (order_id,
--- amount)` means those characters, and `^insert into users` still anchors.
--- `response` is a row, a list of rows, or a function receiving (sql, ...).
function Memory:on(pattern, response)
  self.responses[#self.responses + 1] = { pattern = pattern, response = response }
  return self
end

--- Makes an otherwise unprogrammed query fail the way the real adapter would.
function Memory:fail(pattern, message)
  return self:on(pattern, function() error("db: " .. (message or "query failed"), 0) end)
end

--- Makes a query TAKE TIME, so a deadline above it can fire.
---
--- `:fail` raises immediately, which exercises the error path and nothing
--- else. The defect class this project keeps finding is different: a
--- capability acquired, a coroutine abandoned mid-yield, and a release that
--- never runs -- and staging it needs a query that YIELDS rather than one
--- that returns. Without this the only way to make a query slow was a real
--- `pg_sleep`, which is why `spec/abandoned_spec.lua` is `pending` on every
--- machine without Docker.
---
--- Real seconds on purpose. `akkar.time` can move a budget forward without
--- waiting, but it deliberately does not move the event loop -- see that
--- module's header -- and what has to happen here is a genuine yield, so
--- that whatever is racing this query actually gets scheduled.
---
--- Which is why it is `time.real.sleep` and not `time.sleep`. Under a manual
--- clock the second one advances timestamps and returns at once, so `:hang`
--- would quietly stop hanging and become `:fail` under another name -- and a
--- fault that silently turns into a different fault is the one thing a fake
--- must never do. `latency_ms` wants exactly the opposite and gets it: that
--- one goes through `akkar.time` precisely so a manual clock can collapse it.
function Memory:hang(pattern, seconds)
  return self:on(pattern, function()
    time.real.sleep(seconds or 60)
    error("db: query hung and was never answered", 0)
  end)
end

--- Makes the CONNECTION die mid-query, not merely the query fail.
---
--- The difference matters and it is the difference `:fail` cannot express: a
--- failed query leaves a healthy connection that goes back to the pool, while
--- a dropped connection must never go back -- `akkar/pool.lua` has to discard
--- it, and a pool that recycles a dead socket hands the next request a
--- descriptor that answers nothing.
---
--- Everything on this adapter fails after the drop, which is what a closed
--- socket does. Nothing un-drops it but `reset`.
function Memory:drop(pattern)
  return self:on(pattern, function()
    self.dropped = true
    error("db: connection reset by peer", 0)
  end)
end

-- LITERAL FIRST, PATTERN SECOND.
--
-- Every needle written against this fake is a piece of the SQL itself, and
-- SQL is made of Lua pattern magic: parentheses, `$1`, `%`, `-`, `.`. Matched
-- as a pattern alone, `insert into ledger (order_id, amount)` is a capture of
-- the text between the parentheses, so it matches only SQL that has no
-- parentheses in it -- and `db:count "insert into ledger (order_id, amount)"`
-- answered 0 for a query that WAS issued. An `assert.equal(0, ...)` meaning
-- "we did not double-charge" then passed unconditionally: a fake proving the
-- opposite of what the test says, which is the one thing a fake must never
-- do. `"values ($1"` did worse and threw "unfinished capture" out of the fake
-- and into the test.
--
-- Patterns stay, because `^insert into users` and `select .* from users` are
-- deliberate and this module's own documentation promises them. So a needle
-- is tried as plain text first and as a pattern only if that fails: every
-- pattern that matched before still matches, and a needle that is literally
-- in the SQL now always matches. `pcall` because a needle chosen as text is
-- under no obligation to compile as a pattern.
local function matches(sql, needle)
  if sql:find(needle, 1, true) then return true end
  local ok, found = pcall(sql.find, sql, needle)
  return ok and found ~= nil
end

Memory._matches = matches       -- exposed for tests; not part of the contract

local function find(self, sql)
  for _, entry in ipairs(self.responses) do
    if matches(sql, entry.pattern) then return entry end
  end
end

function Memory:query(sql, ...)
  -- An `akkar.sql` builder is assembled here, exactly as the real adapter
  -- assembles it, so a test sees the SQL the server would have sent.
  if type(sql) == "table" and sql.build then return self:query(sql:build()) end

  if type(sql) ~= "string" then
    error("akkar.db.memory: query needs SQL, got " .. type(sql) ..
          "\n  the real adapter would fail the same way; a fake that accepts " ..
          "no query hides that", 0)
  end
  self.log[#self.log + 1] = { sql = sql, args = table.pack(...) }

  -- A DROPPED CONNECTION STAYS DROPPED. A real socket does not recover
  -- because the next caller asked nicely, and a fake that answers again after
  -- a reset by peer would let a pool pass a dead connection around while the
  -- test went green. See `Memory:drop`.
  if self.dropped then
    error("db: connection reset by peer", 0)
  end

  -- The round trip, charged before the answer is found and after the
  -- connection is checked: a reset socket costs the server no work.
  serve(self)

  -- Transaction control is answered by the adapter itself, so a test does not
  -- have to program `begin` and `commit` -- nor the savepoints a nested
  -- `transaction` issues.
  if sql == "begin" or sql == "commit" or sql == "rollback"
     or sql:match "^savepoint "
     or sql:match "^release savepoint "
     or sql:match "^rollback to savepoint " then
    return {}
  end

  local entry = find(self, sql)
  if not entry then
    error("akkar.db.memory: no response programmed for query:\n  " .. sql ..
          "\n  program one with :on(pattern, response)", 0)
  end

  local response = entry.response
  if type(response) == "function" then response = response(sql, ...) end
  if response == nil then return {} end
  -- A single row is returned as a one-row result, so :one and :many both work
  -- against the same programming.
  if response[1] == nil then return { response } end
  return response
end

function Memory:many(sql, ...)
  local rows = self:query(sql, ...)
  return type(rows) == "table" and rows or {}
end

function Memory:one(sql, ...)
  return self:many(sql, ...)[1]
end

function Memory:exec(sql, ...)
  return self:query(sql, ...)
end

--- Same semantics as the real adapter: commit at the end, rollback on any
--- error, and the error is re-raised so a thrown response still works.
---
--- Including the nesting semantics. `depth` was counted here and never used,
--- so a nested block sent a second `begin` and an inner `commit` and then
--- reported a clean rollback -- which is precisely what the real adapter does
--- NOT do, and it meant no memory-backed test could catch the flat-transaction
--- defect. A fake whose safety property differs from the real one is how a
--- test proves the wrong thing, so the savepoints are mirrored exactly.
function Memory:transaction(fn)
  if self.depth > 0 then
    local name = "akkar_sp_" .. (self.depth + 1)
    self:query("savepoint " .. name)
    self.depth = self.depth + 1
    local ok, result = pcall(fn, self)
    self.depth = self.depth - 1
    if not ok then
      self:query("rollback to savepoint " .. name)
      error(result, 0)
    end
    self:query("release savepoint " .. name)
    return result
  end

  self:query "begin"
  self.depth = 1
  local ok, result = pcall(fn, self)
  self.depth = 0
  if not ok then
    self:query "rollback"
    self.rolled_back = true
    error(result, 0)
  end
  self:query "commit"
  self.committed = true
  return result
end

--- Same scoping as the real adapter, through the same module.
function Memory:scope(column, value) return Scope.wrap(self, column, value) end
function Memory:unscoped() return self end

function Memory:release() end
function Memory:close() end

-- ================================================================ assertions
-- What a test wants to ask afterwards.

--- Was a query matching this pattern issued?
function Memory:received(pattern)
  for _, call in ipairs(self.log) do
    if matches(call.sql, pattern) then return true, call end
  end
  return false
end

function Memory:count(pattern)
  local n = 0
  for _, call in ipairs(self.log) do
    if not pattern or matches(call.sql, pattern) then n = n + 1 end
  end
  return n
end

function Memory:reset()
  self.log, self.committed, self.rolled_back = {}, nil, nil
  self.dropped = nil
  self.free_at = nil       -- the queue drains too; the capacity itself stays
  return self
end

--- The factory shape `app:run{}` and `app:test{}` expect.
---
--- A function programs the fake, as it always did. A table is `M.new`'s
--- options, so `db.factory { max_qps = 1500 }` reads the way the rest of the
--- framework does, and both together are `db.factory({ ... }, function ... end)`.
function M.factory(configure, program)
  local options = type(configure) == "table" and configure or nil
  if type(configure) == "function" then program = configure end

  local instance = M.new(options)
  if program then program(instance) end
  return setmetatable({ instance = instance }, {
    __call = function() return instance end,
  })
end

M.Memory = Memory
return M
