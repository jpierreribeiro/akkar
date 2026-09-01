--[[
Five small defects, each confirmed by running it.

They share a shape: a module states a property in its own comments and then
does not hold it. A logfmt line that a request body can add fields to. A
"yield budget" wrapper that produced zero yields. A multipart parser whose
delimiter is not the one RFC 2046 describes. A label set documented as bounded
with an unbounded label beside it. A process-wide switch anything can flip.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues   = require "cqueues"
local akkar     = require "akkar"
local log       = require "akkar.log"
local work      = require "akkar.work"
local multipart = require "akkar.multipart"
local metrics   = require "akkar.metrics"
local strict    = require "akkar.strict"

describe("a logfmt value the caller chose", function()
  local function line_for(fields)
    local written
    local logger = log.new { format = "text", sink = function(s) written = s end }
    logger:info("request", fields)
    return written
  end

  it("cannot add fields of its own", function()
    -- `key .. "=" .. tostring(value)` with no quoting, and text is the
    -- default format, so any value reachable from a request body forged
    -- fields the log store then indexed as if the server had written them.
    local line = line_for { email = "a@b.test role=admin tenant=other" }
    assert.equal('INFO  request email="a@b.test role=admin tenant=other"\n', line)
  end)

  it("cannot forge a whole line with a newline", function()
    local line = line_for { note = "ok\nERROR  the database is gone" }
    assert.equal(1, select(2, line:gsub("\n", "")) ,
      "the value ended the line and started another")
    assert.is_truthy(line:find("\\n", 1, true))
  end)

  it("cannot forge a field from the key side either", function()
    local line = line_for { ["a b=c"] = 1 }
    assert.is_nil(line:match "%sb=c")
  end)

  it("still writes ordinary values bare, which is the point of logfmt", function()
    local line = line_for { request_id = "7b8e888e", ms = 250 }
    assert.is_truthy(line:find("request_id=7b8e888e", 1, true))
    assert.is_truthy(line:find("ms=250", 1, true))
  end)
end)

describe("work.chunked", function()
  it("actually hands the handler a yield", function()
    -- It was an identity wrapper: the inner closure took no argument, so it
    -- never called the yield `yielding` handed it. `chunked(10)` over a
    -- million iterations produced zero scheduler trips while documenting
    -- itself as a yield budget.
    local received
    local wrapped = work.chunked(10)(function(n, yield)
      received = yield
      return n * 2
    end)
    assert.equal(84, wrapped(42))
    assert.is_function(received, "the handler was given no yield to call")
  end)

  it("gives other work a turn while the handler runs", function()
    local turns, done = 0, false
    local cq = cqueues.new()
    cq:wrap(function()
      work.chunked(10)(function(iterations, yield)
        for _ = 1, iterations do yield() end
      end)(2000)
      done = true
    end)
    cq:wrap(function()
      while not done do turns = turns + 1 cqueues.poll(0) end
    end)
    assert(cq:loop(10))
    assert.is_true(turns > 1, "the neighbour got " .. turns .. " turns")
  end)
end)

describe("the multipart delimiter", function()
  local B = "----abc"
  local function body(...)
    return table.concat({ ... }, "\r\n")
  end

  it("is CRLF--boundary, not --boundary anywhere", function()
    -- The client picks the boundary, so it can plant those bytes MID-LINE
    -- inside a part. Split there, akkar reads a different form than anything
    -- in front of it that parses multipart correctly.
    local parsed, err = multipart.parse(body(
      "--" .. B,
      'Content-Disposition: form-data; name="note"',
      "",
      "harmless --" .. B .. " trailing",
      "--" .. B,
      'Content-Disposition: form-data; name="amount"',
      "",
      "10",
      "--" .. B .. "--",
      ""), B)

    assert.is_truthy(parsed, tostring(err))
    assert.equal("harmless --" .. B .. " trailing", parsed.note)
    assert.equal("10", parsed.amount)
  end)

  it("refuses two parts under one name rather than keeping the last", function()
    local parsed, err = multipart.parse(body(
      "--" .. B, 'Content-Disposition: form-data; name="amount"', "", "10",
      "--" .. B, 'Content-Disposition: form-data; name="amount"', "", "99999",
      "--" .. B .. "--", ""), B)

    assert.is_nil(parsed)
    assert.is_truthy(err:find("two parts named 'amount'", 1, true))
  end)

  it("refuses a truncated upload instead of calling it a form", function()
    local parsed, err = multipart.parse(body(
      "--" .. B, 'Content-Disposition: form-data; name="file"; filename="a.bin"',
      "", "half of it"), B)

    assert.is_nil(parsed)
    assert.is_truthy(err)
  end)

  it("still parses an ordinary form", function()
    local parsed = multipart.parse(body(
      "--" .. B, 'Content-Disposition: form-data; name="title"', "", "hello",
      "--" .. B, 'Content-Disposition: form-data; name="avatar"; filename="c.png"',
      "Content-Type: image/png", "", "PNGDATA",
      "--" .. B .. "--", ""), B)

    assert.equal("hello", parsed.title)
    assert.equal("c.png", parsed.avatar.filename)
    assert.equal("PNGDATA", parsed.avatar.data)
    assert.equal("image/png", parsed.avatar.content_type)
  end)
end)

describe("the multipart boundary parameter", function()
  it("is a parameter, not a substring of the header", function()
    assert.is_nil(multipart.boundary "multipart/form-data; name=xboundary=zzz")
    assert.equal("abc", multipart.boundary "multipart/form-data; boundary=abc")
    assert.equal("a b", multipart.boundary 'multipart/form-data; boundary="a b"')
    assert.equal("abc", multipart.boundary "multipart/form-data; BOUNDARY=abc")
  end)
end)

describe("the metrics method label", function()
  it("is bounded, like the route label beside it", function()
    -- The route was bounded exactly as documented while `req.method` --
    -- whatever token the client put on the request line -- went straight into
    -- a label. Bounding one of two labels bounds nothing.
    local registry = metrics.new()
    local middleware = registry:middleware()
    for i = 1, 50 do
      middleware({ method = "FORGED" .. i, route = "/users/:id" },
                 function() return { status = 200 } end)
    end
    middleware({ method = "GET", route = "/users/:id" },
               function() return { status = 200 } end)

    local scrape = registry:render()
    assert.is_nil(scrape:find("FORGED1", 1, true),
      "one series per made-up verb")
    assert.is_truthy(scrape:find("<other>", 1, true))
    assert.is_truthy(scrape:find('method="GET"', 1, true))
  end)
end)

describe("strict mode's process-wide switch", function()
  it("cannot be turned off without the key on() returned", function()
    local key = strict.on()
    assert.is_false((pcall(strict.off)))
    assert.is_false((pcall(strict.off, {})))
    assert.is_true(strict.active())
    assert.is_table(key)
  end)

  it("puts back what it found rather than nil, and only if it is still ours", function()
    -- `off` set the metatable to nil unconditionally. If anything else had
    -- swapped it in the meantime -- busted does exactly this, to implement
    -- `insulate` -- that removed theirs.
    local key = strict.on()
    local foreign = { __index = function() return nil end }
    debug.setmetatable(_G, foreign)
    strict.off(key)
    local after = debug.getmetatable(_G)
    debug.setmetatable(_G, nil)
    strict.on()                      -- the suite runs under strict mode

    assert.is_true(rawequal(foreign, after),
      "off() removed a metatable it had not installed")
  end)

  it("refuses to clobber a metatable somebody else installed", function()
    -- `off` set the metatable to nil rather than restoring it, and `on`
    -- replaced whatever was there. Either one silently breaks the library
    -- that installed it, somewhere far from here.
    local key = strict.on()
    strict.off(key)
    debug.setmetatable(_G, { __index = function() return nil end })
    local ok, err = pcall(strict.on)
    debug.setmetatable(_G, nil)
    strict.on()                      -- the suite runs under strict mode

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("already has a metatable", 1, true))
  end)
end)
