--[[
akkar.doctor — what is actually installed, what is actually configured, and
what will bite.

## Why this exists in Lua specifically

"Which combination of libraries and versions actually works" is a recurring
cost here in a way it is not in Go or Python, and this project paid it three
times before writing any framework code:

- `pgmoon` requires `mime`, from luasocket, **without declaring it**. A clean
  install dies with a `require` traceback naming a module nobody asked for.
- `cqueues` pins `lua == 5.4` exactly and has had no release since 2020.
- `luaossl` builds against OpenSSL 3 with deprecation warnings that look like
  failures and are not.

Every one of those cost an afternoon, and every one is a five-line check once
somebody knows. That is the whole idea: this file is where what we learned the
hard way goes, so the next person reads it in a second.

## The rule this follows

**A doctor that cries wolf gets ignored.** So findings have three levels and
they mean different things:

    fail   broken now.  Exit code 1.  A deploy gate can read this.
    warn   works today, will bite.  Exit code 0.
    ok     checked, fine.  Shown so the absence of a check is visible.

A missing optional dependency is not a failure. An unreachable database when
the app declares one **is**, because the server would refuse to boot anyway.

## Using it

    akkar.doctor.report()                       -- environment only
    akkar.doctor.report(app, { db = ..., })     -- and this app's configuration

    lua -e 'require("akkar.doctor").cli()'      -- prints, exits 0 or 1
    lua -e 'require("akkar.doctor").cli{ json = true }'
]]

local bitwise = require "akkar.bitwise"
local M = {}

-- `akkar` itself is required lazily, in one place, and not at the top of this
-- file: the doctor's job is to run in a tree where something is missing, and
-- a top-level require of the framework would make a broken install fail with
-- a traceback instead of a report naming what is broken.
local function akkar_module() return require "akkar" end

-- ==================================================================== findings
local Report = {}
Report.__index = Report

local function new_report()
  return setmetatable({ findings = {} }, Report)
end

function Report:add(level, area, title, detail, fix)
  self.findings[#self.findings + 1] = {
    level = level, area = area, title = title, detail = detail, fix = fix,
  }
  return self
end

function Report:ok(area, title, detail)   return self:add("ok", area, title, detail) end
function Report:warn(area, title, d, fix) return self:add("warn", area, title, d, fix) end
function Report:fail(area, title, d, fix) return self:add("fail", area, title, d, fix) end

function Report:count(level)
  local n = 0
  for _, f in ipairs(self.findings) do if f.level == level then n = n + 1 end end
  return n
end

function Report:healthy() return self:count "fail" == 0 end

-- ================================================================ environment
--
-- Version numbers come from each module's own declaration where it has one,
-- and are reported as unknown where it does not.  Guessing a version from a
-- rock directory name is how a doctor tells you something false with
-- confidence.
local function module_version(name, mod)
  if type(mod) ~= "table" then return nil end
  for _, field in ipairs { "VERSION", "_VERSION", "version", "_version" } do
    local v = rawget(mod, field)
    if type(v) == "string" or type(v) == "number" then return tostring(v) end
  end
  return nil
end

-- `akkar.vendor.http.server`, NOT `http.server`.
--
-- akkar carries its own HTTP/1.1 half and has not required upstream lua-http
-- at runtime since it was vendored -- `akkar-dev-1.rockspec` says so, and
-- lists `http` under `test_dependencies` alone, because the specs use it as
-- an INDEPENDENT client to check our framing against somebody else's.
--
-- The doctor was the last thing that had not been told. On a clean install
-- from the rockspec it looked for a rock the rockspec deliberately does not
-- pull, reported `FAIL lua-http: the HTTP server is missing`, and exited 1 --
-- so `akkar doctor` failed on every correct installation. CI's `install` job
-- is what finally said it out loud, and it had been saying it for a while.
--
-- Checking the vendored path also makes the check mean something again: it
-- now answers "is the server akkar actually uses loadable", which is the
-- question, rather than "is a rock we no longer use installed".
local REQUIRED = {
  { name = "cqueues",   why = "the event loop" },
  { name = "akkar.vendor.http.server", why = "the HTTP server (vendored)" },
  -- LISTED SEPARATELY BECAUSE IT IS NO LONGER PROVED BY THE LINE ABOVE.
  --
  -- `server.lua` used to require `h2_connection` at the top, so loading the
  -- server parsed the whole h2 half -- `h2_stream`, `hpack`, `h2_error`,
  -- `vendor/http/bit` -- and any syntax or load error in it surfaced right
  -- here. That require is now deferred to `new_server`, for ~19 ms of boot,
  -- and the proof went with it.
  --
  -- This entry buys it back in the one place that already knows how to
  -- report a module that will not load. It is REQUIRED rather than OPTIONAL
  -- on purpose: h2 is not an optional install here, it is vendored in the
  -- tree, so a copy that does not load is a broken checkout, not a missing
  -- rock.
  { name = "akkar.vendor.http.h2_connection",
    why = "the HTTP/2 half (vendored), loaded lazily by the server" },
  { name = "cjson",     why = "JSON encoding", rock = "lua-cjson" },
}

local OPTIONAL = {
  { name = "pgmoon",    why = "the Postgres adapter (akkar.db)" },
  { name = "mime",      why = "required by pgmoon, which does not declare it",
    rock = "luasocket", critical_for = "pgmoon" },
  { name = "openssl",   why = "TLS", rock = "luaossl" },
  { name = "tl",        why = "Teal type checking", rock = "tl" },
  { name = "busted",    why = "the test suite" },
  -- THE C DRIVER, WHICH IS TWO HALVES AND ONLY ONE OF THEM SHIPS HERE.
  --
  -- `akkar/pq.lua` is in every install; `pq_native.so` is a separate rock.
  -- So "akkar.pq does not load" has two entirely different causes and one of
  -- them is not "not installed" -- which is why this entry diagnoses its own
  -- failure instead of taking the generic message below.
  --
  -- A `.so` BUILT FOR THE WRONG LUA is the one worth naming. `akkar/pq.lua`
  -- refuses it at load with a marker check, because the alternative is a
  -- segfault on the first call rather than an error -- and a doctor that
  -- reported that as "not installed" would send somebody to rebuild a rock
  -- they already have, for the version they already have.
  { name = "akkar.pq",  rock = "akkar-pq",
    why = "the C Postgres driver, db.connect { driver = 'pq' }",
    diagnose = function(err)
      if err:find("was built for Lua", 1, true) then
        return "akkar-pq is built for the WRONG Lua",
          err:match "^[^\n]*",
          "luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir), " ..
          "or remove the stale pq_native.so"
      end
      return "akkar-pq",
        "the Lua half is here and pq_native.so is not, so " ..
        "db.connect { driver = 'pq' } would raise at the first connection: " ..
        (err:match "^[^\n]*"):gsub(":%s*$", ""),
        "luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir) " ..
        "-- or leave the default pgmoon driver, which needs no C module"
    end },
}

local function present(name)
  local ok, mod = pcall(require, name)
  if not ok then return false, mod end
  return true, mod
end

function M.check_environment(report)
  report = report or new_report()
  require("akkar.internal.substrate").check(report, os.getenv("AKKAR_SUBSTRATE_MANIFEST"))

  -- The Lua version.
  --
  -- 5.4 and 5.5 both, and the second one is recent enough to explain. This
  -- used to fail anything but 5.4, with the reason "cqueues pins it exactly
  -- and has had no release since 2020" -- which stopped being true: cqueues
  -- gained 5.5 support upstream in March 2026, in the commit akkar pins, and
  -- the whole suite has since been run under 5.5.
  --
  -- 5.5 is NOT yet the recommended version, and `docs/substrate/LUA-55.md`
  -- says why -- it needs a luaossl built by hand and a cqueues whose vendored
  -- compat shim has been updated, neither of which luarocks will do for you.
  -- So it passes with a note rather than silently, because somebody on 5.5
  -- has done something deliberate and should be told the ground is newer.
  local version = _VERSION
  if version == "Lua 5.4" then
    report:ok("runtime", version, "the version akkar ships and tests against")
  elseif version == "Lua 5.5" then
    report:ok("runtime", version,
      "supported; needs luaossl and cqueues built for 5.5 -- see docs/substrate/LUA-55.md")
  else
    report:fail("runtime", version,
      "akkar runs on Lua 5.4 or 5.5",
      "install Lua 5.4 and rebuild the rocks against it")
  end

  -- Integer division and math.type are what akkar.db uses to decide int8 vs
  -- float8 on a bound parameter, which is the 3.91x fix.  If math.type is
  -- missing, the runtime is not what it claims.
  if math.type == nil then
    report:fail("runtime", "math.type is missing",
      "akkar.db uses it to bind integers as int8; without it every " ..
      "parameterised lookup falls back to a sequential scan")
  end

  for _, entry in ipairs(REQUIRED) do
    local ok, mod = present(entry.name)
    if ok then
      report:ok("required", entry.rock or entry.name,
                (module_version(entry.name, mod) or "version not declared") ..
                " -- " .. entry.why)
    else
      report:fail("required", entry.rock or entry.name,
        entry.why .. " is missing: " .. tostring(mod):match "^[^\n]*",
        "luarocks install " .. (entry.rock or entry.name))
    end
  end

  for _, entry in ipairs(OPTIONAL) do
    local ok, mod = present(entry.name)
    if ok then
      report:ok("optional", entry.rock or entry.name,
                (module_version(entry.name, mod) or "version not declared") ..
                " -- " .. entry.why)
    elseif entry.critical_for and present(entry.critical_for) then
      -- The exact trap this file was written for: pgmoon installed, `mime`
      -- absent, and the failure arrives at the first query as a `require`
      -- traceback naming a module nobody asked for.
      report:fail("optional", entry.rock or entry.name,
        entry.why .. ", and " .. entry.critical_for ..
        " IS installed -- the first query will die with a require traceback",
        "luarocks install " .. (entry.rock or entry.name))
    elseif entry.diagnose then
      -- An entry that knows why its own load failed says so; "not installed"
      -- is a guess, and here it would be the wrong one half the time.
      report:warn("optional", entry.diagnose(tostring(mod)))
    else
      report:warn("optional", entry.rock or entry.name,
        "not installed -- " .. entry.why,
        "luarocks install " .. (entry.rock or entry.name))
    end
  end

  -- luaossl against OpenSSL 3 prints deprecation warnings at build time that
  -- look like failures and are not.  Saying so here saves the afternoon that
  -- discovering it costs.
  local has_ssl = present "openssl"
  if has_ssl then
    local ok, raw = pcall(function()
      local ssl = require "openssl"
      return ssl.version and ssl.version() or nil
    end)
    -- luaossl returns OPENSSL_VERSION_NUMBER, a packed integer.  Printing it
    -- raw ("805306576") is a doctor telling you a true fact you cannot use.
    if ok and type(raw) == "number" then
      local major = bitwise.band(bitwise.rshift(raw, 28), 0xFF)
      local minor = bitwise.band(bitwise.rshift(raw, 20), 0xFF)
      local patch = bitwise.band(bitwise.rshift(raw, 4),  0xFF)
      report:ok("optional", "openssl runtime",
                ("%d.%d.%d (0x%08x)"):format(major, minor, patch, raw))
    elseif ok and raw then
      report:ok("optional", "openssl runtime", tostring(raw))
    end
  end

  M.check_descriptors(report)

  return report
end

-- =============================================================== descriptors
--
-- THE LIMIT THAT DECIDES HOW MANY REQUESTS THIS PROCESS CAN HOLD AT ONCE, and
-- nothing told an operator what it was.
--
-- `akkar.descriptor_ceiling` caps `max_concurrent` at 66% of the SOFT
-- descriptor limit, one descriptor per in-flight request. On the common
-- `ulimit -n 1024` that is 675 -- a number nobody chose, printed nowhere, and
-- the whole capacity of the process. The consequence is not academic:
-- `docs/HANDOFF.md` records the full spec suite failing on this laptop's
-- default 1024 in a 42-error cascade, passing only after `ulimit -n 8192`.
-- This check would have said so first.
--
-- Three ways to raise it, and which one applies depends on how the service is
-- started, so all three are named rather than guessed at.
local RAISE_IT =
  "`ulimit -n 8192` in the shell that starts it; `LimitNOFILE=8192` in the " ..
  "systemd unit; `--ulimit nofile=8192:8192` on the container"

local function describe_limit(n)
  if n == math.huge then return "unlimited" end
  return tostring(math.floor(n))
end

--- What the descriptor limits mean, as a PURE FUNCTION OF THE TWO NUMBERS,
--- returning `level, title, detail, fix`.
---
--- Pure on purpose. The soft limit on the machine running the suite is
--- 1,048,576, so a test that reads `/proc` can never provoke the warning that
--- matters -- the one about `ulimit -n 1024`. Handing the numbers in means the
--- rule is testable at any limit, and `check_descriptors` below is the only
--- part that depends on the box it runs on.
---
--- `soft = nil` is the off-Linux case, and it is a warning about akkar rather
--- than about the machine: `akkar.descriptor_limits` reads `/proc/self/limits`
--- and returns nil where there is none, so no ceiling is derived at all.
function M.descriptor_finding(soft, hard)
  local akkar = akkar_module()

  if not soft then
    return "warn", "no descriptor limit could be read",
      "`/proc/self/limits` is not readable here, and akkar derives NO " ..
      "ceiling from it either: `akkar.descriptor_limits` returns nil off " ..
      "Linux, so `max_concurrent` is left unset and the server accepts " ..
      "connections until the kernel refuses -- which is not a clean " ..
      "failure. `docs/PLATFORMS.md` carries deriving a limit off Linux " ..
      "(`ulimit -n` is POSIX) as an open decision",
      "set `max_concurrent` explicitly in `app:run{}` on this platform"
  end

  local ceiling = akkar.descriptor_ceiling(soft)
  local room = hard and hard > soft
    and (" The hard limit is " .. describe_limit(hard) ..
         ", so `ulimit -n` can raise the soft one without root.")
    or ""

  local title = ("max_concurrent %d, from a soft limit of %d")
    :format(ceiling, soft)

  if soft >= 4096 then
    return "ok", title,
      "akkar caps itself at 66% of the soft limit when the application " ..
      "sets no `max_concurrent`; an in-flight request holds one descriptor, " ..
      "its own connection, and the third held back is for everything else " ..
      "-- pools, log files, the listening socket"
  end

  return "warn", title,
    ("%d descriptors is the WHOLE capacity of this process, not a budget " ..
     "for requests alone: the derived ceiling is %d, and the pools, the log " ..
     "files and the listening socket come out of the same %d. 1024 is the " ..
     "usual default and this project has already been bitten by it -- " ..
     "`docs/HANDOFF.md` records the spec suite dying in a 42-error cascade " ..
     "on exactly this number.%s"):format(soft, ceiling, soft, room),
    RAISE_IT
end

--- The same finding, against the limits this process actually has.
function M.check_descriptors(report)
  report = report or new_report()
  local akkar = akkar_module()
  local level, title, detail, fix = M.descriptor_finding(akkar.descriptor_limits())
  report:add(level, "descriptors", title, detail, fix)
  return report
end

-- ======================================================================= app
--
-- Duplicate routes already fail at startup, naming both sites, so there is
-- nothing for a doctor to add there.  What no invariant catches is a route
-- that CAN never match because an earlier one swallows it.
local function shadowed_routes(app, report, prefix)
  prefix = prefix or ""
  local dynamic = {}

  for _, route in ipairs(app.routes or {}) do
    if #route.names > 0 then
      for _, earlier in ipairs(dynamic) do
        -- Compared by identity, not by pattern.  Guarding on
        -- `earlier.pattern ~= route.pattern` was meant to avoid comparing a
        -- route with itself and instead excluded the commonest case of all:
        -- `/users/:id` and `/users/:name` compile to the SAME pattern, and
        -- the second can never match.
        if earlier ~= route and earlier.method == route.method
           and route.path:match(earlier.pattern) then
          report:warn("routes",
            ("%s %s%s can never match"):format(route.method, prefix, route.path),
            ("%s %s%s is registered first at %s and its pattern covers this one")
              :format(earlier.method, prefix, earlier.path, earlier.where),
            "register the more specific route first, or make the patterns disjoint")
        end
      end
      dynamic[#dynamic + 1] = route
    end
  end

  for _, mount in ipairs(app.mounts or {}) do
    shadowed_routes(mount.app, report, prefix .. mount.prefix)
  end
  for _, host in ipairs(app.hosts or {}) do
    shadowed_routes(host.app, report, host.pattern .. prefix)
  end
end

-- A route that validates its INPUT and says nothing about its OUTPUT is half a
-- contract. `akkar gen` still emits a client for it, but the return type is
-- honestly `unknown`, and `akkar.openapi` documents "a response exists" with
-- no shape -- so every consumer of the contract gets the checking on the way
-- in and none on the way out. Nothing at runtime can notice that; a response
-- schema is optional by design. So the doctor says it, per route, as a warn:
-- the fix is one `response = { ... }` table beside the `body` that is already
-- there.
local function untyped_responses(app, report, prefix)
  prefix = prefix or ""
  for _, route in ipairs(app.routes or {}) do
    local opts = route.opts or {}
    local typed_input = opts.body or opts.params or opts.query
    if typed_input and not opts.response and not opts.responses then
      report:warn("routes",
        ("%s %s%s validates its input and declares no response"):format(
          route.method, prefix, route.path),
        "the generated client returns `unknown` for it and the OpenAPI document "
        .. "carries no response shape, so a caller is checked on the way in and "
        .. "not on the way out",
        "add `response = { ... }` (or `responses = { [201] = ... }`) beside the "
        .. "input schema")
    end
  end
  for _, mount in ipairs(app.mounts or {}) do
    untyped_responses(mount.app, report, prefix .. mount.prefix)
  end
  for _, host in ipairs(app.hosts or {}) do
    untyped_responses(host.app, report, host.pattern .. prefix)
  end
end

local function count_routes(app)
  local n = #(app.routes or {})
  for _, mount in ipairs(app.mounts or {}) do n = n + count_routes(mount.app) end
  for _, host in ipairs(app.hosts or {}) do n = n + count_routes(host.app) end
  return n
end

--- Which capabilities the routes actually read, found by looking at what the
--- handlers close over -- `debug.getupvalue` cannot see a `req.db` inside a
--- function body, so this is deliberately NOT attempted. Guessing which
--- capabilities an app needs, and then warning about the guess, would be
--- worse than saying nothing.
function M.check_app(app, config, report)
  report = report or new_report()
  config = config or {}

  if type(app) ~= "table" or type(app.routes) ~= "table" then
    report:fail("app", "not an akkar app",
                "check_app needs the value akkar.new() returned")
    return report
  end

  local total = count_routes(app)
  if total == 0 then
    report:warn("routes", "no routes registered",
                "the server would answer 404 to everything")
  else
    report:ok("routes", total .. " route" .. (total == 1 and "" or "s"),
              #(app.mounts or {}) .. " mounted sub-app(s), " ..
              #(app.hosts or {}) .. " host(s)")
  end

  shadowed_routes(app, report)
  untyped_responses(app, report)

  -- EVERY SETTING WHOSE VALUE THE RUNTIME CANNOT USE, checked here rather
  -- than discovered at `app:run`.
  --
  -- `akkar.check_settings` is the same function the server calls, exported
  -- precisely so a caller that must not bind a port can ask -- and the doctor,
  -- which is the deploy gate this project tells people to gate on, was not
  -- asking. `timeout = "30"` passed `akkar doctor` and failed the deploy.
  --
  -- ONE CALL PER SETTING, because `check_settings` raises on the FIRST value
  -- it rejects: handing it the whole table reports one bad setting and hides
  -- the rest, which is the shape that costs a second deploy. The keys are
  -- sorted so a report of two failures reads the same way twice.
  --
  -- The message is the runtime's own, not a second wording of it. `error`
  -- there is raised at level 3, so it arrives with the caller's position
  -- glued to the front; the prefix is cut back to where the real sentence
  -- starts rather than printing a line number inside this file.
  local WHAT = "app:run{}"
  local rejected = {}
  local keys = {}
  for key in pairs(config) do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local ok, message = pcall(akkar_module().check_settings,
                              { [key] = config[key] }, WHAT)
    if not ok then
      rejected[key] = true
      message = tostring(message)
      local at = message:find(WHAT, 1, true)
      report:fail("settings", key .. " is not a value the runtime can use",
                  at and message:sub(at) or message,
                  "fix it before deploying: `app:run{}` raises this at boot, " ..
                  "so the server would not come up")
    end
  end

  -- Which production defaults are actually in force, stated as numbers rather
  -- than as "defaults applied". A limit nobody can see is a limit nobody
  -- checks against.
  local defaults = akkar_module().defaults
  local settings = {
    { "body_limit", "bytes" }, { "timeout", "s" }, { "shutdown_grace", "s" },
  }
  for _, entry in ipairs(settings) do
    local key, unit = entry[1], entry[2]
    -- A value the runtime refuses is not "in force": the server would not
    -- start with it. Printing `ok timeout = 30 s` under a FAIL about the same
    -- setting is the doctor contradicting itself in the same paragraph.
    if not rejected[key] then
      local value = config[key] or defaults[key]
      local source = config[key] and "configured" or "default"
      report:ok("settings", key .. " = " .. tostring(value) .. " " .. unit, source)
    end
  end

  if config.check_capabilities == false then
    report:warn("settings", "check_capabilities is off",
      "a misconfigured adapter will surface on the first request that " ..
      "touches it rather than at boot",
      "leave it on unless this service must come up degraded")
  end

  -- THE DRIVER THIS DEPLOYMENT ASKED FOR, AGAINST THE ONE THAT IS INSTALLED.
  --
  -- What the doctor can see here is limited, and naming the signal it does
  -- read beats pretending to read the one it cannot. `driver = "pq"` is given
  -- to `db.connect{}`; what arrives in this config is the factory that closed
  -- over that table, so the driver name is not in it -- and a `driver` key on
  -- the run config is not an alternative, because `app:run{}` rejects any
  -- option it does not know. So the visible signal is `AKKAR_DRIVER`, which
  -- `bench/study/apps/serve.lua` and the deploy scripts set, and if it does
  -- not name pq nothing is reported and nothing is guessed.
  --
  -- The in-config case is not lost: with `probe` on, `check_capabilities`
  -- acquires the db and `db.connect` raises the rock's own install message,
  -- which is already reported as a failure. This covers `--no-probe` and the
  -- bench path.
  --
  -- Worth reporting because of where the failure lands otherwise: at the
  -- first CONNECTION, not at load. With `check_capabilities` on that is a
  -- refusal to boot; with it off it is, in the words of the bench harness,
  -- "a 500 in the middle of a timed run" -- after the time has been spent.
  local wants_pq = os.getenv "AKKAR_DRIVER" == "pq"
  if wants_pq then
    local loaded, why = present "akkar.pq"
    if loaded then
      report:ok("settings", "driver = pq",
        "akkar.pq loads, so the C driver is the one this app will use")
    else
      report:warn("settings", "driver = pq, and akkar.pq does not load",
        "the driver was asked for and is not usable here: " ..
        (tostring(why):match "^[^\n]*"):gsub(":%s*$", "") ..
        " -- db.connect raises at the first connection, not at load",
        "luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir), " ..
        "or drop the driver option and use pgmoon")
    end
  end

  -- WHICH HTTP VERSIONS THIS SERVER WILL ACTUALLY SPEAK.
  --
  -- This check exists because of a failure that reports nothing. akkar builds
  -- its own TLS context when given `certificate` and `key`, and a context
  -- without an ALPN callback advertises no h2 -- so a browser negotiates
  -- HTTP/1.1 against a server that speaks HTTP/2 perfectly well, the
  -- handshake succeeds, the request is answered, and the multiplexing simply
  -- never happens. Nothing in a log, nothing in a metric.
  --
  -- akkar sets ALPN on the contexts it builds. It cannot set it on one handed
  -- over through `ctx`, and it will not silently reach into a context the
  -- application configured -- so that case is a warning rather than a claim.
  if config.ctx then
    report:warn("settings", "HTTP/2 over TLS cannot be confirmed",
      "the TLS context came from `ctx`, so akkar did not install the ALPN " ..
      "callback and cannot tell whether h2 is on offer; without it a browser " ..
      "silently falls back to HTTP/1.1",
      "call ctx:setAlpnSelect(require('akkar.vendor.http.server').alpn_select) " ..
      "on it, or pass `tls = { certificate = ..., key = ... }` and let akkar " ..
      "build the context")
  elseif config.tls or config.h2c then
    -- AND THE CLAIM IS CHECKED, NOT DEDUCED FROM THE CONFIG.
    --
    -- `server.lua` loads `h2_connection` lazily now -- at `new_server`, for
    -- exactly these configurations -- so "this server speaks HTTP/2" is no
    -- longer something the config alone can establish. Read off the config
    -- it would be a claim about a tree whose `hpack.lua` might not parse,
    -- and the doctor would be asserting the very thing it exists to catch.
    -- So it is asked, here, of the module that would have to work.
    local h2_ok, h2_err = present "akkar.vendor.http.h2_connection"
    if not h2_ok then
      report:fail("settings",
        config.tls and "HTTP/2 is configured and the h2 half does not load"
                    or "h2c is on and the h2 half does not load",
        "the server would accept the connection and then fail it: " ..
        (tostring(h2_err):match "^[^\n]*"):gsub(":%s*$", ""),
        "this is vendored code, not a rock -- check the tree under " ..
        "akkar/vendor/http/ is complete and parses")
    elseif config.tls then
      report:ok("settings", "HTTP/1.1 and HTTP/2",
        "h2 is negotiated by ALPN; a client that does not ask for it gets h1")
    else
      report:ok("settings", "HTTP/1.1 and cleartext HTTP/2",
        "h2c costs one read per connection to sniff the preface, h1 " ..
        "connections included")
    end
  else
    report:ok("settings", "HTTP/1.1 only",
      "no TLS, so there is no ALPN to negotiate h2 with; `h2c = true` " ..
      "enables cleartext h2 for a proxy or a gRPC client")
  end

  -- WEBSOCKETS AGAINST `max_concurrent`, which is the interaction nobody
  -- reads about until it happens. A socket is a connection that lasts, and
  -- `max_concurrent` counts connections -- measured, ten idle sockets against
  -- `max_concurrent = 10` and the eleventh client is never accepted at all.
  local has_socket_route = false
  for _, route in ipairs(app.routes or {}) do
    if route.websocket_route then has_socket_route = true break end
  end
  if has_socket_route then
    if config.websocket_max_connections then
      report:ok("settings",
        "websocket_max_connections = " .. tostring(config.websocket_max_connections),
        "sockets cannot take the whole connection budget")
    elseif config.max_concurrent then
      report:warn("settings",
        "websockets share max_concurrent with everything else",
        ("max_concurrent is %s and a socket holds one of those for as long as "
         .. "it lives; enough open sockets and ordinary requests stop being "
         .. "accepted"):format(tostring(config.max_concurrent)),
        "set websocket_max_connections to something below max_concurrent")
    else
      report:warn("settings", "websocket connections are unbounded",
        "a socket holds a connection for as long as it lives, and nothing "
        .. "here bounds how many there are",
        "set websocket_max_connections")
    end
  end

  if config.reuseport then
    report:ok("settings", "reuseport is on",
              "several processes can share the port; capacity is processes")
  else
    report:warn("settings", "reuseport is off",
      "one Lua VM is one core, so a single process uses one core no matter " ..
      "how many the machine has",
      "app:run { reuseport = true } and start one process per core")
  end

  return report
end

-- ============================================================== reachability
--
-- Acquired and released exactly as a request would, so what is tested is the
-- configuration the server will actually use.
--
-- This is the only part that touches the network, and it is the only part
-- that can hang, so it is separable: `report(app, config, { probe = false })`
-- skips it.
local CONTRACTS = {
  db    = { "one", "many", "exec", "transaction" },
  cache = { "get", "set", "del" },
}

function M.check_capabilities(config, report)
  report = report or new_report()
  config = config or {}

  for name, methods in pairs(CONTRACTS) do
    local provided = config[name]
    if provided == nil then
      report:ok("capabilities", name .. " not configured",
                "handlers reading req." .. name .. " get a guard that says so")
    else
      local ok, resource = pcall(function()
        if type(provided) == "function" or
           (type(provided) == "table" and getmetatable(provided)
            and getmetatable(provided).__call) then
          return provided()
        end
        return provided
      end)

      if not ok then
        report:fail("capabilities", name .. " cannot be acquired",
          tostring(resource):match "^[^\n]*",
          "the server refuses to start in this state unless " ..
          "check_capabilities = false")
      else
        local missing = {}
        for _, method in ipairs(methods) do
          if type(resource[method]) ~= "function" then
            missing[#missing + 1] = method
          end
        end
        if #missing > 0 then
          report:fail("capabilities", name .. " does not satisfy its contract",
            "missing: " .. table.concat(missing, ", "))
        else
          report:ok("capabilities", name .. " is reachable and complete",
                    "answers " .. table.concat(methods, ", "))
        end
        pcall(function() if resource.release then resource:release() end end)
      end
    end
  end

  return report
end

-- ==================================================================== output
local LEVEL_MARK = { ok = "ok  ", warn = "warn", fail = "FAIL" }
local ORDER = { fail = 1, warn = 2, ok = 3 }

function M.format(report)
  local lines = {}
  local by_area, areas = {}, {}
  for _, finding in ipairs(report.findings) do
    if not by_area[finding.area] then
      by_area[finding.area] = {}
      areas[#areas + 1] = finding.area
    end
    local bucket = by_area[finding.area]
    bucket[#bucket + 1] = finding
  end

  for _, area in ipairs(areas) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = area
    local bucket = by_area[area]
    table.sort(bucket, function(a, b) return ORDER[a.level] < ORDER[b.level] end)
    for _, f in ipairs(bucket) do
      lines[#lines + 1] = ("  %s  %s"):format(LEVEL_MARK[f.level], f.title)
      if f.detail then lines[#lines + 1] = "        " .. f.detail end
      if f.fix then lines[#lines + 1] = "        fix: " .. f.fix end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = ("%d ok, %d warning(s), %d failure(s)")
    :format(report:count "ok", report:count "warn", report:count "fail")
  lines[#lines + 1] = report:healthy()
    and "nothing is broken"
    or "something is broken; the lines marked FAIL are the ones to read"
  return table.concat(lines, "\n")
end

--- The whole examination.  `app` and `config` are optional: with neither, this
--- checks the environment, which is what a fresh clone wants to know first.
function M.report(app, config, options)
  options = options or {}
  local report = new_report()

  M.check_environment(report)
  if app then M.check_app(app, config, report) end
  if config and options.probe ~= false then M.check_capabilities(config, report) end

  return report
end

--- Prints and exits: 0 when nothing is broken, 1 when something is.
--- A warning is not a failure, so a deploy gate reading the exit code is not
--- blocked by "luaossl is not installed" on a service that speaks plain HTTP.
function M.cli(options)
  options = options or {}
  local report = M.report(options.app, options.config, options)

  if options.json then
    print(require("cjson").encode {
      healthy = report:healthy(),
      findings = report.findings,
      summary = { ok = report:count "ok", warn = report:count "warn",
                  fail = report:count "fail" },
    })
  else
    print(M.format(report))
  end

  if options.exit ~= false then os.exit(report:healthy() and 0 or 1) end
  return report
end

M.Report = Report
M.new_report = new_report
return M
