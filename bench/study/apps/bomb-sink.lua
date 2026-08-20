package.path = "./?.lua;./?/init.lua;" .. package.path
local akkar = require "akkar"
local app = akkar.new()
-- A POST that actually READS the body, or the server never decompresses it.
app:post("/sink", function(req)
  return { got = #(req.raw_body or "") }
end)
app:run { port = 18090, check_capabilities = false, body_limit = 1024 * 1024,
          log = akkar.log.new { level = "error", sink = function() end } }
