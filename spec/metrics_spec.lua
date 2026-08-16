--[[
Prometheus metrics.

The property worth pinning hardest is label cardinality: a series per request
path is how a metrics backend falls over, and it is an easy mistake for a
framework to hand its users.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local metrics = require "akkar.metrics"

local function count_series(text, name)
  local n = 0
  for line in text:gmatch "[^\n]+" do
    if line:sub(1, #name) == name and line:sub(1, 1) ~= "#" then n = n + 1 end
  end
  return n
end

describe("metrics registry", function()
  it("counts requests by method, route and status", function()
    local registry = metrics.new()
    registry:observe("GET", "/users/:id", 200, 0.01)
    registry:observe("GET", "/users/:id", 200, 0.02)
    registry:observe("GET", "/users/:id", 404, 0.01)

    local text = registry:render()
    assert.is_truthy(text:match 'akkar_requests_total{method="GET",route="/users/:id",status="200"} 2')
    assert.is_truthy(text:match 'akkar_requests_total{method="GET",route="/users/:id",status="404"} 1')
  end)

  it("renders a histogram with cumulative buckets", function()
    local registry = metrics.new { buckets = { 0.01, 0.1, 1 } }
    registry:observe("GET", "/x", 200, 0.005)
    registry:observe("GET", "/x", 200, 0.05)
    registry:observe("GET", "/x", 200, 5)

    local text = registry:render()
    -- Cumulative: le=0.01 has one, le=0.1 has two, +Inf has all three.
    assert.is_truthy(text:match 'le="0.01"} 1')
    assert.is_truthy(text:match 'le="0.1"} 2')
    assert.is_truthy(text:match 'le="%+Inf"} 3')
    assert.is_truthy(text:match "akkar_request_duration_seconds_count{[^}]*} 3")
  end)

  it("escapes a label value that would break the scrape", function()
    local registry = metrics.new()
    registry:observe("GET", 'weird"route\\here', 200, 0.01)
    local text = registry:render()
    assert.is_truthy(text:find 'weird\\"route\\\\here', 1, true)
  end)

  it("renders gauges", function()
    local registry = metrics.new()
    registry:gauge("akkar_pool_idle", 7)
    assert.is_truthy(registry:render():match "akkar_pool_idle 7")
  end)
end)

describe("metrics through requests", function()
  local function instrumented()
    local registry = metrics.new()
    local app = akkar.new()
    app:use(registry:middleware())
    app:get("/users/:id", function(req) return { id = req.params.id } end)
    registry:serve(app, "/metrics")
    return app, registry
  end

  it("labels by route pattern, not by path", function()
    local app, registry = instrumented()
    local c = app:test()
    for i = 1, 50 do c:get("/users/" .. i) end

    local text = registry:render()
    -- Fifty distinct paths, one series.  Labelling by req.path would have
    -- produced fifty, and a million requests would produce a million.
    assert.equal(1, count_series(text, "akkar_requests_total"))
    assert.is_truthy(text:match 'route="/users/:id",status="200"} 50')
  end)

  it("does not create a series per probed URL", function()
    local app, registry = instrumented()
    local c = app:test()
    for i = 1, 20 do c:get("/wp-admin/" .. i .. ".php") end

    local text = registry:render()
    assert.equal(1, count_series(text, "akkar_requests_total"))
    assert.is_truthy(text:match 'route="<unmatched>"')
  end)

  it("observes a thrown response and a raised error, not just a return", function()
    -- The middleware read `local res = next(req)` and observed `res.status`.
    -- Raising is how akkar expresses a deliberate 404 and how a handler error
    -- becomes a 500, so neither ever reached the histogram: the scrape showed
    -- a clean latency distribution over the requests that happened to succeed
    -- and said nothing about the ones that did not.
    --
    -- An operator reads this during an incident, and during an incident the
    -- errors are the traffic.
    local registry = metrics.new()
    local app = akkar.new()
    app:use(registry:middleware())
    app:get("/gone", function() error(akkar.not_found "no such user") end)
    app:get("/boom", function() error "the cursor died" end)
    app:get("/fine", function() return { ok = true } end)

    local c = app:test { log = akkar.log.new { level = "error", sink = function() end } }
    assert.equal(404, c:get("/gone").status)
    assert.equal(500, c:get("/boom").status)
    assert.equal(200, c:get("/fine").status)

    local text = registry:render()
    assert.is_truthy(text:match 'route="/gone",status="404"} 1',
      "a thrown response never reached the histogram")
    assert.is_truthy(text:match 'route="/boom",status="500"} 1',
      "a raised error never reached the histogram")
    assert.is_truthy(text:match 'route="/fine",status="200"} 1')
    assert.equal(3, count_series(text, "akkar_requests_total"))
  end)

  it("still lets the error through after measuring it", function()
    -- Measuring must not swallow. A middleware that observed an error and
    -- returned normally would turn every 500 into a 200 with no body.
    local registry = metrics.new()
    local app = akkar.new()
    app:use(registry:middleware())
    app:get("/gone", function() error(akkar.not_found "no such user") end)

    local res = app:test():get "/gone"
    assert.equal(404, res.status)
    assert.equal("no such user", res.body.error)
  end)

  it("serves the exposition over HTTP as text, not JSON", function()
    local app = instrumented()
    local res = app:test():get "/metrics"
    assert.equal(200, res.status)
    assert.is_truthy(res.raw:match "# TYPE akkar_requests_total counter")
    assert.is_nil(res.body)
  end)

  it("reads gauge sources at scrape time", function()
    local registry = metrics.new()
    local app = akkar.new()
    local depth = 3
    registry:serve(app, "/metrics", { akkar_queue_depth = function() return depth end })

    assert.is_truthy(app:test():get("/metrics").raw:match "akkar_queue_depth 3")
    depth = 9
    assert.is_truthy(app:test():get("/metrics").raw:match "akkar_queue_depth 9")
  end)

  it("survives a gauge source that raises", function()
    local registry = metrics.new()
    local app = akkar.new()
    registry:serve(app, "/metrics", { broken = function() error "no" end })
    -- A broken gauge must not take the scrape down with it.
    assert.equal(200, app:test():get("/metrics").status)
  end)
end)

describe("memory metrics", function()
  local metrics = require "akkar.metrics"
  local akkar = require "akkar"

  it("reports the Lua heap and the process resident size", function()
    local registry = metrics.new()
    local lua_bytes, rss_bytes = registry:memory()
    assert.is_true(lua_bytes > 0)
    -- Two numbers because they answer different questions: the Lua heap says
    -- whether the application is holding tables, RSS says what the OS thinks
    -- the process costs including the C side.
    assert.is_true(rss_bytes > lua_bytes)
  end)

  it("always includes them in a scrape", function()
    local registry = metrics.new()
    local app = akkar.new()
    registry:serve(app, "/metrics")

    local text = app:test():get("/metrics").raw
    assert.is_truthy(text:match "akkar_lua_heap_bytes %d+")
    assert.is_truthy(text:match "akkar_process_resident_bytes %d+")
  end)

  it("tracks the heap growing", function()
    -- Collect first, or this measures the wrong thing.  `memory()` reports
    -- LIVE bytes, so with a suite's worth of garbage still uncollected, a
    -- collection landing inside the loop below can free more than the ballast
    -- adds and the heap ends up smaller than it started.  This test passed
    -- alone and failed in the full suite for exactly that reason.
    collectgarbage(); collectgarbage()

    local registry = metrics.new()
    local before = registry:memory()
    local ballast = {}
    for i = 1, 200000 do ballast[i] = { i } end
    local after = registry:memory()
    assert.is_true(after > before,
      string.format("heap did not grow: %.0f -> %.0f bytes", before, after))
    ballast = nil
  end)
end)
