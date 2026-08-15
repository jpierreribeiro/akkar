rockspec_format = "3.0"
package = "akkar"
version = "dev-1"

source = {
  url = "git+https://github.com/jpierreribeiro/akkar.git",
}

description = {
  summary  = "A microframework for JSON APIs in Lua 5.4",
  detailed = [[
    akkar is a microframework for JSON APIs on cqueues and lua-http.

    Handlers return the response instead of mutating a context, which makes
    writing the response twice structurally impossible.  All I/O goes through
    adapters the framework owns, never through a library called directly from
    a handler.  A watchdog warns when a handler blocks the event loop without
    yielding.
  ]],
  homepage = "https://github.com/jpierreribeiro/akkar",
  license  = "MIT",
}

dependencies = {
  "lua >= 5.4, < 5.5",

  -- Server, event loop and TLS.
  "cqueues >= 20200726",
  "http >= 0.4",
  "luaossl >= 20250929",

  -- Serialization.
  "lua-cjson >= 2.1.0",

  -- Postgres adapter.
  "pgmoon >= 1.18.0",

  -- pgmoon requires the `mime` module (from luasocket) without declaring it
  -- in its own rockspec.  Without this line a clean install dies with a
  -- `require` traceback.  See docs/substrate/RESULT.md, finding 2.
  "luasocket >= 3.1.0",
}

test_dependencies = {
  "busted >= 2.3.0",
}

test = {
  type = "busted",
}

build = {
  type = "builtin",
  modules = {
    ["akkar"]    = "akkar/init.lua",
    ["akkar.db"] = "akkar/db.lua",
    ["akkar.db.memory"] = "akkar/db/memory.lua",
    ["akkar.cache.memory"] = "akkar/cache/memory.lua",
    ["akkar.log"] = "akkar/log.lua",
    ["akkar.metrics"] = "akkar/metrics.lua",
    ["akkar.multipart"] = "akkar/multipart.lua",
    ["akkar.pool"] = "akkar/pool.lua",
    ["akkar.redis"] = "akkar/redis.lua",
    ["akkar.strict"] = "akkar/strict.lua",
    ["akkar.work"] = "akkar/work.lua",
    ["akkar.openapi"] = "akkar/openapi.lua",
  },
  copy_directories = { "docs", "examples", "bench", "types" },
}
