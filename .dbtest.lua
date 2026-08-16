local db   = require "akkar.db"
local json = require "akkar.json"
local cq   = require "cqueues"

local loop = cq.new()
loop:wrap(function()
  local acquire = db.connect {
    host = os.getenv "PGHOST", port = 5432,
    database = "akkar", user = "postgres", password = "akkar",
  }
  local handle = acquire()
  local ok, err = pcall(function()
    local row = handle:one("select 1 as n, $1::text as who", "akkar")
    print("ROW:", json.encode(row))
  end)
  if not ok then print("ERROR:", err) end
end)
print("loop:", loop:loop())
