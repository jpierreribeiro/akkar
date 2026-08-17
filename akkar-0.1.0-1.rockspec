rockspec_format = "3.0"
package = "akkar"
version = "0.1.0-1"

-- A RELEASE PINS A TAG. The development rockspec tracks the branch, which is
-- what you want while writing akkar and exactly what you do not want while
-- installing it: `luarocks install` from a moving branch gives two people
-- different code under the same version number.
source = {
  url = "git+https://github.com/jpierreribeiro/akkar.git",
  tag = "v0.1.0",
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
    ["akkar.auth"] = "akkar/auth.lua",
    ["akkar.build"] = "akkar/build.lua",
    ["akkar.db"] = "akkar/db.lua",
    ["akkar.db.memory"] = "akkar/db/memory.lua",
    ["akkar.cache.memory"] = "akkar/cache/memory.lua",
    ["akkar.jobs"] = "akkar/jobs.lua",
    ["akkar.jobs.redis"] = "akkar/jobs/redis.lua",
    ["akkar.jobs.memory"] = "akkar/jobs/memory.lua",
    ["akkar.compress"] = "akkar/compress.lua",
    ["akkar.config"] = "akkar/config.lua",
    ["akkar.crypto"] = "akkar/crypto.lua",
    ["akkar.csrf"] = "akkar/csrf.lua",
    ["akkar.health"] = "akkar/health.lua",
    ["akkar.http"] = "akkar/http.lua",
    ["akkar.json"] = "akkar/json.lua",
    ["akkar.jwt"] = "akkar/jwt.lua",
    ["akkar.log"] = "akkar/log.lua",
    ["akkar.metrics"] = "akkar/metrics.lua",
    ["akkar.migrate"] = "akkar/migrate.lua",
    ["akkar.multipart"] = "akkar/multipart.lua",
    ["akkar.pool"] = "akkar/pool.lua",

    -- The Lua half of the Postgres driver. Its C half, `akkar.pq_native`, is
    -- DELIBERATELY NOT HERE: declaring it would make libpq a hard dependency
    -- of `luarocks install akkar` and break the install for everyone who does
    -- not use Postgres. It ships as its own rock instead --
    -- `akkar-pq-0.1.0-1.rockspec` -- so `db.connect { driver = "pq" }` is an
    -- option an installed copy of akkar can actually satisfy.
    --
    -- `akkar/db.lua` IS wired to it and has been since the driver landed; the
    -- sentence that used to sit here saying otherwise was true for about a day.
    -- What remains true is that pgmoon is the DEFAULT, and
    -- `bench/driver/RESULTS.md` §5.4 has the measured reason.
    ["akkar.pq"] = "akkar/pq.lua",
    ["akkar.redis"] = "akkar/redis.lua",
    ["akkar.sql"] = "akkar/sql.lua",
    ["akkar.static"] = "akkar/static.lua",
    ["akkar.storage"] = "akkar/storage.lua",
    ["akkar.substrate"] = "akkar/substrate.lua",
    ["akkar.scope"] = "akkar/scope.lua",
    ["akkar.session"] = "akkar/session.lua",
    ["akkar.time"] = "akkar/time.lua",
    ["akkar.trace"] = "akkar/trace.lua",
    ["akkar.vm"] = "akkar/vm.lua",
    ["akkar.watch"] = "akkar/watch.lua",
    ["akkar.doctor"] = "akkar/doctor.lua",
    ["akkar.limit"] = "akkar/limit.lua",
    ["akkar.idempotency"] = "akkar/idempotency.lua",
    ["akkar.email"] = "akkar/email.lua",
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
