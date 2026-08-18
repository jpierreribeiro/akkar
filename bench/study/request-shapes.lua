-- What a request costs when it looks like a request.
--
-- WHY THIS EXISTS. Every measurement in this repository used the same
-- fixture: three short headers, identical on every request, a 13-byte
-- response, no request body, one keep-alive connection, no TLS, and a route
-- with no schema. That fixture hid a header parse whose cost grew with the
-- value's length -- 45% of a production request's CPU, found by accident.
--
-- So the fixture itself is under suspicion, and this measures the same server
-- under shapes that differ one at a time. Anything that moves a lot was being
-- hidden.
--
-- Each shape is a hypothesis: "the benchmark's choice of X hides the cost of
-- Y". A shape that measures the same as the baseline REFUTES its hypothesis,
-- and that is worth as much as one that does not.
package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local socket  = require "cqueues.socket"
local akkar   = require "akkar"

local N    = tonumber(os.getenv "N") or 2000
local PORT = tonumber(os.getenv "PORT") or (9600 + math.random(0, 300))

-- ------------------------------------------------------------- the shapes
--
-- `headers` is what the client sends beyond Host and Connection.
-- `path` selects the route. `body` is a request body, or nil.
local BROWSERISH = {
  "user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  "accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
  "accept-language: en-GB,en;q=0.9,pt-BR;q=0.8",
  "accept-encoding: gzip, deflate, br",
  "cookie: session=8f3a9c2e1b7d4f6a0e5c3b8d2f7a1e9c; consent=1; theme=dark",
  "referer: https://example.com/previous/page?utm_source=x",
}

local SHAPES = {
  { name = "baseline: 3 short headers, /ping",
    path = "/ping" },

  { name = "+ 6 browser headers",
    path = "/ping", headers = BROWSERISH },

  { name = "+ headers UNIQUE per request",
    path = "/ping", headers = BROWSERISH, unique = true },

  { name = "a validated route, /users/42",
    path = "/users/42?limit=10&cursor=abc" },

  { name = "a validated route WITH browser headers",
    path = "/users/42?limit=10&cursor=abc", headers = BROWSERISH },

  { name = "a 4 KB JSON response",
    path = "/big" },

  { name = "a 64 KB JSON response",
    path = "/huge" },

  { name = "a POST with a 2 KB JSON body",
    path = "/echo", body = true },

  { name = "a NEW CONNECTION per request",
    path = "/ping", fresh = true },
}

-- --------------------------------------------------------------- the app
local app = akkar.new()
app:get("/ping", function() return { pong = true } end)

app:get("/users/:id", {
  params = { id = akkar.v.integer { min = 1 } },
  query  = { limit = "integer?", cursor = "string?" },
}, function(req) return { id = req.params.id, name = "user", email = "u@x.com" } end)

local BIG  = {} for i = 1, 60  do BIG[i]  = { id = i, name = "row " .. i, note = "some text here" } end
local HUGE = {} for i = 1, 900 do HUGE[i] = { id = i, name = "row " .. i, note = "some text here" } end
app:get("/big",  function() return { rows = BIG } end)
app:get("/huge", function() return { rows = HUGE } end)

app:post("/echo", { body = { payload = "string" } },
  function(req) return { got = #req.body.payload } end)

local REQUEST_BODY = ('{"payload":"%s"}'):format(("x"):rep(2000))

-- --------------------------------------------------------------- the run
local cq = cqueues.new()
local results = {}

cq:wrap(function()
  pcall(function()
    app:run { port = PORT, check_capabilities = false,
              log = akkar.log.new { level = "error", sink = function() end } }
  end)
end)

cq:wrap(function()
  cqueues.sleep(0.4)

  local function connect()
    local c = assert(socket.connect("127.0.0.1", PORT))
    c:setmode("bn", "bn")
    c:settimeout(20)
    return c
  end

  --- One exchange. Returns false if the server did not answer 2xx, because a
  --- shape measured against an error is a shape measured against nothing.
  local function exchange(c, shape, i)
    local lines = { ("%s %s HTTP/1.1"):format(shape.body and "POST" or "GET", shape.path),
                    "host: x", "connection: keep-alive" }
    for _, h in ipairs(shape.headers or {}) do
      lines[#lines + 1] = shape.unique and (h .. "-" .. i) or h
    end
    if shape.body then
      lines[#lines + 1] = "content-type: application/json"
      lines[#lines + 1] = "content-length: " .. #REQUEST_BODY
    end
    c:write(table.concat(lines, "\r\n") .. "\r\n\r\n" .. (shape.body and REQUEST_BODY or ""))

    local status, len
    while true do
      local line = c:read "*l"
      if not line then return false end
      status = status or line:match "^HTTP/1%.1 (%d+)"
      if line == "" or line == "\r" then break end
      local n = line:lower():match "^content%-length:%s*(%d+)"
      if n then len = tonumber(n) end
    end
    if len and len > 0 then c:read(len) end
    return status == "200"
  end

  for _, shape in ipairs(SHAPES) do
    local c = not shape.fresh and connect() or nil
    local ok = true
    for i = 1, 200 do                       -- warm
      local conn = shape.fresh and connect() or c
      ok = exchange(conn, shape, i) and ok
      if shape.fresh then conn:close() end
    end
    if not ok then
      results[#results + 1] = { shape.name, -1, -1, "NOT 2xx" }
    else
      collectgarbage(); collectgarbage()
      collectgarbage "stop"
      local before = collectgarbage "count"
      local t0 = os.clock()
      for i = 1, N do
        local conn = shape.fresh and connect() or c
        exchange(conn, shape, i)
        if shape.fresh then conn:close() end
      end
      local micros = (os.clock() - t0) / N * 1e6
      local bytes  = (collectgarbage "count" - before) * 1024 / N
      collectgarbage "restart"
      results[#results + 1] = { shape.name, micros, bytes }
    end
    if c then c:close() end
  end

  app:stop(1)
end)

assert(cq:loop(600))

print(("%-44s %10s %12s %8s"):format("shape", "us/req", "bytes/req", "vs base"))
local base_us, base_b
for _, r in ipairs(results) do
  if not base_us then base_us, base_b = r[2], r[3] end
  if r[4] then
    print(("%-44s %10s %12s"):format(r[1], r[4], ""))
  else
    print(("%-44s %10.1f %12.0f %7.2fx"):format(r[1], r[2], r[3], r[2] / base_us))
  end
end
