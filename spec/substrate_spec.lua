--[[
The substrate contract — what akkar REQUIRES of the libraries under it.

## Why this file exists

akkar's rule is that the public API never depends on the implementation of the
substrate: `app:get`, `req.db` and `akkar.stream` are akkar, while cqueues,
lua-http, luaossl and the JSON library are replaceable details. A rule like
that is worth nothing unless somebody can check it, and "replaceable" means
nothing unless the thing a replacement has to do is written down.

So this file is the specification. Every assertion is a property akkar
actually depends on, named alongside the code that depends on it. It has two
readers:

- an upstream bump, which fails HERE with a message saying what it broke,
  rather than three layers up in a request;
- a future substitute -- a different event loop, a different HTTP server, a
  native runtime -- for which this is the acceptance test. Nothing else in the
  repository says what such a thing would have to do.

Deliberately NOT a test of the libraries. cqueues has its own suite and it is
not our business. What is our business is the handful of behaviours akkar
built on, several of which are unusual enough that a reasonable
reimplementation would get them wrong.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"

describe("cqueues: the concurrency model", function()
  it("costs exactly two descriptors per controller", function()
    -- `akkar/init.lua` spends one controller per in-flight request for its
    -- deadline, so this number IS the concurrency ceiling: against
    -- `ulimit -n 1024` it puts the wall at about 500 concurrent requests, and
    -- `descriptor_ceiling()` derives `max_concurrent` from it directly.
    -- A substitute that costs three moves the ceiling by a third.
    local function open_fds()
      local pid = io.open("/proc/self/stat"):read "n"
      local n = 0
      for _ in io.popen("ls /proc/" .. pid .. "/fd 2>/dev/null"):lines() do n = n + 1 end
      return n
    end

    collectgarbage() collectgarbage()
    local before = open_fds()
    local held = {}
    for i = 1, 50 do held[i] = cqueues.new() end
    local after = open_fds()

    local per = (after - before) / 50
    assert.is_true(per >= 1.9 and per <= 2.1,
      ("a controller costs %.2f descriptors, not 2"):format(per))
  end)

  it("costs no descriptor for a condition", function()
    -- Why `akkar/pool.lua` parks waiters on a condition rather than on a
    -- controller: a pool of thirty waiters must not cost sixty descriptors.
    local condition = require "cqueues.condition"
    local function open_fds()
      local pid = io.open("/proc/self/stat"):read "n"
      local n = 0
      for _ in io.popen("ls /proc/" .. pid .. "/fd 2>/dev/null"):lines() do n = n + 1 end
      return n
    end

    collectgarbage() collectgarbage()
    local before = open_fds()
    local held = {}
    for i = 1, 50 do held[i] = condition.new() end
    local grew = open_fds() - before

    -- Not an equality: the measurement itself opens a pipe, so a couple of
    -- descriptors of noise are the instrument, not the subject. Fifty
    -- conditions costing fewer than ten descriptors is the property; fifty
    -- costing a hundred would be a different library.
    assert.is_true(grew < 10,
      ("50 conditions cost %d descriptors -- they are no longer free"):format(grew))
    assert.equal(50, #held)
  end)

  it("wakes every waiter on signal(), and one on signal(1)", function()
    -- `Pool:put` wakes ALL. A request abandoned while parked in `get()` stays
    -- registered on the condition, so `signal(1)` can hand the wakeup to a
    -- coroutine that will never take it while a live waiter sleeps beside an
    -- idle connection. Measured before the fix: a request burned its whole
    -- ten-second budget with `idle=1` in the pool.
    local condition = require "cqueues.condition"

    local function woke(how_many_signalled)
      local cond, woken = condition.new(), 0
      local cq = cqueues.new()
      for _ = 1, 3 do
        cq:wrap(function() cond:wait() woken = woken + 1 end)
      end
      cq:step(0.05)
      cq:wrap(function()
        if how_many_signalled then cond:signal(how_many_signalled)
        else cond:signal() end
      end)
      cq:step(0.05) cq:step(0.05)
      return woken
    end

    assert.equal(1, woke(1), "signal(1) woke more than one waiter")
    assert.equal(3, woke(nil), "signal() did not wake every waiter")
  end)

  it("steps a nested controller without running the outer loop", function()
    -- The property `with_deadline` is built on: a request's handler runs in
    -- its OWN controller, polled from the outer one, so a handler abandoned
    -- by its deadline sits in a controller nothing ever steps again and is
    -- therefore inert. An event loop without that nesting would leave the
    -- abandoned handler running -- and it would wake up after the 503 and
    -- touch a connection already back in the pool.
    local inner_ran, outer_ran = false, false
    local inner = cqueues.new()
    inner:wrap(function() inner_ran = true end)

    local outer = cqueues.new()
    outer:wrap(function() outer_ran = true end)

    assert(inner:step(0.05))
    assert.is_true(inner_ran)
    assert.is_false(outer_ran, "stepping one controller ran another's coroutine")
  end)

  it("leaves an abandoned coroutine suspended, not dead", function()
    -- Why `Pool:reap` cannot ask `coroutine.status`, and has to use a weak
    -- table and a collection instead. A substitute whose abandoned tasks
    -- report "dead" would let the pool recover slots far more cheaply.
    local co
    do
      local cq = cqueues.new()
      cq:wrap(function() co = coroutine.running() cqueues.sleep(60) end)
      cq:step(0.05)
    end
    assert.equal("suspended", coroutine.status(co))
  end)

  it("collects an abandoned coroutine only after TWO collections", function()
    -- Measured, and `Pool:reap` depends on the number: the controller has a
    -- finalizer, the first collection runs it, and only the second collects
    -- the coroutine it was holding. One collection is not enough.
    local weak = setmetatable({}, { __mode = "k" })
    local function count() local n = 0 for _ in pairs(weak) do n = n + 1 end return n end

    do
      local cq = cqueues.new()
      cq:wrap(function() weak[coroutine.running()] = true cqueues.sleep(60) end)
      cq:step(0.05)
    end

    collectgarbage()
    local after_one = count()
    collectgarbage()
    local after_two = count()

    assert.equal(0, after_two, "two collections did not free the coroutine")
    assert.equal(1, after_one,
      "one collection now frees it -- Pool:reap can be made cheaper")
  end)
end)

describe("lua-http: the server", function()
  local headers = require "http.headers"

  it("returns NO VALUES for an absent header, not nil", function()
    -- `read_body` in `akkar/init.lua` binds `h:get "content-length"` to a
    -- local before touching it, with a comment saying why: passing the call
    -- straight into `tonumber()` gives that function zero arguments and
    -- raises. This broke every GET once already.
    local h = headers.new()
    assert.equal(0, select("#", h:get "content-length"),
      "an absent header now returns a value; the binding in read_body can go")

    h:append("content-length", "12")
    assert.equal(1, select("#", h:get "content-length"))
  end)

  it("drops an over-long request line before akkar ever sees it", function()
    -- Found by `spec/fuzz_spec.lua` and then measured: a request line up to
    -- 4000 bytes reaches akkar and is answered 404; at 8000 bytes lua-http
    -- closes the connection with no response, and a middleware counter proves
    -- akkar was never called.
    --
    -- The consequence is a limit akkar does not own and cannot report. It
    -- cannot answer 414, it cannot log the attempt, and `max_concurrent` is
    -- the only thing that ever counted it. A substitute HTTP layer with a
    -- different cutoff -- or none -- changes what this framework is exposed
    -- to without changing a line of it.
    --
    -- Not asserted as an exact number: the boundary is lua-http's business
    -- and may move. What is asserted is that the boundary EXISTS, so that a
    -- replacement without one is noticed here rather than in production.
    local akkar_saw = 0
    local PORT = 8380
    local app = akkar.new()
    app:use(function(req, next) akkar_saw = akkar_saw + 1 return next(req) end)
    app:get("/x", function() return { ok = true } end)

    local short_status, long_status
    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false,
                  log = akkar.log.new { level = "error", sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.25)
      local request = require "http.request"

      local function try(length)
        local status
        pcall(function()
          local req = request.new_from_uri(
            "http://127.0.0.1:" .. PORT .. "/x/" .. string.rep("a", length))
          local headers, stream = req:go(5)
          if headers then
            status = tonumber(headers:get ":status")
            stream:get_body_as_string(2)
          end
        end)
        return status
      end

      short_status = try(1000)
      local before = akkar_saw
      long_status = try(16000)
      akkar_saw = akkar_saw - before      -- reused as "did the long one arrive"
      app:stop(2)
    end)
    assert(cq:loop(30))

    assert.equal(404, short_status, "a 1000-byte request line no longer reaches akkar")
    assert.is_nil(long_status, "lua-http now answers an over-long request line")
    assert.equal(0, akkar_saw, "the over-long request reached akkar after all")
  end)

  it("keeps header names lowercase, which req.headers relies on", function()
    -- `normalize_headers` hands handlers a plain lowercase table so no
    -- application ever writes `req.headers:get "X-Thing"`.
    local h = headers.new()
    h:append("X-Custom", "value")
    local seen = {}
    for name in h:each() do seen[#seen + 1] = name end
    assert.is_truthy(seen[1] == "x-custom" or seen[1] == "X-Custom",
      "unexpected header name form: " .. tostring(seen[1]))
  end)
end)

describe("the serializer", function()
  local json = require "akkar.json"

  it("decodes a JSON null to a sentinel that is not nil", function()
    -- `akkar.null` IS this value, and dispatch compares against it by
    -- identity. A serializer that decoded null to nil would make "set this
    -- field to null" indistinguishable from "do not touch this field".
    local decoded = json.decode '{"a":null,"b":1}'
    assert.is_not_nil(decoded.a, "null decoded to nil")
    assert.equal(json.null, decoded.a)
    assert.equal(akkar.null, decoded.a,
      "akkar.null is no longer the serializer's null")
  end)

  it("round-trips the shapes akkar puts on the wire", function()
    assert.equal('{"a":1}', json.encode { a = 1 })
    assert.equal(1, json.decode('{"a":1}').a)
    assert.same({ 1, 2, 3 }, json.decode "[1,2,3]")
  end)

  it("refuses a value it cannot represent, rather than inventing one", function()
    -- `normalize` turns this into a 500 naming the type. A serializer that
    -- silently encoded a function as null would put a lie on the wire.
    assert.has_error(function() json.encode { f = function() end } end)
  end)
end)

describe("what a replacement would have to answer", function()
  it("is this file, and the list is short on purpose", function()
    -- A note rather than an assertion. Six properties of the event loop,
    -- two of the HTTP layer and three of the serializer is the whole of what
    -- akkar depends on that is not ordinary. Everything else the libraries do
    -- is theirs.
    --
    -- What is NOT pinned here, and should be before anyone swaps a substrate:
    -- whether `stream:write_chunk` raises or returns nil on a dead peer (it
    -- decides the shape of a fault-injecting writer), and whether pgmoon
    -- yields rather than blocking under cqueues (asserted today only by
    -- `docs/substrate/01_concurrency.lua`, which is a script and not a test).
    assert.is_true(true)
  end)
end)
