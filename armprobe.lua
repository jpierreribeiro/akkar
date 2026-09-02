-- Diagnostic probe (branch-only, never merged).
-- Replays exactly what spec/abandoned_spec.lua does at FILE LOAD TIME, with a
-- marker printed before each step, so a segfault names the last marker reached.
package.path = "./?.lua;./?/init.lua;" .. package.path

local function mark(s)
  io.stderr:write("PROBE: " .. s .. "\n")
  io.stderr:flush()
end

mark("start")

local which = os.getenv("PROBE") or "all"

mark("require cqueues")
local cqueues = require "cqueues"
mark("cqueues " .. tostring(cqueues.VERSION))

if which == "all" or which == "akkar" then
  mark("require akkar")
  local _ = require "akkar"
  mark("required akkar")
end

mark("require akkar.db")
local db = require "akkar.db"
mark("require akkar.redis")
local redis = require "akkar.redis"
mark("modules loaded")

local PG = { host = "127.0.0.1", port = 55432, database = "akkar",
             user = "postgres", password = "akkar" }

if which == "all" or which == "pg" then
  mark("pg: build factory")
  local factory = db.connect { host = PG.host, port = PG.port,
    database = PG.database, user = PG.user, password = PG.password, pool_size = 0 }
  mark("pg: factory built, type=" .. type(factory))
  mark("pg: pcall(factory)")
  local ok, conn = pcall(factory)
  mark("pg: pcall returned ok=" .. tostring(ok) .. " conn=" .. tostring(conn))
  if ok then
    mark("pg: close")
    conn:close()
    mark("pg: closed")
  end
  mark("pg: done")
end

if which == "all" or which == "redis" then
  mark("redis: build factory")
  local factory = redis.connect { pool_size = 0 }
  mark("redis: factory built, type=" .. type(factory))
  mark("redis: pcall(factory)")
  local ok, conn = pcall(factory)
  mark("redis: pcall returned ok=" .. tostring(ok) .. " conn=" .. tostring(conn))
  if ok then
    mark("redis: ping")
    local alive, why = pcall(function() return conn:ping() end)
    mark("redis: ping returned alive=" .. tostring(alive) .. " why=" .. tostring(why))
    mark("redis: close")
    conn:close()
    mark("redis: closed")
  end
  mark("redis: done")
end

mark("collectgarbage")
collectgarbage()
collectgarbage()
mark("survived gc")

mark("END OK")
