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
  it("does not let the client choose the request id", function()
    -- This test used to assert the opposite: `X-Request-Id` became `req.id`
    -- verbatim, "so a trace survives across services". That is the assertion
    -- that encoded the bug. `req.id` is the concurrency limiter's slot
    -- identity and every framework log line's `request_id`, so a client
    -- choosing it collapsed limiter slots and wrote its own fields into the
    -- operator's log.
    --
    -- What the client sent is still available, under a name that says whose
    -- it is.
    local app = akkar.new()
    app:get("/x", function(req)
      return { id = req.id, from_client = req.client_request_id }
    end)

    local res = app:test():get("/x", { headers = { ["X-Request-Id"] = "from-client" } })
    assert.are_not.equal("from-client", res.body.id)
    assert.equal("from-client", res.body.from_client)
    assert.equal(res.body.id, res.headers["x-request-id"])
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

    local res = app:test { log = logger }
      :get("/x", { headers = { ["x-request-id"] = "trace-me" } })

    local entry = cjson.decode(lines[#lines])
    assert.equal("handler ran", entry.message)
    -- The handler passed no id.  Correlation is a property of the logger, not
    -- something every call site has to remember.
    assert.equal(res.headers["x-request-id"], entry.request_id)
    -- And the caller's own id rides along beside it, named as theirs, so a
    -- line can still be joined to an upstream's logs.
    assert.equal("trace-me", entry.client_request_id)
    assert.equal(1, entry.detail)
  end)

  it("puts a request id on an error response too", function()
    local app = akkar.new()
    app:get("/boom", function() error "nope" end)
    local res = app:test():get("/boom", { headers = { ["x-request-id"] = "trace-error" } })
    assert.equal(500, res.status)
    assert.is_string(res.headers["x-request-id"])
    assert.are_not.equal("trace-error", res.headers["x-request-id"])
  end)
end)

describe("numbers that came back from JSON", function()
  -- A job payload round-trips through JSON, and a JSON number returns as a Lua
  -- float. So `account_id = 7` in a handler became `account_id=7.0` in akkar's
  -- OWN log line, which reads like a bug to anybody grepping for an id and is
  -- not one.
  --
  -- Reported by someone writing the beginner guide, who found it by pasting
  -- real output into a page and seeing that it looked wrong on the screen --
  -- which is the third defect that writing documentation has surfaced.
  local log = require "akkar.log"

  local function line_for(fields)
    local seen
    local l = log.new {
      level = "info", format = "text",
      sink = function(text) seen = text end,
    }
    l:info("m", fields)
    return seen
  end

  it("prints a whole float as an integer", function()
    assert.is_truthy(line_for { account_id = 7.0 }:find("account_id=7", 1, true))
    assert.is_falsy(line_for { account_id = 7.0 }:find("7.0", 1, true))
    assert.is_truthy(line_for { delta = -3.0 }:find("delta=-3", 1, true))
  end)

  it("leaves a real fraction alone", function()
    -- The rendering must not round. A duration is still a duration.
    assert.is_truthy(line_for { seconds = 2.5 }:find("seconds=2.5", 1, true))
    assert.is_truthy(line_for { seconds = 0.001 }:find("0.001", 1, true))
  end)

  it("does not pretend a huge float is an exact integer", function()
    -- Past 2^53 a float cannot represent every integer, so `%d` would print a
    -- number that was never the value. The float rendering at least admits
    -- the imprecision.
    local line = line_for { huge = 2 ^ 60 }
    assert.is_truthy(line:find("e+", 1, true),
      "a float too large to be exact was printed as though it were: " .. line)
  end)

  it("leaves integers and strings as they were", function()
    assert.is_truthy(line_for { n = 7 }:find("n=7", 1, true))
    assert.is_truthy(line_for { s = "7.0" }:find("s=7.0", 1, true))
  end)
end)
