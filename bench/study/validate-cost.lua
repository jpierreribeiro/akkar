-- What does validation cost, and therefore what could codegen ever buy?
--
-- F4 proposes compiling a specialised function per schema with `load()`,
-- instead of walking the schema with `pairs` and a chain of `if kind ==` on
-- every request. Pydantic v2 and fast-json-stringify both did it and both
-- report large wins, so the technique is not in question.
--
-- What is in question is the SHARE. `docs/PLAN.md` already deprioritised F4
-- on the grounds that validation allocates nothing above its output, leaving
-- a CPU-only benefit that nobody had measured -- and the same gap is what
-- made `bench/study/parse-cost.lua` argue for a C tokeniser on 46.6% of a
-- request's CPU that had already been removed in Lua.
--
-- So: measure first, and price the ceiling by Amdahl before writing a
-- generator. If validation is three percent of a request, a perfect codegen
-- is worth 1.03x and the answer is no, exactly as it was for the tokeniser
-- at 8.1%.
--
-- ## THE ANSWER, on the benchmark box, spreads of 0.5% to 1.6%
--
--     one field, as `/users/:id` declares   1.07 us   1.16%   ceiling 1.012x
--     six fields, a real POST               3.67 us   3.95%   ceiling 1.041x
--
-- **F4 is refused at 1.04x.** That is what codegen would buy if it made
-- validation FREE, and no generator does. The bar this project set before
-- the LuaJIT spike was 2x; the C tokeniser was refused at 1.09x.
--
-- And the ceiling does not price the risk. `akkar.from_spec` passes schemas
-- that came from DATA straight to route registration, so in a multi-tenant
-- case the field names are a third party's -- and a generator that
-- interpolates a field name into Lua source is code injection. `docs/PLAN.md`
-- wrote that constraint down before any code existed. Paying an injection
-- surface for four percent is a bad trade at any reading.
--
-- THE SHAPES ARE THE ONES THAT RUN. `bench/study/apps/serve.lua` validates
-- `{ id = akkar.v.integer { min = 1 } }` on `/users/:id`, which is the route
-- the regression harness alternates on. The heavier shapes below are what a
-- real POST looks like, because a one-field param schema would understate
-- the case F4 is for.
package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

local N = tonumber(os.getenv "N") or 200000

--- Validation is a local in `akkar/init.lua`, so it is exercised through the
--- only public thing that reaches it: a route with a schema, through
--- `app:test`. That includes the dispatch around it, which is why the bare
--- route below is measured too and subtracted.
local function client_for(schema, handler)
  local app = akkar.new()
  app:post("/v", schema and { body = schema } or nil,
           handler or function() return { ok = true } end)
  return app:test { log = akkar.log.new { level = "error",
                                          sink = function() end } }
end

--- ARMS ALTERNATE AND EACH IS MEASURED MANY TIMES, and the first version of
--- this file did neither. Run once each in sequence it reported validation of
--- one field at MINUS 6.22 us -- an impossibility, since validating cannot
--- make a request faster -- because the drift between the first arm and the
--- second was larger than the effect. A negative result means the instrument
--- cannot see the thing, not that the thing is free.
---
--- So: `ROUNDS` passes, arms interleaved within each pass so drift lands on
--- all of them, and the MINIMUM kept rather than the mean. The minimum is the
--- right summary for a CPU measurement -- noise only ever adds time -- and
--- the spread across passes is reported as the floor a difference must clear.
local ROUNDS = tonumber(os.getenv "ROUNDS") or 7

local function measure(arms, body_for)
  local samples = {}
  for name in pairs(arms) do samples[name] = {} end

  for _ = 1, ROUNDS do
    for name, client in pairs(arms) do
      local body = body_for(name)
      client:post("/v", { body = body })                 -- warm this pass
      local t0 = os.clock()
      for _ = 1, N do client:post("/v", { body = body }) end
      samples[name][#samples[name] + 1] = (os.clock() - t0) / N * 1e6
    end
  end

  local out = {}
  for name, list in pairs(samples) do
    table.sort(list)
    out[name] = { best = list[1], worst = list[#list] }
    out[name].spread = (list[#list] - list[1]) / list[1] * 100
  end
  return out
end

local SIX = {
  id      = akkar.v.integer { min = 1 },
  name    = "string",
  email   = "string",
  active  = "boolean?",
  score   = "number?",
  note    = "string?",
}

local arms = {
  bare = client_for(nil),
  one  = client_for { id = akkar.v.integer { min = 1 } },
  six  = client_for(SIX),
}

local bodies = {
  bare = { id = 42 },
  one  = { id = 42 },
  six  = { id = 42, name = "ada", email = "a@b.c",
           active = true, score = 9.5, note = "x" },
}

local r = measure(arms, function(name) return bodies[name] end)

print(("%d rounds of %d requests, arms interleaved\n"):format(ROUNDS, N))
for _, name in ipairs { "bare", "one", "six" } do
  print(("%-6s best %7.2f us   worst %7.2f us   spread %5.1f%%")
    :format(name, r[name].best, r[name].worst, r[name].spread))
end

local one_cost = r.one.best - r.bare.best
local six_cost = r.six.best - r.bare.best
local floor = math.max(r.bare.worst - r.bare.best, r.one.worst - r.one.best,
                       r.six.worst - r.six.best)

print()
print(("validation alone, one field  : %6.2f us"):format(one_cost))
print(("validation alone, six fields : %6.2f us"):format(six_cost))
print(("noise floor (worst spread)   : %6.2f us"):format(floor))
if one_cost <= floor then
  print("  -> the one-field cost is BELOW the floor and is not a result")
end

-- THE DENOMINATOR, WITH ITS PROVENANCE, and the same rule `parse-cost.lua`
-- learned the hard way: a share is two numbers, and dividing a numerator
-- measured here by a denominator measured somewhere else is not a share.
-- Run this ON the benchmark box, or pass that machine's own figure.
local CPU_US = tonumber(os.getenv "CPU_US") or 93.0

print()
print(("against %.1f us of CPU per request:"):format(CPU_US))
print(("  one field    : %5.2f%%   ceiling %.3fx")
  :format(one_cost / CPU_US * 100, 1 / (1 - one_cost / CPU_US)))
print(("  six fields   : %5.2f%%   ceiling %.3fx")
  :format(six_cost / CPU_US * 100, 1 / (1 - six_cost / CPU_US)))
print()
print("The ceiling is what codegen could buy if it made validation FREE,")
print("which no generator does. F3 refused LuaJIT at 1.62x against a bar of")
print("2x, and F5 refused a C tokeniser at 1.09x.")
