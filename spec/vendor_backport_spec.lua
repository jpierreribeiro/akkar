--[[
Two fixes upstream made after v0.4 and never released, backported by hand.

## Why by hand

lua-http's last release is v0.4 (2021-02-06) and its last commit is
2024-09-08. Three commits since the release touch shipped code and two of them
are real; there is no version to upgrade to, and there will not be one. The
vendored tree carried v0.4's bugs for as long as it existed.

## `ddab283` -- EOF on a `length` body was a clean end of body

`read_next_chunk` answered `nil, nil` when the peer hung up part-way through a
body it had announced with `content-length`. Every caller in the library reads
`nil, nil` as *the body ended normally*, so:

  - `get_body_as_string` returns the SHORT body and no error;
  - `akkar.http`'s `read_bounded` breaks out of its loop and hands the caller a
    truncated response as a complete one -- the exact outcome its own comment
    says must never happen ("a body that was cut short leaves the stream
    part-read");
  - `shutdown` drains until the body is done, so it drains for ever.

The last of those is what upstream's commit message names. The first two are
worse, because nothing anywhere reports them: an API client parses half a JSON
document and the error surfaces somewhere else entirely.

## `059ae00` -- 304 was handled as a redirect

`304 Not Modified` begins with a 3 and carries no `location`, so
`request:go()` called `handle_redirect`, found no `location`, and returned
`nil, "missing location header for redirect", EINVAL`. A correct answer to a
conditional request came back as a failed request.

The blast radius, stated honestly: **`akkar.http` does not call `go()`**. It
drives a pooled connection directly, precisely to avoid `go`'s
connection-per-request. So this one reaches users of the vendored
`akkar.vendor.http.request` module, not `akkar.http`'s client -- and the
regression test that matters most for `akkar.http` is the `ddab283` one below,
which does reach it.

## The harness

A raw TCP server in this process. Safe here for the reason
`spec/http_pool_spec.lua` gives: the deadlock `spec/support/raw_client.lua`
warns about needs a half of the exchange that blocks without yielding, and
every socket below is a cqueues socket read inside one controller. Raw,
because both properties need a server that answers something no correct server
would -- a 304 with a `location`, and a body that stops early -- and akkar's
own server will not do either on request.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local socket  = require "cqueues.socket"
local request = require "akkar.vendor.http.request"
local http    = require "akkar.http"

--- Every call yields, so every test runs inside a controller.
local function inside(fn, budget)
  local err
  local cq = cqueues.new()
  cq:wrap(function()
    local ok, why = pcall(fn, cq)
    if not ok then err = why end
  end)
  assert(cq:loop(budget or 20))
  if err then error(err, 0) end
end

--- Reads one request off `conn`, headers only. Returns the request line.
---
--- The blank line that ends a header block arrives as "\r" in binary mode, not
--- as "", because cqueues' `*l` strips only the newline.
local function read_request(conn)
  local first = conn:read "*l"
  if not first then return nil end
  while true do
    local line = conn:read "*l"
    if line == nil then return nil end
    if line:gsub("\r$", "") == "" then break end
  end
  return (first:gsub("\r$", ""))
end

--- A raw TCP server on a free port. `handle(conn, state)` answers one
--- connection; `state.requests` counts what it was asked for.
local function raw_server(cq, handle)
  local listener, port
  for candidate = 8940, 8999 do
    local attempt = socket.listen("127.0.0.1", candidate)
    if attempt then
      local ok = pcall(function() attempt:listen() end)
      if ok then listener, port = attempt, candidate break end
    end
  end
  assert(listener, "no free port for the raw server")

  local server = { port = port, requests = 0, stopped = false }

  cq:wrap(function()
    while not server.stopped do
      local ok, conn = pcall(function() return listener:accept() end)
      if not ok or not conn then break end
      conn:setmode("bn", "bn")
      conn:onerror(function(_, _, why) return why end)
      cq:wrap(function() pcall(handle, conn, server) end)
    end
  end)

  -- Killed on every path, `finally` included: leaked listeners on this
  -- machine have already cost a benchmark run that was measuring something
  -- else entirely.
  function server.stop()
    server.stopped = true
    pcall(function() listener:close() end)
  end

  return server
end

--- Runs `body(server)` against `handle`, and stops the server whatever happens.
local function against(handle, body)
  inside(function(cq)
    local server = raw_server(cq, handle)
    local ok, why = pcall(body, server)
    server.stop()
    assert(ok, tostring(why))
  end)
end

local function url(server, path)
  return ("http://127.0.0.1:%d%s"):format(server.port, path or "/")
end

-- ===================================================================== 059ae00

describe("the vendored request module and 304", function()
  --- Answers `status_line` plus `extra` headers, once, then closes.
  local function answers(status_line, extra)
    return function(conn, state)
      if not read_request(conn) then return end
      state.requests = state.requests + 1
      conn:write(status_line .. "\r\n" .. (extra or "") .. "\r\n")
      conn:flush()
      conn:shutdown "w"
    end
  end

  it("hands a 304 back to the caller instead of chasing a redirect", function()
    against(answers("HTTP/1.1 304 Not Modified", "etag: \"v1\"\r\n"), function(server)
      local req = request.new_from_uri(url(server, "/thing"))
      req.headers:upsert("if-none-match", '"v1"')
      local headers, stream = req:go(5)
      -- Before the backport this was `nil, "missing location header for
      -- redirect"`: a correct cache revalidation reported as a failure.
      assert.is_truthy(headers, tostring(stream))
      assert.equal("304", headers:get ":status")
      assert.equal('"v1"', headers:get "etag")
      stream:shutdown()
      assert.equal(1, server.requests)
    end)
  end)

  it("does not follow a 304 that carries a location either", function()
    -- The guard has to be on the STATUS, not on the missing header. A 304 with
    -- a `location` is legal -- servers put one there by accident and some CDNs
    -- on purpose -- and the pre-backport code would have followed it happily,
    -- turning a "your copy is current" into a second request somewhere else.
    against(answers("HTTP/1.1 304 Not Modified", "location: /elsewhere\r\n"),
      function(server)
        local req = request.new_from_uri(url(server, "/thing"))
        local headers, stream = req:go(5)
        assert.is_truthy(headers, tostring(stream))
        assert.equal("304", headers:get ":status")
        stream:shutdown()
        -- One request. A followed redirect would be two.
        assert.equal(1, server.requests)
      end)
  end)

  it("still follows a 302, which is what the condition is for", function()
    -- The cheap way to break the backport is to disable redirects entirely,
    -- and every test above would still pass.
    against(function(conn, state)
      local line = read_request(conn)
      if not line then return end
      state.requests = state.requests + 1
      if state.requests == 1 then
        conn:write("HTTP/1.1 302 Found\r\nlocation: /moved\r\ncontent-length: 0\r\n\r\n")
      else
        conn:write("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
      end
      conn:flush()
      conn:shutdown "w"
    end, function(server)
      local req = request.new_from_uri(url(server, "/start"))
      local headers, stream = req:go(5)
      assert.is_truthy(headers, tostring(stream))
      assert.equal("200", headers:get ":status")
      stream:shutdown()
      assert.equal(2, server.requests)
    end)
  end)
end)

-- ===================================================================== ddab283

--- Announces `content-length: 100` and sends forty bytes, then hangs up.
local SHORT = string.rep("x", 40)
local function short_body(conn, state)
  if not read_request(conn) then return end
  state.requests = state.requests + 1
  conn:write("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n" .. SHORT)
  conn:flush()
  conn:shutdown "w"
end

describe("a body that stops before its content-length", function()
  it("is an error on the vendored stream, not a short body", function()
    against(short_body, function(server)
      local req = request.new_from_uri(url(server, "/truncated"))
      local headers, stream = req:go(5)
      assert.is_truthy(headers, tostring(stream))
      assert.equal("200", headers:get ":status")

      local body, err = stream:get_body_as_string(5)
      -- Before the backport this returned the 40 bytes with no error at all,
      -- so the caller could not tell 40 from 100.
      assert.is_nil(body)
      assert.is_string(err)
      assert.is_truthy(err:lower():find("pipe", 1, true),
                       "expected EPIPE, got " .. tostring(err))
      stream:shutdown()
    end)
  end)

  it("is an error through akkar.http, which is the public consumer", function()
    -- `read_bounded` in akkar/http.lua breaks its loop on `err == nil` and
    -- returns what it has. Its comment says a cut-short body "must not look
    -- like a complete short response" -- and the vendored stream was making it
    -- look like exactly that. This is the assertion that ties the backport to
    -- something a user of akkar can observe.
    against(short_body, function(server)
      local client = http.connect {}()
      local res, why = client:get(url(server, "/truncated"))
      assert.is_nil(res, res and ("a truncated body came back as a complete "
                                  .. #tostring(res.body) .. "-byte response"))
      assert.is_string(why)
      client:close()
    end)
  end)

  it("still reads a body that arrives whole", function()
    -- The backport turns one `nil, nil` into an error. If it turned the
    -- ordinary end of a body into one too, every response in the runtime would
    -- fail, so this is the case that proves the branch is the right branch.
    against(function(conn, state)
      if not read_request(conn) then return end
      state.requests = state.requests + 1
      conn:write("HTTP/1.1 200 OK\r\ncontent-length: 40\r\n\r\n" .. SHORT)
      conn:flush()
      conn:shutdown "w"
    end, function(server)
      local req = request.new_from_uri(url(server, "/whole"))
      local headers, stream = req:go(5)
      assert.is_truthy(headers, tostring(stream))
      assert.equal(SHORT, assert(stream:get_body_as_string(5)))
      stream:shutdown()
    end)
  end)
end)
