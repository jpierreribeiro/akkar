--[[
Luvit, matching bench/compare/akkar/serve.lua exactly on `/ping`.

Luvit is the candidate that would break akkar's claim if the claim is
breakable: Node-like on libuv, actively released (2.18.1), and the direct
answer to "Lua already has a runtime". It is also what prices
`akkar-substrate-luv`, parked in the Execution Scope plan.

WHAT THIS FILE DOES NOT SERVE, and it is a finding rather than an omission:
`/users/:id`. Luvit has no maintained Postgres driver -- there is no
equivalent of pgmoon in its ecosystem, and writing one over libuv for a
benchmark would be measuring code written this afternoon rather than the
runtime. Rule 2 in METHOD.md says what cannot be equalised is reported as a
caveat rather than absorbed into a number, so it is reported: on this
dimension Luvit is not a service runtime in the sense akkar claims to be, and
that is worth more than a fabricated row.

Routing is by hand because that is what Luvit gives you, and that is the
honest comparison: akkar's 103 µs includes a router, and Luvit's number
should include whatever Luvit makes you write to get the same behaviour.
]]

local http = require "http"

local port = tonumber(args[2]) or 8411

local PONG = '{"pong":true}'

-- TCP_NODELAY, and the reason it is here is the whole story of this file's
-- first number.
--
-- Without it Luvit measured 2,435 req/s across three repetitions with 0.06%
-- spread -- a constant, which is the shape of a limit rather than of
-- performance. Single-request latency said why: the first request on a
-- connection took 0.45 ms and every one after it took 40.9 ms. That is Nagle
-- meeting delayed ACK, the classic 40 ms stall, because the response leaves
-- as two segments and the kernel waits for an ACK that the peer is holding.
--
-- akkar on the same box answered in 0.15 ms, so the comparison would have
-- reported Luvit at a quarter of akkar's throughput while measuring neither.
-- A number that wrong in our favour is worse than no number.
http.createServer(function(req, res)
  -- Set per connection: Luvit does not do it for you, and that is itself a
  -- fact about the runtime worth recording -- but it is a fact about a
  -- default, not about how fast libuv can go.
  if res.socket and res.socket.nodelay then pcall(res.socket.nodelay, res.socket, true) end
  -- `req.url` carries the query string too; the routes here have none, but
  -- splitting is what any real handler would do and skipping it would be
  -- doing less work than the others.
  local path = req.url:match "^([^?]*)" or req.url

  if path == "/ping" and req.method == "GET" then
    res:setHeader("Content-Type", "application/json")
    res:setHeader("Content-Length", #PONG)
    res:finish(PONG)
    return
  end

  local body = '{"error":"no route for ' .. req.method .. ' ' .. path .. '"}'
  res.statusCode = 404
  res:setHeader("Content-Type", "application/json")
  res:setHeader("Content-Length", #body)
  res:finish(body)
end):listen(port)

print("luvit listening on " .. port)
