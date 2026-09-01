--[[
Three things the runtime used to do quietly, and one it used to accept.

  A 500 left no trace. `error_kind = type(err)` was the whole log line, so a
  real outage produced five lines of `ERROR stream failed error_kind=string`
  and nothing that said what failed or where. The reasoning behind removing
  the text (commit f1c1388) is right for the RESPONSE BODY -- a Lua error
  carries file paths, line numbers and sometimes credentials -- and was
  over-applied to the LOG, which nobody outside the process reads.

  `app:use()` after the first request was dropped in silence, because the
  chain is memoised. Auth middleware registered late meant no auth and no
  warning.

  `v.integer` tested `value % 1 ~= 0`, which is a test for a fractional part
  and not for an integer: `1e15` and `1e308` are both whole and both floats.
  On the branch this runtime is being validated against, those are prices and
  quantities.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local request = require "http.request"
local v       = akkar.v

--- The framework's own voice is replaced by `app:run { log = ... }`, not by
--- the test client, so these run against a real server -- which is also the
--- path the outage that motivated this happened on.
local PORT = 8397

local function lines_from(routes, paths)
  local lines = {}
  local app = akkar.new()
  routes(app)

  local cq = cqueues.new()
  cq:wrap(function()
    pcall(function()
      app:run { port = PORT, check_capabilities = false,
                log = akkar.log.new { level = "error", format = "text",
                                      sink = function(l) lines[#lines + 1] = l end } }
    end)
  end)
  cq:wrap(function()
    cqueues.sleep(0.12)
    for _, path in ipairs(paths) do
      local req = request.new_from_uri("http://127.0.0.1:" .. PORT .. path)
      local headers, stream = req:go(5)
      assert(headers, "no response for " .. path)
      -- Reading the body finishes the exchange; leaving it unread holds the
      -- connection until lua-http's intra-stream timeout.  Bounded and
      -- forgiving, because a failed stream producer deliberately drops the
      -- connection without its terminating chunk -- which is one of the
      -- cases under test.
      pcall(function() stream:get_body_as_string(2) end)
      pcall(function() stream:shutdown() end)
    end
    app:stop(1)
  end)
  assert(cq:loop())
  return table.concat(lines, "\n")
end

describe("what a 500 leaves behind", function()
  it("names the failure and the frame it came from", function()
    -- Before this, the entire record of a 500 was
    --     ERROR handler raised at=... error_kind=string
    -- which says a string was raised and nothing about which one.
    local line = lines_from(function(app)
      app:get("/boom", function() error "the cursor died" end)
    end, { "/boom" })

    assert.is_truthy(line:find("the cursor died", 1, true), line)
    assert.is_truthy(line:find("runtime_diagnostics_spec.lua:", 1, true), line)
    assert.is_truthy(line:find("traceback=", 1, true), line)
  end)

  it("keeps every bit of that out of the response", function()
    -- The distinction the whole fix rests on: the operator sees the cause,
    -- the client sees a bare 500 and a correlation id.
    local app = akkar.new()
    app:get("/boom", function() error "select * from secrets where id = 1" end)

    local res = app:test():get "/boom"
    assert.equal(500, res.status)
    assert.equal("internal server error", res.body.error)
    assert.is_nil(res.body.traceback)
    assert.is_nil(res.body.detail)
    assert.is_string(res.headers["x-request-id"])
    assert.is_falsy(require("cjson").encode(res.body):find("secrets", 1, true))
  end)

  it("says it for a middleware that raised, too", function()
    local line = lines_from(function(app)
      app:use(function() error "the session store is gone" end)
      app:get("/x", function() return { ok = true } end)
    end, { "/x" })

    assert.is_truthy(line:find("the session store is gone", 1, true), line)
    assert.is_truthy(line:find("runtime_diagnostics_spec.lua:", 1, true), line)
  end)

  it("says it for a stream producer that raised, too", function()
    -- A stream cannot become a 500 -- the status went out with the first
    -- byte -- so the log is the ONLY record that anything went wrong.
    local line = lines_from(function(app)
      app:get("/export", function()
        return akkar.stream(function(write)
          write "["
          error "the export query failed halfway"
        end)
      end)
    end, { "/export" })

    assert.is_truthy(line:find("the export query failed halfway", 1, true), line)
  end)

  it("folds the traceback onto one line, because logfmt is one line", function()
    local text = lines_from(function(app)
      app:get("/boom", function() error "nope" end)
    end, { "/boom" })

    -- One entry, so one line: a traceback that breaks that is a traceback no
    -- collector reassembles.
    local entries = 0
    for _ in text:gmatch "[^\n]+" do entries = entries + 1 end
    assert.equal(1, entries, text)
  end)

  it("does not wrap a response thrown as control flow", function()
    -- Response-as-error is how a deep layer signals HTTP without threading a
    -- return value back through every frame, and it must survive the
    -- traceback machinery untouched.
    local app = akkar.new()
    app:get("/x", function() error(akkar.forbidden "not yours") end)

    local res = app:test():get "/x"
    assert.equal(403, res.status)
    assert.equal("not yours", res.body.error)
  end)

  it("hands the application's on_error the original error, not a wrapper", function()
    local seen
    local app = akkar.new()
    app:on_error(function(err) seen = err return akkar.response(500, { seen = true }) end)
    app:get("/boom", function() error "raw text" end)

    app:test():get "/boom"
    assert.equal("string", type(seen))
    assert.is_truthy(seen:find("raw text", 1, true))
  end)
end)

describe("app:use() after the first request", function()
  it("runs rather than being dropped", function()
    -- WHAT THIS ASSERTS WAS WEAKENED DELIBERATELY -- from `pcall` catching a
    -- raise to a status code -- and the weaker-looking assertion is the
    -- stronger repair.
    --
    -- Refusing a late `app:use` fixes the silence and keeps the loss: the
    -- author still does not get the middleware they registered, and now they
    -- get a crash for asking. The cause was never the timing, it was the
    -- memo: the chain is built once and cached, and `use` appended to a list
    -- nobody read again. Invalidating that cache -- `self._chain,
    -- self._chain_short = nil, nil` in `App:use` -- makes the next request
    -- rebuild, so the middleware the author registered is the middleware
    -- that runs. Auth added one line late now authenticates instead of
    -- raising, and nothing has to be reordered to make it work.
    --
    -- So the test is that it RUNS. A version that raises fails here, which is
    -- the guard: refusing the call must not come back as a fix.
    local app = akkar.new()
    app:get("/x", function() return { ok = true } end)
    local client = app:test()
    assert.equal(200, client:get("/x").status)

    app:use(function(req, next) return akkar.unauthorized() end)
    assert.equal(401, client:get("/x").status,
                 "the late middleware was accepted and never ran")
  end)

  it("runs after app:test{} builds the chain, before any request", function()
    -- `app:test()` builds the chain, so this is the same defect with no
    -- request in it: the memo exists, and the middleware registered against
    -- it must still reach the first request that arrives.
    local app = akkar.new()
    app:get("/x", function() return { ok = true } end)
    local client = app:test()
    app:use(function(req, next) return akkar.unauthorized() end)
    assert.equal(401, client:get("/x").status,
                 "the chain app:test{} built was never rebuilt")
  end)

  it("still allows every middleware registered before the first request", function()
    local app = akkar.new()
    app:use(function(req, next) return next(req) end)
    app:get("/x", function() return { ok = true } end)
    app:use(function(req, next) return next(req) end)
    assert.equal(200, app:test():get("/x").status)
  end)
end)

describe("v.integer", function()
  local function query(rule, qs)
    local app = akkar.new()
    app:get("/x", { query = { n = rule } },
            function(req) return { n = req.query.n, kind = math.type(req.query.n) } end)
    return app:test():get("/x?n=" .. qs)
  end

  local function body(rule, value)
    local app = akkar.new()
    app:post("/x", { body = { n = rule } },
             function(req) return { n = req.body.n, kind = math.type(req.body.n) } end)
    return app:test():post("/x", { body = { n = value } })
  end

  it("rejects a float dressed as a whole number", function()
    -- `1e1` passed `% 1 == 0`, validated, and then raised inside the SQL
    -- builder -- an unauthenticated query string producing a 500. It is
    -- accepted here only because it converts EXACTLY, and it arrives as an
    -- integer rather than as 10.0.
    local res = query(v.integer { min = 1 }, "1e1")
    assert.equal(200, res.status)
    assert.equal(10, res.body.n)
    assert.equal("integer", res.body.kind)
  end)

  it("rejects a value too large for an integer to exist", function()
    assert.equal(422, query(v.integer { min = 1 }, "1e308").status)
  end)

  it("rejects anything at or past the precision cliff", function()
    -- cjson decodes 9007199254740993 as ...992. Accepting that would round
    -- somebody's amount by one and call it valid.
    assert.equal(422, body(v.integer {}, 9007199254740992.0).status)
    assert.equal(422, body(v.integer {}, 2.0 ^ 60).status)
  end)

  it("rejects a fraction", function()
    assert.equal(422, query(v.integer {}, "1.5").status)
    assert.equal(422, body(v.integer {}, 1.5).status)
    assert.equal("expected integer",
                 body(v.integer {}, 1.5).body.fields["body.n"])
  end)

  it("rejects the values that are not numbers at all", function()
    assert.equal(422, body(v.integer {}, 0 / 0).status)          -- nan
    assert.equal(422, body(v.integer {}, math.huge).status)
  end)

  it("still takes the integers it always took", function()
    assert.equal(7, query(v.integer { min = 1, max = 9 }, "7").body.n)
    assert.equal(7, body(v.integer {}, 7).body.n)
    assert.equal(-7, body(v.integer {}, -7).body.n)
    assert.equal(0, body(v.integer {}, 0).body.n)
    -- A whole float that converts exactly is the value it says it is.
    assert.equal(3, body(v.integer {}, 3.0).body.n)
    assert.equal("integer", body(v.integer {}, 3.0).body.kind)
  end)

  it("leaves v.number alone", function()
    assert.equal(200, body(v.number {}, 1.5).status)
    assert.equal(200, query(v.number {}, "1e15").status)
  end)

  it("applies min and max to the converted value", function()
    assert.equal(422, query(v.integer { min = 11 }, "1e1").status)
    assert.equal(200, query(v.integer { max = 10 }, "1e1").status)
  end)
end)
