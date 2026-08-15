--[[
akkar.log and request correlation.

The sink is injectable, so these capture lines instead of writing them.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local log   = require "akkar.log"
local cjson = require "cjson"

local function capturing(options)
  local lines = {}
  options = options or {}
  options.sink = function(line) lines[#lines + 1] = line end
  return log.new(options), lines
end

describe("akkar.log", function()
  it("writes one JSON object per line", function()
    local logger, lines = capturing { format = "json" }
    logger:info("charged", { amount = 10, currency = "BRL" })

    assert.equal(1, #lines)
    local entry = cjson.decode(lines[1])
    assert.equal("info", entry.level)
    assert.equal("charged", entry.message)
    assert.equal(10, entry.amount)
    assert.equal("BRL", entry.currency)
    assert.is_number(entry.time)
  end)

  it("writes something a person can read in text mode", function()
    local logger, lines = capturing { format = "text" }
    logger:warn("slow query", { ms = 250 })
    assert.is_truthy(lines[1]:match "^WARN  slow query")
    assert.is_truthy(lines[1]:match "ms=250")
  end)

  it("drops lines below the configured level", function()
    local logger, lines = capturing { level = "warn" }
    logger:debug "invisible"
    logger:info "also invisible"
    logger:warn "visible"
    logger:error "visible too"
    assert.equal(2, #lines)
  end)

  it("rejects an unknown level at construction, not at the first call", function()
    local ok, err = pcall(log.new, { level = "verbose" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "unknown level")
  end)

  it("stringifies a value JSON cannot carry rather than dropping it", function()
    local logger, lines = capturing { format = "json" }
    logger:info("odd", { fn = print })
    -- A line that quietly loses a field is worse than an ugly one.
    assert.is_truthy(cjson.decode(lines[1]).fn)
  end)

  it("binds fields onto every line a derived logger writes", function()
    local logger, lines = capturing { format = "json" }
    local bound = logger:with { request_id = "abc123" }
    bound:info "first"
    bound:info("second", { extra = true })

    assert.equal("abc123", cjson.decode(lines[1]).request_id)
    assert.equal("abc123", cjson.decode(lines[2]).request_id)
    assert.is_true(cjson.decode(lines[2]).extra)
  end)

  it("leaves the parent logger unbound", function()
    local logger, lines = capturing { format = "json" }
    logger:with { request_id = "abc" }
    logger:info "parent"
    assert.is_nil(cjson.decode(lines[1]).request_id)
  end)
end)

describe("request correlation", function()
  it("keeps a request id the client supplied", function()
    local app = akkar.new()
    app:get("/x", function(req) return { id = req.id } end)

    local res = app:test():get("/x", { headers = { ["X-Request-Id"] = "from-client" } })
    -- Preserved so a trace survives across services.
    assert.equal("from-client", res.body.id)
    assert.equal("from-client", res.headers["x-request-id"])
  end)

  it("generates one when the client sends none", function()
    local app = akkar.new()
    app:get("/x", function(req) return { id = req.id } end)

    local res = app:test():get "/x"
    assert.is_string(res.body.id)
    assert.is_true(#res.body.id > 0)
    assert.equal(res.body.id, res.headers["x-request-id"])
  end)

  it("gives different requests different ids", function()
    local app = akkar.new()
    app:get("/x", function(req) return { id = req.id } end)
    local c = app:test()
    assert.are_not.equal(c:get("/x").body.id, c:get("/x").body.id)
  end)

  it("attaches the request id to what the handler logs, unasked", function()
    local logger, lines = capturing { format = "json" }
    local app = akkar.new()
    app:get("/x", function(req)
      req.log:info("handler ran", { detail = 1 })
      return { ok = true }
    end)

    app:test { log = logger }:get("/x", { headers = { ["x-request-id"] = "trace-me" } })

    local entry = cjson.decode(lines[#lines])
    assert.equal("handler ran", entry.message)
    -- The handler passed no id.  Correlation is a property of the logger, not
    -- something every call site has to remember.
    assert.equal("trace-me", entry.request_id)
    assert.equal(1, entry.detail)
  end)

  it("echoes the id on an error response too", function()
    local app = akkar.new()
    app:get("/boom", function() error "nope" end)
    local res = app:test():get("/boom", { headers = { ["x-request-id"] = "trace-error" } })
    assert.equal(500, res.status)
    assert.equal("trace-error", res.headers["x-request-id"])
  end)
end)
