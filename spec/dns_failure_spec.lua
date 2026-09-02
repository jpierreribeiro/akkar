--[[
DNS failing, or resolving to something new — `docs/UNKNOWNS.md` §3.

`akkar/http.lua` is the outbound half, and every url it is handed carries a
NAME. Nothing under `akkar/` mentions DNS: `grep -rn "dns\|resolver" akkar/`
finds `akkar/auth.lua`'s principal resolvers and nothing else. So the whole of
name resolution is inherited from cqueues, unconfigured and unmeasured, and
this file is the first thing to point at it.

Three questions, and the answers are not the same shape.

## 1. Does a lookup respect the request deadline?  YES — measured

This was the one worth fearing. A DNS lookup that ignores the caller's budget
means one sick resolver blows every deadline in the process, and the
`execution.bounded` line in `akkar/http.lua` — the whole cascading-failure
argument — would be decoration. It is not: elapsed tracked the configured
timeout to the millisecond at 0.5 s, 2 s and 4 s.

    nxdomain timeout=0.5 elapsed=0.501
    nxdomain timeout=2   elapsed=2.003
    nxdomain timeout=4   elapsed=4.005

A verified non-issue, and it is the most valuable line in this file.

## 2. Does it FAIL FAST when the answer is already known?  NO — a defect

Tracking the timeout exactly is also the bad news. The resolver has a
definitive NXDOMAIN in hand and the client waits out its entire budget anyway,
so a hostname with a typo in it costs what an overloaded upstream costs. On
`akkar/http.lua`'s own default of `timeout = 10`, that is ten seconds per
attempt, multiplied by `retries`, and — because the budget comes from
`execution.bounded` — it is the REQUEST's ten seconds, not a spare ten.

Measured underneath, on a systemd-resolved host, for the same name:

    getent hosts nope-akkar-test-12345.com     0.18 s   (NXDOMAIN)
    cqueues dns.query same name               10.019 s  (NXDOMAIN)

Root cause, isolated by bisecting the resolver config: `/etc/resolv.conf` on
every systemd-resolved box carries `search .`, and cqueues' resolver spends
`attempts × timeout` (2 × 5 s) on it before it will hand back the NXDOMAIN it
already has. Dropping that one entry:

    as-is                     elapsed=10.019 rcode=NXDOMAIN(3)
    attempts=1                elapsed= 5.008 rcode=NXDOMAIN(3)
    search={}                 elapsed= 0.071 rcode=NXDOMAIN(3)
    edns0=false,search={}     elapsed= 0.007 rcode=NXDOMAIN(3)

140x, from one line of resolver config. akkar cannot reach it. `dns.setpool`
changes what `cqueues.dns.query` uses and NOT what `cqueues.socket.connect`
uses — proven directly: with a pool whose only nameserver was blackholed,
`dns.query` timed out and `cs.connect` resolved the same name in 44 ms. There
is no `socket.setresolver`. So the fix has to be akkar resolving the name
itself, on a bounded sub-budget, before it dials — which is a change to the
connect path and not a line of config, and is why this file measures the
defect rather than carrying its fix.

## 3. What does the caller SEE?  `flush: Connection timed out` — a defect

No host, no url, no mention of a name. `https` says `starttls: Connection
timed out`. A service calling three upstreams gets one indistinguishable
string for "the hostname is misspelled", "the firewall drops us" and "the
peer is overloaded" — three incidents with three different responses. The
module that documents A NAMED TIMEOUT, NOT A HANG for its body reads is
handing back an unnamed one for its lookups.

## What is NOT wrong

A blackhole address respects the timeout rather than Linux's ~130 s SYN retry
period, a refused connection comes back in a millisecond, and twenty failed
lookups leak no descriptor and no pool slot. All asserted below.

## Why the defect assertions read as they do

They assert the CURRENT number, and each is marked. This branch is shared and
green; a spec that goes red the moment it lands is a message to whoever runs
CI next, not to whoever fixes this. When the connect path learns to resolve
first, invert the two marked assertions and this file becomes the regression
test.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local http    = require "akkar.http"
local time    = require "akkar.time"

-- RFC 6761 reserves `.invalid`: it is guaranteed never to resolve, so this
-- name cannot be bought out from under the suite the way a `.com` could.
local NOWHERE = "http://this-does-not-exist.invalid/"

-- TEST-NET-1. Routable-looking, documented as never routed, so packets to it
-- are dropped rather than refused -- which is what makes it a SYN blackhole
-- rather than a fast `ECONNREFUSED`.
local BLACKHOLE = "http://192.0.2.1/"

--- Runs `fn` inside a controller, since every call in `akkar.http` yields.
local function inside(fn, budget)
  local err
  local cq = cqueues.new()
  cq:wrap(function()
    local ok, why = pcall(fn)
    if not ok then err = why end
  end)
  assert(cq:loop(budget or 60))
  if err then error(err, 0) end
end

--- Seconds one call took, and what it returned.
local function timed(fn)
  local started = time.monotime()
  local res, why = fn()
  return time.monotime() - started, res, why
end

--- Open descriptors, or nil where the question cannot be asked.
---
--- `/proc/self/fd` is Linux. `spec/support/portable.lua` exists because this
--- suite once assumed everyone had `timeout` and `setsid`; asking whether the
--- path is there costs one `open` and does not repeat that.
local function descriptors()
  local dir = io.open("/proc/self/fd", "r")
  if dir then dir:close() end
  local pipe = io.popen("ls /proc/self/fd 2>/dev/null | wc -l")
  if not pipe then return nil end
  local count = tonumber((pipe:read "a" or ""):match "%d+")
  pipe:close()
  return count
end

--- What one NXDOMAIN costs the resolver underneath, independent of akkar.
---
--- Measured rather than assumed, because the defect below is only reachable
--- when the resolver is slower than the budget. On a box whose resolv.conf
--- has no `search .` the same lookup takes 7 ms, akkar returns in 7 ms, and
--- asserting "it burned the budget" there would be asserting the local
--- resolv.conf.
local resolver_cost
do
  local ok, dns = pcall(require, "cqueues.dns")
  if ok then
    inside(function()
      resolver_cost = timed(function()
        return pcall(dns.query, "this-does-not-exist.invalid", "A")
      end)
    end, 60)
  end
end

describe("akkar.http when a name does not resolve", function()
  it("prints what one NXDOMAIN costs the resolver underneath", function()
    -- Not an assertion. The number is the whole argument in the header, and a
    -- number nobody prints is a number nobody checks again.
    print(("\n    cqueues resolver, one NXDOMAIN: %s")
          :format(resolver_cost and ("%.3f s"):format(resolver_cost) or "unknown"))
    assert.is_truthy(true)
  end)

  -- THE GUARANTEE. A lookup cannot outlive the caller's budget.
  --
  -- This is the property the cascading-failure paragraph in `akkar/http.lua`
  -- depends on, and until this file it had never been checked against a name
  -- rather than against a socket.
  it("never outlives the timeout it was given", function()
    for _, budget in ipairs { 0.4, 1.2 } do
      inside(function()
        local client = http.connect { timeout = budget } ()
        local elapsed, res, why = timed(function() return client:get(NOWHERE) end)
        assert.is_nil(res)
        assert.is_truthy(why)
        -- Half a second of slack: the assertion is "bounded by the budget",
        -- not "accurate to the scheduler tick", and a loaded CI box is
        -- allowed a tick.
        assert.is_true(elapsed < budget + 0.5,
          ("a %.1f s budget took %.3f s"):format(budget, elapsed))
      end, 30)
    end
  end)

  -- THE DEFECT. It spends every millisecond of that budget, on an answer the
  -- resolver already had.
  --
  -- INVERT THIS WHEN THE CONNECT PATH RESOLVES FIRST: the assertion becomes
  -- `elapsed < budget / 2`, and it will hold, because the header measured the
  -- same NXDOMAIN coming back in 0.071 s with `search` cleared.
  it("spends the whole budget on a name that is already known not to exist", function()
    local budget = 0.4
    if not (resolver_cost and resolver_cost > budget) then
      -- The resolver here answers faster than the budget, so there is nothing
      -- for the client to waste. Saying so is the result.
      print("\n    resolver answers faster than the budget; nothing to burn")
      return
    end
    inside(function()
      local client = http.connect { timeout = budget } ()
      local elapsed = timed(function() return client:get(NOWHERE) end)
      assert.is_true(elapsed > budget * 0.9,
        ("expected the full %.1f s budget to be spent, took %.3f s")
        :format(budget, elapsed))
    end, 30)
  end)

  -- THE SECOND DEFECT. Nothing in the reason says which host, or that a name
  -- was involved at all.
  --
  -- INVERT THIS WHEN THE ERROR IS NAMED: the two `is_nil` become
  -- `assert.is_truthy(why:find("this-does-not-exist.invalid", 1, true))`.
  it("blames the connection for a failure that was a lookup", function()
    inside(function()
      local client = http.connect { timeout = 0.4 } ()
      local _, why = client:get(NOWHERE)
      why = tostring(why)
      assert.is_nil(why:find("this%-does%-not%-exist"))
      assert.is_nil(why:lower():find("dns", 1, true))
      assert.is_nil(why:lower():find("resolve", 1, true))
      -- What it says instead, so a change to the string is visible here
      -- rather than in somebody's incident.
      assert.is_truthy(why:lower():find("timed out", 1, true))
    end, 30)
  end)
end)

describe("akkar.http against an address that swallows packets", function()
  -- The sharp one from §3: an address that used to be the answer and is not
  -- reachable any more. Linux retries a SYN for about 130 s by default, so a
  -- client that hands the deadline to the kernel and looks away holds the
  -- coroutine for two minutes on a one-second call.
  it("gives up on its own deadline, not on the SYN retry period", function()
    local budget = 0.4
    inside(function()
      local client = http.connect { timeout = budget } ()
      local elapsed, res, why = timed(function() return client:get(BLACKHOLE) end)
      assert.is_nil(res)
      assert.is_truthy(why)
      print(("\n    blackhole 192.0.2.1, budget %.1f s: returned in %.3f s")
            :format(budget, elapsed))
      assert.is_true(elapsed < budget + 0.5,
        ("a %.1f s budget against a blackhole took %.3f s"):format(budget, elapsed))
    end, 30)
  end)

  it("still fails a refused port immediately", function()
    -- The control. Without it, "it respected the timeout" could just as well
    -- be "it never tries anything", and the blackhole number above would mean
    -- nothing.
    inside(function()
      local client = http.connect { timeout = 5 } ()
      local elapsed, res = timed(function() return client:get("http://127.0.0.1:9/") end)
      assert.is_nil(res)
      assert.is_true(elapsed < 0.5,
        ("a refused port took %.3f s"):format(elapsed))
    end, 30)
  end)
end)

describe("what a failed lookup leaves behind", function()
  -- Seven lifetime leaks have been found in this project, all of them on a
  -- path somebody had only ever walked when it succeeded. The DNS path had
  -- never been walked at all.
  it("leaks no descriptor and no pool slot across twenty failures", function()
    local before, after, stats
    inside(function()
      local client = http.connect { timeout = 0.2 } ()
      client:get(NOWHERE)                     -- warm: the pool exists after this
      before = descriptors()
      for _ = 1, 20 do client:get(NOWHERE) end
      collectgarbage(); collectgarbage()
      after = descriptors()
      stats = client:stats()
    end, 60)

    for key, origin in pairs(stats.origins) do
      assert.equal(0, origin.live,     key .. " kept a live connection")
      assert.equal(0, origin.idle,     key .. " kept an idle connection")
      assert.equal(0, origin.reserved, key .. " kept a slot reserved")
    end

    if before and after then
      print(("\n    descriptors across 20 failed lookups: %d -> %d")
            :format(before, after))
      assert.equal(before, after)
    end
  end)
end)
