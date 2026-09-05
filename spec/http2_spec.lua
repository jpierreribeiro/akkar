--[[
HTTP/2, and the one property it exists for.

## Why this file exists at all

akkar spoke HTTP/1.1 and nothing else, deliberately: only the `h1_*` half of
lua-http was vendored, `alpn_select` never offered `h2`, and the client never
asked for it. The README's first paragraph nonetheless offers to run **without
nginx in front**, and that is precisely the deployment where the missing
version is felt -- a browser talking straight to akkar falls back to h1, so no
multiplexing and no HPACK, and gRPC is impossible outright.

The gap was not written down anywhere either, which is its own defect: an
absence that no list mentions reads as an oversight rather than a decision.

## What was actually required to close it

Less than it looks. The h2 half of lua-http 0.4 -- `h2_connection`,
`h2_stream`, `hpack`, `h2_error` and the `bit` shim they share -- is the same
release the h1 half here was vendored from, so this is reintegration and not an
implementation of HPACK. What had to be checked was whether akkar's OWN changes
to the shared files had made the h2 half unusable, because `headers.lua`
diverges from upstream by 239 lines: upstream stores every header as an entry
table with a `never_index` flag, and akkar removed the flag from every entry
for 432 bytes per request, on the stated grounds that it is HPACK's flag and
HPACK had gone.

HPACK came back. See "the flag that came back" below.

## The property this file protects

**Streams on one h2 connection must run concurrently**, and that is the one
thing an optimisation here has already put at risk once. `handle_socket` used
to wrap every stream in its own coroutine; that coroutine costs ~3,900 bytes
and buys nothing under h1, where the connection is serial, so it was removed --
but removed BEHIND `conn.version < 2`, keeping `add_stream` as the concurrent
path, exactly so that h2 could come back without anyone having to rediscover
which line mattered. This file is what would go red if that condition were ever
dropped.

## The client is upstream's, on purpose

`http.request` here is the published rock, not the vendored copy. Two
independent HPACK implementations understanding each other is interoperability;
a vendored codec talking to itself would agree with itself no matter what it
did.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local request = require "http.request"
local client  = require "http.client"

local quiet = function()
  return akkar.log.new { level = "error", sink = function() end }
end

--- Runs `body(port)` against a live akkar server and returns whatever it
--- returns. The server is stopped on the way out, including when `body`
--- raises -- a spec that leaks a listening socket poisons the next one.
local function with_server(port, routes, config, body)
  local app = akkar.new()
  routes(app)

  local result, failure
  local cq = cqueues.new()
  cq:wrap(function()
    pcall(function()
      local settings = { port = port, check_capabilities = false, log = quiet() }
      for k, v in pairs(config or {}) do settings[k] = v end
      app:run(settings)
    end)
  end)
  cq:wrap(function()
    cqueues.sleep(0.3)                      -- the listener is up by here
    local ok, res = pcall(body, port)
    if ok then result = res else failure = res end
    app:stop(2)
  end)
  assert(cq:loop(30))
  if failure then error(failure, 0) end
  return result
end

describe("HTTP/2", function()
  it("answers a cleartext h2 request, with h2c on", function()
    local answer = with_server(8391,
      function(app)
        app:get("/ping", function() return { pong = true } end)
      end,
      { h2c = true },
      function(port)
        local req = request.new_from_uri("http://127.0.0.1:" .. port .. "/ping")
        -- Prior knowledge: no upgrade dance, the preface goes out first and
        -- the server has to recognise it. This is what a gRPC client does.
        req.version = 2
        local headers, stream = assert(req:go(5))
        local body = assert(stream:get_body_as_string(5))
        stream:shutdown()
        return {
          status  = headers:get ":status",
          version = stream.connection.version,
          body    = body,
        }
      end)

    assert.equal("200", answer.status)
    assert.equal(2, answer.version)
    assert.equal('{"pong":true}', answer.body)
  end)

  it("still answers HTTP/1.1 on the same server, unchanged", function()
    -- h2 must be an addition, not a replacement. If offering h2 changed what
    -- an h1 client gets, every existing deployment would be the experiment.
    local answer = with_server(8392,
      function(app)
        app:get("/ping", function() return { pong = true } end)
      end,
      { h2c = true },
      function(port)
        local req = request.new_from_uri("http://127.0.0.1:" .. port .. "/ping")
        req.version = 1.1
        local headers, stream = assert(req:go(5))
        local body = assert(stream:get_body_as_string(5))
        stream:shutdown()
        return {
          status  = headers:get ":status",
          version = stream.connection.version,
          body    = body,
        }
      end)

    assert.equal("200", answer.status)
    assert.equal(1.1, answer.version)
    assert.equal('{"pong":true}', answer.body)
  end)

  it("runs streams on one connection CONCURRENTLY, which is the whole point",
     function()
    -- THE ASSERTION THAT PROTECTS THE OPTIMISATION. Two handlers that each
    -- sleep 0.4 s, on ONE connection. Serial they take 0.8 s; concurrent they
    -- take about 0.4. If `handle_socket` ever stops routing h2 through
    -- `add_stream` -- if the `conn.version < 2` condition is dropped and the
    -- inline call becomes unconditional -- this is the test that goes red,
    -- and it goes red on time rather than on a crash.
    local elapsed = with_server(8393,
      function(app)
        app:get("/slow", function()
          cqueues.sleep(0.4)
          return { slow = true }
        end)
      end,
      { h2c = true, timeout = 20 },
      function(port)
        local conn = assert(client.connect({
          host = "127.0.0.1", port = port, tls = false, version = 2,
        }, 5))

        local function fire()
          local stream = assert(conn:new_stream())
          local headers = require("http.headers").new()
          headers:append(":method", "GET")
          headers:append(":scheme", "http")
          headers:append(":authority", "127.0.0.1:" .. port)
          headers:append(":path", "/slow")
          assert(stream:write_headers(headers, true, 5))
          return stream
        end

        local t0 = cqueues.monotime()
        local a, b = fire(), fire()             -- both in flight before either reads
        assert.equal('{"slow":true}', assert(a:get_body_as_string(10)))
        assert.equal('{"slow":true}', assert(b:get_body_as_string(10)))
        local t1 = cqueues.monotime()
        a:shutdown(); b:shutdown(); conn:close()
        return t1 - t0
      end)

    assert.is_true(elapsed < 0.7,
      ("two 0.4 s streams took %.2f s on one connection; they ran serially")
        :format(elapsed))
    -- And the floor, so a handler that stopped sleeping cannot pass this by
    -- being instant: the measurement has to have measured something.
    assert.is_true(elapsed > 0.35,
      ("%.2f s is below one handler's own sleep; nothing was measured")
        :format(elapsed))
  end)

  it("refuses the h2 preface cleanly when h2c is off, rather than hanging",
     function()
    -- h2c COSTS A READ PER CONNECTION, h1 ones included, because without TLS
    -- there is no ALPN and the only way to know is to sniff. So it is off by
    -- default -- and the behaviour with it off has to be a refusal, not a
    -- hang. A hang here would be worse than the missing feature.
    local outcome = with_server(8394,
      function(app)
        app:get("/ping", function() return { pong = true } end)
      end,
      nil,                                     -- h2c off: the default
      function(port)
        local socket = require "cqueues.socket"
        local conn = socket.connect("127.0.0.1", port)
        conn:setmode("bn", "bn")
        conn:onerror(function(_, _, why) return why end)
        -- THE TIMEOUT GOES ON THE SOCKET. `conn:read("*l", 3)` does NOT read
        -- a line with a three-second deadline: cqueues' `read` takes a LIST OF
        -- FORMATS, so that reads a line AND THEN THREE MORE BYTES, with no
        -- deadline anywhere. Against a server that hangs -- the exact failure
        -- this test's title forbids -- it blocked until the enclosing
        -- `cq:loop(30)` timed out, `loop` returned truthy (timeout and drain
        -- are indistinguishable in its return), `outcome` stayed nil, and the
        -- `if outcome ~= nil` below skipped every assertion in the test.
        -- `spec/h2_framing_spec.lua` documents this same trap; the fix had
        -- never reached this file.
        conn:settimeout(3)
        conn:write "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        conn:flush()
        -- Either an HTTP/1.1 refusal or a closed connection is correct. What
        -- is not correct is nothing at all -- and "nothing at all" must come
        -- back as a VALUE the assertions can see, never as a nil that turns
        -- them off.
        local line, why = conn:read "*l"
        local closed = conn:eof "r"
        conn:close()
        if line then return line end
        if closed then return "closed" end
        return "silence: " .. tostring(why)
      end)

    -- UNCONDITIONAL. The body always returns a string now, so there is no
    -- shape of this test in which zero assertions run.
    assert.is_string(outcome)
    assert.is_falsy(outcome:match "^silence:",
      "the server neither answered nor closed -- it hung: " .. outcome)
    if outcome ~= "closed" then      -- a close is a clean refusal too
      assert.is_truthy(outcome:match "^HTTP/1%.1",
        "answered something that was not an HTTP/1.1 refusal: " .. outcome)
      assert.is_falsy(outcome:match " 2%d%d ",
        "the preface was accepted as a request: " .. outcome)
    end
  end)

  it("round-trips headers through HPACK against akkar's own headers object",
     function()
    -- THE FLAG THAT CAME BACK. akkar's `headers.lua` dropped `never_index`
    -- from every entry -- 432 bytes a request -- on the grounds that it is
    -- HPACK's flag and HPACK had gone. HPACK is back, and it reads that flag
    -- in two places: `encode_headers` iterates `headers:each()` expecting a
    -- third value, and the decoder calls `append(name, value, never_index)`.
    --
    -- Neither breaks. Lua drops the extra argument and the missing third
    -- return reads as nil, so every header takes the ordinary indexed path.
    -- What is lost is the ability to mark a field "never place this in the
    -- dynamic table" -- a hint, and one upstream only ever set when somebody
    -- asked. What is NOT lost is correctness, and that is what this asserts:
    -- names, values and count survive a full encode and decode.
    local hpack = require "akkar.vendor.http.hpack"
    local new_headers = require "akkar.vendor.http.headers".new

    local sent = new_headers()
    sent:append(":method", "POST")
    sent:append(":scheme", "https")
    sent:append(":path", "/users/42")
    sent:append(":authority", "example.com")
    sent:append("content-type", "application/json")
    sent:append("authorization", "Bearer a-token-that-is-in-no-static-table")

    local encoder = hpack.new(4096)
    encoder:encode_headers(sent)
    local block = encoder:render_data()
    assert.is_true(#block > 0, "HPACK encoded nothing")

    local got = hpack.new(4096):decode_headers(block)
    assert.equal(sent:len(), got:len())
    for name, value in sent:each() do
      assert.equal(value, got:get(name), "header " .. name .. " did not survive")
    end
  end)

  it("refuses a header block that decodes to more fields than h1 allows",
     function()
    -- THE AMPLIFIER. `h1_stream` has capped header lines at 100 since it was
    -- vendored; the h2 half had no counterpart anywhere -- not `h2_stream`,
    -- not `h2_connection`, not `hpack` -- and advertises
    -- SETTINGS_MAX_HEADER_LIST_SIZE = math.huge. The only h2 bound was
    -- `MAX_HEADER_BUFFER_SIZE`, 400 KB of COMPRESSED block, and HPACK is a
    -- compressor: an indexed header field (RFC 7541 Section 6.1) is the single
    -- byte `0x80 | index` and appends a whole name/value pair.
    --
    -- So: one literal header with a 4,000-byte value, which HPACK puts in the
    -- dynamic table at index 62, then one-byte references to it. Measured
    -- against the unbounded decoder, 20,008 bytes on the wire decoded to
    -- 16,001 fields carrying 64 MB of value, and the 400 KB cap allows roughly
    -- 400,000 fields.
    --
    -- THIS ASSERTS THE REFUSAL, not survival. A survival assertion is the
    -- wrong instrument for a bound: a server with no cap at all survives a
    -- block this size comfortably -- the run below takes well under a second
    -- unbounded -- so it would pass with the cap removed and prove nothing.
    -- What the cap changes is that the decode is refused, so that is what is
    -- checked, along with the field count at which it stops.
    local hpack = require "akkar.vendor.http.hpack"

    local seed = hpack.new(8192)
    seed:add_header_indexed("x-a", string.rep("v", 4000))
    local block = seed:render_data() .. string.rep(string.char(0x80 + 62), 16000)
    assert.is_true(#block < 400 * 1024,
      "the attack has to fit under the compressed-block cap or it proves nothing")

    local got, err = hpack.new(8192):decode_headers(block)
    assert.is_nil(got,
      ("%s fields decoded from %d bytes with no refusal")
        :format(got and got:len() or "?", #block))
    assert.is_truthy(tostring(err):find("field", 1, true),
      "refused, but not for the reason this test is about: " .. tostring(err))

    -- And the number is h1's, reached through the h2 stream so the two cannot
    -- drift apart in a later edit.
    local h2_stream = require "akkar.vendor.http.h2_stream"
    local h1_stream = require "akkar.vendor.http.h1_stream"
    assert.equal(h1_stream.methods.max_header_lines,
                 h2_stream.methods.max_header_lines,
      "h1 and h2 disagree about how many header fields a request may carry")

    -- A block AT the limit still decodes. A bound that refuses ordinary
    -- traffic is not a fix.
    local ordinary = hpack.new(8192)
    for i = 1, h2_stream.methods.max_header_lines do
      ordinary:add_header_indexed("x-" .. i, "v")
    end
    local decoded = hpack.new(8192):decode_headers(ordinary:render_data(), nil, nil,
                                                   h2_stream.methods.max_header_lines)
    assert.is_truthy(decoded, "a block at exactly the limit was refused")
    assert.equal(h2_stream.methods.max_header_lines, decoded:len())
  end)

  it("bounds decompressed header bytes, including indexed repetitions", function()
    local hpack = require "akkar.vendor.http.hpack"
    local encoder = hpack.new(8192)
    encoder:add_header_indexed("x-large", string.rep("v", 1024))
    local block = encoder:render_data() .. string.rep(string.char(0x80 + 62), 8)

    local got, err = hpack.new(8192):decode_headers(block, nil, nil, 100, 4096)
    assert.is_nil(got, "an expanded HPACK list crossed the byte ceiling")
    assert.is_truthy(tostring(err):find("4096 bytes", 1, true), tostring(err))

    local within = hpack.new(8192)
    within:add_header_indexed("x-small", string.rep("v", 64))
    assert.is_truthy(hpack.new(8192):decode_headers(
      within:render_data(), nil, nil, 100, 4096))
  end)

  it("joins duplicate header values in linear time", function()
    -- The other half of the same attack. `normalize_headers` accumulated
    -- repeats of one name with `existing .. ", " .. clean`, which rebuilds the
    -- whole accumulation on every repeat: quadratic, in a count the peer picks.
    -- Measured with the old line, 4,000-byte values: 1,000 repeats 2.5 s,
    -- 4,000 repeats 32.2 s, 16,000 repeats 364 s. None of it yields.
    --
    -- `req.headers` is lazy, but `req.ip` reads it and `akkar/limit.lua` reads
    -- `req.ip` for the default rate-limit key, so the ordinary path arrives
    -- here.
    --
    -- ASSERTED AS A RATIO, not a wall clock. An absolute budget is a machine
    -- benchmark and turns into a flake on a loaded box; the SHAPE of the cost
    -- is what was wrong. Doubling the input doubles linear work and quadruples
    -- quadratic work, so the ratio separates them by 2x whatever the box is
    -- doing. The gate is 3x -- comfortably above linear's 2, comfortably below
    -- quadratic's 4 -- and the measured ratio at these sizes with the old line
    -- was 5.0x (1.835 s -> 9.170 s), against 1.84x with this one -- and the
    -- 1,000-duplicate case itself went from 1.835 s to 0.043 s.
    local akkar = require "akkar"
    local new_headers = require "akkar.vendor.http.headers".new
    local monotime = require("cqueues").monotime

    local function build(n)
      local h = new_headers()
      h:append(":method", "GET")
      local value = string.rep("v", 4000)
      for _ = 1, n do h:append("x-a", value) end
      return h
    end

    local function cost(n)
      local h = build(n)
      collectgarbage()
      local t0 = monotime()
      local out = akkar.normalize_headers(h)
      local elapsed = monotime() - t0
      -- The work has to have actually happened, and the answer has to be right.
      assert.equal(n * 4000 + (n - 1) * 2, #out["x-a"])
      assert.is_nil(out[":method"])
      return elapsed
    end

    cost(500)                                    -- warm the allocator
    local small = cost(1000)
    local large = cost(2000)

    assert.is_true(large < small * 3,
      ("doubling the duplicate count multiplied the cost by %.1fx (%.3f s -> "
       .. "%.3f s); linear is 2x, the old quadratic line measured 5.0x")
        :format(large / small, small, large))
  end)
end)
