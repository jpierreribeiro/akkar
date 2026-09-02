--[[
`akkar gen`: the typed TypeScript client, generated from the route schemas.

Two halves, and they prove different things.

The first is pure Lua and always runs: it asserts the SHAPE of what the
generator emits -- one interface per input the route declares, `?` on optional
fields, `unknown` (never `any`) where the route declared no response, and a
comment naming every constraint the server enforces that a TS type cannot. A
generator that quietly widened a type to `any` would pass every tsc proof below
(nothing is an error against `any`) and fail here.

The second drives a real type checker, because a claim about what tsc catches
is a claim only tsc can back. It is `pending` when `tsc` is not on PATH (or in
`AKKAR_TSC`), and it says so rather than passing vacuously -- the same rule as
the rest of the suite. It proves the three things that make this tRPC-like:
a wrong call is a compile error, a right call is not, and -- the one that
matters -- a change to the SERVER's schema turns a previously-correct client
red once regenerated. That last case is the whole point of generating from the
route table rather than hand-writing types beside it.
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
  app:get("/search", { query = { q = "string", limit = akkar.v.integer { min = 1, max = 100 } } },
    function() return { hits = {} } end)
  local body = { to = "string", memo = akkar.v.string { optional = true } }
  body[amount_field] = akkar.v.integer { min = 1 }
  app:post("/transfers", { body = body, response = { id = "string", status = "string" } },
    function() return { id = "tr", status = "posted" } end)
  return app
end

describe("akkar gen, the generated TypeScript", function()
  local ts = gen.typescript(fixture(), { title = "t", version = "1" })

  it("emits one named interface per declared input, and a function per route", function()
    assert.is_truthy(ts:find("export interface PostTransfersBody {", 1, true))
    assert.is_truthy(ts:find("export interface PostTransfersResponse {", 1, true))
    assert.is_truthy(ts:find("export interface GetUsersIdParams {", 1, true))
    assert.is_truthy(ts:find("export interface GetSearchQuery {", 1, true))
    assert.is_truthy(ts:find("export async function postTransfers(", 1, true))
    assert.is_truthy(ts:find("export async function getUsersId(", 1, true))
    assert.is_truthy(ts:find("export async function getSearch(", 1, true))
  end)

  it("marks an optional field with ? and a required one without", function()
    assert.is_truthy(ts:find("memo?: string;", 1, true))
    assert.is_truthy(ts:find("  to: string;", 1, true))
    assert.is_truthy(ts:find("  amount: number;", 1, true))
  end)

  it("says unknown, never any, where the route declared no response", function()
    assert.is_truthy(ts:find("export type GetUsersIdResponse = unknown;", 1, true))
    assert.is_nil(ts:find(": any", 1, true), "an `any` in the output type-checks against nothing")
  end)

  it("names the constraints the server enforces that the type cannot", function()
    assert.is_truthy(ts:find("body.amount >= 1", 1, true))
    assert.is_truthy(ts:find("query.limit <= 100", 1, true))
    assert.is_truthy(ts:find("#params.id >= 1", 1, true))
  end)

  it("types the error half: a per-route union of the declared error bodies", function()
    -- The 422 akkar produces is in the document with its shape now, so the
    -- client can narrow on `error` and read `fields` by the dotted path the
    -- validator wrote -- akkar's version of a defined, typed error.
    assert.is_truthy(ts:find("export class AkkarError<TBody = unknown> extends Error", 1, true))
    assert.is_truthy(ts:find("export type PostTransfersError = {", 1, true))
    assert.is_truthy(ts:find('error: "validation failed";', 1, true))
    assert.is_truthy(ts:find("fields: Record<string, string>;", 1, true))
    assert.is_truthy(ts:find('error: "internal server error";', 1, true))
    assert.is_truthy(ts:find("throw new AkkarError<PostTransfersError>(", 1, true))
  end)

  it("substitutes path parameters and serialises query parameters", function()
    assert.is_truthy(ts:find('path.replace("{id}", encodeURIComponent(String(args.params.id)))', 1, true))
    assert.is_truthy(ts:find("new URLSearchParams()", 1, true))
  end)

  it("is byte-stable across runs, so the drift gate compares something real", function()
    assert.equal(ts, gen.typescript(fixture(), { title = "t", version = "1" }))
  end)

  it("moves with the schema: renaming a body field renames the emitted field", function()
    local v2 = gen.typescript(fixture("cents"), { title = "t", version = "1" })
    assert.is_truthy(v2:find("  cents: number;", 1, true))
    assert.is_nil(v2:find("  amount: number;", 1, true))
  end)
end)

describe("akkar gen, checked by tsc", function()
  local tsc = os.getenv "AKKAR_TSC"
  if not tsc and portable.have "tsc" then tsc = "tsc" end
  if not tsc then
    pending "tsc is not on PATH (set AKKAR_TSC to a tsc binary to run these)"
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

  --- Runs tsc over one file; returns ok, and the diagnostics text.
  local function check(name)
    -- NO `--moduleResolution`, and its absence is the point.
    --
    -- This passed `--moduleResolution node` and CI refused it: modern
    -- TypeScript removed that mode outright, so every case here failed with
    -- `TS5108: Option 'moduleResolution=node10' has been removed` -- a
    -- diagnostic about the invocation, reported as though the generated client
    -- were wrong.
    --
    -- The flag was never needed. These fixtures import one sibling by relative
    -- path, which every resolution mode has always handled. Naming a mode only
    -- pinned the proof to one era of the compiler, and the whole reason to run
    -- a real checker is that it is the one the reader will actually have --
    -- including the newer one a CI runner ships by default, which is exactly
    -- what caught this.
    local cmd = ("%s --strict --noEmit --target es2020 "
              .. "--lib es2020,dom %q 2>&1"):format(tsc, dir .. "/" .. name)
    local pipe = assert(io.popen(cmd))
    local out = pipe:read "a"
    local ok = pipe:close()
    return ok and true or false, out
  end

  setup(function()
    write("client.ts", gen.typescript(fixture(), { title = "t", version = "1" }))
    write("good.ts", [[
import { postTransfers, getUsersId, getSearch } from "./client";
export async function ok() {
  const t = await postTransfers({ body: { to: "acct_9", amount: 5 } });
  const s: string = t.status;
  await getUsersId({ params: { id: "u1" } });
  await getSearch({ query: { q: "x", limit: 10 } });
  return s;
}
]])
    write("bad.ts", [[
import { postTransfers, getUsersId } from "./client";
export async function bad() {
  await postTransfers({ body: { to: 1, amount: 5 } });
  await postTransfers({ body: { to: "a" } });
  await getUsersId({ params: { idd: "u1" } });
}
]])
    write("errors.ts", [[
import { postTransfers, AkkarError, PostTransfersError } from "./client";
export async function handled(): Promise<string | undefined> {
  try {
    await postTransfers({ body: { to: "acct_9", amount: 5 } });
  } catch (e) {
    if (e instanceof AkkarError) {
      const body = e.body as PostTransfersError;
      if (body.error === "validation failed") {
        // Narrowed: `fields` exists on this member and is a string map.
        return body.fields["body.amount"];
      }
      const status: number = e.status;
      return String(status);
    }
    throw e;
  }
}
]])
    write("errors_bad.ts", [[
import { postTransfers, AkkarError, PostTransfersError } from "./client";
export async function mishandled() {
  try {
    await postTransfers({ body: { to: "acct_9", amount: 5 } });
  } catch (e) {
    if (e instanceof AkkarError) {
      const body = e.body as PostTransfersError;
      if (body.error === "internal server error") {
        return body.fields;   // no `fields` on a 500: must not type-check
      }
    }
  }
}
]])
  end)

  it("lets a caller narrow a thrown error to the 422 and read its fields", function()
    local ok, out = check "errors.ts"
    assert.is_true(ok, "typed error narrowing was rejected:\n" .. out)
  end)

  it("refuses to read `fields` off the 500 member, because a 500 has none", function()
    local ok, out = check "errors_bad.ts"
    assert.is_false(ok, "tsc let a 500 be read as if it carried fields")
    assert.is_truthy(out:find("TS2339", 1, true), out)
  end)

  teardown(function() os.execute(("rm -rf %q"):format(dir)) end)

  it("accepts a correct client", function()
    local ok, out = check "good.ts"
    assert.is_true(ok, "tsc rejected a correct client:\n" .. out)
  end)

  it("rejects a wrong type, a missing required field and an unknown field", function()
    local ok, out = check "bad.ts"
    assert.is_false(ok, "tsc accepted a wrong client")
    assert.is_truthy(out:find("TS2322", 1, true), "wrong type not reported:\n" .. out)
    assert.is_truthy(out:find("TS2741", 1, true), "missing field not reported:\n" .. out)
    assert.is_truthy(out:find("TS2353", 1, true), "unknown field not reported:\n" .. out)
  end)

  it("turns a correct client red when the SERVER renames a field and the client is regenerated", function()
    -- This is the contract flowing server -> client, which is what generating
    -- from the route table buys over hand-written types beside it.
    write("client.ts", gen.typescript(fixture("cents"), { title = "t", version = "1" }))
    local ok, out = check "good.ts"
    assert.is_false(ok, "a stale call type-checked against a changed contract")
    assert.is_truthy(out:find("'amount' does not exist", 1, true), out)
    -- And back, so the proof is symmetric rather than a one-way accident.
    write("client.ts", gen.typescript(fixture(), { title = "t", version = "1" }))
    assert.is_true((check "good.ts"))
  end)
end)
