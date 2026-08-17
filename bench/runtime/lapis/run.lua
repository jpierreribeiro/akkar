--[[
Launches the Lapis app on lua-http/cqueues.

Deliberately NOT `lapis serve`. The CLI brings its own config discovery,
environment handling and process supervision, and any of that would end up
inside the measured number. This does what `lapis.cqueues` does and nothing
else: build a lua-http server, hand each stream to `dispatch`, loop.

`dispatch(app, server, stream)` is a lua-http `onstream` handler — the same
shape akkar's own server installs. So on this box the two candidates are
running the same cqueues build, the same lua-http, listening the same way,
with `reuseport` on both. What differs between the numbers is the framework,
which is the entire reason Lapis is in this comparison.
]]

local http_server = require "http.server"
local lapis_cq    = require "lapis.cqueues"
local config      = require "lapis.config"

-- Postgres reachable at the same place every other candidate uses. Set before
-- the app is required, because `lapis.db` reads it at load.
config("development", {
  postgres = { host = "127.0.0.1:55432", user = "postgres",
               password = "akkar", database = "akkar" },
})

local port = tonumber(arg[1]) or 8413

-- `lapis.Application()` returns a CLASS. `dispatch` wants an instance, and
-- handing it the class produces `attempt to index a nil value (field
-- 'router')` from inside lapis rather than anything that names the mistake.
-- Instantiating is what `lapis serve` does before it ever reaches dispatch.
local app = require "lapis-serve"
if type(app) == "table" and app.__base then app = app() end
if app.build_router and not app.router then app:build_router() end

local server = assert(http_server.listen {
  host      = "0.0.0.0",
  port      = port,
  reuseport = true,
  onstream  = function(srv, stream)
    -- pcall so one bad request cannot take the process down mid-run and turn
    -- a throughput number into a story about a crash.
    local ok, err = pcall(lapis_cq.dispatch, app, srv, stream)
    if not ok then io.stderr:write("lapis dispatch error: " .. tostring(err) .. "\n") end
    stream:shutdown()
  end,
  onerror = function() end,
})

io.stderr:write("lapis listening on " .. port .. "\n")
assert(server:loop())
