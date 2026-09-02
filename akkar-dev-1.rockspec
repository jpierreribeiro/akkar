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
  "luaossl >= 20250929, < 20300000",

  -- WHAT `akkar/vendor/http/` NEEDS, DECLARED RATHER THAN INHERITED.
  --
  -- The HTTP/1.1 half of lua-http is vendored into this tree, and it brings
  -- its own dependencies with it. Until this block existed they arrived by
  -- accident: `http >= 0.4` was still declared, so LuaRocks pulled these five
  -- in transitively and `luarocks install akkar` worked -- right up until
  -- somebody acted on the obvious thought, "we vendor http, so drop the
  -- dependency". That would have been a correct-looking edit that broke every
  -- fresh install, and nothing here would have said why.
  --
  -- Each one is load-bearing, and the file that needs it is named:
  "basexx >= 0.4.0, < 1.0",          -- request.lua, Basic auth
  "binaryheap >= 0.4, < 1.0",        -- cookie.lua and hsts.lua, expiry
  "fifo >= 0.2, < 1.0",              -- h1_connection.lua, pipelining
  "lpeg >= 1.0.0, < 2.0",            -- util.lua, h1_stream.lua, request.lua
  "lpeg_patterns >= 0.5, < 1.0",     -- the same three, header grammars
  -- NOT `zlib`: `h1_stream.lua` reaches for it through pcall and runs
  -- without it, so a hard bound here would make a Content-Encoding this
  -- runtime never requires into an install-time requirement.

  -- Serialization.  Reached through `akkar.json`, never required directly.
  "lua-cjson >= 2.1.0, < 3.0",

  -- Postgres adapter.
  "pgmoon >= 1.18.0, < 2.0",

  -- pgmoon requires the `mime` module (from luasocket) without declaring it
  -- in its own rockspec.  Without this line a clean install dies with a
  -- `require` traceback.  See docs/substrate/RESULT.md, finding 2.
  "luasocket >= 3.1.0, < 4.0",
}

-- `http` IS STILL HERE, AND ONLY HERE. akkar no longer requires upstream
-- lua-http at runtime -- it carries its own copy. The specs require it as an
-- INDEPENDENT CLIENT: `spec/framing_spec.lua` and `spec/fuzz_spec.lua` speak
-- to our server with somebody else's implementation, so a framing bug that is
-- symmetric between our reader and our writer cannot pass its own tests.
-- Testing a vendored parser with the vendored parser proves nothing.
test_dependencies = {
  "busted >= 2.3.0",
  "http >= 0.4, < 1.0",
}

test = {
  type = "busted",
}

build = {
  type = "builtin",
  modules = {
    ["akkar"]    = "akkar/init.lua",
    ["akkar.auth"] = "akkar/auth.lua",
    -- Bitwise operations and integer division, spelled as functions so the
    -- nine files that use them parse under LuaJIT, where `&`, `|`, `~`, `<<`,
    -- `>>` and `//` are syntax errors rather than missing functions. See
    -- `docs/substrate/LUAJIT.md`.
    ["akkar.bitwise"] = "akkar/bitwise.lua",
    ["akkar.random"]  = "akkar/random.lua",

    -- String work whose cost must not grow with attacker-controlled input.
    -- `^%s*(.-)%s*$` cost 515 us on a 10 KB header against 2 us here; every
    -- caller trims something a client sent.
    ["akkar.text"] = "akkar/text.lua",
    ["akkar.build"] = "akkar/build.lua",
    ["akkar.db"] = "akkar/db.lua",
    ["akkar.db.memory"] = "akkar/db/memory.lua",
    ["akkar.cache.memory"] = "akkar/cache/memory.lua",
    ["akkar.jobs"] = "akkar/jobs.lua",
    ["akkar.jobs.redis"] = "akkar/jobs/redis.lua",
    ["akkar.jobs.memory"] = "akkar/jobs/memory.lua",
    ["akkar.cache_remember"] = "akkar/cache_remember.lua",
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
    -- not use Postgres. It is built by `src/build.sh` and required only by
    -- this module, which nothing else requires yet -- `akkar/db.lua` still
    -- goes through pgmoon. See `bench/driver/RESULTS.md` for why that wiring
    -- is a separate decision.
    ["akkar.pq"] = "akkar/pq.lua",
    ["akkar.redis"] = "akkar/redis.lua",
    ["akkar.sql"] = "akkar/sql.lua",
    ["akkar.static"] = "akkar/static.lua",
    ["akkar.storage"] = "akkar/storage.lua",
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
    ["akkar.errno"] = "akkar/errno.lua",
    ["akkar.execution"] = "akkar/execution.lua",
    ["akkar.websocket"] = "akkar/websocket.lua",
    ["akkar.vendor.http.bit"] = "akkar/vendor/http/bit.lua",
    ["akkar.vendor.http.client"] = "akkar/vendor/http/client.lua",
    ["akkar.vendor.http.connection_common"] = "akkar/vendor/http/connection_common.lua",
    ["akkar.vendor.http.cookie"] = "akkar/vendor/http/cookie.lua",
    ["akkar.vendor.http.h1_connection"] = "akkar/vendor/http/h1_connection.lua",
    ["akkar.vendor.http.h1_reason_phrases"] = "akkar/vendor/http/h1_reason_phrases.lua",
    ["akkar.vendor.http.h1_stream"] = "akkar/vendor/http/h1_stream.lua",
    ["akkar.vendor.http.h2_connection"] = "akkar/vendor/http/h2_connection.lua",
    ["akkar.vendor.http.h2_error"] = "akkar/vendor/http/h2_error.lua",
    ["akkar.vendor.http.h2_stream"] = "akkar/vendor/http/h2_stream.lua",
    ["akkar.vendor.http.headers"] = "akkar/vendor/http/headers.lua",
    ["akkar.vendor.http.hpack"] = "akkar/vendor/http/hpack.lua",
    ["akkar.vendor.http.hsts"] = "akkar/vendor/http/hsts.lua",
    ["akkar.vendor.http.proxies"] = "akkar/vendor/http/proxies.lua",
    ["akkar.vendor.http.request"] = "akkar/vendor/http/request.lua",
    ["akkar.vendor.http.server"] = "akkar/vendor/http/server.lua",
    ["akkar.vendor.http.stream_common"] = "akkar/vendor/http/stream_common.lua",
    ["akkar.vendor.http.tls"] = "akkar/vendor/http/tls.lua",
    ["akkar.vendor.http.util"] = "akkar/vendor/http/util.lua",
    ["akkar.vendor.http.version"] = "akkar/vendor/http/version.lua",
    ["akkar.vendor.http.websocket"] = "akkar/vendor/http/websocket.lua",
    ["akkar.vendor.http.zlib"] = "akkar/vendor/http/zlib.lua",
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
