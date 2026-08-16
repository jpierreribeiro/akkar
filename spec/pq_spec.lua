--[[
akkar.pq — the C driver, and the property that makes it worth having.

Two claims are checked, and only one of them is about speed.

**It yields.** `pg_sleep(0.4)` twice, concurrently, must take about four
tenths of a second and not eight. A driver that blocks the OS thread while a
query runs would pass every correctness test in this file and destroy the
thing akkar is: `docs/PLAN.md` records pgmoon's yielding as worth 7.56x out of
a possible 8x, so a faster driver that blocks is a slower server.

**It answers the same contract pgmoon does.** Types come back as the same Lua
types, a SQL NULL leaves the key absent rather than present-and-null, and
parameters are bound with their Postgres type rather than spliced into the
text. Any of those differing would make the driver a rewrite of every caller
rather than a replacement for one adapter.

The comparison against pgmoon lives in `bench/`, not here: a spec that asserts
a speed asserts the speed of the machine it happens to run on.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

local has_native = pcall(require, "akkar.pq_native")
if not has_native then
  describe("akkar.pq", function()
    pending "akkar/pq_native.so is not built; skipping"
  end)
  return
end

local cqueues = require "cqueues"
local pq      = require "akkar.pq"

local CONFIG = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
}

-- Reachability is checked by CONNECTING, not by assuming. Every skip guard in
-- this suite was decorative once, and CI found it on its first run.
local function reachable()
  local ok = false
  local cq = cqueues.new()
  cq:wrap(function()
    local conn = pq.connect(CONFIG, cqueues.monotime() + 3)
    if conn then ok = true conn:close() end
  end)
  cq:loop(5)
  return ok
end

if not reachable() then
  describe("akkar.pq", function()
    pending "Postgres is not reachable on 127.0.0.1:55432; skipping"
  end)
  return
end

--- Runs `fn` inside a controller, since every wait in the driver is a poll.
local function inside(fn, budget)
  local err
  local cq = cqueues.new()
  cq:wrap(function()
    local ok, why = pcall(fn)
    if not ok then err = why end
  end)
  assert(cq:loop(budget or 10))
  if err then error(err, 0) end
end

describe("akkar.pq", function()
  it("connects and answers a query", function()
    inside(function()
      local conn = assert(pq.connect(CONFIG))
      local rows = assert(conn:query "select 42 as answer")
      assert.equal(1, #rows)
      assert.equal(42, rows[1].answer)
      conn:close()
    end)
  end)

  it("binds parameters with their type, never splicing them", function()
    inside(function()
      local conn = assert(pq.connect(CONFIG))

      -- The apostrophe is the whole point: spliced, this ends the string
      -- literal and the rest is SQL.
      local rows = assert(conn:query("select $1::text as name", { "o'brien" }))
      assert.equal("o'brien", rows[1].name)

      -- And the type is declared, which is the 43x finding in `akkar/db.lua`:
      -- an integer parameter must arrive as int8, not numeric, or an indexed
      -- column is compared across types and scanned.
      local typed = assert(conn:query(
        "select pg_typeof($1)::text as t", { 7 }))
      assert.equal("bigint", typed[1].t)

      local float = assert(conn:query(
        "select pg_typeof($1)::text as t", { 7.5 }))
      assert.equal("double precision", float[1].t)

      conn:close()
    end)
  end)

  it("keeps Lua's integer and float distinction", function()
    inside(function()
      local conn = assert(pq.connect(CONFIG))
      local rows = assert(conn:query
        "select 7::bigint as i, 7.5::float8 as f, true as b, 'x'::text as s")

      -- `math.type` has to keep telling the truth: an integer column that
      -- came back as a float would silently stop matching the int8 binding
      -- above, and the mismatch would only show as a slow query.
      assert.equal("integer", math.type(rows[1].i))
      assert.equal("float", math.type(rows[1].f))
      assert.equal(true, rows[1].b)
      assert.equal("x", rows[1].s)
      conn:close()
    end)
  end)

  it("leaves a SQL NULL absent rather than present-and-null", function()
    inside(function()
      local conn = assert(pq.connect(CONFIG))
      local rows = assert(conn:query
        "select 1 as present, null::text as missing")

      assert.equal(1, rows[1].present)
      assert.is_nil(rows[1].missing)
      -- Absent, not nil-valued: the difference is what `next` sees, and
      -- `akkar/db.lua` relies on it to avoid walking every field of every row
      -- -- which an earlier version did, for a sentinel that did not exist,
      -- at 12% of the database path.
      local keys = 0
      for _ in pairs(rows[1]) do keys = keys + 1 end
      assert.equal(1, keys)
      conn:close()
    end)
  end)

  it("matches pgmoon on NUMERIC by default, and can be exact on request", function()
    -- The one place where drop-in and correct point different ways, so both
    -- are pinned rather than one being chosen quietly.
    --
    -- pgmoon decodes OID 1700 as a Lua number (pgmoon/init.lua:110) and
    -- therefore loses digits on money columns. This driver does the same by
    -- default -- breaking every caller's arithmetic is not a trade it gets to
    -- make while its value is that swapping it changes one file -- and offers
    -- the exact digits to anyone who asks.
    local native = require "akkar.pq_native"
    local BIG = "12345678901234567890.123456789"

    inside(function()
      local conn = assert(pq.connect(CONFIG))

      assert.is_false(native.numeric_as_string())
      local lossy = assert(conn:query("select " .. BIG .. "::numeric as n"))
      assert.equal("number", type(lossy[1].n))

      native.numeric_as_string(true)
      local exact = assert(conn:query("select " .. BIG .. "::numeric as n"))
      assert.equal("string", type(exact[1].n))
      assert.equal(BIG, exact[1].n)
      native.numeric_as_string(false)

      conn:close()
    end)
  end)

  it("reports a failed statement without taking the process down", function()
    inside(function()
      local conn = assert(pq.connect(CONFIG))
      local rows, err = conn:query "select * from a_table_that_is_not_there"
      assert.is_nil(rows)
      assert.is_table(err)
      assert.is_truthy(tostring(err.message):find("a_table_that_is_not_there", 1, true))
      -- SQLSTATE is what distinguishes a unique violation from a deadlock,
      -- and a caller that cannot tell them apart cannot retry correctly.
      assert.equal("42P01", err.sqlstate)

      -- And the connection still works afterwards.
      local ok = assert(conn:query "select 1 as n")
      assert.equal(1, ok[1].n)
      conn:close()
    end)
  end)

  it("YIELDS -- two slow queries take the time of one", function()
    -- The property the whole design exists for. A driver that blocked the OS
    -- thread would pass every test above and make akkar single-file
    -- sequential: `docs/PLAN.md` scores pgmoon's yielding at 7.56x out of 8,
    -- and a faster driver that blocks is a slower server.
    local finished, started = 0, nil
    local elapsed

    local cq = cqueues.new()
    for _ = 1, 2 do
      cq:wrap(function()
        local conn = assert(pq.connect(CONFIG))
        started = started or cqueues.monotime()
        assert(conn:query "select pg_sleep(0.4)")
        finished = finished + 1
        conn:close()
      end)
    end
    local begin = cqueues.monotime()
    assert(cq:loop(10))
    elapsed = cqueues.monotime() - begin

    assert.equal(2, finished)
    -- Serial would be 0.8s or more. Generous bound because CI machines are
    -- not quiet, but 0.8 is unreachable if the two overlapped at all.
    assert.is_true(elapsed < 0.7,
      ("two concurrent 0.4s queries took %.3fs, so the driver serialised them")
      :format(elapsed))
  end)

  it("times out without leaving the connection reusable", function()
    inside(function()
      local conn = assert(pq.connect(CONFIG))
      local rows, err = conn:query("select pg_sleep(5)", nil,
                                   cqueues.monotime() + 0.5)
      assert.is_nil(rows)
      assert.is_true(err.timeout)

      -- A timed-out query is STILL RUNNING on the server and its result is
      -- uncollected, so the connection must not go back to a pool: the next
      -- borrower would read this query's rows as its own. The driver marks
      -- it, and the pool's job is to believe the mark.
      assert.is_true(conn.spoiled)
      conn:close()
    end)
  end, 15)

  it("knows when it is inside a transaction", function()
    inside(function()
      local conn = assert(pq.connect(CONFIG))
      assert.is_false(conn:in_transaction())
      assert(conn:query "begin")
      assert.is_true(conn:in_transaction(),
        "a connection returned to the pool mid-transaction is the defect " ..
        "class this project has already paid for twice")
      assert(conn:query "rollback")
      assert.is_false(conn:in_transaction())
      conn:close()
    end)
  end)

  it("carries many rows back in one go", function()
    inside(function()
      local conn = assert(pq.connect(CONFIG))
      local rows = assert(conn:query
        "select i, i::text as label from generate_series(1, 1000) as i")
      assert.equal(1000, #rows)
      assert.equal(1, rows[1].i)
      assert.equal("1000", rows[1000].label)
      conn:close()
    end)
  end)
end)
