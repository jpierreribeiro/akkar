--[[
What STOP_ACCEPTING actually stops.

`App:stop` pauses the listener, and pausing a listener stops `accept()` and
nothing else.  A client that already holds a connection -- an h2 stream, or an
ordinary 1.1 keep-alive -- can keep asking for NEW work while the drain is
trying to end, and every one of those requests extends the drain by its own
duration.  Nothing about that requires malice: a browser with an open
connection and a page that polls will do it.

So the drain had no bound of its own.  `read_timeout` bounds any single
request, and the never-force policy means the process waits; together those
gave a shutdown that ends only when the clients decide to stop asking.

These tests use TWO connections, which is the only way to watch it: one holds a
slow request so the drain stays pending, and the second asks for new work after
the signal.  Both are opened before the signal, because after it the listener
is paused and a third connection would never be accepted -- which is the part
that already worked.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar   = require "akkar"
local cqueues = require "cqueues"
local client  = require "http.client"
local headers = require "http.headers"

local QUIET = { level = "error", format = "text", sink = function() end }

local function get(conn, path, timeout)
  local stream = assert(conn:new_stream())
  local rh = headers.new()
  rh:append(":method", "GET")
  rh:append(":scheme", "http")
  rh:append(":authority", "127.0.0.1")
  rh:append(":path", path)
  assert(stream:write_headers(rh, true))
  local response = assert(stream:get_headers(timeout or 5))
  local body = stream:get_body_as_string(timeout or 5)
  return tonumber(response:get ":status"), response, body
end

describe("a server that is shutting down", function()
  local outcome

  setup(function()
    local port = 18771
    local app = akkar.new()
    -- The two durations are chosen so the harm is measurable: the drain has
    -- to wait 0.3 s for the request it accepted before the signal, and would
    -- have to wait 1.5 s if it also accepted the one that arrived after.
    app:get("/slow", function() cqueues.sleep(0.3) return { ok = true } end)
    local slower_entered = 0
    app:get("/slower", function()
      slower_entered = slower_entered + 1
      cqueues.sleep(1.5)
      return { ok = true }
    end)
    app:get("/fast", function() return { ok = true } end)

    outcome = {}
    local cq = cqueues.new()

    cq:wrap(function()
      pcall(function()
        app:run { port = port, check_capabilities = false, shutdown_grace = 5,
                  log = akkar.log.new(QUIET) }
      end)
    end)

    cq:wrap(function()
      cqueues.sleep(0.25)
      -- Both connections exist BEFORE the signal.  After it the listener is
      -- paused, and a connection opened then would never be accepted.
      local holder = assert(client.connect(
        { host = "127.0.0.1", port = port, tls = false, version = 1.1 }, 5))
      local latecomer = assert(client.connect(
        { host = "127.0.0.1", port = port, tls = false, version = 1.1 }, 5))

      -- Prove the second connection works while the server is RUNNING, so a
      -- refusal later cannot be confused with a connection that was never
      -- usable.
      outcome.before_status = get(latecomer, "/fast")

      cq:wrap(function() outcome.holder_status = get(holder, "/slow") end)
      while (app.in_flight or 0) < 1 do cqueues.sleep(0.01) end

      local stop_began = cqueues.monotime()
      cq:wrap(function()
        outcome.stop_state = app:stop(5)
        outcome.drain_seconds = cqueues.monotime() - stop_began
      end)
      while app.state == "RUNNING" do cqueues.sleep(0.01) end

      -- The request the whole file is about: new work, on a connection that
      -- was already open, after the signal.  It asks for the SLOW route on
      -- purpose -- a fast one would be refused and accepted in
      -- indistinguishable time, and the test would prove nothing.
      outcome.after_status, outcome.after_headers, outcome.after_body =
        get(latecomer, "/slower")
      outcome.slower_entered = slower_entered
    end)

    assert(cq:loop(20))
  end)

  it("serves that same connection normally while it is running", function()
    assert.equal(200, outcome.before_status)
  end)

  it("refuses new work with 503 instead of accepting it into the drain", function()
    assert.equal(503, outcome.after_status)
  end)

  it("tells the client not to ask again on this connection", function()
    -- Without `connection: close` a keep-alive client takes the 503 and asks
    -- again on the same socket, and the refusal becomes a loop.
    assert.equal("close", outcome.after_headers:get "connection")
    assert.equal("1", outcome.after_headers:get "retry-after")
  end)

  it("does not let a refused request extend the drain", function()
    -- The harm, asserted as a fact rather than as a duration.  A threshold on
    -- the drain's wall time says the same thing and says it flakily: this
    -- suite shares a machine, and a 0.3 s sleep under load is not reliably
    -- under any bound worth writing down.  Whether the handler RAN is the same
    -- claim, measured where it cannot drift -- the 1.5 s route the latecomer
    -- asked for is what the drain would have had to wait for.
    assert.equal(0, outcome.slower_entered,
      "the refused request reached its handler, so the drain waited for it")
  end)

  it("still finishes the request that was already in flight", function()
    -- Refusing new work is not forcing: what was accepted is still served.
    assert.equal(200, outcome.holder_status)
    assert.equal("STOPPED", outcome.stop_state)
  end)
end)
