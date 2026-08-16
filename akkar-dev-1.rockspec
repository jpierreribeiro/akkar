rockspec_format = "3.0"
package = "akkar"
version = "dev-1"

source = {
  url = "git+https://github.com/jpierreribeiro/akkar.git",
}

description = {
  summary  = "An application runtime for backend services in Lua",
  detailed = [[
    akkar is an application runtime for JSON APIs on cqueues and lua-http:
    routing, validation, database and cache adapters, pooling, jobs, metrics,
    OpenAPI, streaming, idempotency, rate limiting, tenant scope and safe SQL.

    Handlers return the response instead of mutating a context, which makes
    writing the response twice structurally impossible.  All I/O goes through
    adapters the framework owns, never through a library called directly from
    a handler.  A watchdog warns when a handler blocks the event loop without
    yielding.

    The public API never depends on the implementation of the substrate:
    `app:get`, `req.db` and `akkar.stream` are akkar, while cqueues, lua-http,
    pgmoon and the JSON library are replaceable details. `spec/substrate_spec`
    is the executable statement of what a replacement would have to answer.
  ]],
  homepage = "https://github.com/jpierreribeiro/akkar",
  license  = "MIT",
}

-- BOUNDS, NOT WISHES. `docs/PLAN.md` §5 has said "pin versions, commit the
-- rockspec" since the beginning and every bound here was an open `>=`, which
-- is how a dependency that reaches into another library's internals -- as
-- `akkar/db.lua` does with pgmoon's socket -- breaks on a minor release
-- nobody chose to take.
--
-- The upper bounds are deliberately generous: they exclude the next MAJOR of
-- anything, and nothing else. A bound that has to be edited every month
-- teaches people to edit it without reading.
--
-- ONE HONEST GAP, stated rather than hidden. `cqueues 20200726` is the last
-- PUBLISHED rock; upstream master has six years of fixes on top of it,
-- including Lua 5.5 support. CI builds from a pinned commit of master
-- (`.github/workflows/ci.yml`), which LuaRocks cannot express -- so what a
-- `luarocks install` gets and what CI proves are not the same build. That is
-- the strongest single argument for `akkar build`; see `docs/RUNTIME.md`.
dependencies = {
  "lua >= 5.4, < 5.6",

  -- Server, event loop and TLS.
  "cqueues >= 20200726, < 20300000",
  "http >= 0.4, < 1.0",
  "luaossl >= 20250929, < 20300000",

  -- Serialization.  Reached through `akkar.json`, never required directly.
  "lua-cjson >= 2.1.0, < 3.0",

  -- Postgres adapter.
  "pgmoon >= 1.18.0, < 2.0",

  -- pgmoon requires the `mime` module (from luasocket) without declaring it
  -- in its own rockspec.  Without this line a clean install dies with a
  -- `require` traceback.  See docs/substrate/RESULT.md, finding 2.
  "luasocket >= 3.1.0, < 4.0",
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
    ["akkar.build"] = "akkar/build.lua",
    ["akkar.db"] = "akkar/db.lua",
    ["akkar.db.memory"] = "akkar/db/memory.lua",
    ["akkar.cache.memory"] = "akkar/cache/memory.lua",
    ["akkar.jobs"] = "akkar/jobs.lua",
    ["akkar.jobs.redis"] = "akkar/jobs/redis.lua",
    ["akkar.jobs.memory"] = "akkar/jobs/memory.lua",
    ["akkar.json"] = "akkar/json.lua",
    ["akkar.log"] = "akkar/log.lua",
    ["akkar.metrics"] = "akkar/metrics.lua",
    ["akkar.multipart"] = "akkar/multipart.lua",
    ["akkar.pool"] = "akkar/pool.lua",
    ["akkar.redis"] = "akkar/redis.lua",
    ["akkar.sql"] = "akkar/sql.lua",
    ["akkar.scope"] = "akkar/scope.lua",
    ["akkar.time"] = "akkar/time.lua",
    ["akkar.vm"] = "akkar/vm.lua",
    ["akkar.doctor"] = "akkar/doctor.lua",
    ["akkar.limit"] = "akkar/limit.lua",
    ["akkar.idempotency"] = "akkar/idempotency.lua",
    ["akkar.etag"] = "akkar/etag.lua",
    ["akkar.strict"] = "akkar/strict.lua",
    ["akkar.work"] = "akkar/work.lua",
    ["akkar.openapi"] = "akkar/openapi.lua",
  },

  -- The CLI SHIPS. `README.md` documents `akkar doctor` as a shell command
  -- and nothing installed it: there was no `install.bin` and `bin` was not
  -- among the copied directories, so the command existed only for someone
  -- running out of a source checkout with LUA_PATH set by hand. No documented
  -- flow installed the rock at all, which is why nothing ever noticed.
  install = {
    bin = { akkar = "bin/akkar" },
  },

  -- `bench` is gone from here. It is deliberately Linux-only shell that
  -- expects docker, sudo, taskset and a machine reserved for the purpose --
  -- dead weight in an installed rock, and misleading about what akkar needs
  -- to run.
  copy_directories = { "docs", "examples", "types" },
}
