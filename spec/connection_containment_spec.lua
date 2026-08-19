--[[
One connection must not be able to kill the server.

## The class, from two directions

`cq:wrap` gives every connection its own coroutine in the server's controller,
and cqueues propagates a raise out of `cq:loop()`. So an unexpected error
anywhere under `handle_socket` -- a framing layer, a TLS handshake, a parser
meeting bytes it did not consider -- travelled out of `app:run` and took the
ACCEPT LOOP with it. The process stayed up, the listening socket stayed open,
and nothing was ever accepted again.

Both times it happened here it was a one-line parser bug and a total outage:

  * `Content-Length: banana` on the HTTP/1.1 side, recorded in
    `akkar/init.lua`, where `get_headers` raised for a length that is not a
    number;
  * a three-byte HTTP/2 frame header, found by `spec/h2_framing_spec.lua` on
    its first run, where `string.unpack` raised on a short read.

Each was fixed where it happened. This file is about the third one, which
nobody has found yet.

## What is asserted

`add_socket` now runs `handle_socket` under `xpcall`. When it raises:

  * the error is contained -- `cq:loop()` returns normally rather than
    propagating;
  * `n_connections` comes back down. This is the half that is easy to miss:
    `handle_socket` decrements it on its LAST line, so a raise skips it, and a
    connection count that only climbs walls the server off at `max_concurrent`
    just as completely, only slower;
  * and the server keeps accepting.

## Why the raise is staged this way

Passing something that is not a socket to `add_socket` makes `wrap_socket`
raise on the first method call -- and `wrap_socket` is the function upstream's
own comment says "should never throw". It needs no malformed protocol and no
timing, so it is the same raise on every machine, which a hostile-bytes test
cannot promise once the parser bug behind it is fixed.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local server  = require "akkar.vendor.http.server"

describe("a connection coroutine that raises", function()
  local function server_with_a_broken_connection(n)
    local reported = {}

    local cq = cqueues.new()
    local s = server.new {
      cq = cq,
      tls = false,
      onstream = function() end,
      onerror = function(_, _, op, err)
        reported[#reported + 1] = { op = op, err = tostring(err) }
      end,
    }

    for _ = 1, n do
      -- Not a socket. `wrap_socket` calls a method on it and raises.
      s:add_socket(setmetatable({}, {}))
    end

    -- The whole assertion in one line: this must RETURN rather than propagate.
    local ok, err = cq:loop(5)
    return ok, err, s, reported
  end

  it("is contained, instead of taking the loop down with it", function()
    local ok, err = server_with_a_broken_connection(1)
    assert.is_truthy(ok,
      ("the raise escaped the connection and reached the loop: %s")
        :format(tostring(err)))
  end)

  it("gives its connection slot back", function()
    -- `max_concurrent` is enforced against `n_connections`, so a count that
    -- only goes up is an outage on a delay: the server stops accepting once
    -- enough connections have raised, with no error anywhere to explain it.
    local _, _, s = server_with_a_broken_connection(5)
    assert.equal(0, s.n_connections,
      ("%d of 5 connection slots were never given back"):format(s.n_connections))
  end)

  it("is reported as a connection failure, not as transport noise", function()
    -- `akkar/init.lua` logs `op == "connection"` at error level with the
    -- traceback, because a connection that raised is a BUG and everything
    -- else reaching `onerror` -- a peer that went away mid-write, an accept
    -- that failed -- is ordinary and rightly a warning. With both at warn, a
    -- server dropping every connection would say nothing at error level.
    local _, _, _, reported = server_with_a_broken_connection(1)

    assert.equal(1, #reported,
      ("expected one report, got %d"):format(#reported))
    assert.equal("connection", reported[1].op)
    assert.is_truthy(reported[1].err:find "stack traceback",
      "the report carries no traceback, so it names no line to fix")
  end)

  it("keeps accepting afterwards", function()
    -- The property the other three are for. Five connections raise, and the
    -- server is still able to take a sixth: `add_socket` returns true and the
    -- loop still drains.
    local _, _, s = server_with_a_broken_connection(5)
    assert.is_true(s:add_socket(setmetatable({}, {})))
    assert.is_truthy(s.cq:loop(5), "the server stopped accepting")
    assert.equal(0, s.n_connections)
  end)
end)
