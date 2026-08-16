-- A lua-http server with no akkar in it at all. If this wedges too, the
-- defect is in the substrate and akkar can only work around it.
io.stdout:setvbuf "no"
io.stderr:setvbuf "no"

local server  = require "http.server"
local headers = require "http.headers"

local s = assert(server.listen {
  host = "127.0.0.1",
  port = tonumber(arg[1]),
  onstream = function(_, stream)
    local ok, err = pcall(function()
      local h = assert(stream:get_headers())
      local rh = headers.new()
      rh:append(":status", "200")
      rh:append("content-length", "2")
      stream:write_headers(rh, false)
      stream:write_chunk("ok", true)
    end)
    if not ok then io.stderr:write("onstream error: " .. tostring(err) .. "\n") end
    pcall(function() stream:shutdown() end)
  end,
  onerror = function(_, _, op, e)
    io.stderr:write("server onerror: " .. tostring(op) .. " " .. tostring(e) .. "\n")
  end,
})

io.stderr:write("bare lua-http listening\n")
local ok, err = pcall(function() return s:loop() end)
io.stderr:write("LOOP EXITED ok=" .. tostring(ok) .. " err=" .. tostring(err) .. "\n")
