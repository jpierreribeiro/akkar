--[[
`akkar gen --lang luals`: the LuaLS `---@meta` file, generated from the routes.

The projection for a plain-Lua caller: no dialect, no compiler, no runtime --
a comment-only file the language server reads, so a wrong call is a red
squiggle in the editor and nothing new ships. The pure-Lua half always runs
and asserts the SHAPE: one `---@class` per declared input with `---@field`s,
`?` on the optional ones, a literal union for a `one_of`, a dotted class for a
nested object, `any` only where the route declared no response, and -- the
property that makes it safe to check in -- that the file is INERT: loading it
executes nothing but empty tables, empty functions and a `return`.

The second half drives `lua-language-server --check`, because what LuaLS
catches is a claim only LuaLS can back. It is `pending` when the server is
neither on PATH nor named by `AKKAR_LUALS`, and says so. It proves: a right
call is clean; a wrong type, a MISSING required field and an undeclared field
read are each reported; an EXTRA field in a literal is NOT (LuaLS has no
excess-property check -- the header says so, and this keeps it true); and the
server renaming a field turns a previously-correct client red once
regenerated.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar    = require "akkar"
local gen      = require "akkar.gen"
local json     = require "akkar.json"
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

describe("akkar gen --lang luals, the generated meta file", function()
  local meta = gen.luals(fixture(), INFO)

  it("is a @meta for the module, with one @class per declared input and a stub per route", function()
    assert.equal("---@meta client\n", meta:sub(1, #"---@meta client\n"))
    assert.is_truthy(meta:find("---@class client.PostTransfersBody\n", 1, true))
    assert.is_truthy(meta:find("---@class client.PostTransfersResponse\n", 1, true))
    assert.is_truthy(meta:find("---@class client.GetUsersIdParams\n", 1, true))
    assert.is_truthy(meta:find("---@class client.GetSearchQuery\n", 1, true))
    assert.is_truthy(meta:find("---@param args client.PostTransfersArgs\n", 1, true))
    assert.is_truthy(meta:find("---@return client.PostTransfersResponse? result", 1, true))
    assert.is_truthy(meta:find("---@return client.PostTransfersError? err", 1, true))
    assert.is_truthy(meta:find("function Client:post_transfers(args) end", 1, true))
    assert.is_truthy(meta:find("---@param args? client.GetSearchArgs\n", 1, true))
    assert.is_truthy(meta:find("function client.new(options) end", 1, true))
  end)

  it("marks an optional field with ?, keeps integer as integer", function()
    assert.is_truthy(meta:find("---@field memo? string\n", 1, true))
    assert.is_truthy(meta:find("---@field to string\n", 1, true))
    assert.is_truthy(meta:find("---@field amount integer\n", 1, true))
    assert.is_truthy(meta:find("---@field limit? integer\n", 1, true))
  end)

  it("turns a one_of into a literal union, and the error discriminator too", function()
    assert.is_truthy(meta:find('---@field kind? "wire"|"ach"\n', 1, true))
    assert.is_truthy(meta:find('---@field error "validation failed"|"internal server error"\n', 1, true))
    assert.is_truthy(meta:find("---@field fields? table<string, string>\n", 1, true))
  end)

  it("names a nested object as a dotted class, and an array of it with []", function()
    assert.is_truthy(meta:find("---@class client.GetSearchResponse.HitsItem\n---@field id string\n", 1, true))
    assert.is_truthy(meta:find("---@field hits client.GetSearchResponse.HitsItem[]\n", 1, true))
  end)

  it("says any only where the route declared no response", function()
    assert.is_truthy(meta:find("---@alias client.GetUsersIdResponse any", 1, true))
    for line in meta:gmatch "[^\n]+" do
      if line:find("^%-%-%-@field") and line:find(" any", 1, true) and not line:find("body any", 1, true) then
        error("a declared shape was widened to any: " .. line)
      end
    end
  end)

  it("names the constraints the server enforces, and what LuaLS cannot catch", function()
    assert.is_truthy(meta:find("body.amount >= 1", 1, true))
    assert.is_truthy(meta:find("query.limit <= 100", 1, true))
    assert.is_truthy(meta:find("EXTRA field", 1, true))
    assert.is_truthy(meta:find("missing-fields", 1, true))
  end)

  it("is inert: loading it defines nothing but empty tables, empty functions and a return", function()
    for line in meta:gmatch "[^\n]+" do
      local code = line:match "^%s*(.-)%s*$"
      if code ~= "" and not code:find "^%-%-" then
        assert.is_truthy(
          code:match "^local [%w_]+ = {}$"
            or code:match "^function [%w_.:]+%([%w_, ]*%) end$"
            or code:match "^return [%w_]+$",
          "a line with runtime in a meta file: " .. line)
      end
    end
    local chunk = assert(load(meta, "client.d.lua", "t", {}))
    local returned = chunk()
    assert.is_table(returned)
    -- The only member the stub module carries is `new`, and it is an empty
    -- function: a caller who `require`d this file by mistake gets nil, not a
    -- client that half-works.
    assert.is_function(returned.new)
    assert.is_nil(returned.new { transport = function() end })
    assert.is_nil(next(returned, "new"), "a member beyond the `new` stub at runtime")
    assert.equal("new", (next(returned)))
  end)

  it("is byte-stable across runs, so the drift gate compares something real", function()
    assert.equal(meta, gen.luals(fixture(), INFO))
  end)

  it("moves with the schema: renaming a body field renames the emitted field", function()
    local v2 = gen.luals(fixture("cents"), INFO)
    assert.is_truthy(v2:find("---@field cents integer\n", 1, true))
    assert.is_nil(v2:find("---@field amount integer\n", 1, true))
  end)

  it("names the module after info.module", function()
    local named = gen.luals(fixture(), { title = "t", version = "1", module = "api" })
    assert.equal("---@meta api\n", named:sub(1, #"---@meta api\n"))
    assert.is_truthy(named:find("---@class api.PostTransfersBody\n", 1, true))
    assert.is_truthy(named:find("\nreturn api\n", 1, true))
  end)
end)

describe("akkar gen --lang luals, checked by lua-language-server", function()
  local luals = os.getenv "AKKAR_LUALS"
  if not luals and portable.have "lua-language-server" then luals = "lua-language-server" end
  if not luals then
    pending "lua-language-server is not on PATH (set AKKAR_LUALS to its binary) -- the LuaLS checker proofs did not run"
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

  --- Runs the checker over the whole directory and returns the diagnostics
  --- per file name: `{ ["bad.lua"] = { {code=..., message=...}, ... } }`.
  --- A file with no problems is absent, so callers ask for `or {}`.
  local function check()
    os.execute(("rm -rf %q"):format(dir .. "/log"))
    local cmd = ("%s --check %q --checklevel=Hint --check_format=json --logpath %q >/dev/null 2>&1")
      :format(luals, dir, dir .. "/log")
    os.execute(cmd)
    local f = io.open(dir .. "/log/check.json")
    if not f then return {} end
    local text = f:read "a"
    f:close()
    local by_uri = json.decode(text)
    local by_name = {}
    if type(by_uri) == "table" then
      for uri, list in pairs(by_uri) do
        by_name[uri:match "[^/]+$"] = list
      end
    end
    return by_name
  end

  local function codes(list)
    local out = {}
    for _, d in ipairs(list or {}) do out[#out + 1] = d.code .. ": " .. d.message end
    table.sort(out)
    return table.concat(out, "\n")
  end

  setup(function()
    write("client.d.lua", gen.luals(fixture(), INFO))
    write("good.lua", [[
local client = require("client")
local c = client.new({ transport = function(_) return 200, {} end })
local t = c:post_transfers({ body = { to = "acct_9", amount = 5, kind = "wire" } })
local s = t and t.status
local page = c:get_search({ query = { q = "x", limit = 10 } })
local hit = page and page.hits[1].id
c:get_users_id({ params = { id = "u1" } })
print(s, hit)
]])
    write("bad.lua", [[
local client = require("client")
local c = client.new({ transport = function(_) return 200, {} end })
c:post_transfers({ body = { to = 1, amount = 5 } })
c:post_transfers({ body = { to = "a" } })
local t = c:post_transfers({ body = { to = "a", amount = 5 } })
print(t and t.statuss)
]])
    write("extra.lua", [[
local client = require("client")
local c = client.new({ transport = function(_) return 200, {} end })
c:get_users_id({ params = { id = "u1", idd = "u2" } })
]])
  end)

  teardown(function() os.execute(("rm -rf %q"):format(dir)) end)

  it("accepts a correct client, rejects a wrong type, a missing field and an undeclared read, and lets an extra field through", function()
    -- One run of the checker over the whole directory; each file's verdict
    -- is read out of the same report, so the three claims share one measure.
    local report = check()
    assert.is_nil(report["good.lua"], "LuaLS rejected a correct client:\n" .. codes(report["good.lua"]))

    local bad = codes(report["bad.lua"])
    assert.is_truthy(bad:find("assign-type-mismatch", 1, true), "wrong type not reported:\n" .. bad)
    assert.is_truthy(bad:find("missing-fields: Missing required fields in type `client.PostTransfersBody`: `amount`", 1, true),
                     "missing field not reported:\n" .. bad)
    assert.is_truthy(bad:find("undefined-field: Undefined field `statuss`", 1, true),
                     "undeclared read not reported:\n" .. bad)

    -- The limit the header states, kept honest: no excess-property check.
    assert.is_nil(report["extra.lua"],
      "LuaLS now reports an extra field; the header's claim is stale:\n" .. codes(report["extra.lua"]))
  end)

  it("turns a correct client red when the SERVER renames a field and the client is regenerated", function()
    write("client.d.lua", gen.luals(fixture("cents"), INFO))
    local red = codes(check()["good.lua"])
    assert.is_truthy(red:find("missing-fields: Missing required fields in type `client.PostTransfersBody`: `cents`", 1, true),
                     "a stale call was not flagged against the changed contract:\n" .. red)
    -- And back, so the proof is symmetric rather than a one-way accident.
    write("client.d.lua", gen.luals(fixture(), INFO))
    assert.is_nil(check()["good.lua"])
  end)
end)
