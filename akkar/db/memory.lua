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
--- `pattern` is a Lua pattern matched against the SQL; a plain string that
--- happens to contain no magic characters therefore works as a substring.
--- `response` is a row, a list of rows, or a function receiving (sql, ...).
function Memory:on(pattern, response)
  self.responses[#self.responses + 1] = { pattern = pattern, response = response }
  return self
end

--- Makes an otherwise unprogrammed query fail the way the real adapter would.
function Memory:fail(pattern, message)
  return self:on(pattern, function() error("db: " .. (message or "query failed"), 0) end)
end

local function find(self, sql)
  for _, entry in ipairs(self.responses) do
    if sql:find(entry.pattern) then return entry end
  end
end

function Memory:query(sql, ...)
  if type(sql) ~= "string" then
    error("akkar.db.memory: query needs SQL, got " .. type(sql) ..
          "\n  the real adapter would fail the same way; a fake that accepts " ..
          "no query hides that", 0)
  end
  self.log[#self.log + 1] = { sql = sql, args = table.pack(...) }

  -- Transaction control is answered by the adapter itself, so a test does not
  -- have to program `begin` and `commit`.
  if sql == "begin" or sql == "commit" or sql == "rollback" then return {} end

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
function Memory:transaction(fn)
  self:query "begin"
  self.depth = self.depth + 1
  local ok, result = pcall(fn, self)
  self.depth = self.depth - 1
  if not ok then
    self:query "rollback"
    self.rolled_back = true
    error(result, 0)
  end
  self:query "commit"
  self.committed = true
  return result
end

function Memory:release() end
function Memory:close() end

-- ================================================================ assertions
-- What a test wants to ask afterwards.

--- Was a query matching this pattern issued?
function Memory:received(pattern)
  for _, call in ipairs(self.log) do
    if call.sql:find(pattern) then return true, call end
  end
  return false
end

function Memory:count(pattern)
  local n = 0
  for _, call in ipairs(self.log) do
    if not pattern or call.sql:find(pattern) then n = n + 1 end
  end
  return n
end

function Memory:reset()
  self.log, self.committed, self.rolled_back = {}, nil, nil
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
