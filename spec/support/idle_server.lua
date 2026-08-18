--[[
A server in a process of its own, for the two specs that have to watch what a
server COSTS rather than what it answers.

It exists because the first version of that measurement ran inside busted and
answered ZERO bytes per connection for both buffer sizes. Not a wrong number --
no number: by the time the case runs, the busted process has a heap with room
to spare, so three hundred more sockets fit in pages it already owns and VmRSS
does not move. An instrument that cannot see the effect it is measuring reports
"no difference", which is indistinguishable from a regression.

So the server gets its own process, whose resident memory and descriptor
count start small and grow only because of what a test does to them. The same
argument applies to descriptors, and `spec/concurrency_spec.lua` uses it for
that: busted holds sockets of its own, and the number that matters is the
DELTA in one process that is doing nothing else.

    AKKAR_PORT    where to listen
    AKKAR_BUFSIZ  passed straight to `app:run { socket_buffer = ... }`,
                  or the string "false" for cqueues' own default
    AKKAR_HOLD    seconds `/hold` sleeps for, default 2

Routes:

    /ping   answers immediately
    /hold   sleeps, so a caller stays IN FLIGHT and whatever a request in
            flight costs is still held when /fds is asked
    /fds    how many descriptors this process holds right now, and the
            ceiling akkar derived for itself
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

local port = assert(tonumber(os.getenv "AKKAR_PORT"), "AKKAR_PORT is required")
local raw  = os.getenv "AKKAR_BUFSIZ"
local buffer
if raw == "false" then buffer = false else buffer = tonumber(raw) end

local hold = tonumber(os.getenv "AKKAR_HOLD") or 2

-- io.open, NOT io.popen, to learn our own pid: popen forks, and /proc/self in
-- the child is the shell. `spec/concurrency_spec.lua` documents that trap for
-- descriptor counting and this is the same one.
local PID do
  local f = assert(io.open "/proc/self/stat")
  PID = f:read("a"):match "^(%d+)"
  f:close()
end

local function fd_count()
  local p = io.popen("ls /proc/" .. PID .. "/fd 2>/dev/null | wc -l")
  local n = tonumber(p:read "l") or 0
  p:close()
  return n
end

local cqueues = require "cqueues"

local app = akkar.new()
app:get("/ping", function() return { pong = true } end)
app:get("/hold", function() cqueues.sleep(hold) return { held = true } end)
app:get("/fds",  function()
  return { fds = fd_count(), max_concurrent = app.max_concurrent }
end)

app:run {
  port = port,
  socket_buffer = buffer,
  check_capabilities = false,
  log = akkar.log.new { level = "error", sink = function() end },
}
