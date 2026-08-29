--[[
Admission control, when the client decides how many requests fit in a socket.

`max_concurrent` is handed to lua-http, which bounds CONNECTIONS. The reason
it exists is the descriptor ceiling, and that is about REQUESTS: two file
descriptors per request in flight, whichever connection carried it. One
request per connection was an assumption, and both HTTP versions break it.
Measured against `max_concurrent = 1`, forty requests, ONE connection:

    http_version = 2      peak 40 in flight, 0.33 s   h2 multiplexing
    http_version = 1.1    peak 40 in flight, 0.32 s   h1 pipelining

lua-http closes neither hole: its h2 connection ships
`MAX_CONCURRENT_STREAMS = math.huge`, `server.listen` takes no settings table
to change that, and the two places that would enforce a limit -- the one it
announces and the one a peer announces -- both carry
`-- TODO: check MAX_CONCURRENT_STREAMS`.

So the runtime counts requests itself, refuses past the ceiling, and tells h2
clients the number so a well-behaved one need never be refused. These are the
measurements, run as tests: the peak on both protocols, and the price of a
refusal.

The client is lua-http's own, deliberately: it ignores an advertised
MAX_CONCURRENT_STREAMS, and a test that only bounded polite clients would be
testing the client. Two things about it are worked around rather than proved
here, both established outside this file:

  * every request is written before any response is read. Several stream
    coroutines calling `:step` on one h2 connection is not safe, and the
    single reader also makes the 1.1 case genuine pipelining.
  * the h2 cases use a ceiling of ONE, so only one 200 is ever in flight.
    Two responses coming back together on one h2 connection make this client
    raise COMPRESSION_ERROR, and that is its bug, not the server's: the same
    three requests against a plain handler returning 503 reproduce it with no
    admission control anywhere, and a trace of the server shows its HPACK
    encode order and its wire order agreeing frame for frame.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local client  = require "http.client"
local headers = require "http.headers"

local QUIET = { level = "error", format = "text", sink = function() end }

--- Puts `n` requests on ONE connection before reading any answer, and reports
--- what came back along with the highest request count the server ever held
--- at once.
local function burst(opts)
  local app = akkar.new()
  local entered = 0
  app:get("/slow", function()
    entered = entered + 1
    cqueues.sleep(opts.hold or 0.2)
    return { ok = true }
  end)

  local peak, statuses, retry_after, advertised, left_counted = 0, {}, nil, nil, nil
  local finished = false
  local cq = cqueues.new()

  cq:wrap(function()
    pcall(function()
      app:run { port = opts.port, max_concurrent = opts.max_concurrent,
                http_version = opts.version, check_capabilities = false,
                log = akkar.log.new(QUIET) }
    end)
  end)

  cq:wrap(function()
    while not finished do
      if (app.in_flight or 0) > peak then peak = app.in_flight end
      cqueues.sleep(0.005)
    end
  end)

  cq:wrap(function()
    cqueues.sleep(0.25)
    local conn = assert(client.connect({ host = "127.0.0.1", port = opts.port,
                                         tls = false, version = opts.version }, 5))
    local streams = {}
    for i = 1, opts.n do
      local stream = assert(conn:new_stream())
      local rh = headers.new()
      rh:append(":method", "GET")
      rh:append(":scheme", "http")
      rh:append(":authority", "127.0.0.1:" .. opts.port)
      rh:append(":path", "/slow")
      assert(stream:write_headers(rh, true, 5))
      streams[i] = stream
    end
    for i = 1, opts.n do
      local res = assert(streams[i]:get_headers(15))
      local status = res:get ":status"
      statuses[status] = (statuses[status] or 0) + 1
      if status == "503" then retry_after = res:get "retry-after" end
      streams[i]:get_body_as_string(5)
    end
    -- What the peer believes about us after a response has come back: the
    -- advertisement travels on the connection's first stream.
    advertised = conn.peer_settings and conn.peer_settings[0x3]
    pcall(function() conn:close() end)
    -- Nothing is in flight now, so a drain must be able to end. A refusal that
    -- forgot to give the count back would leave this above zero.
    left_counted = app.in_flight
    app:stop(1)
    finished = true
  end)

  assert(cq:loop(60))
  return { statuses = statuses, peak = peak, retry_after = retry_after,
           entered = entered, advertised = advertised, left = left_counted }
end

describe("the concurrency ceiling counts requests, not connections", function()
  it("holds under HTTP/2 multiplexing, where it used to reach 40", function()
    -- The original measurement, run the other way round: forty requests down
    -- one h2c connection against a ceiling of one.
    local r = burst { port = 8651, version = 2, max_concurrent = 1, n = 40 }
    assert.equal(1, r.peak)
    assert.equal(1, r.statuses["200"])
    assert.equal(39, r.statuses["503"])
  end)

  it("holds under HTTP/1.1 pipelining, which was never safe either", function()
    -- The default configuration. One connection, twenty requests written back
    -- to back before the first response is read: the same forty-in-flight
    -- measurement as h2, and the same gate stops it.
    local r = burst { port = 8652, version = 1.1, max_concurrent = 2, n = 20 }
    assert.is_true(r.peak <= 2,
      string.format("peak was %d against max_concurrent = 2", r.peak))
    assert.equal(2, r.statuses["200"])
    assert.equal(18, r.statuses["503"])
  end)

  it("refuses before the handler, so a shed request costs nothing", function()
    -- The point of gating in onstream rather than inside the chain: a refusal
    -- spends no deadline controller, no pool checkout and no handler. If the
    -- handler had run for a request that got a 503, this would say so.
    local r = burst { port = 8653, version = 2, max_concurrent = 1, n = 20 }
    assert.equal(r.statuses["200"], r.entered)
  end)

  it("says 503 with a delay in it, not a bare failure", function()
    local r = burst { port = 8654, version = 2, max_concurrent = 1, n = 12 }
    assert.equal(11, r.statuses["503"])
    assert.equal("1", r.retry_after)
  end)

  it("gives the count back, so a drain can still end", function()
    -- A refused request was never in flight. If shedding leaked the count, the
    -- ceiling would shrink permanently and App:stop would wait forever -- the
    -- one failure the drain's never-force policy cannot rescue.
    local r = burst { port = 8655, version = 2, max_concurrent = 1, n = 20 }
    assert.equal(0, r.left)
  end)

  it("tells an h2 client the number, so a polite one need never be refused", function()
    -- lua-http announces MAX_CONCURRENT_STREAMS = math.huge and offers no way
    -- to change it through server.listen, so the frame is written from
    -- onstream on the connection's first stream. This is the peer's own view
    -- of it, and it read `inf` before the request.
    local r = burst { port = 8656, version = 2, max_concurrent = 3, n = 1 }
    assert.equal(3, r.advertised)
  end)

  it("is not consulted at all on a connection that stays within it", function()
    -- The default configuration must be unchanged: with a ceiling above the
    -- load nothing is refused and nothing is announced to an HTTP/1.1 peer.
    local r = burst { port = 8657, version = 1.1, max_concurrent = 8, n = 5 }
    assert.equal(5, r.statuses["200"])
    assert.is_nil(r.statuses["503"])
    assert.equal(5, r.entered)
  end)
end)
