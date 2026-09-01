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
]]

local time  = require "akkar.time"
local Scope = require "akkar.scope"

local Memory = {}
Memory.__index = Memory

local M = {}

function M.new()
  return setmetatable({
    responses = {},     -- ordered: first matching pattern wins
    log = {},           -- every query received, for assertions
    depth = 0,          -- transaction nesting
  }, Memory)
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
function Memory:hang(pattern, seconds)
  return self:on(pattern, function()
    time.sleep(seconds or 60)
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
  return self
end

--- The factory shape `app:run{}` and `app:test{}` expect.
function M.factory(configure)
  local instance = M.new()
  if configure then configure(instance) end
  return setmetatable({ instance = instance }, {
    __call = function() return instance end,
  })
end

M.Memory = Memory
return M
