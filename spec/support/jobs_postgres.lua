--[[
What every spec that drives `akkar.jobs.postgres` needs and none should
repeat: the connection, the schema, the skip guard and the sweep.

Connect AND ask a question, in the shape `spec/migrate_spec.lua` uses. A guard
that only builds the handle is decorative -- `spec/jobs_spec.lua` records how
every Redis skip in this suite was, for as long as somebody's machine had
Redis running -- and a decorative guard's failure mode is a silently empty
suite.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

local db       = require "akkar.db"
local postgres = require "akkar.jobs.postgres"

local M = {}

function M.config(driver)
  return {
    host = "127.0.0.1", port = 55432, database = "akkar",
    user = "postgres", password = "akkar", pool_size = 0,
    driver = driver or "pgmoon",
  }
end

function M.reachable(driver)
  local ok, conn = pcall(function() return db.connect(M.config(driver))() end)
  if not ok or not conn then return false end
  local alive = pcall(function() return conn:one "select 1 as n" end)
  pcall(function() conn:close() end)
  return alive
end

-- THE SCHEMA GOES IN OVER pgmoon WHATEVER DRIVER THE TEST RUNS ON. The C
-- driver sends everything through `PQsendQueryParams`, which refuses a string
-- carrying more than one statement -- so a migration file, which is several,
-- cannot be applied through it. That is a property of the driver and not of
-- this store; it is recorded in the report that shipped the store, and until
-- it changes the schema is applied through the driver that can.
local schema_applied = false

local function ensure_schema()
  if schema_applied then return end
  local conn = db.connect(M.config "pgmoon")()
  conn:exec(postgres.SCHEMA)
  conn:close()
  schema_applied = true
end

--- A connection with the schema in place.
function M.open(driver)
  ensure_schema()
  return db.connect(M.config(driver))()
end

--- Leaves nothing behind for a queue: the database outlives the suite, so a
--- job left by an earlier run is state the next run inherits, and a test
--- that reads a depth would then be measuring history.
---
--- EVERY KEY THE QUEUE TOUCHES, not just the main one. `akkar/jobs.lua` puts
--- dead letters under `key .. ":dead"`, which is why the `like` is here and
--- not a second exact match -- the Redis half of `spec/jobs_spec.lua` records
--- what leaving one out costs: a test that expected one dead letter got 200,
--- because every job buried since the suite was written was still there.
function M.clean(conn, key)
  conn:exec("delete from akkar_jobs where queue = $1 or queue like $2", key, key .. ":%")
  conn:exec("delete from akkar_job_claims where queue = $1 or queue like $2",
            key, key .. ":%")
end

-- ONE CONNECTION FOR A WHOLE SPEC FILE, and it is not only frugality.
--
-- `LISTEN` is session state, so a store that reconnected per test would lose
-- its subscription every time -- and the contract specs below call `make()`
-- from `before_each`, which is once per case. A connection per case would also
-- be a connection per case LEAKED, since nothing in a `before_each` closes the
-- previous one, and Postgres's default `max_connections` is 100.
local shared

--- The connection every contract pass in this suite shares.
function M.shared()
  if not shared then shared = M.open "pgmoon" end
  return shared
end

--- A queue with nothing left over from an earlier run.
---
--- The name is FIXED rather than random, and the rows are deleted on the way
--- in: a random name per case never collides but never gets collected either,
--- so the table grows by a few hundred rows every time the suite runs and the
--- claim's index quietly stops being the thing under test. Wiping a fixed
--- name is self-limiting -- each run clears the last one's leavings.
function M.queue(name, options)
  local conn = M.shared()
  local q = postgres.new(conn, name, options)
  M.clean(conn, q.key)
  return q
end

return M
