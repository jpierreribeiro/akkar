--[[
A join's values belong to the join.

`build` emits every join before any condition, but `join` and `where` appended
to the same flat `_values` list -- so the numbering followed the order the calls
were made and the text followed the order of the clauses. Confirmed output:

    select * from t join t2 on ... acl.project_id = $1 where (project_id = $2)
    VALUES: 999, 7

The ACL check ran against the tenant id and the tenant filter against the user
id. It survives review because the two orders only diverge when a CONDITIONAL
`where` precedes an unconditional `join`: with the optional filter absent the
statement is correct, so it mis-authorises exactly the requests that carry a
filter.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local sql = require "akkar.sql"

describe("join values", function()
  it("bind to the join, not to the condition written before it", function()
    local q = sql.select("*"):from "t"
    q:where("project_id = ?", 999)                       -- the optional filter
    q:join("join acl on acl.thing = t.id and acl.user_id = ?", 7)

    local text, first, second = q:build()
    assert.equal("select * from t join acl on acl.thing = t.id and acl.user_id = $1"
              .. " where (project_id = $2)", text)
    assert.equal(7, first,   "the ACL check was bound to the tenant id")
    assert.equal(999, second)
  end)

  it("keeps working when the optional filter is absent", function()
    -- The case that always passed, and therefore hid the other one.
    local q = sql.select("*"):from "t"
    q:join("join acl on acl.thing = t.id and acl.user_id = ?", 7)
    local text, first = q:build()
    assert.equal("select * from t join acl on acl.thing = t.id and acl.user_id = $1", text)
    assert.equal(7, first)
  end)

  it("number several joins and conditions in clause order", function()
    local q = sql.select("*"):from "t"
    q:where("a = ?", "where-1")
    q:join("join x on x.k = ?", "join-1")
    q:where("b = ?", "where-2")
    q:join("join y on y.k = ?", "join-2")
    q:limit(5)

    assert.same({ "join-1", "join-2", "where-1", "where-2", 5 }, q:values())
    assert.equal("select * from t join x on x.k = $1 join y on y.k = $2"
              .. " where (a = $3) and (b = $4) limit $5", q:to_string())
  end)

  it("survive a tenant scope appended after both", function()
    -- The scope is appended as a condition, so it must still land after the
    -- join's values and after the handler's own.
    local q = sql.select("*"):from "orders"
    q:where("status = ?", "paid")
    q:join("join customers on customers.id = orders.customer_id and customers.region = ?", "eu")
    q:scope("tenant_id", 42)

    assert.same({ "eu", "paid", 42 }, q:values())
  end)

  it("are refused where build would drop the join text", function()
    -- Only a SELECT emits joins. Accepting one on an update would keep the
    -- values and lose the text they belong to, which is the same mis-binding
    -- from the other direction.
    local q = sql.update("t")
    assert.is_false(pcall(function() return q:join("join x on x.k = ?", 1) end))
  end)
end)
