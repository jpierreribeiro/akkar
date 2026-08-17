--[[
`akkar new`, `akkar run` and `akkar test` — the first minute.

## Why this file exists

The reframing this project took is that akkar is a backend RUNTIME whose
application language is Lua, not a web framework. The argument for it is that
Lua's cost of adoption has never been a missing library: it is that a person
has to choose an interpreter, a package manager, an event loop, an HTTP
library, a TLS library, a JSON library and a driver, and then find out which
combination works.

A runtime answers that by having a first minute. This file is that minute,
asserted: create a project, start it, get an answer, run its tests.

Everything here spawns the real CLI, because the value of a scaffold is
entirely in whether the thing it emits runs.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local portable = require "spec.support.portable"

local function have_lua()
  local pipe = io.popen(portable.lua .. " -v 2>&1")
  if not pipe then return false end
  local out = pipe:read "a"
  pipe:close()
  return out and out:find "Lua" ~= nil
end

if not have_lua() then
  describe("the akkar CLI", function()
    pending "no Lua interpreter to spawn the CLI with; skipping"
  end)
  return
end

-- The paths the child needs, carried rather than appended.
--
-- Same lesson as `spec/task_spec.lua`: a fresh interpreter inherits only the
-- environment, so a suite run on a shell where luarocks is per-user and
-- LUA_PATH is unset would report the scaffold broken when the truth is that
-- cqueues was never found.
local ROOT = os.getenv "PWD" or "."

-- ABSOLUTE, because the child runs in the project it just created and a
-- relative `./?.lua` resolves THERE. The first version of this file passed the
-- suite's own `package.path`, whose leading entries are relative, and the
-- scaffolded app reported that the akkar module did not exist -- in a checkout
-- that obviously contains it.
local ENV = ("LUA_PATH=%q LUA_CPATH=%q"):format(
  ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;./?.lua;./?/init.lua;" .. package.path,
  ROOT .. "/?.so;./?.so;" .. package.cpath)

local function tmpdir()
  local name = os.tmpname()
  os.remove(name)
  os.execute(("mkdir -p %q"):format(name))
  return name
end

--- Runs the CLI in `dir` and returns its output and whether it succeeded.
local function cli(dir, args, timeout)
  local command = ("cd %q && %s %s 2>&1"):format(dir, ENV,
    portable.timeout(timeout or 30,
      ("%s %q/bin/akkar %s"):format(portable.lua, ROOT, args)))
  local pipe = assert(io.popen(command))
  local out = pipe:read "a"
  local ok = pipe:close()
  return out or "", ok and true or false
end

describe("akkar new", function()
  local dir
  before_each(function() dir = tmpdir() end)
  after_each(function() if dir then os.execute(("rm -rf %q"):format(dir)) end end)

  it("creates a project that is four files, not twelve", function()
    local out = cli(dir, "new demo")
    assert.is_truthy(out:find("created demo", 1, true), out)

    for _, path in ipairs { "demo/app.lua", "demo/spec/app_spec.lua",
                            "demo/README.md", "demo/migrations/.keep" } do
      local f = io.open(dir .. "/" .. path, "r")
      assert.is_truthy(f, "missing " .. path)
      if f then f:close() end
    end
  end)

  it("refuses to write over a project that is already there", function()
    cli(dir, "new demo")
    -- Something worth keeping goes in first: the refusal has to be about not
    -- losing this, not about tidiness.
    local f = assert(io.open(dir .. "/demo/app.lua", "a"))
    f:write "\n-- a whole afternoon\n"
    f:close()

    local out = cli(dir, "new demo")
    assert.is_truthy(out:find("refusing to overwrite", 1, true), out)

    local kept = assert(io.open(dir .. "/demo/app.lua", "r"))
    local body = kept:read "a"
    kept:close()
    assert.is_truthy(body:find("a whole afternoon", 1, true),
      "the scaffold overwrote work that was already there")
  end)

  it("refuses a name that is not a directory name", function()
    local out = cli(dir, "new ../escape")
    assert.is_truthy(out:find("characters a directory should not", 1, true), out)
  end)

  it("needs a name", function()
    local out = cli(dir, "new")
    assert.is_truthy(out:find("needs a name", 1, true), out)
  end)
end)

describe("akkar test", function()
  local dir
  before_each(function() dir = tmpdir() end)
  after_each(function() if dir then os.execute(("rm -rf %q"):format(dir)) end end)

  it("runs the spec the scaffold wrote, and it passes", function()
    cli(dir, "new demo")
    local out = cli(dir .. "/demo", "test", 60)
    -- The scaffold ships three cases. A scaffold whose own tests fail is
    -- worse than a scaffold with no tests.
    assert.is_truthy(out:find("3 successes", 1, true) or
                     out:find("0 failures", 1, true),
      "the scaffold's own spec did not pass:\n" .. out)
    assert.is_nil(out:find("busted is not installed", 1, true),
      "busted was expected in this environment")
  end)
end)

describe("akkar run", function()
  local cqueues = require "cqueues"
  local request = require "http.request"

  local dir
  before_each(function() dir = tmpdir() end)
  after_each(function() if dir then os.execute(("rm -rf %q"):format(dir)) end end)

  it("starts what the scaffold wrote and answers", function()
    cli(dir, "new demo")

    local PORT = 8385
    -- `setsid ... &` where there is a `setsid`, and a plain `&` where there
    -- is not -- `disown` is NOT the fallback: it is a bashism, and
    -- `os.execute` runs `sh`, which reported "disown: not found" and left the
    -- reader wondering why the server had not started.
    os.execute(("cd %q/demo && PORT=%d %s %s"):format(dir, PORT, ENV,
      portable.detached(
        ("%s %q/bin/akkar run"):format(portable.lua, ROOT),
        dir .. "/run.err")))

    local health, greeting, refused
    local cq = cqueues.new()
    cq:wrap(function()
      -- Poll rather than sleep a fixed amount: a fixed sleep is either flaky
      -- or slow, and on a loaded machine it is both.
      for _ = 1, 40 do
        local r = request.new_from_uri(("http://127.0.0.1:%d/health"):format(PORT))
        local h, s = r:go(1)
        if h then health = s:get_body_as_string() break end
        cqueues.sleep(0.25)
      end

      if health then
        local r = request.new_from_uri(("http://127.0.0.1:%d/hello/world"):format(PORT))
        local _, s = r:go(5)
        greeting = s and s:get_body_as_string()

        local long = request.new_from_uri(
          ("http://127.0.0.1:%d/hello/%s"):format(PORT, string.rep("x", 100)))
        local hh, ss = long:go(5)
        refused = hh and hh:get ":status"
        if ss then ss:get_body_as_string() end
      end
    end)
    cq:loop(30)

    -- Stop it by port rather than by name: `pkill -f lua5.4` in a suite that
    -- spawns interpreters is a way to kill the suite. `ss` is iproute2, so
    -- the lookup itself lives in `portable`; the reason for it does not
    -- change across platforms.
    local pid = portable.pid_on_port(PORT)
    if pid then os.execute(("kill %s 2>/dev/null"):format(pid)) end

    local err = io.open(dir .. "/run.err", "r")
    local stderr = err and err:read "a" or ""
    if err then err:close() end

    assert.is_truthy(health, "the scaffolded app never answered:\n" .. stderr)
    assert.is_truthy(health:find('"ok":true', 1, true), health)
    assert.is_truthy(greeting and greeting:find('"hello":"world"', 1, true),
      tostring(greeting))
    -- The scaffold declares a schema, so the runtime refuses before the
    -- handler. A scaffold that shipped an unvalidated route would be teaching
    -- the wrong thing on line one.
    assert.equal("422", refused)
  end)
end)
