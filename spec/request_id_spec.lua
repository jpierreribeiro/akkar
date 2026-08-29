--[[
`req.id` is akkar's, not the caller's.

This file exists because the framework got the same distinction right for
`X-Forwarded-For` -- seventy lines of comment on why a client-supplied address
must not be believed -- and wrong, twenty lines above it, for `X-Request-Id`,
which was taken verbatim with only a length check. Two consequences, both
reproduced against a running server:

  `akkar.limit` keys a concurrency slot on `req.id`. Clients all sending the
  same `X-Request-Id` shared ONE slot: peak 46 simultaneous requests against
  `limit = 2`. The only admission control the runtime has, defeated by a
  constant header.

  Every framework log line carries `request_id=<that string>`, and logfmt
  separates fields with spaces. One header --
  `abc level=error message=DB_DELETED actor=admin` -- wrote four fields into
  the operator's log, three of them lies.

What the client sent is still available. It is called `req.client_request_id`,
because reading it should be a decision rather than an inheritance.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local cjson = require "cjson"

local INJECTION = "abc level=error message=DB_DELETED actor=admin"

local function ids_app()
  local app = akkar.new()
  app:get("/x", function(req)
    return { id = req.id, from_client = req.client_request_id or false }
  end)
  return app:test()
end

describe("the request id akkar uses", function()
  it("is not the one the client asked for", function()
    local res = ids_app():get("/x", { headers = { ["x-request-id"] = "chosen-by-client" } })
    assert.are_not.equal("chosen-by-client", res.body.id)
    assert.are_not.equal("chosen-by-client", res.headers["x-request-id"])
  end)

  it("is unique even when every request sends the same header", function()
    -- This is the limiter defect stated at its source: `req.id` IS the slot
    -- identity, so a repeated id is a shared slot.
    local client, seen = ids_app(), {}
    for _ = 1, 40 do
      local id = client:get("/x", { headers = { ["x-request-id"] = "CONSTANT" } }).body.id
      assert.is_nil(seen[id], "two requests were handed the same slot identity")
      seen[id] = true
    end
  end)

  it("contains nothing a log format can be steered with", function()
    local client = ids_app()
    for _, header in ipairs {
      INJECTION,
      'x" , "level":"error',
      "a\nlevel=error",
      ("x"):rep(5000),
    } do
      local id = client:get("/x", { headers = { ["x-request-id"] = header } }).body.id
      assert.is_truthy(id:match "^[%w]+$", "id was not alphanumeric: " .. id)
    end
  end)
end)

describe("what the client sent", function()
  it("is kept, under a name that says whose it is", function()
    local res = ids_app():get("/x", { headers = { ["x-request-id"] = "upstream-42" } })
    assert.equal("upstream-42", res.body.from_client)
  end)

  it("survives the separators real id schemes use", function()
    for _, given in ipairs {
      "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
      "edge.eu-west-1.00193",
      "svc:orders:993",
      "req_A1b2C3",
    } do
      assert.equal(given,
        ids_app():get("/x", { headers = { ["x-request-id"] = given } }).body.from_client)
    end
  end)

  it("is dropped, not trimmed, when it carries anything else", function()
    -- Sanitising an id into a DIFFERENT id correlates a line to the wrong
    -- request, which is worse than not correlating at all.
    for _, given in ipairs {
      INJECTION,
      "spaces here",
      'quote"inside',
      "semi;colon",
      "new\nline",
      ("x"):rep(129),
    } do
      assert.equal(false,
        ids_app():get("/x", { headers = { ["x-request-id"] = given } }).body.from_client,
        "accepted: " .. given)
    end
  end)

  it("is capped at a UUID with room to spare, and 128 is still fine", function()
    local ok = ("a"):rep(128)
    assert.equal(ok,
      ids_app():get("/x", { headers = { ["x-request-id"] = ok } }).body.from_client)
  end)
end)

describe("the operator's log", function()
  local function capturing(options)
    local lines = {}
    options.sink = function(line) lines[#lines + 1] = line end
    return akkar.log.new(options), lines
  end

  it("cannot be given extra fields by a request header", function()
    -- logfmt is space-separated `key=value`, so this is field injection in
    -- the plainest possible form.
    local logger, lines = capturing { format = "text", level = "error" }
    local app = akkar.new()
    app:get("/boom", function() error "nope" end)

    app:test { log = logger }:get("/boom", { headers = { ["x-request-id"] = INJECTION } })

    local line = table.concat(lines, "\n")
    assert.is_falsy(line:find("actor=admin", 1, true))
    assert.is_falsy(line:find("message=DB_DELETED", 1, true))
  end)

  it("carries both ids on what the handler writes", function()
    local logger, lines = capturing { format = "json", level = "info" }
    local app = akkar.new()
    app:get("/x", function(req)
      req.log:info "handler ran"
      return { id = req.id }
    end)

    local res = app:test { log = logger }
      :get("/x", { headers = { ["x-request-id"] = "upstream-42" } })

    local entry = cjson.decode(lines[#lines])
    assert.equal(res.body.id, entry.request_id)
    assert.equal("upstream-42", entry.client_request_id)
  end)

  it("carries only akkar's id when the client's is unusable", function()
    local logger, lines = capturing { format = "json", level = "info" }
    local app = akkar.new()
    app:get("/x", function(req) req.log:info "handler ran" return { ok = true } end)

    app:test { log = logger }:get("/x", { headers = { ["x-request-id"] = INJECTION } })

    local entry = cjson.decode(lines[#lines])
    assert.is_string(entry.request_id)
    assert.is_nil(entry.client_request_id)
  end)
end)

describe("allocation", function()
  it("does not pay for client_request_id on a request without the header", function()
    -- `client_request_id` is resolved lazily through `req`'s metatable for
    -- the same reason `trace` and `ip` are: a ninth field in the constructor
    -- grew the table's hash part and cost 191 bytes on EVERY request. The
    -- ceiling in allocation_spec is the real guard; this asserts the shape
    -- that keeps it there.
    local app = akkar.new()
    app:get("/x", function(req) return { has = rawget(req, "client_request_id") ~= nil } end)
    assert.is_false(app:test():get("/x").body.has)
  end)
end)
