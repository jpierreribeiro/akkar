--[[
akkar.sql — composing SQL from data without being able to concatenate.

The tests that matter most are the ones proving a hostile value cannot escape
parameterisation, and that there is no door left open for it to escape
through.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local sql = require "akkar.sql"

describe("building a query", function()
  it("numbers placeholders once, at the end", function()
    -- The reason people give up and concatenate is tracking $1 by hand across
    -- conditions added in different places.
    local q = sql.select("id, name"):from("users")
      :where("name = ?", "ada")
      :where("age >= ?", 18)
    local text, a, b = q:build()
    assert.equal("select id, name from users where (name = $1) and (age >= $2)", text)
    assert.equal("ada", a)
    assert.equal(18, b)
  end)

  it("binds limit and offset rather than writing them in", function()
    local text, a, b = sql.select("*"):from("users"):limit(10):offset(20):build()
    assert.equal("select * from users limit $1 offset $2", text)
    assert.equal(10, a)
    assert.equal(20, b)
  end)

  it("expands IN with one placeholder per element", function()
    local q = sql.select("*"):from("users"):where_in("id", { 1, 2, 3 })
    local text = q:to_string()
    assert.equal("select * from users where (id in ($1, $2, $3))", text)
    assert.same({ 1, 2, 3 }, q:values())
  end)

  it("turns an empty IN into false, not into every row", function()
    -- `in ()` is a syntax error, and dropping the condition would return
    -- everything instead of nothing -- the dangerous direction.
    local q = sql.select("*"):from("users"):where_in("id", {})
    assert.equal("select * from users where (false)", q:to_string())
  end)

  it("casts a bound UUID without interpolating its value", function()
    local id = "5b06ddf5-4158-45e8-9726-60e064478cac"
    local q = sql.insert_into("memberships", {
      tenant_id = sql.uuid(id), role = "owner",
    }, { "tenant_id", "role" })
    assert.equal(
      "insert into memberships (role, tenant_id) values ($1, $2::uuid)",
      q:to_string())
    assert.same({ "owner", id }, q:values())
  end)

  it("supports typed UUIDs in composed conditions and tenant scopes", function()
    local tenant_id = "5b06ddf5-4158-45e8-9726-60e064478cac"
    local item_id = "746c24d7-f2da-4fe4-872c-1809b527a75c"
    local q = sql.select("*"):from("items")
      :where("id = ?", sql.uuid(item_id))
      :scope("tenant_id", sql.uuid(tenant_id))
    assert.equal(
      "select * from items where (id = $1::uuid) and (tenant_id = $2::uuid)",
      q:to_string())
    assert.same({ item_id, tenant_id }, q:values())
  end)

  it("rejects arbitrary cast text", function()
    local ok, err = pcall(sql.cast, "x", "uuid); drop table users; --")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match("unsupported parameter cast"))
  end)
end)

describe("values can never become SQL", function()
  it("keeps an injection attempt as a value", function()
    local hostile = "'; drop table users; --"
    local q = sql.select("*"):from("users"):where("name = ?", hostile)

    assert.equal("select * from users where (name = $1)", q:to_string())
    assert.same({ hostile }, q:values())
    -- The text contains no part of the attack.
    assert.is_nil(q:to_string():find("drop", 1, true))
  end)

  it("keeps a value that looks like a placeholder", function()
    local q = sql.select("*"):from("users"):where("name = ?", "$1 or 1=1")
    assert.equal("select * from users where (name = $1)", q:to_string())
    assert.same({ "$1 or 1=1" }, q:values())
  end)

  it("refuses a condition whose placeholders and values disagree", function()
    -- Silently binding the wrong number is how a value lands in the wrong
    -- column, or a condition quietly does nothing.
    local ok, err = pcall(function()
      sql.select("*"):from("users"):where("a = ? and b = ?", 1)
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "2 placeholder%(s%) but 1 value")
  end)

  it("offers no raw-SQL escape hatch", function()
    -- An escape hatch is where the injection goes.  Assert the door does not
    -- exist rather than trusting nobody opens it.
    local q = sql.select("*"):from("users")
    assert.is_nil(q.where_raw)
    assert.is_nil(q.raw)
    assert.is_nil(q.append)
    assert.is_nil(sql.raw)
  end)
end)

describe("identifiers are checked, because they cannot be parameterised", function()
  it("accepts a plain and a qualified name", function()
    assert.equal("users", sql.identifier("users", nil, "table"))
    assert.equal("public.users", sql.identifier("public.users", nil, "table"))
  end)

  it("refuses anything that is not an identifier", function()
    for _, bad in ipairs { "users; drop table x", "users--", "1users",
                           "us ers", "users)", "" } do
      local ok = pcall(sql.identifier, bad, nil, "table")
      assert.is_false(ok, "accepted a bad identifier: " .. bad)
    end
  end)

  it("requires an order column to be on the allow list", function()
    local q = sql.select("*"):from("users")
    -- A real column the route never meant to expose is still refused.
    local ok, err = pcall(function()
      q:order_by("password_hash", { "id", "name" })
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "not in the allowed list")
  end)

  it("accepts an allow-listed order column with a direction", function()
    local q = sql.select("*"):from("users"):order_by("name", { "id", "name" }, "desc")
    assert.equal("select * from users order by name desc", q:to_string())
  end)

  it("refuses an order direction that is not asc or desc", function()
    local ok = pcall(function()
      sql.select("*"):from("users"):order_by("id", { "id" }, "asc; drop table users")
    end)
    assert.is_false(ok)
  end)

  it("refuses a non-integer limit", function()
    assert.is_false((pcall(function() sql.select("*"):from("u"):limit("10; drop") end)))
    assert.is_false((pcall(function() sql.select("*"):from("u"):limit(-1) end)))
    assert.is_false((pcall(function() sql.select("*"):from("u"):limit(1.5) end)))
  end)
end)

describe("claiming rows for a worker", function()
  it("writes the lock clause last, after limit", function()
    -- Postgres rejects `for update` before `limit`, and the builder is the
    -- only thing deciding the order -- a caller cannot reach the suffix.
    local text = sql.select("id"):from("jobs"):where("available_at <= now()")
      :order_by("available_at", { "available_at" }, "asc"):limit(10)
      :for_update():skip_locked():to_string()
    assert.equal("select id from jobs where (available_at <= now()) " ..
                 "order by available_at asc limit $1 for update skip locked", text)
  end)

  it("takes the calls in either order", function()
    -- Both spellings describe the same query; rejecting one would be rejecting
    -- a well-formed statement over the order two builder calls happened to
    -- arrive in.
    assert.equal(sql.select("*"):from("jobs"):for_update():skip_locked():to_string(),
                 sql.select("*"):from("jobs"):skip_locked():for_update():to_string())
  end)

  it("refuses to skip locked rows without locking any", function()
    -- `skip locked` alone is not valid SQL, and the mistake it hides is worse
    -- than the syntax error: a claimer that never locked anything has nothing
    -- to skip and takes the same rows as everyone else.
    local ok, err = pcall(function() sql.select("*"):from("jobs"):skip_locked():build() end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "requires for_update")
  end)

  it("refuses to lock rows an update or delete never selected", function()
    for _, kind in ipairs { "update", "delete_from" } do
      assert.is_false((pcall(function() sql[kind]("jobs"):skip_locked() end)))
    end
  end)

  it("stays out of a plain select", function()
    assert.equal("select * from jobs", sql.select("*"):from("jobs"):to_string())
    assert.equal("select * from jobs for update",
                 sql.select("*"):from("jobs"):for_update():to_string())
  end)
end)
