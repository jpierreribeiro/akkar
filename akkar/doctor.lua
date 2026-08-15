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

local M = {}

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

local REQUIRED = {
  { name = "cqueues",   why = "the event loop" },
  { name = "http.server", why = "the HTTP server", rock = "lua-http" },
  { name = "cjson",     why = "JSON encoding", rock = "lua-cjson" },
}

local OPTIONAL = {
  { name = "pgmoon",    why = "the Postgres adapter (akkar.db)" },
  { name = "mime",      why = "required by pgmoon, which does not declare it",
    rock = "luasocket", critical_for = "pgmoon" },
  { name = "openssl",   why = "TLS", rock = "luaossl" },
  { name = "tl",        why = "Teal type checking", rock = "tl" },
  { name = "busted",    why = "the test suite" },
}

local function present(name)
  local ok, mod = pcall(require, name)
  if not ok then return false, mod end
  return true, mod
end

function M.check_environment(report)
  report = report or new_report()

  -- The Lua version, and the pin that makes it non-negotiable.
  local version = _VERSION
  if version == "Lua 5.4" then
    report:ok("runtime", version, "cqueues pins lua == 5.4, so this is the only supported one")
  else
    report:fail("runtime", version,
      "akkar runs on Lua 5.4; cqueues pins it exactly and has had no release since 2020",
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
      local major = (raw >> 28) & 0xFF
      local minor = (raw >> 20) & 0xFF
      local patch = (raw >> 4)  & 0xFF
      report:ok("optional", "openssl runtime",
                ("%d.%d.%d (0x%08x)"):format(major, minor, patch, raw))
    elseif ok and raw then
      report:ok("optional", "openssl runtime", tostring(raw))
    end
  end

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

  -- Which production defaults are actually in force, stated as numbers rather
  -- than as "defaults applied". A limit nobody can see is a limit nobody
  -- checks against.
  local defaults = require("akkar").defaults
  local settings = {
    { "body_limit", "bytes" }, { "timeout", "s" }, { "shutdown_grace", "s" },
  }
  for _, entry in ipairs(settings) do
    local key, unit = entry[1], entry[2]
    local value = config[key] or defaults[key]
    local source = config[key] and "configured" or "default"
    report:ok("settings", key .. " = " .. tostring(value) .. " " .. unit, source)
  end

  if config.check_capabilities == false then
    report:warn("settings", "check_capabilities is off",
      "a misconfigured adapter will surface on the first request that " ..
      "touches it rather than at boot",
      "leave it on unless this service must come up degraded")
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
