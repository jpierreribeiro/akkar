--[[
akkar.substrate — the defects akkar repairs in the libraries underneath it.

## Why this module exists at all

Every other module here treats the substrate as replaceable and leaves it
alone; `spec/substrate_spec.lua` states what akkar requires and stops there.
This one reaches in and changes lua-http's behaviour, which is a thing to do
reluctantly and never silently. It exists because of one defect that cannot be
worked around from outside and cannot be waited out:

  **One malformed header stops a lua-http server accepting connections, for
  ever, while the listening socket stays open.**

`docs/substrate/lua-http-wedge.md` has the reproduction -- 25 lines, no akkar
in them. A single `Content-Length: banana` costs an attacker one request and
costs the server everything. There is no volume, no timing and no
authentication involved.

Reporting it upstream is not a fix available to us: lua-http's last commit is
September 2024. So the choice is to carry the repair or to ship a server that
one header can take down, and between those two this is not a close call.

## The mechanism, measured rather than guessed

`http/h1_stream.lua`, and each of these was read off a running process:

  * `stream:shutdown()` ends by draining whatever is left of the request so
    the connection can be reused (line 190): it loops while the stream is
    open and `step(0)` keeps returning true.
  * `step` takes the read branch when `body_read_left ~= 0` (line 224) -- and
    an invalid `Content-Length` leaves that field **nil**, which is not zero.
  * `read_next_chunk(0)` answers `nil, nil, nil`: nothing to read, no error.
    `step` reads that as success and returns **true** (line 228).
  * So `stats_recv` never advances, the state never changes, and the loop
    spins. Not blocked -- SPINNING: measured at `voluntary_ctxt_switches`
    frozen at 1 while the process burned CPU continuously, and confirmed at
    50,000 `step` calls with `state="half closed (local)"`,
    `body_read_left=nil`, `stats_recv=0`.

That last point is why the wedge is so quiet. One coroutine that never yields
starves the whole cqueues controller, so the accept loop stops running without
ever stopping: `server:loop()` does not return, no error is raised, no `pcall`
fires, and the kernel holds the listening socket open with connections queued
behind it. Every health check that asks "is the port open" says yes.

`docs/substrate/lua-http-wedge.md` said the accept loop had stopped. It had
not; it was starved. The distinction is the whole reason a fix is possible.

## The repair, and why it is this one

Two obvious repairs do not work, and both were tried:

  * Setting `body_read_left = 0` skips the read branch -- and `step` then
    falls through to the unconditional `return true` at the end of the
    function. The loop spins in the same place for a different reason.
  * Answering 400 before the stream shuts down (akkar already does, and it is
    a better answer than the 503 lua-http produces on its own) does not help
    either: the bare server in the reproduction catches the raise too, and
    still wedges.

What is actually wrong is that `step` reports progress where progress is
impossible, and the drain loop trusts it as its only stopping condition. So
the repair is to make the drain REQUIRE progress: during `shutdown`, and only
during `shutdown`, `step` must show that `stats_recv` moved or it is treated
as finished.

Breaking out of that loop early is safe by construction. The drain is
best-effort -- lua-http's own comment calls it "read any remaining available
response and get out of the way" -- and `shutdown` closes the socket
immediately afterwards when the stream did not reach a closed state. Ending it
early means the connection is not reused, which for a request whose framing
cannot be parsed is the correct outcome anyway.

It is installed per stream instance for the duration of one `shutdown` call,
so nothing else in lua-http observes a modified `step`, and a stream that
drains normally is unaffected: it makes progress and the guard never fires.
]]

local M = {}

-- How many consecutive fruitless `step` calls to tolerate before calling the
-- drain finished. One would do -- the wedge produces them without limit -- but
-- a healthy stream can legitimately answer "nothing available right now" once
-- or twice against a slow peer, and the cost of being generous here is a few
-- microseconds on a path that is already tearing a connection down.
local IDLE_STEPS_ALLOWED = 8

M.applied = {}

-- COUNTED, NOT SILENT. Swallowing an error is the right call here and it is
-- still an error; a repair that leaves no trace is indistinguishable from a
-- repair that is no longer needed. `akkar.substrate.rescued` is how a test
-- asserts the rescue fired, and how anyone reading a running process can tell
-- that malformed framing is arriving at all.
M.rescued = 0

--- Repairs the wedge described above. Idempotent; safe to call at any time.
---
--- Returns true if the patch is in place, or false plus a reason when
--- lua-http is absent or is not shaped the way this repair expects -- a
--- version that has fixed the defect itself, most hopefully.
function M.fix_h1_shutdown_spin()
  if M.applied.h1_shutdown_spin then return true end

  local ok, h1_stream = pcall(require, "http.h1_stream")
  if not ok then return false, "http.h1_stream is not installed" end

  local methods = h1_stream.methods
  if type(methods) ~= "table"
    or type(methods.shutdown) ~= "function"
    or type(methods.step) ~= "function" then
    -- Refusing to patch a shape we do not recognise, rather than patching it
    -- anyway and finding out in production. A substrate that has moved on is
    -- the good outcome here.
    return false, "http.h1_stream does not have the expected shutdown/step"
  end

  local original_shutdown = methods.shutdown
  local original_step     = methods.step

  -- ONE guard function, built once when the patch is installed.
  --
  -- It used to be a closure built inside `shutdown`, which meant a closure, a
  -- hash insert and a `table.pack` table allocated on EVERY stream -- and in
  -- HTTP/1.1 keep-alive a stream is a request. Measured on the study machine
  -- it cost **4.1% of /ping throughput**, 20,208 req/s against 19,383, which
  -- is a real price for a guard that matters only when a drain is possible.
  --
  -- The state moves onto the stream so the function can be shared. Two field
  -- writes are cheaper than allocating a closure with two upvalues, and they
  -- are namespaced because this module is a guest in somebody else's table.
  local function guarded_step(stream, timeout)
    local advanced, err, errno = original_step(stream, timeout)
    if not advanced then return advanced, err, errno end

    local recv = stream.stats_recv or 0
    if recv > stream.akkar_drain_recv then
      stream.akkar_drain_recv, stream.akkar_drain_idle = recv, 0
    else
      local idle = stream.akkar_drain_idle + 1
      stream.akkar_drain_idle = idle
      if idle > IDLE_STEPS_ALLOWED then
        -- "No progress is possible" reported as "done", which is what the
        -- drain loop is asking about and what `step` failed to answer.
        return false
      end
    end
    return advanced, err, errno
  end

  methods.shutdown = function(self, ...)
    -- The guard lives on the INSTANCE, so it shadows the metatable method for
    -- this stream only and only until this call returns.
    self.akkar_drain_recv = self.stats_recv or 0
    self.akkar_drain_idle = 0
    rawset(self, "step", guarded_step)

    -- `pcall` so the instance override is always removed, even if shutdown
    -- raises. A stream left carrying a patched `step` would be a leak of this
    -- module into code that never asked for it.
    --
    -- Three return values rather than `table.pack`, which allocated a table
    -- per request to carry what lua-http documents as `true` or `nil, err,
    -- errno`. The shape check above is what makes that safe to assume; if a
    -- future lua-http returns more, the check is where it should be caught.
    local ok, a, b, c = pcall(original_shutdown, self, ...)
    rawset(self, "step", nil)
    if ok then return a, b, c end
    -- `a` is the error pcall caught. Everything below runs only here, on the
    -- rescue path, so nothing it costs is paid by a healthy request.

    -- THE SECOND FAILURE MODE, and it is not the same one.
    --
    -- `Content-Length: -5` parses to `body_read_left = -5` with a body type of
    -- "length", and `read_next_chunk` answers that with a bare
    -- `error("invalid length: -5")` (h1_stream.lua:869). It is not a spin --
    -- it is a raise, and it travels: `handle_stream` in `http/server.lua`
    -- calls `stream:shutdown()` with no pcall around it, so the error leaves
    -- the coroutine, `cq:loop()` returns it, and `server:loop()` returns.
    -- The process EXITS and the port closes.
    --
    -- Measured, because the writeup got this wrong and said `-5` "does the
    -- same" as `banana`: it does not. Against the bare unpatched server, the
    -- malformed request is answered 200 and the server is dead a moment
    -- later. Louder than the wedge and easier to survive -- a supervisor
    -- restarts it, and a health check sees a closed port rather than an open
    -- one -- but still a denial of service costing one request.
    --
    -- Swallowing an error is defensible in exactly this place: lua-http calls
    -- this method without a pcall, so lua-http already treats it as a method
    -- that does not throw. Where it throws anyway, the contract its own
    -- caller assumes is what gets honoured here.
    M.rescued = M.rescued + 1
    M.last_rescued = a

    if self.state ~= "closed" then
      -- The same teardown `shutdown` performs on its own unhappy path, so a
      -- connection is never left open by the rescue.
      pcall(function()
        if self.connection and self.connection.socket then
          self.connection.socket:shutdown()
        end
        self:set_state "closed"
      end)
    end
    return true
  end

  M.applied.h1_shutdown_spin = true
  return true
end

--- Applies every repair, and says what happened.
---
--- Called from `App:run` rather than at require time: importing a module
--- should not mutate a third-party library as a side effect, and a test that
--- wants the unpatched behaviour -- `spec/substrate_spec.lua` has one -- must
--- be able to have it.
--- RETIRED, and reporting that rather than pretending.
---
--- The repair this module existed for now lives in the source of
--- `akkar/vendor/http/h1_stream.lua`, inside the drain loop it protects.
--- Folding it in is most of why lua-http was vendored: sixty lines of
--- instance overrides, `rawset` juggling and defensive shape checks became
--- eight lines in the loop, and they can no longer silently stop applying
--- when upstream changes shape.
---
--- Keeping this as a no-op rather than deleting the file, for two reasons.
--- The header above is the only written account of the wedge and how it was
--- found, and `akkar.doctor` reports what the substrate applied -- a function
--- that vanished would be a harder read than one that says it retired.
---
--- `fix_h1_shutdown_spin` is still callable and still works. It patches the
--- UPSTREAM `http.h1_stream`, which akkar no longer loads, so calling it now
--- repairs a module nothing here uses. That is exactly why `apply` stopped
--- calling it: a repair that reports "applied" while doing nothing for the
--- running server is worse than no repair at all.
function M.apply()
  return {
    h1_shutdown_spin = {
      applied = false,
      reason = "folded into akkar/vendor/http/h1_stream.lua; no patch needed",
    },
  }
end

return M
