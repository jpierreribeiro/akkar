local db      = require "akkar.db"
local migrate = require "akkar.migrate"
local json    = require "akkar.json"
local cq      = require "cqueues"

local loop = cq.new()
loop:wrap(function()
  local acquire = db.connect {
    host = os.getenv "PGHOST", port = 5432,
    database = "akkar", user = "postgres", password = "akkar",
    pool_size = 0,
  }
  local handle = acquire()
  local runner = migrate.new(handle, { dir = os.getenv "MIGRATIONS" or "/migrations" })

  print("pending:", json.encode(runner:pending()))
  local ok, applied = pcall(function() return runner:apply() end)
  if not ok then print("ERROR:", applied) return end
  print("applied this run:", #applied)
  for _, name in ipairs(applied) do print("  ", name) end
  print("ledger:", json.encode(runner:applied()))
  print("columns:", json.encode(
    handle:many("select column_name from information_schema.columns " ..
                "where table_name = 'widgets' order by 1")))
end)
print("loop:", loop:loop())
