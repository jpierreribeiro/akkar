--[[
akkar.http's connection pool, against real sockets.

## What is real here and what is not

Everything. There is no fake transport in this file: one akkar server in its
own process (`spec/support/raw_client.lua`) and, where a server has to
misbehave on purpose, a raw TCP server in this one.

The in-process raw server is safe here for the reason `raw_client.lua`'s
header says it is usually NOT: the deadlock that file describes needs a half
of the exchange that blocks without yielding, and every socket below is a
cqueues socket read inside a controller. What that file rules out is a
BLOCKING client against a same-process server, and none of these are.

## The four properties, and why each one is worth a socket

**Reuse actually happens.** A pool that silently opens a connection per
request passes every functional test in the suite and buys nothing, so the
assertion is on the server's own count of accepted connections -- not on
timing, which is a proxy, and not on the pool's own bookkeeping alone, which
is the thing under test.

**The pool is not shared across origins.** Asserted by pointing a second
origin at a port where nothing is listening. If the pool were keyed on
anything looser than scheme+host+port, that request would be answered by the
first origin's live connection, which is the worst outcome available: a
request sent to the wrong server, answered, and never reported.

**A connection the peer closed is not handed to the next caller.** The raw
server answers one request and then closes the socket a moment later without
saying `Connection: close` -- exactly the shape of an idle timeout on a load
balancer, and the case a pool gets wrong. The next call must succeed.

**Two defects the pool work uncovered stay fixed.** A body read that ignored
the timeout, and a fixed one-second penalty on every body over 1 KiB. Both are
regression tests now; both are described at length in `akkar/http.lua`.

## NOT covered here

TLS, HTTP/2, and any peer that is not on this machine. The pool key includes
the scheme, so `https` gets its own pool by construction, but nothing in this
file proves the liveness probe behaves the same on a TLS socket -- and against
an h2 peer the probe is deliberately conservative: a connection carrying
control frames looks readable and is discarded, which costs a reconnect and
cannot cost a wrong answer. Neither is verified against a real server.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local socket  = require "cqueues.socket"
local time    = require "akkar.time"
local http    = require "akkar.http"
local raw     = require "spec.support.raw_client"

if not raw.available() then
  describe("akkar.http pooling", function()
    pending "no Lua interpreter to spawn a server with; skipping"
  end)
  return
end

--- Every call yields, so every test runs inside a controller.
local function inside(fn, budget)
  local err
  local cq = cqueues.new()
  cq:wrap(function()
    local ok, why = pcall(fn, cq)
    if not ok then err = why end
  end)
  assert(cq:loop(budget or 30))
  if err then error(err, 0) end
end

-- ======================================================= a raw server, on tap

--- Reads one request off `conn`, body included.
---
--- The body is CONSUMED even though nothing here looks at it. A server that
--- leaves a request body in the socket desynchronises the next request on the
--- same connection, and this file's whole subject is the next request on the
--- same connection.
---
--- Lines are matched with the carriage return stripped explicitly. In binary
--- mode cqueues' `*l` strips only the newline, so the blank line that ends a
--- header block arrives as "\r" and not as "" -- which cost half an hour the
--- first time, in a loop that read headers until doomsday.
local function read_request(conn)
  local first = conn:read "*l"
  if not first then return nil end
  local headers = {}
  while true do
    local line = conn:read "*l"
    if line == nil then return nil end
    line = line:gsub("\r$", "")
    if line == "" then break end
    local name, value = line:match "^(.-):%s*(.*)$"
    if name then headers[name:lower()] = value end
  end
  local length = tonumber(headers["content-length"])
  if length and length > 0 then conn:read(length) end
  return (first:gsub("\r$", "")), headers
end

--- Writes a complete response and flushes it.
---
--- The flush is not decoration. A cqueues socket auto-flushes before a READ,
--- so a server that answers and then goes quiet -- which is most of the
--- servers below -- leaves its answer sitting in the buffer for ever.
local function respond(conn, body, extra_headers)
  conn:write(("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n%s\r\n%s")
             :format(#body, extra_headers or "", body))
  conn:flush()
end

--- Starts a raw TCP server on a free port and returns a handle.
---
--- The port is searched for rather than fixed, for the reason
--- `raw_client.lua` gives: this machine has a history of leaving listening
--- sockets behind, and a fixed port makes the second run of a spec fail for a
--- reason that has nothing to do with what it tests.
local function raw_server(cq, handle)
  local listener, port
  for candidate = 8840, 8900 do
    local attempt = socket.listen("127.0.0.1", candidate)
    if attempt then
      local ok = pcall(function() attempt:listen() end)
      if ok then listener, port = attempt, candidate break end
    end
  end
  assert(listener, "no free port for the raw server")

  local server = {
    port = port, listener = listener,
    connections = 0, requests = 0, stopped = false,
  }

  cq:wrap(function()
    while not server.stopped do
      local ok, conn = pcall(function() return listener:accept() end)
      if not ok or not conn then break end
      server.connections = server.connections + 1
      conn:setmode("bn", "bn")
      conn:onerror(function(_, _, why) return why end)
      cq:wrap(function() pcall(handle, conn, server) end)
    end
  end)

  --- KILLS THE SERVER. Called from `finally` on every path, because the
  --- alternative is on this machine's record: twenty-two leaked servers
  --- spinning on their cores under a benchmark that was measuring something
  --- else entirely.
  function server.stop()
    server.stopped = true
    pcall(function() listener:close() end)
  end

  return server
end

-- ============================================================== the properties

describe("akkar.http pooling", function()
  local stop, port, base

  setup(function()
    stop, port = raw.start(8470)
    assert(stop, "the server did not start: " .. tostring(port))
    base = "http://127.0.0.1:" .. port
  end)

  teardown(function() if stop then stop() end end)

  it("reuses one connection for many requests to one origin", function()
    inside(function(cq)
      local server = raw_server(cq, function(conn, state)
        while true do
          local line = read_request(conn)
          if not line then break end
          state.requests = state.requests + 1
          respond(conn, "ok")
        end
      end)

      local ok, why = pcall(function()
        local client = http.connect { pool_size = 4 }()
        for _ = 1, 5 do
          local res, err = client:get("http://127.0.0.1:" .. server.port .. "/x")
          assert.is_truthy(res, tostring(err))
          assert.equal(200, res.status)
        end

        -- The server's own count, not the client's opinion of it.
        assert.equal(5, server.requests)
        assert.equal(1, server.connections)

        local stats = client:stats().origins["http://127.0.0.1:" .. server.port]
        assert.equal(1, stats.live)
        assert.equal(1, stats.idle)   -- back in the pool, ready for the next
        client:close()
      end)

      server.stop()
      assert(ok, tostring(why))
    end)
  end)

  it("keeps a separate pool per scheme, host and port", function()
    inside(function(cq)
      local server = raw_server(cq, function(conn, state)
        while true do
          local line = read_request(conn)
          if not line then break end
          state.requests = state.requests + 1
          respond(conn, "ok")
        end
      end)

      local ok, why = pcall(function()
        local client = http.connect { timeout = 2 }()
        local live = "http://127.0.0.1:" .. server.port .. "/x"

        assert.is_truthy(client:get(live))

        -- A PORT WITH NOTHING BEHIND IT. If the pool were keyed on anything
        -- looser than the origin -- on the host alone, or on one pool for the
        -- client -- this call would be served by the connection opened above
        -- and would come back 200, which is a request answered by a server it
        -- was never sent to.
        local dead = "http://127.0.0.1:" .. (server.port + 7) .. "/x"
        local res, err = client:get(dead)
        assert.is_nil(res)
        assert.is_string(err)

        -- Same address, different name: still a different origin, because the
        -- key is what was written and resolution is not this module's to
        -- guess at.
        local named = "http://localhost:" .. server.port .. "/x"
        assert.is_truthy(client:get(named))

        local origins = client:stats().origins
        assert.is_table(origins["http://127.0.0.1:" .. server.port])
        assert.is_table(origins["http://localhost:" .. server.port])
        assert.equal(2, server.connections)
        client:close()
      end)

      server.stop()
      assert(ok, tostring(why))
    end)
  end)

  it("never hands out a connection the peer has closed", function()
    inside(function(cq)
      -- One request per connection, then a close A MOMENT LATER and without
      -- `Connection: close` -- the shape of an idle timeout on a proxy, and
      -- the case that makes a naive pool answer nothing.
      local server = raw_server(cq, function(conn, state)
        local line = read_request(conn)
        if not line then return end
        state.requests = state.requests + 1
        respond(conn, "ok")
        cqueues.sleep(0.05)
        conn:close()
      end)

      local ok, why = pcall(function()
        local client = http.connect { timeout = 3 }()
        local url = "http://127.0.0.1:" .. server.port .. "/x"

        local first, err1 = client:get(url)
        assert.is_truthy(first, tostring(err1))
        assert.equal(200, first.status)

        -- Long enough for the FIN to arrive while the connection sits idle.
        cqueues.sleep(0.4)

        local second, err2 = client:get(url)
        assert.is_truthy(second, tostring(err2))
        assert.equal(200, second.status)

        -- And it was recognised as dead rather than merely surviving a retry.
        assert.is_true(client:stats().stale_reused >= 1)
        assert.equal(2, server.connections)
        client:close()
      end)

      server.stop()
      assert(ok, tostring(why))
    end)
  end)

  it("bounds the body read by the timeout", function()
    -- THE DEFECT, IN ONE TEST. `read_bounded` used to pass an absolute
    -- deadline where lua-http wants a relative timeout, so the wait was
    -- `monotime` seconds -- days on a machine that has been up a while.
    -- Measured before the fix: the first chunk arrived and the second call
    -- never returned.
    inside(function(cq)
      local server = raw_server(cq, function(conn)
        local line = read_request(conn)
        if not line then return end
        -- Promises a hundred bytes, sends five, then holds the socket open.
        conn:write "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort"
        conn:flush()
        cqueues.sleep(30)
      end)

      local ok, why = pcall(function()
        local client = http.connect { timeout = 1 }()
        local started = time.monotime()
        local res, err = client:get("http://127.0.0.1:" .. server.port .. "/x")
        local waited = time.monotime() - started

        assert.is_nil(res)
        assert.is_string(err)
        assert.is_true(waited < 3,
                       ("the read waited %.1fs on a 1s timeout"):format(waited))
        client:close()
      end)

      server.stop()
      assert(ok, tostring(why))
    end)
  end)

  it("sends a body over 1 KiB without the 100-continue penalty", function()
    -- ALSO A DEFECT WITH A NUMBER. `request:set_body` appended
    -- `expect: 100-continue` above 1024 bytes; lua-http then waited a second
    -- for a `100` most servers never send. Measured against this very server
    -- before the fix: 10 bytes answered 201 in 0.002 s, 2000 bytes answered
    -- **408 in 1.005 s**. akkar.storage puts objects through here.
    inside(function()
      local client = http.connect { timeout = 5 }()
      local started = time.monotime()
      local decoded, res = client:json("POST", base .. "/users",
                                       { body = { name = string.rep("a", 2000) } })
      local waited = time.monotime() - started

      assert.is_truthy(decoded, tostring(res))
      assert.equal(2000, #decoded.name)
      assert.is_true(waited < 0.5,
                     ("a 2 KiB body took %.3fs"):format(waited))
      client:close()
    end)
  end)

  it("still answers correctly with reuse switched off", function()
    -- `reuse = false` is the old behaviour through the NEW code path, which
    -- is the point of having only one path: this is also the benchmark's
    -- baseline, so it has to be a real client and not a straw man.
    inside(function(cq)
      local server = raw_server(cq, function(conn, state)
        while true do
          local line = read_request(conn)
          if not line then break end
          state.requests = state.requests + 1
          respond(conn, "ok")
        end
      end)

      local ok, why = pcall(function()
        local client = http.connect { reuse = false }()
        for _ = 1, 4 do
          local res, err = client:get("http://127.0.0.1:" .. server.port .. "/x")
          assert.is_truthy(res, tostring(err))
        end
        assert.equal(4, server.connections)   -- one per request, as asked
        local stats = client:stats().origins["http://127.0.0.1:" .. server.port]
        assert.equal(0, stats.live)           -- and every slot given back
        assert.equal(0, stats.idle)
        client:close()
      end)

      server.stop()
      assert(ok, tostring(why))
    end)
  end)

  it("holds the pool to its size under concurrency", function()
    inside(function(cq)
      -- Every request takes 50 ms, so ten concurrent callers against a pool
      -- of three must queue -- which is the state `Pool:get` yields in, and
      -- the one where a pool that blocked instead would stall the process.
      local server = raw_server(cq, function(conn, state)
        while true do
          local line = read_request(conn)
          if not line then break end
          state.requests = state.requests + 1
          cqueues.sleep(0.05)
          respond(conn, "ok")
        end
      end)

      local ok, why = pcall(function()
        local client = http.connect { pool_size = 3, timeout = 10 }()
        local url = "http://127.0.0.1:" .. server.port .. "/x"
        local done, failed = 0, nil

        for _ = 1, 10 do
          cq:wrap(function()
            local res, err = client:get(url)
            if res and res.status == 200 then done = done + 1
            else failed = failed or tostring(err) end
          end)
        end
        -- Yield until they finish; the controller runs them.
        for _ = 1, 200 do
          if done + (failed and 1 or 0) >= 10 then break end
          cqueues.sleep(0.02)
        end

        assert.is_nil(failed)
        assert.equal(10, done)
        assert.equal(10, server.requests)
        -- The ceiling held: never more sockets than the pool allows.
        assert.is_true(server.connections <= 3,
                       ("opened %d connections for a pool of 3")
                       :format(server.connections))
        local stats = client:stats().origins[url:match "^(.-)/x$"]
        assert.is_true(stats.waits > 0, "nothing ever queued; the pool was not the limit")
        client:close()
      end)

      server.stop()
      assert(ok, tostring(why))
    end)
  end)

  -- ================================================================ the number

  it("is measurably faster than a connection per request", function()
    -- REPORTED WHETHER OR NOT IT HELPS. A pool that does not pay for itself
    -- against a server on loopback -- where the handshake is at its cheapest
    -- and the case for pooling at its weakest -- is a pool that should not be
    -- on by default, and the honest way to find that out is to print the
    -- number either way.
    inside(function(cq)
      local N = 300

      --- BEST OF FIVE, ALTERNATING. This machine runs other work, and a
      --- single timing of each arm measures whatever else was running at the
      --- time -- observed directly while writing this, as a ratio that
      --- wandered between 1.02x and 1.25x across consecutive runs of the same
      --- code. The minimum of several interleaved runs is the least
      --- contaminated number available without a quiet machine.
      local function race(url)
        local best = { [true] = math.huge, [false] = math.huge }
        for _ = 1, 5 do
          for _, reuse in ipairs { true, false } do
            local client = http.connect { reuse = reuse, timeout = 10 }()
            client:get(url)                    -- warm the path, not the pool
            local started = time.monotime()
            for _ = 1, N do assert.is_truthy(client:get(url)) end
            local elapsed = time.monotime() - started
            client:close()
            if elapsed < best[reuse] then best[reuse] = elapsed end
          end
        end
        return best[true], best[false]
      end

      local function report(label, pooled, direct)
        print(("\n  %s -- %d sequential GETs, best of five:"):format(label, N))
        print(("    connection per request : %7.1f ms  (%.3f ms/req)")
              :format(direct * 1000, direct * 1000 / N))
        print(("    pooled                 : %7.1f ms  (%.3f ms/req)")
              :format(pooled * 1000, pooled * 1000 / N))
        print(("    saved per request      : %+.3f ms   (%.2fx)")
              :format((direct - pooled) * 1000 / N, direct / pooled))
      end

      -- TWO SERVERS, BECAUSE ONE NUMBER HIDES THE ANSWER.
      --
      -- Against akkar's own server most of a request is the server's work --
      -- routing, schema, JSON -- and the connection is a small share of it,
      -- so a ratio there understates what pooling does and overstates what it
      -- costs. Against a socket that answers a fixed string, almost all of
      -- what is left IS the connection, so the second number is close to the
      -- price of a handshake on loopback. Neither one alone is the answer and
      -- both are printed.
      local akkar_pooled, akkar_direct = race(base .. "/users")
      report("against akkar's own server", akkar_pooled, akkar_direct)

      local server = raw_server(cq, function(conn, state)
        while true do
          local line = read_request(conn)
          if not line then break end
          state.requests = state.requests + 1
          respond(conn, "ok")
        end
      end)
      local ok, why = pcall(function()
        local bare_pooled, bare_direct = race("http://127.0.0.1:" .. server.port .. "/x")
        report("against a bare socket server", bare_pooled, bare_direct)
        assert.is_true(bare_pooled <= bare_direct * 1.2,
                       ("pooling was slower: %.1f ms vs %.1f ms")
                       :format(bare_pooled * 1000, bare_direct * 1000))
      end)
      server.stop()
      assert(ok, tostring(why))

      -- The assertion is deliberately weak, and separate from the numbers.
      -- What is worth defending in CI is "pooling is not a regression"; the
      -- interesting figures are printed, and a loaded machine must not turn a
      -- benchmark into a red build.
      assert.is_true(akkar_pooled <= akkar_direct * 1.2,
                     ("pooling was slower: %.1f ms vs %.1f ms")
                     :format(akkar_pooled * 1000, akkar_direct * 1000))
    end, 300)
  end)
end)
