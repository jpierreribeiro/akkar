--[[
An akkar application shaped for a PaaS — Railway specifically, but nothing
here is Railway-only. It is the entry file `akkar build` compiles into a
binary, and `docs/DEPLOY.md` is the prose around it.

Three things in this file are the whole reason it exists, and all three are
mistakes that a working localhost app makes silently:

  1. THE PORT IS THE PLATFORM'S TO CHOOSE. akkar defaults to 8080, which is
     also the value Railway injects, so a hard-coded 8080 appears to work
     right up until the platform picks something else. Reading `PORT` costs
     one line and removes a class of "application failed to respond".

  2. THE HOST MUST BE 0.0.0.0. `akkar/init.lua` defaults to 127.0.0.1 --
     correct for a laptop, and the single most common way a container passes
     every local test and answers nothing in production. The edge proxy
     connects from outside the container's loopback; a listener on 127.0.0.1
     is invisible to it. Verified in this repository's own container run: the
     first image built from this file bound to loopback and `curl` from the
     host got a connection reset with the process demonstrably running.

  3. LIVENESS AND READINESS ARE DIFFERENT ENDPOINTS. `akkar/health.lua`
     argues this at length and the argument is not repeated here. The short
     version: a liveness probe that touches the database turns one slow
     database into every instance being killed at once.

Run it three ways, all of which work:

    lua5.4 examples/railway.lua            # from a source checkout
    ./myapp                                # compiled in by `akkar build`
    ./myapp run examples/railway.lua       # hosted by the binary
]]

local akkar  = require "akkar"
local health = require "akkar.health"

local app = akkar.new()

-- `PORT` is a string when it is set at all, and `tonumber` on a missing
-- variable is nil rather than an error, so the `or` supplies the default.
-- 8080 matches both akkar's own default and what Railway injects, which
-- makes the local run and the deployed run agree.
local port = tonumber(os.getenv "PORT") or 8080

-- 0.0.0.0 unless told otherwise, which is the inverse of akkar's own default
-- and deliberately so: this file's job is to be deployed. Keeping the
-- override means `HOST=127.0.0.1 lua5.4 examples/railway.lua` still gives a
-- laptop the tighter binding.
local host = os.getenv "HOST" or "0.0.0.0"

-- ============================================================ the probes
--
-- No checks are registered here because this example has no dependencies to
-- check. Adding one is the commented line, and the shape matters: a check
-- returns true to pass, or false/nil plus a reason to fail.
local probe = health.new {
  checks = {
    -- db = function() return db:one "select 1" ~= nil end,
  },
  timeout = 2,    -- per check, seconds
  cache   = 5,    -- seconds a result is reused, failures included
}

--- Liveness. Touches nothing, by construction -- see `akkar/health.lua`.
--- Point the platform's restart policy at this one.
app:get("/health/live", function()
  return probe:live()
end)

--- Readiness. Answers 503 when a dependency is down, which is what takes an
--- instance out of the load balancer WITHOUT restarting it. With no checks
--- registered it always passes, and that is honest rather than useful: it
--- becomes useful when the checks table above is not empty.
app:get("/health/ready", function()
  local result = probe:ready()
  if result.status == "fail" then error(akkar.unavailable(result)) end
  return result
end)

app:get("/", function()
  return { service = "akkar", ok = true }
end)

--- Enough of a real route to prove routing and parameter validation survived
--- the build. `/echo/abc` answers 422, which is akkar doing the validation,
--- not this handler.
app:get("/echo/:n", { params = { n = "integer" } }, function(req)
  return { n = req.params.n }
end)

-- `akkar build` embeds this file and runs it, so the app must actually start
-- here rather than only be returned. `bin/akkar doctor app.lua` wants the
-- return value instead, hence both.
--
-- The guard: `akkar doctor` loads this file to inspect it and must NOT end up
-- serving. It sets no PORT of its own, so keying on something else -- an
-- explicit opt-out -- is the reliable signal.
if os.getenv "AKKAR_NO_SERVE" ~= "1" then
  -- SIGTERM IS HOW A PaaS STOPS YOU, and akkar does not install the handler
  -- on its own -- `akkar/init.lua` explains that a library installing signal
  -- handlers behind an application's back fights with whatever else the
  -- process is doing. Correct as a default, and wrong to leave out here:
  -- without this line a deploy kills in-flight requests instead of draining
  -- them, and PID 1 in a container gets no default SIGTERM action either.
  --
  -- Railway's own reference is blunt about the budget: the old deployment
  -- "is sent a SIGTERM signal. By default, it is given 0 seconds to
  -- gracefully shutdown before being forcefully stopped with a SIGKILL." So
  -- this handler only helps if the platform is also told to wait --
  -- `drainingSeconds` in `railway.json`. Both halves, or neither works.
  app:handle_signals()

  app:run {
    host = host,
    port = port,

    -- SO_REUSEPORT is how akkar uses more than one core: one Lua VM is one
    -- core, so capacity is processes sharing a port. Harmless with one
    -- process, and it is the difference between the second process starting
    -- and dying with EADDRINUSE.
    reuseport = true,

    -- akkar's own default, written out because it is one half of a pair: it
    -- must be LESS than the platform's kill deadline, or the drain is
    -- interrupted by SIGKILL and the grace was decorative. With Railway's
    -- `drainingSeconds` set to 15, ten seconds here leaves margin.
    shutdown_grace = 10,
  }
end

return app, { host = host, port = port }
