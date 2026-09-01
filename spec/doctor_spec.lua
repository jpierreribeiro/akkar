--[[
akkar.doctor — the checks, and the rule that keeps them useful.

A doctor that cries wolf gets ignored, so the tests that matter are about
levels: a missing optional dependency must NOT be a failure, an unreachable
declared database must be, and the exit code has to mean something a deploy
step can gate on.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar  = require "akkar"
local doctor = require "akkar.doctor"

local function levels_of(report, area)
  local out = {}
  for _, f in ipairs(report.findings) do
    if f.area == area then out[#out + 1] = f.level end
  end
  return out
end

--- Plain substring, not a pattern.  "lua-http" as a Lua pattern reads as
--- "lu", zero-or-more "a", "http" -- it matches "luhttp" and never the
--- literal name. The same magic-character trap the host router is tested for.
local function find(report, text)
  for _, f in ipairs(report.findings) do
    if f.title:find(text, 1, true) then return f end
  end
end

describe("the environment check", function()
  it("passes on the machine running the suite", function()
    -- If this fails, the suite could not have got this far -- which is the
    -- point: the check agrees with reality rather than describing an ideal.
    local report = doctor.check_environment()
    assert.equal(0, report:count "fail")
    assert.is_true(report:healthy())
  end)

  it("names every required library with its version", function()
    -- `akkar.vendor.http.server` rather than `lua-http`, and the change is
    -- the point: akkar stopped depending on upstream lua-http at runtime when
    -- it vendored the HTTP/1.1 half, and the rockspec lists `http` under
    -- `test_dependencies` alone. The doctor was the last thing still looking
    -- for the rock, so `akkar doctor` FAILED on every correct installation
    -- from the rockspec -- caught by CI's `install` job, which is the only
    -- thing that installs the way a user does.
    local report = doctor.check_environment()
    for _, rock in ipairs { "cqueues", "akkar.vendor.http.server", "lua-cjson" } do
      assert.is_truthy(find(report, rock), rock .. " was not reported")
    end
  end)

  it("reports a version only when the library declares one", function()
    -- Guessing a version from a rock directory is how a doctor tells you
    -- something false with confidence.
    local cqueues = find(doctor.check_environment(), "cqueues")
    assert.is_truthy(cqueues.detail:match "%d" or
                     cqueues.detail:match "version not declared")
  end)
end)

describe("levels mean different things", function()
  it("treats a missing optional library as a warning, not a failure", function()
    local report = doctor.check_environment()
    for _, f in ipairs(report.findings) do
      if f.area == "optional" then
        assert.not_equal("fail", f.level,
          "an optional library was reported as a failure: " .. f.title)
      end
    end
  end)

  it("treats an unreachable declared database as a failure", function()
    -- Because the server refuses to boot in that state anyway. Reporting it
    -- as a warning would be the doctor disagreeing with the framework.
    local report = doctor.check_capabilities {
      db = function() error("connection refused", 0) end,
    }
    assert.equal(1, report:count "fail")
    assert.is_false(report:healthy())
  end)

  it("treats an unconfigured capability as fine", function()
    -- Not configuring a database is a choice, not a fault. Handlers that
    -- read req.db get a guard that says so.
    local report = doctor.check_capabilities {}
    assert.equal(0, report:count "fail")
    assert.equal(0, report:count "warn")
  end)

  it("fails an adapter that does not answer its contract", function()
    local report = doctor.check_capabilities {
      db = { one = function() end, many = function() end },   -- no exec, no transaction
    }
    local finding = find(report, "contract")
    assert.equal("fail", finding.level)
    assert.is_truthy(finding.detail:match "exec")
    assert.is_truthy(finding.detail:match "transaction")
  end)
end)

describe("the descriptor ceiling", function()
  -- WHY THE RULE IS TESTED AS A PURE FUNCTION AND THE MACHINE ONLY ONCE.
  --
  -- The soft limit on the box running this suite is 1,048,576, so a test that
  -- read `/proc` could never provoke the finding that matters -- the one about
  -- the common `ulimit -n 1024`, where akkar's ceiling is 675 and that is the
  -- entire capacity of the process. `doctor.descriptor_finding` takes the two
  -- numbers, so the rule is checkable at any limit; the integration case below
  -- is the only one that depends on where it runs.
  it("states the ceiling it derives when there is room", function()
    local level, title, detail = doctor.descriptor_finding(4096, 1048576)
    assert.equal("ok", level)
    assert.is_truthy(title:find("2703", 1, true), title)   -- 66% of 4096
    assert.is_truthy(detail:find("one descriptor", 1, true), detail)
  end)

  it("warns at the default 1024 and names the three ways to raise it", function()
    -- 675 concurrent requests, and everything else -- pools, log files, the
    -- listening socket -- out of the same 1024. Which of the three fixes
    -- applies depends on how the service is started, so all three are named
    -- rather than guessed at.
    local level, title, detail, fix = doctor.descriptor_finding(1024, 1048576)
    assert.equal("warn", level)
    assert.is_truthy(title:find("675", 1, true), title)
    assert.is_truthy(detail:find("WHOLE capacity", 1, true), detail)
    for _, way in ipairs { "ulimit %-n", "LimitNOFILE=", "%-%-ulimit nofile=" } do
      assert.is_truthy(fix:match(way), way .. " was not offered: " .. fix)
    end
  end)

  it("says the hard limit leaves room, because that decides the fix", function()
    -- `ulimit -n` raises the soft limit up to the hard one without root; past
    -- it, somebody has to edit a unit file. Different fixes, so the doctor
    -- reads both columns of `/proc/self/limits` rather than only the first.
    local _, _, roomy = doctor.descriptor_finding(1024, 1048576)
    assert.is_truthy(roomy:find("without root", 1, true), roomy)
    local _, _, capped = doctor.descriptor_finding(1024, 1024)
    assert.is_nil(capped:find("without root", 1, true), capped)
  end)

  it("warns that akkar derives NO ceiling where /proc cannot be read", function()
    -- This is the row that earns the check: it is not the doctor being coy
    -- about its own limits, it is a real runtime gap. `descriptor_limits`
    -- returns nil off Linux, so `max_concurrent` is never set and the server
    -- accepts until the kernel refuses. `docs/PLATFORMS.md` carries it as an
    -- open decision.
    local level, title, detail, fix = doctor.descriptor_finding(nil, nil)
    assert.equal("warn", level)
    assert.is_truthy(title:find("no descriptor limit", 1, true), title)
    assert.is_truthy(detail:find("max_concurrent", 1, true), detail)
    assert.is_truthy(detail:find("PLATFORMS.md", 1, true), detail)
    assert.is_truthy(fix:find("max_concurrent", 1, true), fix)
  end)

  it("reports the number the runtime would actually use", function()
    -- A doctor that derives its own ceiling would agree with itself and
    -- nobody else. This is `app:run`'s arithmetic, called.
    local soft = akkar.descriptor_limits()
    local _, title = doctor.descriptor_finding(soft, nil)
    assert.is_truthy(title:find(tostring(akkar.descriptor_ceiling(soft)), 1, true),
                     title)
  end)

  it("reports exactly one descriptors finding here, and no failure", function()
    -- Agreeing with reality rather than describing an ideal: whatever this
    -- machine's limit is, the check must say one thing about it and must not
    -- fail a deploy over it. A descriptor limit is an operational fact.
    local report = doctor.check_environment()
    local levels = levels_of(report, "descriptors")
    assert.equal(1, #levels, "expected one descriptors finding")
    assert.not_equal("fail", levels[1])
    assert.equal(0, report:count "fail")
  end)
end)

describe("the app check", function()
  it("counts routes across mounts and hosts", function()
    local sub = akkar.new()
    sub:get("/a", function() end)
    sub:get("/b", function() end)

    local tenant = akkar.new()
    tenant:get("/c", function() end)

    local app = akkar.new()
    app:get("/", function() end)
    app:mount("/v1", sub)
    app:host("t.example.com", tenant)

    local report = doctor.check_app(app, {})
    assert.is_truthy(find(report, "4 routes"))
  end)

  it("finds a route that can never match", function()
    -- Duplicates already fail at startup naming both sites, so this is the
    -- case no invariant catches: two dynamic routes of the same shape, where
    -- the second is unreachable.
    local app = akkar.new()
    app:get("/users/:id", function() end)
    app:get("/users/:name", function() end)

    local report = doctor.check_app(app, {})
    local finding = find(report, "can never match")
    assert.is_truthy(finding, "the shadowed route was not reported")
    assert.equal("warn", finding.level)
    assert.is_truthy(finding.title:match "/users/:name")
    assert.is_truthy(finding.detail:match "/users/:id")
  end)

  it("does not cry wolf over routes that are genuinely distinct", function()
    local app = akkar.new()
    app:get("/users/:id", function() end)
    app:get("/files/:id", function() end)
    app:post("/users/:id", function() end)        -- different method
    app:get("/users/:id/posts/:post", function() end)

    local report = doctor.check_app(app, {})
    assert.is_nil(find(report, "can never match"))
  end)

  it("warns about an app with no routes at all", function()
    local report = doctor.check_app(akkar.new(), {})
    local finding = find(report, "no routes")
    assert.equal("warn", finding.level)
  end)

  it("states the limits as numbers, configured or default", function()
    -- A limit nobody can see is a limit nobody checks against.
    local app = akkar.new()
    app:get("/", function() end)

    local report = doctor.check_app(app, { timeout = 5 })
    assert.is_truthy(find(report, "timeout = 5 s").detail:match "configured")
    assert.is_truthy(find(report, "body_limit = 1048576").detail:match "default")
  end)

  it("warns when reuseport is off, because one VM is one core", function()
    local app = akkar.new()
    app:get("/", function() end)
    assert.equal("warn", find(doctor.check_app(app, {}), "reuseport is off").level)
    assert.equal("ok", find(doctor.check_app(app, { reuseport = true }), "reuseport is on").level)
  end)

  it("says which HTTP versions the server will actually speak", function()
    -- THE FAILURE THIS REPORTS IS SILENT BY CONSTRUCTION. A TLS context with
    -- no ALPN callback advertises no h2, so a browser negotiates HTTP/1.1
    -- against a server that speaks HTTP/2 fine: handshake succeeds, request
    -- is answered, multiplexing never happens, and nothing logs anything.
    -- Doctor is the only place that can say so before a user wonders.
    local app = akkar.new()
    app:get("/", function() end)

    assert.equal("ok",
      find(doctor.check_app(app, {}), "HTTP/1.1 only").level)
    assert.equal("ok",
      find(doctor.check_app(app, { h2c = true }),
           "cleartext HTTP/2").level)
    assert.equal("ok",
      find(doctor.check_app(app, { tls = { certificate = "x", key = "y" } }),
           "HTTP/1.1 and HTTP/2").level)

    -- A context akkar did not build is the one case it cannot vouch for, and
    -- guessing would be worse than saying so: akkar will not reach into a
    -- context the application configured.
    assert.equal("warn",
      find(doctor.check_app(app, { ctx = {} }),
           "HTTP/2 over TLS cannot be confirmed").level)
  end)

  it("warns when the startup capability check is disabled", function()
    local app = akkar.new()
    app:get("/", function() end)
    local report = doctor.check_app(app, { check_capabilities = false })
    assert.equal("warn", find(report, "check_capabilities is off").level)
  end)

  it("refuses something that is not an app rather than guessing", function()
    local report = doctor.check_app({ not_an = "app" }, {})
    assert.equal("fail", find(report, "not an akkar app").level)
  end)
end)

describe("the settings the runtime cannot use", function()
  -- `akkar doctor` is the deploy gate this project tells people to gate on --
  -- `cli` exits 1 on any failure -- and it was checking that a setting's NAME
  -- was known while never asking whether its VALUE was usable. So
  -- `timeout = "30"` passed the gate and failed at `app:run`, which is the
  -- expensive place to find it.
  local function app_with(config)
    local app = akkar.new()
    app:get("/", function() return { ok = true } end)
    return doctor.check_app(app, config)
  end

  it("fails a setting whose value the runtime would refuse", function()
    local report = app_with { timeout = "30" }
    local finding = find(report, "timeout")
    assert.equal("fail", finding.level)
    assert.is_false(report:healthy(), "the deploy gate must read this as broken")

    -- And it does not also print `ok timeout = 30 s` two lines below. A value
    -- the runtime refuses is not in force -- the server would not start with
    -- it -- so reporting it as a limit that applies is the doctor
    -- contradicting itself inside one area.
    assert.is_nil(find(report, "timeout = 30 s"))
  end)

  it("reuses the runtime's own message, not a second wording of it", function()
    -- Two wordings of one rule drift apart. This is the string
    -- `akkar.check_settings` produces, with the `error` position cut off the
    -- front so a line number inside doctor.lua is not printed as if it were
    -- the problem.
    local finding = find(app_with { timeout = "30" }, "timeout")
    assert.is_truthy(finding.detail:find('got string "30"', 1, true),
                     finding.detail)
    assert.equal("app:run{}", finding.detail:sub(1, 9), finding.detail)
  end)

  it("reports EVERY bad setting, not only the first", function()
    -- `check_settings` raises on the first value it rejects, so one call over
    -- the whole table would hide the rest -- and hiding the rest is what costs
    -- a second deploy. One call per setting is why this passes.
    local report = app_with { timeout = "30", body_limit = -1, port = 70000 }
    assert.equal(3, report:count "fail")
    for _, key in ipairs { "timeout", "body_limit", "port" } do
      assert.is_truthy(find(report, key .. " is not a value"), key)
    end
  end)

  it("says nothing about settings it has no rule for", function()
    -- Every value here is one the runtime actually supports, and a doctor
    -- that flagged them would be describing an ideal rather than the code.
    local report = app_with {
      port = 0, timeout = false, body_limit = 1, max_concurrent = 1,
      reuseport = true, h2c = true, trusted_proxies = { "10.0.0.0/8" },
    }
    assert.equal(0, report:count "fail")
  end)
end)

describe("the C Postgres driver", function()
  -- `akkar.pq` is two halves: `akkar/pq.lua` ships with every install and
  -- `pq_native.so` is a separate rock. The doctor said nothing about either,
  -- so the way a missing .so was found was `db.connect { driver = "pq" }`
  -- raising at the first connection -- "a 500 in the middle of a timed run",
  -- as `bench/study/apps/serve.lua` puts it.
  it("reports it among the optional libraries", function()
    local report = doctor.check_environment()
    local finding = find(report, "akkar-pq")
    assert.is_truthy(finding, "akkar.pq was not reported at all")
    assert.not_equal("fail", finding.level,
      "an optional driver is not a failure; the default is pgmoon")
  end)

  --- Runs `fn` with `require "akkar.pq"` forced to a known outcome, and puts
  --- the loader back afterwards.
  ---
  --- Necessary because the two failures this reports cannot both be produced
  --- on one machine: a box without `pq_native.so` cannot have a stale one, and
  --- a box with a correct one cannot have either. The stand-in raises exactly
  --- what `akkar/pq.lua` raises, so what is tested is the doctor's reading of
  --- that message rather than a message invented here.
  local function with_pq(loader, fn)
    local preload, loaded = package.preload["akkar.pq"], package.loaded["akkar.pq"]
    package.preload["akkar.pq"], package.loaded["akkar.pq"] = loader, nil
    local ok, result = pcall(fn)
    package.preload["akkar.pq"], package.loaded["akkar.pq"] = preload, loaded
    assert.is_true(ok, tostring(result))
    return result
  end

  local function built_for_another_lua()
    error("akkar.pq_native was built for Lua 5.4 and this is Lua 5.5; " ..
          "rebuild it (luarocks install akkar-pq) or remove the stale " ..
          "pq_native.so", 0)
  end

  it("does not call a build for the wrong Lua 'not installed'", function()
    -- `akkar/pq.lua` refuses a `.so` built for a different Lua at load, and it
    -- refuses it rather than segfaulting on the first call. Reporting that as
    -- "not installed" would send somebody to install a rock they already have,
    -- for the Lua they already run.
    local report = with_pq(built_for_another_lua, doctor.check_environment)

    local finding = find(report, "WRONG Lua")
    assert.is_truthy(finding, "the ABI marker failure was reported as something else")
    assert.equal("warn", finding.level)
    assert.is_truthy(finding.detail:find("built for Lua 5.4", 1, true),
                     finding.detail)
    assert.is_truthy(finding.fix:find("stale pq_native.so", 1, true), finding.fix)
  end)

  it("warns when the deployment asked for pq and it does not load", function()
    -- WHAT THE DOCTOR CAN SEE, and only that. `driver = "pq"` goes to
    -- `db.connect{}` and what reaches `check_app` is the factory that closed
    -- over it, so the visible signal is `AKKAR_DRIVER` -- what the bench
    -- harness and the deploy scripts set. Stubbed here rather than exported,
    -- because Lua cannot set its own environment.
    local app = akkar.new()
    app:get("/", function() return { ok = true } end)

    local real = os.getenv
    os.getenv = function(name)
      if name == "AKKAR_DRIVER" then return "pq" end
      return real(name)
    end
    local ok, report = pcall(function()
      return with_pq(built_for_another_lua, function()
        return doctor.check_app(app, {})
      end)
    end)
    os.getenv = real
    assert.is_true(ok, tostring(report))

    local finding = find(report, "driver = pq")
    assert.is_truthy(finding, "nothing was said about the driver that was asked for")
    -- A warning, not a failure: this is the environment disagreeing with the
    -- run, and a service whose routes never touch the database still starts.
    assert.equal("warn", finding.level)
    assert.is_truthy(finding.detail:find("first connection", 1, true),
                     finding.detail)
  end)

  it("says so plainly when the driver asked for is the one installed", function()
    local app = akkar.new()
    app:get("/", function() return { ok = true } end)

    local real = os.getenv
    os.getenv = function(name)
      if name == "AKKAR_DRIVER" then return "pq" end
      return real(name)
    end
    local ok, report = pcall(function()
      return with_pq(function() return { connect = function() end } end,
                     function() return doctor.check_app(app, {}) end)
    end)
    os.getenv = real
    assert.is_true(ok, tostring(report))

    assert.equal("ok", find(report, "driver = pq").level)
  end)

  it("says nothing about the driver when nothing asked for it", function()
    local app = akkar.new()
    app:get("/", function() return { ok = true } end)
    assert.is_nil(find(doctor.check_app(app, {}), "driver = pq"))
  end)
end)

describe("the report itself", function()
  it("is healthy only when nothing failed", function()
    local report = doctor.new_report()
    report:ok("a", "fine")
    assert.is_true(report:healthy())
    report:warn("a", "will bite")
    assert.is_true(report:healthy(), "a warning is not a failure")
    report:fail("a", "broken")
    assert.is_false(report:healthy())
  end)

  it("puts failures first inside each area, where they get read", function()
    local report = doctor.new_report()
    report:ok("area", "fine one")
    report:fail("area", "broken one")
    report:warn("area", "warned one")

    local text = doctor.format(report)
    assert.is_true(text:find("broken one") < text:find("warned one"))
    assert.is_true(text:find("warned one") < text:find("fine one"))
  end)

  it("says plainly whether anything is broken", function()
    local clean = doctor.new_report(); clean:ok("a", "fine")
    assert.is_truthy(doctor.format(clean):match "nothing is broken")

    local broken = doctor.new_report(); broken:fail("a", "no")
    assert.is_truthy(doctor.format(broken):match "something is broken")
  end)
end)
