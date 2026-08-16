--[[
Hostile input against a running server.

This project's own history says this is where the finds are. Three defects
reached a live server before anyone saw them, and every one was invisible to
the in-process suite: an oversized body that got through, `headers:get`
returning zero values rather than nil -- which broke every GET -- and cjson's
null sentinel rejecting `{"email": null}` on an optional field. All three were
found by throwing edge cases at a running server and reading the log.

## The properties, which matter more than the corpus

For every input, whatever it is:

  * the process survives, and the next request is still answered;
  * a malformed CLIENT input is a 4xx, NEVER a 5xx. A 500 means akkar blamed
    itself for the caller's mistake, or raised somewhere it did not expect to;
  * `in_flight` comes back to zero, so nothing is left half-counted;
  * and `app:stop` still terminates.

## WHAT THIS DOES NOT COVER, and why

Framing. Everything here goes through lua-http's client, so every request is
well-framed by construction: a lying `Content-Length`, a duplicated one, a bad
chunk size, a chunked body that never terminates, a missing `Host` -- none of
those can be expressed here, and they are exactly the shapes an attacker
reaches for first.

A raw-socket harness was written for them and is not in this file. Sending
those bytes from the same `cqueues` controller that runs the server deadlocks:
the client waits for a reply the server cannot write until the client yields,
and the whole harness stops with no output. `cqueues.poll` and
`socket:settimeout` both failed to break it. The honest fix is a client in a
separate PROCESS, which is a different piece of work.

So: framing is unfuzzed, it is written down here rather than left as a gap
somebody assumes is covered, and `bench/` is where that harness belongs.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local request = require "http.request"

local PORT = 8385
local BODY_LIMIT = 16 * 1024

--- Every case is (label, method, path, content-type, body).
local function corpus()
  local nested = string.rep("[", 300) .. string.rep("]", 300)
  local big    = string.rep("x", BODY_LIMIT + 4096)

  return {
    { "a path that climbs out",        "GET", "/users/%2e%2e%2f%2e%2e%2fetc%2fpasswd" },
    { "a path with an encoded null",   "GET", "/users/%00" },
    { "a path with an encoded slash",  "GET", "/users/a%2Fb" },
    { "double slashes",                "GET", "//users//1" },
    { "a trailing dot segment",        "GET", "/users/1/." },
    { "a very long path",              "GET", "/users/" .. string.rep("a", 8000) },
    { "a very long query string",      "GET", "/users?" .. string.rep("k=v&", 3000) },
    { "a query key with no value",     "GET", "/users?k" },
    { "repeated query keys",           "GET", "/users?id=1&id=2&id=3" },
    { "an unknown method",             "FROBNICATE", "/users" },
    { "HEAD on a route that has one",  "HEAD", "/users" },
    { "OPTIONS on a known route",      "OPTIONS", "/users" },

    { "truncated JSON",       "POST", "/users", "application/json", '{"name"' },
    { "JSON that is a bare null", "POST", "/users", "application/json", "null" },
    { "JSON that is a number", "POST", "/users", "application/json", "42" },
    { "JSON with a null field", "POST", "/users", "application/json", '{"name":null}' },
    { "deeply nested JSON",   "POST", "/users", "application/json", nested },
    { "invalid utf-8",        "POST", "/users", "application/json", '{"name":"\255\254"}' },
    { "an enormous number",   "POST", "/users", "application/json",
      '{"name":"a","n":' .. string.rep("9", 400) .. "}" },
    { "an empty body with a JSON type", "POST", "/users", "application/json", "" },
    { "a body past the limit", "POST", "/users", "application/json", big },
    { "an unknown content type", "POST", "/users", "application/x-nonsense", '{"name":"a"}' },
    { "form encoding",        "POST", "/users", "application/x-www-form-urlencoded", "name=ada" },
    { "form encoding, malformed", "POST", "/users",
      "application/x-www-form-urlencoded", "%%%=&&=" },
    { "multipart with no boundary", "POST", "/users", "multipart/form-data", "whatever" },
    { "multipart whose boundary never closes", "POST", "/users",
      "multipart/form-data; boundary=zzz",
      "--zzz\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nvalue\r\n" },
  }
end

local function attempt(case)
  local label, method, path, content_type, body = table.unpack(case, 1, 5)
  local status
  local ok = pcall(function()
    local req = request.new_from_uri("http://127.0.0.1:" .. PORT .. path)
    req.headers:upsert(":method", method)
    if body then
      req.headers:upsert("content-type", content_type)
      req:set_body(body)
    end
    local headers, stream = req:go(5)
    if headers then
      status = tonumber(headers:get ":status")
      stream:get_body_as_string(5)
    end
  end)
  return { label = label, ok = ok, status = status }
end

describe("hostile input", function()
  local app, results, survived, in_flight_after

  setup(function()
    app = akkar.new()
    app:get("/users", function() return { users = {} } end)
    app:get("/users/:id", function(req) return { id = req.params.id } end)
    app:post("/users", { body = { name = "string" } },
             function(req) return akkar.created { name = req.body.name } end)

    results = {}
    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false, timeout = 2,
                  body_limit = BODY_LIMIT,
                  log = akkar.log.new { level = "error", sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.3)

      for _, case in ipairs(corpus()) do
        results[#results + 1] = attempt(case)
      end

      -- A seeded mutation pass over a well-formed body, replayable rather
      -- than a story about a Tuesday.
      --
      -- Its OWN generator, and that is not fussiness. Calling
      -- `math.randomseed` here made every later spec deterministic too, and
      -- several of them -- `idempotency_spec`, `limit_spec`, `jobs_spec` --
      -- depend on `math.random` for a fresh key prefix per run. With a fixed
      -- seed those keys repeat across runs, so the second run of the day
      -- inherits the first run's Redis state and eight tests fail. Found by
      -- running the whole suite: the file passes alone.
      local seed = 20260815
      local function next_random(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return (seed % n) + 1
      end

      local base = '{"name":"ada","note":"hello"}'
      for i = 1, 40 do
        local at = next_random(#base)
        local mutated = base:sub(1, at - 1) ..
                        string.char(31 + next_random(224)) ..
                        base:sub(at + 1)
        results[#results + 1] = attempt {
          "mutation " .. i, "POST", "/users", "application/json", mutated,
        }
      end

      survived = attempt { "after everything", "GET", "/users" }.status
      cqueues.sleep(0.2)
      in_flight_after = app.in_flight
      app:stop(3)
    end)
    assert(cq:loop(120))
  end)

  it("survives every one of them", function()
    assert.equal(200, survived, "the server stopped answering after the corpus")
  end)

  it("never blames itself for the caller's mistake", function()
    -- A 5xx here is akkar's bug, not the client's.
    local blamed = {}
    for _, result in ipairs(results) do
      if result.status and result.status >= 500 then
        blamed[#blamed + 1] = result.label .. " -> " .. result.status
      end
    end
    assert.equal(0, #blamed, "answered 5xx: " .. table.concat(blamed, ", "))
  end)

  it("answers or closes cleanly, and never hangs", function()
    -- Two of these get no answer at all, and the fuzzer is how that was
    -- found. Measured afterwards: a request line up to 4000 bytes reaches
    -- akkar and gets a 404; at 8000 lua-http drops the connection BEFORE
    -- akkar sees anything -- proved with a middleware counter that never
    -- incremented. So akkar cannot answer 414 for it and cannot log it: the
    -- request never existed as far as this framework is concerned.
    --
    -- That is a property of the substrate, pinned in `spec/substrate_spec`,
    -- and a closed connection is a legitimate answer to a request line that
    -- long. What must never happen is a HANG, which is what this asserts.
    local hung = {}
    for _, result in ipairs(results) do
      if not result.ok then hung[#hung + 1] = result.label end
    end
    assert.equal(0, #hung,
      "neither answered nor closed: " .. table.concat(hung, ", "))

    local silent = {}
    for _, result in ipairs(results) do
      if not result.status then silent[#silent + 1] = result.label end
    end
    assert.is_true(#silent <= 2,
      "more inputs than expected got no answer: " .. table.concat(silent, ", "))
  end)

  it("leaves nothing half-counted", function()
    assert.equal(0, in_flight_after, "the in-flight count did not return to zero")
  end)

  it("refuses a body past the limit rather than reading it", function()
    local oversized
    for _, result in ipairs(results) do
      if result.label == "a body past the limit" then oversized = result.status end
    end
    assert.equal(413, oversized,
      "a body past body_limit was answered " .. tostring(oversized))
  end)

  it("actually reached the server", function()
    -- A corpus that never arrived would pass everything above.
    local answered = 0
    for _, result in ipairs(results) do
      if result.status then answered = answered + 1 end
    end
    assert.is_true(answered > 50,
      "only " .. answered .. " inputs got a status; the harness is not reaching akkar")
  end)
end)
