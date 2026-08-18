--[[
A server in a process of its own, for `spec/socket_buffer_spec.lua`.

It exists because the first version of that measurement ran inside busted and
answered ZERO bytes per connection for both buffer sizes. Not a wrong number --
no number: by the time the case runs, the busted process has a heap with room
to spare, so three hundred more sockets fit in pages it already owns and VmRSS
does not move. An instrument that cannot see the effect it is measuring reports
"no difference", which is indistinguishable from a regression.

So the server gets its own process, whose resident memory starts small and
grows only because of what this test does to it.

    AKKAR_PORT    where to listen
    AKKAR_BUFSIZ  passed straight to `app:run { socket_buffer = ... }`,
                  or the string "false" for cqueues' own default
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"

local port = assert(tonumber(os.getenv "AKKAR_PORT"), "AKKAR_PORT is required")
local raw  = os.getenv "AKKAR_BUFSIZ"
local buffer
if raw == "false" then buffer = false else buffer = tonumber(raw) end

local app = akkar.new()
app:get("/ping", function() return { pong = true } end)

app:run {
  port = port,
  socket_buffer = buffer,
  check_capabilities = false,
  log = akkar.log.new { level = "error", sink = function() end },
}
