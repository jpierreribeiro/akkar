--[[
`akkar gen --lang teal`: the typed Teal client, generated from the route schemas.

The same two halves as `spec/gen_spec.lua`, for the other caller of an akkar
API: a Lua program. The pure-Lua half always runs and asserts the SHAPE of the
emitted `.tl` -- one `record` per declared input, `integer` kept as `integer`
(the one thing TypeScript cannot say), a Teal `enum` for a `one_of`, `any`
only where the route declared no response, and a header that says what the
checker will NOT catch.

The second half drives `tl` itself, because a claim about what `tl check`
catches is a claim only `tl` can back. `pending` when `tl` is not on PATH, and
said so rather than passed vacuously. It proves: a right call is clean; a wrong
type, an unknown field, a literal outside the enum and a non-integer are each
errors; a MISSING required field is caught only through `<total>` -- which is
the limit Teal imposes, proven here in both directions so the header's claim
is a measured one; the server renaming a field turns a previously-correct
client red once regenerated; and the `tl gen`-compiled client actually runs
over `app:test()` and splits the 422 the way its types say it does.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar    = require "akkar"
local gen      = require "akkar.gen"
local portable = require "spec.support.portable"

local function fixture(amount_field)
  amount_field = amount_field or "amount"
  local app = akkar.new()
  app:get("/users/:id", { params = { id = akkar.v.string { min = 1 } } },
    function(req) return { id = req.params.id } end)
  app:get("/search", {
    query = { q = "string", limit = akkar.v.integer { min = 1, max = 100, optional = true } },
    response = { hits = akkar.v.array { items = akkar.v.object { fields = { id = "string" } } } },
  }, function(req) return { hits = { { id = req.query.q } } } end)
  local body = {
    to   = "string",
    memo = akkar.v.string { optional = true },
    kind = akkar.v.string { one_of = { "wire", "ach" }, optional = true },
  }
  body[amount_field] = akkar.v.integer { min = 1 }
  app:post("/transfers", { body = body, response = { id = "string", status = "string" } },
    function() return { id = "tr", status = "posted" } end)
  return app
end

local INFO = { title = "t", version = "1" }

describe("akkar gen --lang teal, the generated Teal", function()
  local tl = gen.teal(fixture(), INFO)

  it("emits one record per declared input, and a typed method per route", function()
    assert.is_truthy(tl:find("  record PostTransfersBody\n", 1, true))
    assert.is_truthy(tl:find("  record PostTransfersResponse\n", 1, true))
    assert.is_truthy(tl:find("  record GetUsersIdParams\n", 1, true))
    assert.is_truthy(tl:find("  record GetSearchQuery\n", 1, true))
    assert.is_truthy(tl:find(
      "post_transfers: function(Client, PostTransfersArgs): PostTransfersResponse, PostTransfersError", 1, true))
    assert.is_truthy(tl:find("function client.Client:post_transfers(args: client.PostTransfersArgs)", 1, true))
    assert.is_truthy(tl:find("function client.Client:get_users_id(args: client.GetUsersIdArgs)", 1, true))
    -- A query-only route takes its argument table optionally, both in the
    -- record's signature and in the implementation.
    assert.is_truthy(tl:find("get_search: function(Client, ?GetSearchArgs)", 1, true))
    assert.is_truthy(tl:find("function client.Client:get_search(args?: client.GetSearchArgs)", 1, true))
  end)

  it("keeps integer as integer, which is the type TypeScript cannot carry", function()
    assert.is_truthy(tl:find("    amount: integer\n", 1, true))
    assert.is_truthy(tl:find("    limit: integer   -- optional", 1, true))
  end)

  it("marks an optional field, and leaves a required one bare", function()
    assert.is_truthy(tl:find("    memo: string   -- optional", 1, true))
    assert.is_truthy(tl:find("    to: string\n", 1, true))
  end)

  it("turns a one_of into a Teal enum, nested so its name cannot collide", function()
    assert.is_truthy(tl:find('    enum Kind\n      "wire"\n      "ach"\n    end', 1, true))
    assert.is_truthy(tl:find("    kind: Kind   -- optional", 1, true))
  end)

  it("names a nested object as a record inside its parent", function()
    assert.is_truthy(tl:find("  record GetSearchResponse\n    record HitsItem\n      id: string\n    end\n    hits: {HitsItem}", 1, true))
  end)

  it("says any only where the route declared no response", function()
    assert.is_truthy(tl:find("  type GetUsersIdResponse = any   -- the route declares no response", 1, true))
    -- Every other `any` in the file is in the transport seam, which carries
    -- undecoded JSON by design; no declared shape is widened.
    for line in tl:gmatch "[^\n]+" do
      if line:find(": any", 1, true) and not line:find("body", 1, true)
         and not line:find("value: any", 1, true) and not line:find("{string: any}", 1, true) then
        error("a declared shape was widened to any: " .. line)
      end
    end
  end)

  it("types the error half as one merged record with an enum discriminator", function()
    assert.is_truthy(tl:find('  record PostTransfersErrorBody\n    enum Error\n      "validation failed"\n      "internal server error"\n    end\n    error: Error\n    fields: {string: string}   -- optional\n  end', 1, true))
    assert.is_truthy(tl:find("  record PostTransfersError\n    status: integer\n    body: PostTransfersErrorBody\n  end", 1, true))
  end)

  it("names the constraints the server enforces that the types cannot, and the <total> limit", function()
    assert.is_truthy(tl:find("body.amount >= 1", 1, true))
    assert.is_truthy(tl:find("query.limit <= 100", 1, true))
    assert.is_truthy(tl:find("#params.id >= 1", 1, true))
    assert.is_truthy(tl:find("MISSING required field", 1, true))
    assert.is_truthy(tl:find("<total>", 1, true))
  end)

  it("is the client side only: no Request, no App, and it points at types/akkar.d.tl", function()
    assert.is_nil(tl:find("record Request", 1, true))
    assert.is_nil(tl:find("record App", 1, true))
    assert.is_truthy(tl:find("types/akkar.d.tl", 1, true))
  end)

  it("is byte-stable across runs, so the drift gate compares something real", function()
    assert.equal(tl, gen.teal(fixture(), INFO))
  end)

  it("moves with the schema: renaming a body field renames the emitted field", function()
    local v2 = gen.teal(fixture("cents"), INFO)
    assert.is_truthy(v2:find("    cents: integer\n", 1, true))
    assert.is_nil(v2:find("    amount: integer\n", 1, true))
  end)

  it("names the module after info.module", function()
    local named = gen.teal(fixture(), { title = "t", version = "1", module = "api" })
    assert.is_truthy(named:find("local record api\n", 1, true))
    assert.is_truthy(named:find("function api.Client:post_transfers(args: api.PostTransfersArgs)", 1, true))
    assert.is_truthy(named:find("\nreturn api\n", 1, true))
  end)
end)

describe("akkar gen --lang teal, checked by tl", function()
  if not portable.have "tl" then
    pending "tl is not on PATH (luarocks install tl) -- the Teal checker proofs did not run"
    return
  end

  local dir = os.tmpname()
  os.remove(dir)
  assert(os.execute(("mkdir -p %q"):format(dir)))

  local function write(name, text)
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(text)
    f:close()
  end

  --- Runs `tl check` over one file; returns ok, and the diagnostics text.
  local function check(name)
    local pipe = assert(io.popen(("tl check --include-dir %q %q 2>&1"):format(dir, dir .. "/" .. name)))
    local out = pipe:read "a"
    local ok = pipe:close()
    return ok and true or false, out
  end

  setup(function()
    write("client.tl", gen.teal(fixture(), INFO))
    write("good.tl", [[
local client = require("client")
local c = client.new({ transport = function(_: client.TransportRequest): integer, any return 200, {} end })
local t, err = c:post_transfers({ body = { to = "acct_9", amount = 5, kind = "wire" } })
local s: string = t.status
local page = c:get_search({ query = { q = "x", limit = 10 } })
local hit: string = page.hits[1].id
c:get_users_id({ params = { id = "u1" } })
if err and err.body.error == "validation failed" then
  local reason: string = err.body.fields["body.amount"]
  print(reason)
end
print(s, hit)
]])
    write("bad.tl", [[
local client = require("client")
local c = client.new({ transport = function(_: client.TransportRequest): integer, any return 200, {} end })
c:post_transfers({ body = { to = 1, amount = 5 } })
c:get_users_id({ params = { idd = "u1" } })
c:post_transfers({ body = { to = "a", amount = 5, kind = "cheque" } })
c:get_search({ query = { q = "x", limit = 1.5 } })
local t = c:post_transfers({ body = { to = "a", amount = 5 } })
local n: integer = t.status
print(n)
]])
    write("missing_plain.tl", [[
local client = require("client")
local c = client.new({ transport = function(_: client.TransportRequest): integer, any return 200, {} end })
c:post_transfers({ body = { to = "a" } })
]])
    write("missing_total.tl", [[
local client = require("client")
local c = client.new({ transport = function(_: client.TransportRequest): integer, any return 200, {} end })
local body <total>: client.PostTransfersBody = { to = "a", memo = nil, kind = nil }
c:post_transfers({ body = body })
]])
    write("errors_bad.tl", [[
local client = require("client")
local c = client.new({ transport = function(_: client.TransportRequest): integer, any return 200, {} end })
local _, err = c:post_transfers({ body = { to = "a", amount = 5 } })
if err.body.error == "not a declared error" then print("unreachable") end
]])
  end)

  teardown(function() os.execute(("rm -rf %q"):format(dir)) end)

  it("accepts a correct client, including narrowing the 422 to read its fields", function()
    local ok, out = check "good.tl"
    assert.is_true(ok, "tl rejected a correct client:\n" .. out)
    assert.is_truthy(out:find("0 errors detected", 1, true), out)
  end)

  it("rejects a wrong type, an unknown field, a literal outside the enum and a non-integer", function()
    local ok, out = check "bad.tl"
    assert.is_false(ok, "tl accepted a wrong client")
    assert.is_truthy(out:find("in record field: to: got integer, expected string", 1, true), out)
    assert.is_truthy(out:find("unknown field idd", 1, true), out)
    assert.is_truthy(out:find('"cheque" is not a member of Kind', 1, true), out)
    assert.is_truthy(out:find("in record field: limit: got number, expected integer", 1, true), out)
    assert.is_truthy(out:find("got string, expected integer", 1, true), out)
  end)

  it("rejects a comparison against an error literal the route does not declare", function()
    local ok, out = check "errors_bad.tl"
    assert.is_false(ok, "tl accepted an undeclared error literal")
    assert.is_truthy(out:find("is not a member of Error", 1, true), out)
  end)

  it("catches a missing required field only through <total>, which is Teal's limit, stated", function()
    -- Both directions, so the header's claim is measured rather than assumed:
    -- a plain literal with `amount` missing is NOT an error (every Teal record
    -- field admits nil)...
    local ok_plain, out_plain = check "missing_plain.tl"
    assert.is_true(ok_plain, "tl now rejects a plain literal missing a field; the header is stale:\n" .. out_plain)
    -- ...and the `<total>` form the header prescribes IS one, naming the field.
    local ok_total, out_total = check "missing_total.tl"
    assert.is_false(ok_total, "<total> did not demand the missing field")
    assert.is_truthy(out_total:find("does not declare values for all fields (missing: amount)", 1, true), out_total)
  end)

  it("turns a correct client red when the SERVER renames a field and the client is regenerated", function()
    write("client.tl", gen.teal(fixture("cents"), INFO))
    local ok, out = check "good.tl"
    assert.is_false(ok, "a stale call type-checked against a changed contract")
    assert.is_truthy(out:find("unknown field amount", 1, true), out)
    -- And back, so the proof is symmetric rather than a one-way accident.
    write("client.tl", gen.teal(fixture(), INFO))
    assert.is_true((check "good.tl"))
  end)

  it("compiles with tl gen and runs over app:test(), splitting the 422 as its types say", function()
    local pipe = assert(io.popen(("tl gen %q -o %q 2>&1"):format(dir .. "/client.tl", dir .. "/client.lua")))
    local out = pipe:read "a"
    assert.is_true(pipe:close() and true or false, "tl gen failed:\n" .. out)

    local saved_path, saved_loaded = package.path, package.loaded["client"]
    package.path = dir .. "/?.lua;" .. package.path
    package.loaded["client"] = nil
    local ok, err = pcall(function()
      local client = require "client"
      local tc = fixture():test()
      local seen = {}
      local c = client.new {
        transport = function(req)
          seen[#seen + 1] = req.method .. " " .. req.path
          local r = tc[req.method:lower()](tc, req.path, { body = req.body, headers = req.headers })
          return r.status, r.body
        end,
      }
      local t, e = c:post_transfers { body = { to = "acct_9", amount = 5 } }
      assert.is_nil(e)
      assert.equal("posted", t.status)

      local page = c:get_search { query = { q = "a b", limit = 10 } }
      assert.equal("a b", page.hits[1].id)
      assert.equal("GET /search?limit=10&q=a%20b", seen[2])

      local one = c:get_users_id { params = { id = "u 1/x" } }
      assert.equal("u 1/x", one.id)
      assert.equal("GET /users/u%201%2Fx", seen[3])

      local none, failed = c:post_transfers { body = { to = "acct_9", amount = 0 } }
      assert.is_nil(none)
      assert.equal(422, failed.status)
      assert.equal("validation failed", failed.body.error)
      assert.is_string(failed.body.fields["body.amount"])
    end)
    package.path = saved_path
    package.loaded["client"] = saved_loaded
    assert(ok, err)
  end)
end)
