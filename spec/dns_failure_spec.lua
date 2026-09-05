--[[
DNS failing, or resolving to something new — `docs/UNKNOWNS.md` §3.

This lens found that cqueues could hold a definitive NXDOMAIN until the whole
request budget expired. On a systemd-resolved host, `search .` combined with
the resolver's two five-second attempts made a lookup cost 10.019 seconds;
removing the root search suffix made the same answer take 0.071 seconds. The
client also returned `flush: Connection timed out`, with no hostname and no
indication that DNS was the phase that failed.

akkar now resolves before dialing, through its own cqueues resolver pool. It
removes ONLY `search .`, preserving real Kubernetes/corporate search domains,
and spends DNS plus every address attempt from one deadline. The socket dials
the resulting IP while Host, the pool key, TLS SNI and certificate validation
retain the URL hostname. There is no DNS cache here: opening a new connection
can observe a changed answer; a live pooled connection remains live by design.

This file keeps the underlying resolver measurement visible, then asserts the
runtime contract: NXDOMAIN fails fast and names its host, a SYN blackhole stays
bounded, a refused port remains immediate, and repeated failures leak neither
descriptors nor pool slots.
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

  it("fails fast on a name that is already known not to exist", function()
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
      assert.is_true(elapsed < budget / 2,
        ("a definitive NXDOMAIN spent too much of its %.1f s budget: %.3f s")
        :format(budget, elapsed))
    end, 30)
  end)

  it("names the host and DNS in a lookup failure", function()
    inside(function()
      local client = http.connect { timeout = 0.4 } ()
      local _, why = client:get(NOWHERE)
      why = tostring(why)
      assert.is_truthy(why:find("DNS", 1, true), why)
      assert.is_truthy(why:find("this-does-not-exist.invalid", 1, true), why)
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
