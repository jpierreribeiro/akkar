--[[
A database restarted under a live pool.

`akkar/pool.lua` says out loud that it hands a connection out of `idle`
without validating it, and accepts the consequence:

    "after a Postgres restart, a failover, or a load balancer reaping idle
     connections behind the pool's back, up to `size` corpses get dealt out,
     one failed request each"

**Up to `size` corpses, one failed request each** is the contract. This file
measures whether that is what happens, and on the default driver it is not:
the corpse is handed out, the request fails, and THE SAME CORPSE GOES BACK
INTO THE IDLE SET. There is no "one failed request each"; there is one failed
request, then another, then every request for the rest of the process's life.

Why the pool cannot see it. `Pool:put` asks `reusable`, and `db.lua` answers
`not conn.in_transaction and not conn.broken and not conn.in_flight`. Nothing
in that sentence is true of a connection whose backend was killed while it sat
idle -- it is not in a transaction, no query is in flight, and `broken` was
never set, because `Db:query` only sets `broken` when pgmoon RAISES or when the
request's own deadline expired. A dead backend does neither: pgmoon RETURNS
`nil, "receive_message: failed to get type: nil"`, which reads exactly like a
SQL error, and a SQL error must not cost a reconnect.

So the discriminator has to be structural rather than textual, and pgmoon
provides one. A query error is reported after the protocol reached
`ReadyForQuery`, so the message is followed by `result, num_queries`; a
transport failure is reported from `receive_message` with nothing behind it.
That is the shape these cases pin, and `spec/db_spec.lua` holds the other end
of it -- a cancelled statement is a QUERY error and must still be reusable.

The condition is induced with `pg_terminate_backend` rather than by restarting
the container, because the two were measured to be indistinguishable from
inside the process (same message, same permanence) and only one of them needs
a Docker socket. Only the backend pids this file opened for itself are killed,
so a spec running beside it against the same database is untouched.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
-- The C driver's `pq_native.so` lives beside `akkar/pq.lua`; the pgmoon cases
-- do not need it, so this only matters for the `pq` case at the foot of the
-- file, which guards on whether the require below succeeded.
package.cpath = "./?.so;" .. package.cpath

local cqueues = require "cqueues"
local db      = require "akkar.db"

local PG = { host = "127.0.0.1", port = 55432, database = "akkar",
             user = "postgres", password = "akkar" }

-- Only the `pq` case needs a name: it is how a reader of `pg_stat_activity`
-- finds these connections while the case is running.
local MARK = "akkar_pg_restart_spec"

local function pg_reachable()
  local ok, conn = pcall(db.connect { host = PG.host, port = PG.port,
    database = PG.database, user = PG.user, password = PG.password,
    pool_size = 0 })
  if ok then conn:close() end
  return ok
end

--- Runs a body inside a controller, which is where cqueues sockets exist.
---
--- `cq:loop` is asserted separately from the body's own failure, because a
--- controller that DIES is a different result from a body that raised -- and
--- the `pq` case below is exactly that difference.
local function in_controller(fn)
  local cq = cqueues.new()
  local failure
  cq:wrap(function()
    local ok, err = pcall(fn)
    if not ok then failure = err end
  end)
  local alive, why = cq:loop(60)
  if failure then error(failure, 0) end
  return alive, why
end

local function factory_of(options)
  local config = { host = PG.host, port = PG.port, database = PG.database,
                   user = PG.user, password = PG.password }
  for k, v in pairs(options or {}) do config[k] = v end
  return db.connect(config)
end

--- Fills the pool to `n` connections and returns the backend pid of each.
---
--- Pids rather than an `application_name` marker, because `reset_on_release`
--- issues `DISCARD ALL` on the way back to the pool and `DISCARD ALL` resets
--- `application_name` -- so the control case would have unmarked itself and
--- killed nothing, which is exactly what it did the first time this ran.
local function warm(factory, n)
  local held, pids = {}, {}
  for i = 1, n do
    held[i] = factory()
    pids[i] = held[i]:one("select pg_backend_pid() as pid").pid
  end
  for i = 1, n do held[i]:release() end
  return pids
end

--- Kills exactly the listed backends, from a connection outside the pool.
---
--- Exactly those, so a spec running beside this one against the same database
--- keeps its connections.
local function kill_pids(pids)
  if #pids == 0 then return 0 end
  local killer = factory_of { pool_size = 0 }()
  local killed = 0
  for _, pid in ipairs(pids) do
    local row = killer:one(
      "select pg_terminate_backend($1::int) as done", tonumber(pid))
    if row and row.done then killed = killed + 1 end
  end
  killer:close()
  return killed
end

--- Acquires, runs one trivial query, releases. Returns whether it worked,
--- the error, and whether the connection ended up flagged `broken`.
local function one_request(factory)
  local conn = factory()
  local ok, err = pcall(function() return conn:one("select 1 as x").x end)
  local broken = conn.broken
  conn:release()
  return ok, err, broken
end

if not pg_reachable() then
  describe("a database restarted under a live pool", function()
    pending("Postgres is not reachable on 127.0.0.1:55432; skipping")
  end)
else
describe("a database restarted under a live pool", function()
  it("does not hand the same dead connection out twice", function()
    in_controller(function()
      local factory = factory_of { pool_size = 1 }
      local pids = warm(factory, 1)
      assert.equal(1, kill_pids(pids))

      -- The pool's own contract: `size` corpses, one failed request each. A
      -- pool of one therefore owes AT MOST ONE failure.
      local failures, first
      failures = 0
      for _ = 1, 5 do
        local ok, err = one_request(factory)
        if not ok then failures = failures + 1; first = first or err end
      end

      assert.is_true(failures <= 1,
        ("a pool of 1 failed %d of 5 requests after its backend was killed; " ..
         "the dead connection is going back into `idle`. First error: %s")
        :format(failures, tostring(first)))
    end)
  end)

  it("flags the connection whose backend died as broken", function()
    in_controller(function()
      local factory = factory_of { pool_size = 1 }
      local pids = warm(factory, 1)
      assert.equal(1, kill_pids(pids))

      local ok, err, broken = one_request(factory)
      assert.is_false(ok, "the query against a killed backend succeeded")
      assert.is_true(broken,
        ("`broken` was %s on a connection whose backend was killed, so " ..
         "`reusable` judged it fit and the pool kept it. Error was: %s")
        :format(tostring(broken), tostring(err)))
    end)
  end)

  it("recovers within `size` requests, and stays recovered", function()
    in_controller(function()
      local factory = factory_of { pool_size = 3 }
      local pids = warm(factory, 3)
      assert.equal(3, kill_pids(pids))

      local failures, first_ok = 0
      for round = 1, 12 do
        local ok, err = one_request(factory)
        if ok then first_ok = first_ok or round
        else failures = failures + 1 end
      end

      assert.is_true(failures <= 3,
        ("%d of 12 requests failed against a pool of 3 whose backends were " ..
         "killed; the bound is `size` = 3"):format(failures))
      assert.is_not_nil(first_ok,
        "the pool never recovered, though Postgres was up the whole time")
      -- Bounded AND up front: the failures are the first few, not scattered
      -- through the run, because the corpses were removed rather than skipped.
      assert.is_true(first_ok <= 4,
        ("the first success was request %d, not within `size` + 1")
        :format(first_ok))
    end)
  end)

  it("keeps `live` and `reserved` honest across the event", function()
    in_controller(function()
      local factory = factory_of { pool_size = 3 }
      local pool = factory.pool
      local pids = warm(factory, 3)

      local before = pool:stats()
      assert.equal(3, before.live)
      assert.equal(3, before.idle)
      assert.equal(0, before.reserved)

      assert.equal(3, kill_pids(pids))
      for _ = 1, 12 do one_request(factory) end

      local after = pool:stats()
      assert.is_true(after.live >= 0,
        ("live went negative: %d"):format(after.live))
      assert.is_true(after.live <= after.size,
        ("live %d exceeds size %d"):format(after.live, after.size))
      assert.equal(0, after.reserved)
      assert.is_true(after.idle <= after.live,
        ("idle %d exceeds live %d"):format(after.idle, after.live))
    end)
  end)

  it("names the failure in akkar's own terms", function()
    in_controller(function()
      local factory = factory_of { pool_size = 1 }
      local pids = warm(factory, 1)
      assert.equal(1, kill_pids(pids))

      local ok, err = one_request(factory)
      assert.is_false(ok)
      assert.is_string(err)
      -- The prefix is akkar's; the sentence behind it is pgmoon's
      -- `receive_message: failed to get type: nil`, which is what a reader of
      -- the log actually gets. Pinned as the current state rather than as an
      -- endorsement.
      assert.is_truthy(err:find("^db: "),
        ("the caller saw %q, which does not come from akkar"):format(err))
    end)
  end)

  it("recovers in bounded time when `reset_on_release` is on", function()
    -- The workaround that already worked, kept as the control: `DISCARD ALL`
    -- on the way back to the pool is a round trip, so it FAILS on a dead
    -- socket, and that failure is what sets `broken` today. Recovery was
    -- measured at exactly `size` failed requests with it, and never without.
    in_controller(function()
      local factory = factory_of { pool_size = 2, reset_on_release = true }
      local pids = warm(factory, 2)
      assert.equal(2, kill_pids(pids))

      local failures = 0
      for _ = 1, 8 do
        local ok = one_request(factory)
        if not ok then failures = failures + 1 end
      end
      assert.is_true(failures <= 2,
        ("reset_on_release still cost %d failures on a pool of 2"):format(failures))
    end)
  end)
end)

-- ============================================================== the C driver
--
-- `driver = "pq"` gets the `broken` flag right on its own -- libpq reports
-- `terminating connection due to administrator command` as a result error and
-- `akkar/db.lua` believes it, so the corpse above cannot happen there. What it
-- got wrong was louder: a killed backend left its descriptor registered in the
-- cqueues controller, and the next connection handed that same descriptor
-- number KILLED THE WHOLE EVENT LOOP -- every request in the process, not one.
--
--     unable to update event disposition: No such file or directory (fd:5)
--
-- raised at the scheduler rather than at the caller, so no `pcall` around a
-- request caught it and `cq:loop` returned false.
--
-- WHY THE OLD DEFENCE MISSED IT. `akkar/pq.lua`'s `Conn:close` cancels the
-- descriptor before `PQfinish` -- but libpq closes the socket itself, INSIDE
-- `PQconsumeInput`, the instant it reads the dying backend's final message and
-- the EOF glued behind it. By the time `close` runs, `PQsocket` already
-- answers -1, so the fd guard skips the cancel:
--
--     fd while healthy:      5
--     fd after backend died: -1
--
-- and `cqueues.cancel` after the close cannot repair it -- the number is gone,
-- its own EPOLL_CTL_DEL gets the same ENOENT, and it returns before clearing
-- the armed state that does the damage. Four Lua-side repairs were tried
-- against exactly this and none worked; only the C side sees the descriptor
-- while it is still open.
--
-- THE FIX, in `src/akkar_pq.c`: `consume` pulls the descriptor out of the
-- pollset before every `PQconsumeInput`. The closing EOF cannot be told apart
-- from data in advance, so the cancel is unconditional -- it clears the armed
-- state while the fd is still open, the healthy path re-arms it on the next
-- poll, and the death path then closes an fd whose cqueues state is already 0,
-- leaving nothing stale for the descriptor's next owner. This case is the
-- proof: against the pre-fix `.so` it takes the loop down (`cq:loop` returns
-- false with the disposition error); against the fixed one the reused
-- descriptor serves a query and the loop stays up.
local has_native = pcall(require, "akkar.pq_native")
if not has_native then
  describe("a killed backend on the pq driver", function()
    pending("akkar/pq_native.so is not built; skipping the C-driver case")
  end)
else
local pq = require "akkar.pq"

local PQCFG = { host = PG.host, port = PG.port, database = PG.database,
                user = PG.user, password = PG.password }

local function pq_connect()
  local c, err = pq.connect(PQCFG)
  assert(c, err)
  return c
end

describe("a killed backend on the pq driver", function()
  it("leaves the pollset before libpq closes the fd, so the next connection " ..
     "to inherit that descriptor number does not take the loop down",
  function()
    local q_failed, first_err, reused, recovered

    -- The whole scenario runs inside ONE controller, because the bug is a
    -- property of the controller's pollset, not of any one connection.
    local alive, why = in_controller(function()
      local a = pq_connect()
      -- The descriptor cqueues is about to be left holding.
      local healthy_fd = a.handle:pollfd()
      local pid = a:query("select pg_backend_pid() as p")[1].p

      -- Kill it from a second connection, exactly this backend and no other,
      -- then give the reset a moment to arrive.
      local killer = pq_connect()
      killer:query("select pg_terminate_backend($1::int)", { pid })
      killer:close()
      cqueues.sleep(0.2)

      -- The query during which libpq reads the FATAL message and the EOF and
      -- closes the socket. It must fail, and it is the close inside it that
      -- the fix has to get in front of.
      local ok, err = a:query("select 1 as x")
      q_failed = (ok == nil)
      first_err = err and err.message
      a:close()

      -- The next connection is handed the just-freed descriptor number. On
      -- the pre-fix driver, polling it is what raises at the scheduler.
      local c = pq_connect()
      reused = (c.handle:pollfd() == healthy_fd)
      local row = c:query("select 42 as answer")
      recovered = row and row[1] and row[1].answer
      c:close()
    end)

    assert.is_true(alive,
      ("the controller died after a backend was killed: %s"):format(tostring(why)))
    assert.is_true(q_failed,
      ("the query against a killed backend did not fail; message was %s")
      :format(tostring(first_err)))
    assert.is_true(reused,
      "the recovery connection did not inherit the dead descriptor's number, " ..
      "so this run never exercised the hazard -- the assertion above is empty")
    assert.equal(42, recovered,
      "the connection on the reused descriptor could not run a query")
  end)
end)
end
end
